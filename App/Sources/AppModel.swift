import ETSSH
import Foundation
import Observation
import SwiftUI

/// App-wide state: saved servers, the client key, and the live session.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [ServerConfig] = []
    /// nil until loaded; an error message if the Keychain failed.
    private(set) var identity: SSHIdentity?
    private(set) var identityError: String?
    let log = DebugLog()
    private(set) var session: SessionController?
    /// The server to reconnect to when the app comes back to the foreground.
    private var activeServerID: UUID?

    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }()

    init() {
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
        do {
            let identity = try KeyStore.loadOrCreate()
            self.identity = identity
            log.add("Client key loaded (\(identity.isHardwareBacked ? "Secure Enclave" : "software"))")
        } catch {
            identityError = String(describing: error)
            log.add("Client key error: \(error)")
        }
    }

    var publicKey: String {
        identity?.openSSHPublicKey(comment: "E.T.@\(UIDevice.current.name)") ?? ""
    }

    // MARK: - Servers

    func save(_ server: ServerConfig) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    func delete(_ server: ServerConfig) {
        servers.removeAll { $0.id == server.id }
        persist()
    }

    private func persist() {
        do {
            try JSONEncoder().encode(servers).write(to: storeURL, options: .atomic)
        } catch {
            log.add("Could not save servers: \(error)")
        }
    }

    // MARK: - Session

    func connect(_ server: ServerConfig) {
        guard let identity else { return }
        session?.disconnect()
        activeServerID = server.id
        let session = SessionController(server: server, identity: identity, log: log) { [weak self] updated in
            self?.save(updated)
        }
        self.session = session
        session.connect()
    }

    /// Leaves the terminal and goes back to the server list.
    func closeSession() {
        session?.disconnect()
        session = nil
        activeServerID = nil
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // SPEC §7: close the control client; the tmux session keeps running.
            session?.disconnect()
        case .active:
            if let session, session.isDisconnected,
               let id = activeServerID, let server = servers.first(where: { $0.id == id }) {
                log.add("Foreground: reconnecting")
                connect(server)
            }
        default:
            break
        }
    }
}

/// A ring buffer of log lines the user can share from the app.
@MainActor @Observable
final class DebugLog {
    private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func add(_ line: String) {
        lines.append("\(formatter.string(from: Date())) \(line)")
        if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
    }

    var text: String { lines.joined(separator: "\n") }
}
