import AppKit
import ETCore
import ETSSH
import Foundation
import Observation
import UserNotifications

/// A session on a machine, as windows and the sidebar address it.
struct SessionRef: Hashable, Codable, Sendable {
    var machine: String
    var name: String
    var id: String { machine + "/" + name }
}

/// App-wide state: the paired hub, every machine's sessions, and the
/// attached terminals. The manymux half of the iOS app's SessionController,
/// without tmux (PLAN-mac §3).
///
/// Routing is the same as on iOS: the hub and the network's machines answer
/// for themselves (`machine: nil` on their own connection); machines the hub
/// reaches by ssh go through the hub by name.
@MainActor @Observable
final class Fleet {
    enum Phase: Equatable {
        case unpaired
        case connecting(String)
        case ready
        case failed(String)
    }

    private(set) var hub: ServerConfig?
    private(set) var phase: Phase = .unpaired
    private(set) var machines: [MmMachine] = []
    private(set) var network: NetInfo?
    private(set) var hubName: String?
    /// A short message at the bottom of the window (spawn failed, bell…).
    private(set) var notice: String?
    /// A session to show (a tapped notification); the front window takes it.
    var requestedRef: SessionRef?
    /// File sends in progress, and finished machine sends still showing
    /// their paths (PLAN-files F5).
    private(set) var sends: [FileSend] = []
    /// Files waiting for a machine: File → Send File…, or a drop on the Dock
    /// icon. The Send Files window shows them.
    var pendingSend: [URL] = []
    let log = DebugLog()

    /// Attached (or attaching) sessions. The newest few stay attached so
    /// switching back is instant; older ones detach.
    private(set) var terminals: [SessionRef: SessionTerminal] = [:]
    private var recent: [SessionRef] = []
    private static let keepAttached = 4

