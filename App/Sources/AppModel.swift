import ETSSH
import Foundation
import Network
import Observation
import SwiftUI

/// A file opened in E.T. from AirDrop, Files or the share sheet, waiting
/// for the user to pick a window.
struct IncomingFile: Identifiable {
    let id = UUID()
    let name: String
    /// Our own copy (SessionController.stage), deleted after the send.
    let url: URL
}

/// An `et://pair` link waiting for the user to confirm it.
struct PendingPairing: Identifiable {
    let id = UUID()
    let url: String
    let ticket: PairingTicket
}

/// App-wide state: saved servers, the client key, and the live session.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [ServerConfig] = []
    /// nil until loaded; an error message if the Keychain failed.
    private(set) var identity: SSHIdentity?
    private(set) var identityError: String?
    let log = DebugLog()
    private(set) var session: SessionController?
    /// A file opened in E.T., until it's sent to a window.
    var incomingFile: IncomingFile?
    /// A pairing link the confirm sheet shows.
    var pendingPairing: PendingPairing?
    /// Set while pairing runs, or to the error when it failed.
    private(set) var pairingStatus: String?
    private(set) var isPairing = false
    /// The server to reconnect to when the app comes back to the foreground.
    private var activeServerID: UUID?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Window templates per server (SPEC §6.4).
    private var templatesByServer: [UUID: [WindowTemplate]] = [:]
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?

    private static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let storeURL = AppModel.supportDir.appendingPathComponent("servers.json")
    private let templatesURL = AppModel.supportDir.appendingPathComponent("templates.json")

    init() {
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
        if let data = try? Data(contentsOf: templatesURL),
           let saved = try? JSONDecoder().decode([UUID: [WindowTemplate]].self, from: data) {
            templatesByServer = saved
        }
        startPathMonitor()
        // One endpoint for all iroh servers; it takes seconds, so start it now.
        IrohLink.shared.start { [log] line in Task { @MainActor in log.add(line) } }
        do {
            let identity = try KeyStore.loadOrCreate()
            self.identity = identity
            log.add("Client key loaded (\(identity.isHardwareBacked ? "Secure Enclave" : "software"))")
        } catch {
            identityError = String(describing: error)
            log.add("Client key error: \(error)")
        }
        // SPEC §7: on launch, connect to the server used last (unless a
        // tapped notification already chose one above).
        if session == nil, let id = UserDefaults.standard.string(forKey: "lastServerID").flatMap(UUID.init(uuidString:)),
           let server = servers.first(where: { $0.id == id }) {
            connect(server)
        }
        for line in Push.traceLines.suffix(8) { log.add("push trace: \(line)") }
        // Last: a tap that launched the app is delivered now, with the key
        // loaded and the session (if any) already starting.
        Push.shared.onOpen = { [weak self] request in self?.open(request) }
    }

    /// A file opened in E.T. ("Open in…"): kept until the user picks a
    /// window for it.
    func receive(_ url: URL) {
        if url.scheme == "et" {
            receivePairingLink(url.absoluteString)
            return
        }
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // A copy on disk, not in memory: the file can be large.
            let copy = try SessionController.stage(copyOf: url)
            incomingFile = IncomingFile(name: url.lastPathComponent, url: copy)
            log.add("Opened file \(url.lastPathComponent)")
            // iOS copied it into our Inbox; the send uses its own copy.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        } catch {
            log.add("Couldn't read opened file: \(error)")
        }
    }

    /// A tapped notification: connect to its server and session if needed,
    /// then open its window.
    private func open(_ request: Push.OpenRequest) {
        guard var server = servers.first(where: { $0.id == request.server })
                ?? session?.server ?? servers.first else { return }
        if let target = request.manymux {
            log.add("Notification: manymux \(target.machine)/\(target.session)")
            Push.shared.pendingManymux = target
            if let session, session.server.id == server.id {
                if session.isDisconnected { session.reconnect() }
                session.openPendingWindow()
            } else {
                connect(server)
            }
            return
        }
        log.add("Notification: \(request.window ?? "?") in \(request.session ?? "?")")
        Push.shared.pendingWindowName = request.window
        if let session, session.server.id == server.id,
           request.session == nil || session.sessionName == request.session {
            if session.isDisconnected { session.reconnect() }
            session.openPendingWindow()
            return
        }
        if let name = request.session {
            server.lastSession = name
            save(server)
        }
        connect(server)
    }

    // MARK: - Pairing (etd)

    /// An `et://pair?t=…` link, from the Camera app or pasted: shows the
    /// confirm sheet.
    func receivePairingLink(_ text: String) {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let ticket = try IrohLink.ticket(from: link)
            log.add("Pairing link for \(ticket.hostName) (\(ticket.endpointId.prefix(8)))")
            pairingStatus = nil
            pendingPairing = PendingPairing(url: link, ticket: ticket)
        } catch {
            log.add("Bad pairing link: \(error)")
            pairingStatus = "That isn't a valid pairing link. Run `etd pair` on the machine for a new one.\n\n(\(error))"
            pendingPairing = nil
        }
    }

    /// Pairs, adds (or updates) the server, and connects to it.
    func confirmPairing() {
        guard let pending = pendingPairing, !isPairing else { return }
        isPairing = true
        pairingStatus = "Pairing with \(pending.ticket.hostName)…"
        let deviceName = UIDevice.current.name
        Task {
            defer { isPairing = false }
            do {
                let paired = try await IrohLink.shared.pair(url: pending.url, deviceName: deviceName)
                log.add("Paired with \(paired.hostName) (\(paired.endpointId.prefix(8)))")
                var server = servers.first { $0.irohEndpointId == paired.endpointId }
                    ?? ServerConfig(name: paired.hostName, host: paired.hostName, port: 0, user: "")
                server.host = paired.hostName
                server.irohEndpointId = paired.endpointId
                server.irohRelayURL = paired.relayURL
                save(server)
                pendingPairing = nil
                pairingStatus = nil
                connect(server)
            } catch {
                log.add("Pairing failed: \(error)")
                pairingStatus = "Pairing failed: \(SessionController.describe(error, server: ServerConfig(host: pending.ticket.hostName, user: "")))"
            }
        }
    }

    func cancelPairing() {
        pendingPairing = nil
        pairingStatus = nil
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

    // MARK: - Templates

    func templates(for server: UUID) -> [WindowTemplate] {
        templatesByServer[server] ?? []
    }

    func saveTemplate(_ template: WindowTemplate, server: UUID) {
        var list = templatesByServer[server] ?? []
        if let i = list.firstIndex(where: { $0.id == template.id }) { list[i] = template } else { list.append(template) }
        templatesByServer[server] = list
        persistTemplates()
    }

    func deleteTemplate(_ template: WindowTemplate, server: UUID) {
        templatesByServer[server]?.removeAll { $0.id == template.id }
        persistTemplates()
    }

    private func persistTemplates() {
        do {
            try JSONEncoder().encode(templatesByServer).write(to: templatesURL, options: .atomic)
        } catch {
            log.add("Could not save templates: \(error)")
        }
    }

    // MARK: - Network

    /// SPEC §7: reconnect when the network path changes (Wi-Fi ↔ cellular).
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let description = path.status == .satisfied
                ? path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",") : "offline"
            Task { @MainActor in self?.pathChanged(to: description, satisfied: path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "et.path"))
    }

    private func pathChanged(to description: String, satisfied: Bool) {
        defer { lastPath = description }
        guard let previous = lastPath, previous != description else { return }
        log.add("Network: \(previous) → \(description)")
        guard satisfied, let session, UIApplication.shared.applicationState == .active else { return }
        if session.state == .connected || session.isDisconnected || session.isReconnecting {
            session.reconnect()
        }
    }

    // MARK: - Session

    func connect(_ server: ServerConfig) {
        guard let identity else { return }
        session?.disconnect()
        activeServerID = server.id
        UserDefaults.standard.set(server.id.uuidString, forKey: "lastServerID")
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
        UserDefaults.standard.removeObject(forKey: "lastServerID")
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // SPEC §7: close the control client; the tmux session keeps running.
            // Not while a login waits for approval: the user is in Safari
            // approving it, and that login would be lost.
            if let session, session.isAwaitingApproval {
                // Ask for background time so the held login keeps being serviced.
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "login approval") { [weak self] in
                    self?.endBackgroundTask()
                }
            } else if let session, session.pendingHostKey == nil {
                session.disconnect()
            }
        case .active:
            endBackgroundTask()
            if let session, session.isDisconnected, activeServerID != nil {
                log.add("Foreground: reconnecting")
                session.reconnect()
            } else if let session, session.mode == .manymux {
                // Kept connected in the background: lists may be stale.
                Task { await session.refreshMachines() }
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
