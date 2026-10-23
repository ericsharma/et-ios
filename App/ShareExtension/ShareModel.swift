import Foundation
import Observation
import UniformTypeIdentifiers

/// The share extension's state: the shared files (copied to our temporary
/// folder), the machine and session picked, and the send.
///
/// Up to `ShareStore.extensionLimit` the extension sends itself; above it
/// the files go to the App Group outbox and the app sends them when it is
/// next opened (iOS may stop an extension during a long send).
@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case picking
        case sending
        case sent(String)
        case queued
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var files: [URL] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var skipped = 0
    let machines = ShareStore.loadMachines()
    var machine: ShareStore.Machine? {
        didSet {
            if machine != oldValue {
                session = nil
                connect()
            }
        }
    }
    /// nil: no session, only ~/etd-downloads.
    var session: String?
    /// Sessions as the machine reports them now (the cache until then).
    private(set) var sessions: [ShareStore.Session] = []
    private(set) var connecting = false
    private(set) var connectError: String?
    private(set) var fraction: Double?

    @ObservationIgnored private var host: IrohHost?
    @ObservationIgnored private var hostFor: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let finish: () -> Void

    init(finish: @escaping () -> Void) {
        self.finish = finish
    }

    var label: String { files.count == 1 ? files[0].lastPathComponent : "\(files.count) files" }
    var isLarge: Bool { totalBytes > ShareStore.extensionLimit }

    // MARK: - The shared items

    func load(_ providers: [NSItemProvider]) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var taken = Set<String>()
        for provider in providers {
            guard let copy = await Self.copy(provider, into: folder, taken: taken) else {
                skipped += 1
                continue
            }
            taken.insert(copy.lastPathComponent)
            files.append(copy)
            totalBytes += Int64((try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        phase = .picking
        if machines.count == 1 { machine = machines[0] }
    }

    /// The item as a file in `folder`: a file URL (Files) or a file
    /// representation (Photos and most apps). Text and web links are skipped.
    private static func copy(_ provider: NSItemProvider, into folder: URL, taken: Set<String>) async -> URL? {
        let fileURL = UTType.fileURL.identifier
        let type = provider.hasItemConformingToTypeIdentifier(fileURL) ? fileURL
            : provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true }
        guard let type else { return nil }
        return await withCheckedContinuation { continuation in
            let place: @Sendable (URL?) -> Void = { source in
                guard let source else { return continuation.resume(returning: nil) }
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let target = folder.appendingPathComponent(freeName(source.lastPathComponent, taken: taken))
                continuation.resume(returning: (try? FileManager.default.copyItem(at: source, to: target)) != nil ? target : nil)
            }
            if type == fileURL {
                _ = provider.loadItem(forTypeIdentifier: fileURL) { item, _ in
                    place((item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            } else {
                // The URL is valid only inside the handler: copy there.
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in place(url) }
            }
        }
    }

    nonisolated private static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while taken.contains(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)") { n += 1 }
        return ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
    }

    // MARK: - Machine and session

    /// Connects to the picked machine and lists its sessions now.
    private func connect() {
        guard let machine else { return }
        sessions = machine.sessions
        connectError = nil
        guard !isLarge else { return } // the app sends; no connection needed
        connecting = true
        Task {
            defer { if self.machine == machine { connecting = false } }
            do {
                let host = try await IrohLink.shared.connect(endpointId: machine.endpointId, relayURL: machine.relayURL)
                guard self.machine == machine else { return await host.close() }
                self.host = host
                hostFor = machine.name
                let live = try await host.mmList(machine: nil)
                guard self.machine == machine else { return }
                sessions = live.map { ShareStore.Session(name: $0.name, title: $0.title) }
            } catch {
                guard self.machine == machine else { return }
                connectError = Self.describe(error)
            }
        }
    }

    // MARK: - Send

    func send() {
        guard let machine, !files.isEmpty else { return }
        if isLarge {
            do {
                try ShareStore.addJob(files, machine: machine.name, session: session)
                phase = .queued
            } catch {
                phase = .failed("Couldn't hand the files to E.T.: \(error.localizedDescription)")
            }
            return
        }
        phase = .sending
        fraction = nil
        let session = session
        let paths = files.map(\.path)
        task = Task {
            do {
                let host: IrohHost
                if let current = self.host, hostFor == machine.name {
                    host = current
                } else {
                    host = try await IrohLink.shared.connect(endpointId: machine.endpointId, relayURL: machine.relayURL)
                }
                let sent = try await host.sendFiles(paths, session: session) { done, total in
                    guard total > 0 else { return }
                    let fraction = Double(done) / Double(total)
                    Task { @MainActor in self.fraction = fraction }
                }
                guard !Task.isCancelled else { return }
                phase = .sent(sent.paths.joined(separator: "\n"))
                try? await Task.sleep(for: .seconds(1.5))
                close()
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    func close() {
        task?.cancel()
        if let host { Task { await host.close() } }
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        finish()
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}
