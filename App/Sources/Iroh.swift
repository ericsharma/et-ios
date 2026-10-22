import ETCore
import ETSSH
import EtLink
import Foundation
import Security

// The only file that imports EtLink: its `Link`, `SessionInfo`,
// `TmuxInstall` and `ControlEvent` clash with SwiftUI, ETSSH and ETCore.

/// A pairing link, read before the user confirms it.
struct PairingTicket: Sendable, Equatable {
    var hostName: String
    var endpointId: String
    var relayURL: String?
}

/// The app's one iroh endpoint, shared by all servers (PLAN-iroh §8.4).
/// Starting it takes seconds, so it starts at launch, in the background.
final class IrohLink: @unchecked Sendable {
    static let shared = IrohLink()

    private let lock = NSLock()
    private var startTask: Task<Link, any Error>?
    private var link: Link?

    var isStarted: Bool { lock.withLock { link != nil } }

    /// Starts the endpoint if it isn't started or starting. `done` gets a
    /// line for the debug log.
    func start(done: (@Sendable (String) -> Void)? = nil) {
        let task = startIfNeeded()
        Task {
            let began = Date()
            do {
                let link = try await task.value
                done?(String(format: "iroh endpoint %@… started in %.1f s", String(link.endpointId().prefix(8)), Date().timeIntervalSince(began)))
            } catch {
                done?("iroh endpoint failed to start: \(error)")
            }
        }
    }

    private func startIfNeeded() -> Task<Link, any Error> {
        lock.withLock {
            if let startTask { return startTask }
            let task = Task { try await Link.start(secretKey: try DeviceKey.loadOrCreate()) }
            startTask = task
            return task
        }
    }

    private func started() async throws -> Link {
        let task = startIfNeeded()
        do {
            let link = try await task.value
            lock.withLock { self.link = link }
            return link
        } catch {
            // Let the next connect try again.
            lock.withLock { if startTask == task { startTask = nil } }
            throw Self.map(error)
        }
    }

    static func ticket(from url: String) throws -> PairingTicket {
        do {
            let info = try parseTicket(url: url)
            return PairingTicket(hostName: info.hostName, endpointId: info.endpointId, relayURL: info.relayUrl)
        } catch {
            throw map(error)
        }
    }

    /// Sends the pairing secret. One use: a second try with the same link fails.
    func pair(url: String, deviceName: String) async throws -> PairingTicket {
        let link = try await started()
        do {
            let paired = try await link.pair(url: url, deviceName: deviceName)
            return PairingTicket(hostName: paired.hostName, endpointId: paired.endpointId, relayURL: paired.relayUrl)
        } catch {
            throw Self.map(error)
        }
    }

    func connect(endpointId: String, relayURL: String?) async throws -> IrohHost {
        let link = try await started()
        do {
            return IrohHost(try await link.connect(endpointId: endpointId, relayUrl: relayURL))
        } catch {
            throw Self.map(error)
        }
    }

    /// LinkError → HostError, so SessionController doesn't see EtLink types.
    static func map(_ error: any Error) -> any Error {
        guard let error = error as? LinkError else { return error }
        return switch error {
        case .NotPaired: HostError.notPaired
        case .Unreachable(let message): HostError.unreachable(message)
        case .Closed(let message): HostError.closed("Connection closed: \(message)")
        case .PairingRefused(let message): HostError.other("Pairing refused: \(message)")
        case .Remote(let message): HostError.other("etd: \(message)")
        case .Invalid(let message): HostError.other("Invalid: \(message)")
        case .Protocol(let message): HostError.other("Protocol error (update etd or E.T.?): \(message)")
        }
    }
}

/// A machine reached through etd over iroh.
final class IrohHost: HostConnection, @unchecked Sendable {
    private let host: RemoteHost

    init(_ host: RemoteHost) {
        self.host = host
    }

    /// "direct", "relay", or nil while there is no path.
    var pathLabel: String? {
        switch host.path().kind {
        case .direct: "direct"
        case .relay: "relay"
        case .none: nil
        }
    }

    func findTmux() async throws -> ETSSH.TmuxInstall {
        let info = try await mapped { try await host.hello(app: AppInfo.buildLabel) }
        guard let tmux = info.tmux else {
            throw SSHConnectionError.tmuxNotFound(output: info.tmuxError ?? "")
        }
        return ETSSH.TmuxInstall(path: tmux.path, version: tmux.version, tmpDir: tmux.tmpdir)
    }

