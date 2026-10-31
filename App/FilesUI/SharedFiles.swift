import ETSSH
import Foundation
import Observation

/// The Shared Files list (PLAN-files §4.7), for the Mac sidebar and the iOS
/// Files screen: every machine's received files, merged, newest first.
/// Machines that don't answer in time are left out.
@MainActor @Observable
final class SharedFiles {
    private(set) var items: [SharedItem] = []
    private(set) var loading = false
    /// Machines that didn't answer the last time.
    private(set) var unanswered: [String] = []
    /// The last action's result, for a short notice.
    var notice: String?
    /// A fetched file to show in Quick Look.
    var preview: URL?
    /// Items with an action running, with its progress (nil = unknown).
    private(set) var busy: [String: Double?] = [:]

    /// The machines to ask, by network name, each with its own connection.
    @ObservationIgnored private let hosts: @MainActor () -> [String: IrohHost]
    /// The machine each item was listed by (its connection).
    @ObservationIgnored private var listedBy: [String: String] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let log: @MainActor (String) -> Void

    init(hosts: @escaping @MainActor () -> [String: IrohHost], log: @escaping @MainActor (String) -> Void) {
        self.hosts = hosts
        self.log = log
    }

    // MARK: - The list

    func reload() {
        guard loadTask == nil else { return }
        let hosts = hosts()
        guard !hosts.isEmpty else { return }
        loading = true
        loadTask = Task {
            defer {
                loading = false
                loadTask = nil
            }
            var merged: [SharedItem] = []
            var listedBy: [String: String] = [:]
            var unanswered: [String] = []
            await withTaskGroup(of: (String, [SharedItem]?).self) { group in
                for (name, host) in hosts {
                    group.addTask { (name, await Self.list(host)) }
                }
                for await (name, list) in group {
                    guard let list else {
                        unanswered.append(name)
                        continue
                    }
                    merged += list
                    for item in list { listedBy[item.id] = name }
                }
            }
            self.listedBy = listedBy
            self.unanswered = unanswered.sorted()
            items = merged.sorted { $0.received > $1.received }
        }
    }

    /// One machine's list, or nil if it fails or takes over 6 s.
    nonisolated private static func list(_ host: IrohHost) async -> [SharedItem]? {
        await withTaskGroup(of: [SharedItem]?.self) { group in
            group.addTask { try? await host.sharedFiles() }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func host(for item: SharedItem) throws -> IrohHost {
        let all = hosts()
        guard let host = all[listedBy[item.id] ?? item.machine] ?? all[item.machine] else {
            throw HostError.unreachable("\(item.machine) isn't connected")
        }
        return host
    }

    // MARK: - Actions

    /// Fetches the file into Caches and shows it in Quick Look (a folder
    /// opens in Finder on the Mac).
    func open(_ item: SharedItem) {
        run(item, "Fetching \(item.name)") { host, progress in
            // etd allows "." and ".." as machine names: never a path out of the cache.
            guard !["", ".", ".."].contains(item.machine), !item.machine.contains("/") else {
                throw HostError.other("bad machine name \(item.machine)")
            }
            let cache = Self.cacheFolder.standardizedFileURL.path + "/"
            let folder = Self.cacheFolder.appendingPathComponent(item.machine)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let local = URL(fileURLWithPath: try await host.fetchFile(item.path, into: folder.path, progress: progress))
            guard local.standardizedFileURL.path.hasPrefix(cache) else {
                throw HostError.other("\(item.name) landed outside the cache")
            }
            return local
        } done: { url in
            #if os(macOS)
            if item.isDir {
                NSWorkspaceBridge.reveal(url)
                return
            }
            #endif
            self.preview = url
        }
    }

    /// Types the path into a session: on the file's machine directly,
    /// else the file is sent there first (machine to machine).
    func type(_ item: SharedItem, into machine: String, session: String) {
        run(item, "Sending \(item.name) to \(machine)") { host, progress in
            try await host.shareFile(item.path, to: machine, session: session, progress: progress)
        } done: { sent in
            self.notice = sent.typed ? "Typed into \(machine)/\(session)" : "Sent to \(machine): \(sent.paths.joined(separator: " "))"
            self.reload()
        }
    }

    func send(_ item: SharedItem, to machine: String) {
        run(item, "Sending \(item.name) to \(machine)") { host, progress in
            try await host.shareFile(item.path, to: machine, session: nil, progress: progress)
        } done: { sent in
            self.notice = "Sent to \(machine): \(sent.paths.joined(separator: " "))"
            self.reload()
        }
    }

    func delete(_ item: SharedItem) {
        run(item, "Deleting \(item.name)") { host, _ in
            try await host.unshareFile(item.path)
        } done: { _ in
            self.items.removeAll { $0.id == item.id }
            self.notice = "Deleted \(item.name) on \(item.machine)"
        }
    }

    private func run<T: Sendable>(_ item: SharedItem, _ what: String,
                                  _ body: @escaping @Sendable (IrohHost, @escaping @Sendable (UInt64, UInt64) -> Void) async throws -> T,
                                  done: @escaping @MainActor (T) -> Void) {
        guard busy[item.id] == nil else { return }
        let host: IrohHost
        do {
            host = try self.host(for: item)
        } catch {
            notice = "\(item.machine) isn't connected"
            return
        }
        busy[item.id] = .some(nil)
        log("\(what) (\(item.machine):\(item.path))")
        let id = item.id
        Task {
            defer { busy[id] = nil }
            do {
                let result = try await body(host) { done, total in
                    guard total > 0 else { return }
                    let fraction = Double(done) / Double(total)
                    Task { @MainActor in if self.busy[id] != nil { self.busy[id] = fraction } }
                }
                done(result)
            } catch {
                log("\(what) failed: \(error)")
                notice = "\(what) failed: \(Self.describe(error))"
            }
        }
    }

    nonisolated static var cacheFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return caches.appendingPathComponent((Bundle.main.bundleIdentifier ?? "xyz.ericsharma.et.mac") + "/et-files")
        #else
        return caches.appendingPathComponent("et-files")
        #endif
    }

    nonisolated static func describe(_ error: any Error) -> String {
        guard let error = error as? HostError else { return String(describing: error) }
        return switch error {
        case .notPaired: "not paired"
        case .unreachable(let text), .closed(let text), .other(let text): text
        }
    }
}

#if os(macOS)
import AppKit

enum NSWorkspaceBridge {
    @MainActor static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
