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