    func listSessions(tmux: ETSSH.TmuxInstall) async throws -> [ETSSH.SessionInfo] {
        try await mapped { try await host.listSessions() }.compactMap { info in
            guard let id = SessionID(token: info.id) else { return nil }
            return ETSSH.SessionInfo(id: id, name: info.name, windowCount: Int(info.windows), attachedClients: Int(info.attached))
        }
    }

    func openControlChannel(tmux: ETSSH.TmuxInstall, target: ETSSH.ControlTarget) async throws -> OpenedControl {
        let target: EtLink.ControlTarget = switch target {
        case .attach(let name): .attach(name: name)
        case .attachOrCreate(let name): .attachOrCreate(name: name)
        }
        let channel = IrohControlChannel(try await mapped { try await host.openControl(target: target) })
        return OpenedControl(channel: channel, stderr: channel.stderr)
    }

    func run(_ command: String) async throws -> (output: String, exitCode: Int) {
        let result = try await mapped { try await host.exec(script: command) }
        return (String(decoding: result.output, as: UTF8.self), Int(result.exitCode ?? -1))
    }

    func upload(_ data: Data, to path: String) async throws {
        _ = try await mapped { try await host.upload(path: path, data: data) }
    }

    func close() async {
        host.close()
    }

    /// Returns when the connection closes, with the reason.
    func waitClosed() async -> any Error {
        IrohLink.map(await host.closed())
    }

    // MARK: - manymux (PLAN-manymux §3; `machine: nil` = the hub)

    /// The hub's own host name, as etd reports it.
    func hostName() async throws -> String {
        try await mapped { try await host.hello(app: AppInfo.buildLabel) }.hostName
    }

    /// The other machines the hub watches.
    func machines() async throws -> [String] {
        try await mapped { try await host.machines() }
    }

    func mmList(machine: String?) async throws -> [MmSessionInfo] {
        try await mapped { try await host.mmList(machine: machine) }.map {
            MmSessionInfo(name: $0.name, title: $0.title, command: $0.command, attached: Int($0.attached),
                          idleSecs: Int($0.idleSecs), bells: Int($0.bells), started: Int($0.started),
                          cols: Int($0.cols), rows: Int($0.rows))
        }
    }

    /// Starts a session; returns the name it got. `command` empty = login shell.
    func mmSpawn(machine: String?, name: String?, command: [String], cols: Int, rows: Int) async throws -> String {
        let spec = MmSpawn(name: name, command: command, cwd: nil, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
        return try await mapped { try await host.mmSpawn(machine: machine, spec: spec) }
    }

    func mmKill(machine: String?, name: String) async throws {
        try await mapped { try await host.mmKill(machine: machine, name: name) }
    }

    func mmRename(machine: String?, name: String, to newName: String) async throws {
        try await mapped { try await host.mmRename(machine: machine, name: name, to: newName) }
    }

    func mmAttach(machine: String?, name: String, cols: Int, rows: Int, history: Int, readOnly: Bool) async throws -> MmAttachHandle {
        let attachment = try await mapped {
            try await host.mmAttach(machine: machine, name: name, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows),
                                    history: UInt32(clamping: history), readOnly: readOnly)
        }
        return MmAttachHandle(attachment)
    }

    /// Screens for thumbnails and instant paints; `names` empty = all.
    func mmPeek(machine: String?, names: [String]) async throws -> [MmScreen] {
        try await mapped { try await host.mmPeek(machine: machine, names: names) }.map {
            MmScreen(name: $0.name, cols: Int($0.cols), rows: Int($0.rows), bytes: Array($0.screen.utf8))
        }
    }

    /// `run`, on another machine (through ssh from the hub).
    func run(_ script: String, on machine: String) async throws -> (output: String, exitCode: Int) {
        let result = try await mapped { try await host.execOn(machine: machine, script: script) }
        return (String(decoding: result.output, as: UTF8.self), Int(result.exitCode ?? -1))
    }

    func mmEvents() async throws -> MmEventFeed {
        MmEventFeed(try await mapped { try await host.mmEvents() })
    }
}

/// A manymux session, as `mmList` reports it.
struct MmSessionInfo: Sendable, Equatable, Identifiable {
    var name: String
    /// What the program says it is doing (its terminal title).
    var title: String
    var command: String
    var attached: Int
    var idleSecs: Int
    var bells: Int
    var started: Int
    var cols: Int
    var rows: Int
    var id: String { name }
}

/// A session's screen from `mmPeek`: bytes that paint `cols` x `rows`.
struct MmScreen: Sendable {
    var name: String
    var cols: Int
    var rows: Int
    var bytes: [UInt8]
}