    private var hubHost: IrohHost?
    private var hubHostName: String?
    private var mmHosts: [String: IrohHost] = [:]
    private var mmHostNames: [String: String] = [:]
    private var mmHostErrors: [String: String] = [:]
    private var mmConnecting: Set<String> = []
    private var mmLastTry: [String: Date] = [:]
    private var feeds: [String: MmEventFeed] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var networkLoaded: Date?
    private var refreshTask: Task<Void, Never>?
    private var refreshAll = false
    private var refreshNames: Set<String> = []
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    private static let storeURL: URL = {
        return AppDirectory.url.appendingPathComponent("hub.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let saved = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            hub = saved
        }
        IrohLink.shared.start { [log] line in Task { @MainActor in log.add(line) } }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeUp() }
        }
        if hub != nil { connect() }
    }

    // MARK: - The hub (this Mac's etd, paired by Setup)

    /// The app paired with an etd (its own Mac's): save it and connect.
    func adopt(name: String, endpointId: String, relayURL: String?) {
        var server = ServerConfig(name: name, host: name, port: 0, user: "")
        server.irohEndpointId = endpointId
        server.irohRelayURL = relayURL
        save(server)
        connect()
    }

    /// Forgets the hub (this Mac stays a member of the network until `etd revoke`).
    func unpair() {
        disconnect()
        hub = nil
        try? FileManager.default.removeItem(at: Self.storeURL)
        phase = .unpaired
    }

    private func save(_ server: ServerConfig) {
        hub = server
        do {
            try JSONEncoder().encode(server).write(to: Self.storeURL, options: .atomic)
        } catch {
            log.add("Could not save the hub: \(error)")
        }
    }

    // MARK: - Connection

    func connect() {
        guard let hub, let endpoint = hub.irohEndpointId else {
            phase = .unpaired
            return
        }
        disconnect()
        phase = .connecting("Connecting to \(hub.name)…")
        let task = Task {
            do {
                let host = try await IrohLink.shared.connect(endpointId: endpoint, relayURL: hub.irohRelayURL)
                guard !Task.isCancelled else {
                    await host.close()
                    return
                }
                hubHost = host
                log.add("Connected to \(hub.name), \(host.pathLabel ?? "no path yet")")
                try await start(host)
            } catch {
                guard !Task.isCancelled else { return }
                log.add("Connect failed: \(error)")
                phase = .failed(Self.describe(error))
                scheduleReconnect()
            }
        }
        tasks.append(task)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        for task in tasks { task.cancel() }
        tasks = []
        refreshTask?.cancel()
        refreshTask = nil
        for terminal in terminals.values { terminal.detach() }
        let hosts = Array(mmHosts.values) + [hubHost].compactMap { $0 }
        let oldFeeds = Array(feeds.values)
        Task {
            for feed in oldFeeds { await feed.close() }
            for host in hosts { await host.close() }
        }
        hubHost = nil
        mmHosts = [:]
        mmHostNames = [:]
        mmConnecting = []
        feeds = [:]
    }

    private func start(_ host: IrohHost) async throws {
        phase = .connecting("Loading machines…")
        let hostName = try await host.hostName()
        hubHostName = hostName
        await loadNetwork(host)
        hubName = network?.members.first { $0.endpointId == hub?.irohEndpointId }?.name ?? hostName
        connectNetworkMachines()
        // Give the network machines a moment, so the first list has them.
        for _ in 0..<25 where !mmConnecting.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await refreshMachines()
        guard hubHost === host else { return }
        phase = .ready
        reconnectAttempt = 0
        tasks.append(Task { [weak self] in
            let error = await host.waitClosed()
            self?.hubClosed(host, error: error)
        })
        startEvents(host, machine: hubName ?? hostName)
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, self.hubHost === host else { return }
                await self.refreshMachines()
            }
        })
        // While E.T. is the front app, the machines send no pushes to the phone.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.hubHost === host else { return }
                if NSApp.isActive {
                    try? await host.foreground(seconds: 60)
                    for member in self.mmHosts.values { Task { try? await member.foreground(seconds: 60) } }
                }
                try? await Task.sleep(for: .seconds(20))
            }
        })
        for (ref, terminal) in terminals where recent.contains(ref) { reattach(terminal) }
    }

    private func hubClosed(_ host: IrohHost, error: any Error) {
        guard hubHost === host else { return }
        log.add("Connection ended: \(error)")
        phase = .failed(Self.describe(error))
        disconnect()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard hub != nil, reconnectTask == nil else { return }
        let delays = [1, 2, 5, 10, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            reconnectTask = nil
            connect()
        }
    }

    private func wokeUp() {
        guard hub != nil else { return }
        log.add("Woke from sleep: reconnecting")
        reconnectAttempt = 0
        connect()
    }

    // MARK: - Routing

    private func route(_ machine: String) throws -> (host: IrohHost, machine: String?) {
        guard let hub = hubHost else { throw HostError.unreachable("Not connected") }
        if machine == hubName { return (hub, nil) }
        guard networkMachines.contains(where: { $0.name == machine }) else { return (hub, machine) }
        guard let host = mmHosts[machine] else {
            throw HostError.unreachable(mmConnecting.contains(machine) ? "Connecting…" : "Not reachable: \(mmHostErrors[machine] ?? "not connected")")
        }
        return (host, nil)
    }

    /// Every machine with its own connection (hub and network machines),
    /// by name: the Shared Files list asks each.
    func directHosts() -> [String: IrohHost] {
        var hosts = mmHosts
        if let hubHost, let hubName { hosts[hubName] = hubHost }
        return hosts
    }

    /// The network's machines other than the hub, by name.
    private var networkMachines: [NetMember] {
        (network?.members ?? [])
            .filter { $0.isMachine && $0.endpointId != hub?.irohEndpointId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A script on a machine.
    func run(_ script: String, on machine: String) async throws -> (output: String, exitCode: Int) {
        let route = try route(machine)
        if let name = route.machine { return try await route.host.run(script, on: name) }
        return try await route.host.run(script)
    }

    /// Sends local files and folders to ~/etd-downloads on a machine. It
    /// shows on the session's terminal (`session`), or under the machine in
    /// the sidebar; `delivered` runs when it is done.
    @discardableResult
    func send(_ urls: [URL], to machine: String, session: String?,
              delivered: @escaping (SentFiles) -> Void = { _ in }) -> FileSend? {
        guard !urls.isEmpty else { return nil }
        let host: IrohHost
        do {
            let (routed, api) = try route(machine)
            guard api == nil else { throw HostError.other("\(machine) is reached by ssh; files can't be sent there yet") }
            host = routed
        } catch {
            flash("Can't send to \(machine): \(Self.describe(error))")
            return nil
        }
        let send = FileSend(machine: machine, session: session, names: urls.map(\.lastPathComponent))
        sends.append(send)
        log.add("Sending \(urls.count) item(s) to \(machine)\(session.map { "/" + $0 } ?? "")")
        let paths = urls.map(\.path)
        send.task = Task {
            // The machine reads the files during the send: keep access
            // to dropped files until it returns.
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await host.sendFiles(paths, session: session) { done, total in
                    Task { @MainActor in send.progress(done: done, total: total) }
                }
                guard !send.cancelled else { return }
                log.add("Sent to \(machine): \(result.paths.joined(separator: " "))\(result.typed ? " (typed by etd)" : "")")
                if session == nil {
                    send.paths = result.paths
                } else {
                    sends.removeAll { $0 === send }
                }
                delivered(result)
            } catch {
                guard !send.cancelled else { return }
                log.add("Send to \(machine) failed: \(error)")
                if session == nil {
                    send.error = Self.describe(error)
                } else {
                    sends.removeAll { $0 === send }
                    flash("Send failed: \(Self.describe(error))")
                }
            }
        }
        return send
    }

    /// Stops a send, or hides a finished one.
    func dismiss(_ send: FileSend) {
        if send.isRunning {
            send.cancelled = true
            send.task?.cancel()
            log.add("Send to \(send.machine) cancelled")
        }
        sends.removeAll { $0 === send }
    }

    func sends(to machine: String, session: String?) -> [FileSend] {
        sends.filter { $0.machine == machine && $0.session == session }
    }

    /// Files for the Send Files window (no duplicates).
    func queueSend(_ urls: [URL]) {
        for url in urls where !pendingSend.contains(url) { pendingSend.append(url) }
    }

    // MARK: - The etd network

    private func loadNetwork(_ hub: IrohHost) async {
        networkLoaded = Date()
        do {
            let info = try await hub.network()
            guard hubHost === hub else { return }
            if info != network {
                log.add("Network \(info.name): \(info.members.map(\.name).joined(separator: ", "))")
                network = info
            }
        } catch {
            log.add("Network: \(error)")
        }
    }

    func reloadNetwork() async {
        guard let hubHost else { return }
        await loadNetwork(hubHost)
    }

    /// An `et://pair` link for a new device (or `etd join` for a machine).
    func invite(machine: Bool) async throws -> String {
        guard let hubHost else { throw HostError.unreachable("Not connected") }
        return try await hubHost.invite(machine: machine)
    }

    private func connectNetworkMachines() {
        guard let hub = hubHost else { return }
        let members = networkMachines
        for name in mmHosts.keys where !members.contains(where: { $0.name == name }) {
            log.add("\(name) left the network")
            dropMember(name)
        }
        for member in members where mmHosts[member.name] == nil && !mmConnecting.contains(member.name) {
            if let last = mmLastTry[member.name], Date().timeIntervalSince(last) < 15 { continue }
            let name = member.name
            mmConnecting.insert(name)
            mmLastTry[name] = Date()
            Task {
                defer { self.mmConnecting.remove(name) }
                do {
                    let host = try await IrohLink.shared.connect(endpointId: member.endpointId, relayURL: nil)
                    let hostName = try await host.hostName()
                    guard self.hubHost === hub, self.networkMachines.contains(member) else {
                        await host.close()
                        return
                    }
                    self.log.add("Connected to \(name) (\(hostName)), \(host.pathLabel ?? "no path yet")")
                    self.mmHosts[name] = host
                    self.mmHostNames[name] = hostName
                    self.mmHostErrors[name] = nil
                    self.startEvents(host, machine: name)
                    self.tasks.append(Task { [weak self] in
                        let error = await host.waitClosed()
                        guard let self, self.mmHosts[name] === host else { return }
                        self.log.add("\(name): connection ended: \(error)")
                        self.dropMember(name)
                        self.mmHostErrors[name] = Self.describe(error)
                        self.scheduleRefresh(name)
                    })
                    self.scheduleRefresh(name)
                } catch {
                    self.log.add("\(name): \(error)")
                    self.mmHostErrors[name] = Self.describe(error)
                }
            }
        }
    }

    private func dropMember(_ name: String) {
        let host = mmHosts.removeValue(forKey: name)
        let feed = feeds.removeValue(forKey: name)
        mmHostNames[name] = nil
        Task {
            await feed?.close()
            await host?.close()
        }
    }

    // MARK: - Lists

    /// Every machine's sessions, in parallel: the hub, the network's
    /// machines by name, then machines the hub reaches by ssh.
    func refreshMachines() async {
        guard let host = hubHost, let hub = hubName else { return }
        if networkLoaded.map({ Date().timeIntervalSince($0) > 30 }) ?? true { await loadNetwork(host) }
        connectNetworkMachines()
        let networkNames = networkMachines.map(\.name)
        var names = [hub] + networkNames
        do {
            names += try await host.machines().filter { $0 != hub && $0 != hubHostName && !networkNames.contains($0) }
        } catch {
            log.add("machines: \(error)")
        }
        let routes = names.map { name in Result { try route(name) } }
        let listed = await withTaskGroup(of: (Int, MmMachine).self) { group in
            for (i, name) in names.enumerated() {
                let route = routes[i]
                group.addTask {
                    do {
                        let (host, machine) = try route.get()
                        return (i, MmMachine(name: name, sessions: try await host.mmList(machine: machine)))
                    } catch {
                        return (i, MmMachine(name: name, sessions: [], error: Self.describe(error)))
                    }
                }
            }
            var out: [(Int, MmMachine)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard hubHost === host else { return }
        if listed != machines { machines = listed }
        updateBadge()
    }

    private func refreshMachine(_ name: String) async {
        guard let host = hubHost else { return }
        guard machines.contains(where: { $0.name == name }) else {
            await refreshMachines()
            return
        }
        let listed: MmMachine
        do {
            let (target, machine) = try route(name)
            listed = MmMachine(name: name, sessions: try await target.mmList(machine: machine))
        } catch {
            listed = MmMachine(name: name, sessions: [], error: Self.describe(error))
        }
        guard hubHost === host, let i = machines.firstIndex(where: { $0.name == name }) else { return }
        if machines[i] != listed { machines[i] = listed }
        updateBadge()
    }

    /// Events come in bursts (title changes); one list a second is enough.
    func scheduleRefresh(_ machine: String? = nil) {
        if let machine { refreshNames.insert(machine) } else { refreshAll = true }
        guard refreshTask == nil else { return }
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(1))
            refreshTask = nil
            let all = refreshAll, names = refreshNames
            refreshAll = false
            refreshNames = []
            guard !Task.isCancelled else { return }
            if all {
                await refreshMachines()
            } else {
                for name in names.sorted() { await refreshMachine(name) }
            }
        }
    }

    func info(for ref: SessionRef) -> MmSessionInfo? {
        machines.first { $0.name == ref.machine }?.sessions.first { $0.name == ref.name }
    }

    /// Sessions with a bell nobody has seen.
    var bellCount: Int {
        machines.reduce(0) { $0 + $1.sessions.filter { $0.bells > 0 }.count }
    }

    private func updateBadge() {
        let count = bellCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Events

    private func startEvents(_ host: IrohHost, machine: String) {
        let hub = hubHost
        let alive = { [weak self] in
            guard let self, self.hubHost === hub, hub != nil else { return false }
            return host === hub || self.mmHosts[machine] === host
        }
        tasks.append(Task {
            while !Task.isCancelled, alive() {
                do {
                    let feed = try await host.mmEvents()
                    guard alive() else {
                        await feed.close()
                        return
                    }
                    self.feeds[machine] = feed
                    while true {
                        var event = try await feed.next()
                        if host === hub {
                            // The hub's own events, and those of machines it reaches by ssh.
                            if event.machine == self.hubHostName { event.machine = machine }
                            if self.networkMachines.contains(where: { $0.name == event.machine })
                                || self.mmHostNames.values.contains(event.machine) { continue }
                        } else {
                            guard event.machine == self.mmHostNames[machine] || event.machine == machine else { continue }
                            event.machine = machine
                        }
                        self.handle(event)
                    }
                } catch {
                    guard alive() else { return }
                    self.log.add("events (\(machine)): \(error)")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        })
    }

    private func handle(_ event: MmEventInfo) {
        switch event.kind {
        case .bell, .notify:
            let ref = SessionRef(machine: event.machine, name: event.session)
            if let terminal = terminals[ref], terminal.isVisible, NSApp.isActive { break }
            notify(ref, title: event.title)
            scheduleRefresh(event.machine)
        case .titleChanged, .exited, .started:
            scheduleRefresh(event.machine)
        }
    }

    /// A bell in a session you aren't looking at: a notification while E.T.
    /// is in the background, a notice while it's in front.
    private func notify(_ ref: SessionRef, title: String) {
        if NSApp.isActive {
            flash("\(ref.id) needs you")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = ref.id
        content.body = title.isEmpty ? "Needs you" : title
        content.userInfo = ["machine": ref.machine, "session": ref.name]
        content.sound = .default
        let request = UNNotificationRequest(identifier: ref.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice == text { notice = nil }
        }
    }

    // MARK: - Terminals

    /// The terminal for a session, attached. Older terminals beyond
    /// `keepAttached` detach (they attach again when shown).
    func terminal(for ref: SessionRef) -> SessionTerminal {
        let terminal = terminals[ref] ?? {
            let new = SessionTerminal(ref: ref, fleet: self)
            terminals[ref] = new
            return new
        }()
        recent.removeAll { $0 == ref }
        recent.append(ref)
        while recent.count > Self.keepAttached {
            let old = recent.removeFirst()
            if let t = terminals[old], !t.isVisible { t.detach() }
        }
        if !terminal.isAttached, phase == .ready { reattach(terminal) }
        return terminal
    }

    func reattach(_ terminal: SessionTerminal) {
        do {
            let (host, machine) = try route(terminal.ref.machine)
            terminal.attach(host: host, machine: machine)
        } catch {
            terminal.failed(Self.describe(error))
        }
    }

    /// The session ended: drop its terminal and list its machine again.
    func ended(_ ref: SessionRef) {
        terminals[ref] = nil
        recent.removeAll { $0 == ref }
        scheduleRefresh(ref.machine)
    }

    func renamed(_ ref: SessionRef, to name: String) {
        guard let terminal = terminals.removeValue(forKey: ref) else { return }
        var new = ref
        new.name = name
        terminals[new] = terminal
        recent = recent.map { $0 == ref ? new : $0 }
        scheduleRefresh(ref.machine)
    }

    // MARK: - Spawn, rename, end

    /// Starts a session; returns where it is, for the window to show it.
    func spawn(machine: String, name: String?, command: [String], cols: Int, rows: Int) async -> SessionRef? {
        do {
            let (host, api) = try route(machine)
            let got = try await host.mmSpawn(machine: api, name: name, command: command, cols: cols, rows: rows)
            log.add("Spawned \(machine)/\(got): \(command.isEmpty ? "shell" : command.joined(separator: " "))")
            await refreshMachine(machine)
            return SessionRef(machine: machine, name: got)
        } catch {
            log.add("Spawn failed: \(error)")
            flash("Couldn't start: \(Self.describe(error))")
            return nil
        }
    }

    func rename(_ ref: SessionRef, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != ref.name else { return }
        if let terminal = terminals[ref], terminal.isAttached {
            terminal.rename(to: newName)
            return
        }
        Task {
            do {
                let (host, api) = try route(ref.machine)
                try await host.mmRename(machine: api, name: ref.name, to: newName)
            } catch {
                flash("Rename failed: \(Self.describe(error))")
            }
            await refreshMachine(ref.machine)
        }
    }

    func end(_ ref: SessionRef) {
        Task {
            do {
                let (host, api) = try route(ref.machine)
                try await host.mmKill(machine: api, name: ref.name)
                log.add("Ended \(ref.id)")
            } catch {
                flash("Couldn't end \(ref.name): \(Self.describe(error))")
            }
            await refreshMachine(ref.machine)
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case HostError.other(let detail), HostError.closed(let detail), HostError.unreachable(let detail): detail
        case HostError.notPaired: "This Mac isn't paired with that machine (or it was revoked). Pair again with a new `etd invite` link."
        default: "\(error)"
        }
    }
}

/// A ring buffer of log lines (Help → Debug Log).
@MainActor @Observable
final class DebugLog {
    private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Also written to ~/Library/Logs/et-mac.log.
    @ObservationIgnored private let fileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("et-mac.log")
    }()
    @ObservationIgnored private lazy var file: FileHandle? = {
        guard let fileURL else { return nil }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    func add(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)"
        lines.append(stamped)
        if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
        try? file?.write(contentsOf: Data((stamped + "\n").utf8))
    }

    var text: String { lines.joined(separator: "\n") }
}

/// One `sendFiles` call: its progress, then its paths or error.
@MainActor @Observable
final class FileSend: Identifiable {
    let machine: String
    let session: String?
    let names: [String]
    private(set) var done: UInt64 = 0
    private(set) var total: UInt64 = 0
    /// Where the items landed (machine sends; session sends type them).
    var paths: [String]?
    var error: String?
    @ObservationIgnored var cancelled = false
    @ObservationIgnored var task: Task<Void, Never>?

    init(machine: String, session: String?, names: [String]) {
        self.machine = machine
        self.session = session
        self.names = names
    }

    var isRunning: Bool { paths == nil && error == nil }

    var label: String { names.count == 1 ? names[0] : "\(names.count) items" }

    /// 0…1, nil before the size is known.
    var fraction: Double? { total == 0 ? nil : Double(done) / Double(total) }

    /// `done` comes from the machine and starts from 0 again on a resend.
    func progress(done: UInt64, total: UInt64) {
        guard isRunning else { return }
        self.done = done
        self.total = total
    }
}