/// What a manymux event says happened.
enum MmEventKindInfo: Sendable, Equatable {
    case bell, notify(title: String, body: String), titleChanged(String), exited(Int), started
}

struct MmEventInfo: Sendable, Equatable {
    /// A host name; the hub's own name for the hub.
    var machine: String
    var session: String
    var title: String
    var kind: MmEventKindInfo
    var attached: Int

    init(_ event: MmEvent) {
        machine = event.machine
        session = event.session
        title = event.title
        attached = Int(event.attached)
        kind = switch event.kind {
        case .bell: .bell
        case .notify(let title, let body): .notify(title: title, body: body)
        case .titleChanged(let title): .titleChanged(title)
        case .exited(let code): .exited(Int(code))
        case .started: .started
        }
    }
}

/// Output of an attached manymux session.
enum MmOut: Sendable {
    /// Terminal bytes; the first after attaching repaints the screen.
    case data([UInt8])
    /// Scrollback, before the first `data`.
    case history([UInt8])
    /// The whole screen again: reset, then feed.
    case resync([UInt8])
    /// The size the session took.
    case size(cols: Int, rows: Int)
    case event(MmEventInfo)
    case renamed(name: String?, refused: String?)
    case exit(Int)
}

/// One attached manymux session (its own stream).
final class MmAttachHandle: @unchecked Sendable {
    private let attachment: MmAttachment

    init(_ attachment: MmAttachment) {
        self.attachment = attachment
    }

    var cols: Int { Int(attachment.cols()) }
    var rows: Int { Int(attachment.rows()) }

    func next() async throws -> MmOut {
        switch try await mapped({ try await attachment.next() }) {
        case .data(let bytes): .data(Array(bytes))
        case .history(let bytes): .history(Array(bytes))
        case .resync(let bytes): .resync(Array(bytes))
        case .size(let cols, let rows): .size(cols: Int(cols), rows: Int(rows))
        case .event(let event): .event(MmEventInfo(event))
        case .renamed(let name, let refused): .renamed(name: name, refused: refused)
        case .exit(let code): .exit(Int(code))
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        try await mapped { try await attachment.write(bytes: Data(bytes)) }
    }

    func resize(cols: Int, rows: Int) async throws {
        try await mapped { try await attachment.resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows)) }
    }

    func rename(to name: String) async throws {
        try await mapped { try await attachment.rename(to: name) }
    }

    /// `kind`: the file extension (png, jpg, gif, webp).
    func paste(kind: String, bytes: Data) async throws {
        try await mapped { try await attachment.paste(kind: kind, bytes: bytes) }
    }

    /// Leaves the session running.
    func detach() async {
        await attachment.detach()
    }
}

/// The hub's manymux event feed (all machines).
final class MmEventFeed: @unchecked Sendable {
    private let events: MmEvents

    init(_ events: MmEvents) {
        self.events = events
    }

    func next() async throws -> MmEventInfo {
        MmEventInfo(try await mapped { try await events.next() })
    }

    func close() async {
        await events.close()
    }
}

/// `tmux -C` on an etd control stream.
final class IrohControlChannel: ControlChannel, @unchecked Sendable {
    private let control: ControlStream
    private let stream: AsyncThrowingStream<[UInt8], any Error>
    let stderr: AsyncStream<String>

    init(_ control: ControlStream) {
        self.control = control
        let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream(bufferingPolicy: .unbounded)
        let (stderr, stderrContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(200))
        self.stream = stream
        self.stderr = stderr
        Task {
            do {
                loop: while true {
                    switch try await control.next() {
                    case .stdout(let bytes): continuation.yield(Array(bytes))
                    case .stderr(let line): stderrContinuation.yield(line)
                    case .exit: break loop
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: IrohLink.map(error))
            }
            stderrContinuation.finish()
        }
    }

    func incoming() -> AsyncThrowingStream<[UInt8], any Error> {
        stream
    }

    func write(_ bytes: [UInt8]) async throws {
        try await mapped { try await control.write(bytes: Data(bytes)) }
    }

    /// Closes tmux's stdin. tmux detaches; the session keeps running.
    func close() async {
        await control.finish()
    }
}

private func mapped<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch {
        throw IrohLink.map(error)
    }
}

/// The device's iroh key: 32 bytes in the Keychain, this device only,
/// readable after the first unlock (PLAN-iroh §6.2). One key for all machines.
enum DeviceKey {
    private static let service = "xyz.ericsharma.et.iroh-key"
    private static let account = "default"

    static func loadOrCreate() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        let key = generateSecretKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return key
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }
}
