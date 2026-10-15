import ETCore
import ETSSH
import Foundation
import Observation
import UIKit

/// One tmux window shown as a page.
@MainActor @Observable
final class WindowPage: Identifiable {
    let id: WindowID
    var index: Int
    var name: String
    var pane: PaneID
    var hasActivity = false
    var hasBell = false
    @ObservationIgnored let terminal: TerminalHost
    /// Output that arrived while history was being restored (SPEC §2.4).
    @ObservationIgnored var buffered: [[UInt8]]? = nil

    init(info: WindowInfo, terminal: TerminalHost) {
        id = info.id
        index = info.index
        name = info.name
        pane = info.activePane
        self.terminal = terminal
    }
}

/// Connects to one server, attaches to a tmux session in control mode, and
/// keeps one `WindowPage` per tmux window.
@MainActor @Observable
final class SessionController {
    enum State: Equatable {
        case connecting(String)
        case choosingSession([SessionInfo])
        case restoring(done: Int, total: Int)
        case connected
        case failed(String)
        case disconnected
    }

    private(set) var server: ServerConfig
    private(set) var state: State = .connecting("Connecting…")
    private(set) var sessionName: String?
    private(set) var windows: [WindowPage] = []
    var currentWindowID: WindowID? {
        didSet { clearBadges() }
    }
    /// Set while asking the user to trust a new host key.
    private(set) var pendingHostKey: HostKey?
    /// Text the server sent during login, for example Tailscale SSH asking
    /// the user to approve the connection in a browser.
    private(set) var authBanner: String?
    /// The first https link in `authBanner`.
    private(set) var approvalURL: URL?

    @ObservationIgnored private let identity: SSHIdentity
    @ObservationIgnored private let log: DebugLog
    @ObservationIgnored private let onServerChanged: (ServerConfig) -> Void
    @ObservationIgnored private var hostKeyAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var tmux: TmuxInstall?
    @ObservationIgnored private var client: TmuxClient?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var terminalSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var sentSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var restoreLines = 2000

    init(server: ServerConfig, identity: SSHIdentity, log: DebugLog,
         onServerChanged: @escaping (ServerConfig) -> Void) {
        self.server = server
        self.identity = identity
        self.log = log
        self.onServerChanged = onServerChanged
    }

    var isDisconnected: Bool {
        switch state {
        case .disconnected, .failed: true
        default: false
        }
    }

    var currentWindow: WindowPage? {
        windows.first { $0.id == currentWindowID }
    }

    // MARK: - Connect

    func connect() {
        tasks.append(Task { await self.run() })
    }

    private func run() async {
        state = .connecting("Connecting to \(server.host)…")
        log.add("Connecting to \(server.user)@\(server.host):\(server.port)")
        do {
            let connection = try await SSHConnection.connect(
                server, identity: identity,
                trustNewHostKey: { [weak self] key in await self?.askToTrust(key) ?? false },
                onAuthBanner: { [weak self] text in
                    Task { @MainActor in self?.received(banner: text) }
                })
            authBanner = nil
            approvalURL = nil
            self.connection = connection
            state = .connecting("Finding tmux…")
            let tmux = try await connection.findTmux()
            self.tmux = tmux
            log.add("tmux: \(tmux.path) (\(tmux.version))")

            let sessions = try await connection.listSessions(tmux: tmux)
            log.add("Sessions: \(sessions.map(\.name))")
            if sessions.isEmpty {
                await attach(.attachOrCreate("main"), name: "main")
            } else if sessions.count == 1 {
                await attach(.attach(sessions[0].name), name: sessions[0].name)
            } else if let last = server.lastSession, sessions.contains(where: { $0.name == last }) {
                await attach(.attach(last), name: last)
            } else {
                state = .choosingSession(sessions)
            }
        } catch {
            fail(error)
        }
    }

    func chooseSession(_ name: String, create: Bool = false) {
        tasks.append(Task { await self.attach(create ? .attachOrCreate(name) : .attach(name), name: name) })
    }

    private func attach(_ target: SSHConnection.ControlTarget, name: String) async {
        guard let connection, let tmux else { return }
        state = .connecting("Attaching to \(name)…")
        do {
            let channel = try await connection.openControlChannel(tmux: tmux, target: target)
            tasks.append(Task { [log] in
                for await text in channel.stderr { log.add("tmux stderr: \(text)") }
            })
            let client = TmuxClient(channel: channel)
            self.client = client
            await client.setErrorHandler { [weak self] error in
                Task { @MainActor in self?.log.add("Command failed: \(error)") }
            }
            await client.start()
            tasks.append(Task {
                for await event in client.events { self.handle(event) }
                self.connectionEnded()
            })
            sessionName = name
            server.lastSession = name
            onServerChanged(server)
            log.add("Attached to session \(name)")

            if let size = terminalSize {
                try await client.command(TmuxCommand.refreshClientSize(columns: size.cols, rows: size.rows))
                sentSize = size
            }
            try await reloadWindows()
            if state != .connected, client === self.client { state = .connected }
        } catch {
            fail(error)
        }
    }

    func disconnect() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        let client = client
        let connection = connection
        self.client = nil
        self.connection = nil
        Task {
            await client?.close()
            await connection?.close()
        }
        if !isDisconnected { state = .disconnected }
        log.add("Disconnected")
    }

    private func connectionEnded() {
        guard client != nil else { return }
        log.add("Control client ended")
        client = nil
        state = .disconnected
    }

    private func fail(_ error: Error) {
        log.add("Error: \(error)")
        var message = Self.describe(error, server: server)
        if let banner = authBanner, approvalURL == nil {
            message += "\n\nThe server said:\n" + banner
        }
        approvalURL = nil
        state = .failed(message)
    }

    static func describe(_ error: Error, server: ServerConfig) -> String {
        switch error {
        case SSHConnectionError.unreachable:
            "Can't reach \(server.host). Check your network or VPN."
        case SSHConnectionError.authenticationFailed:
            "\(server.host) didn't accept this app's key. Add it to ~/.ssh/authorized_keys for \(server.user)."
        case SSHConnectionError.hostKeyRejected:
            "Host key not trusted."
        case SSHConnectionError.timedOut:
            "\(server.host) answered but the SSH login didn't finish in time. If it asked you to approve the login, retry and approve within 5 minutes."
        case SSHConnectionError.hostKeyChanged(_, let presented):
            "\(server.host)'s host key changed (now \(presented.fingerprint)). Not connecting. If this is expected, delete and re-add the server."
        case SSHConnectionError.tmuxNotFound:
            "tmux not found on \(server.host). Set its path in the server settings."
        case TmuxError.disconnected:
            "The tmux session ended."
        default:
            "\(error)"
        }
    }

    // MARK: - Login banner

    private func received(banner text: String) {
        log.add("Server message: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        authBanner = (authBanner.map { $0 + "\n" } ?? "") + text.trimmingCharacters(in: .whitespacesAndNewlines)
        if approvalURL == nil, let url = Self.firstHTTPSURL(in: text) {
            approvalURL = url
            state = .connecting("Waiting for approval…")
        }
    }

    /// True while the server holds the login for the user to approve it.
    var isAwaitingApproval: Bool {
        if case .connecting = state, approvalURL != nil { return true }
        return false
    }

    static func firstHTTPSURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range)
            .compactMap(\.url)
            .first { $0.scheme == "https" }
    }

    // MARK: - Host key

    private func askToTrust(_ key: HostKey) async -> Bool {
        pendingHostKey = key
        let trusted = await withCheckedContinuation { hostKeyAnswer = $0 }
        if trusted {
            // Save now, so a later failure (for example the key not yet in
            // authorized_keys) doesn't ask again on the next attempt.
            server.hostKey = key
            onServerChanged(server)
            log.add("Pinned host key \(key.fingerprint)")
        } else {
            log.add("Host key \(key.fingerprint) not trusted")
        }
        return trusted
    }

    func answerHostKey(trust: Bool) {
        pendingHostKey = nil
        hostKeyAnswer?.resume(returning: trust)
        hostKeyAnswer = nil
    }

    // MARK: - Windows

    private func reloadWindows() async throws {
        guard let client else { return }
        let infos = TmuxCommand.parseWindowList(try await client.command(TmuxCommand.listWindows()))
            .sorted { $0.index < $1.index }
        var pages: [WindowPage] = []
        var toRestore: [WindowPage] = []
        for info in infos {
            if let page = windows.first(where: { $0.id == info.id }) {
                page.index = info.index
                page.name = info.name
                if page.pane != info.activePane {
                    page.pane = info.activePane
                    toRestore.append(page)
                }
                pages.append(page)
            } else {
                let page = WindowPage(info: info, terminal: TerminalHost(log: log))
                page.terminal.onInput = { [weak self, weak page] bytes in
                    guard let self, let page else { return }
                    self.send(bytes, to: page)
                }
                page.terminal.onSizeChange = { [weak self] cols, rows in
                    self?.terminalResized(cols: cols, rows: rows)
                }
                pages.append(page)
                toRestore.append(page)
            }
        }
        // Reconnect: existing pages keep their views but get fresh content.
        if state != .connected {
            toRestore = pages
        }
        windows = pages
        if currentWindowID == nil || !pages.contains(where: { $0.id == currentWindowID }) {
            currentWindowID = (infos.first(where: \.isActive) ?? infos.first)?.id
        }

        // Visible window first, then the rest (SPEC §2.4).
        toRestore.sort { a, _ in a.id == currentWindowID }
        let restoringAll = state != .connected
        for (i, page) in toRestore.enumerated() {
            if restoringAll { state = .restoring(done: i, total: toRestore.count) }
            try await restore(page)
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            do { try await reloadWindows() } catch { log.add("Reload failed: \(error)") }
        }
    }

    /// Replays a pane's history and screen into its terminal (SPEC §2.4).
    private func restore(_ page: WindowPage) async throws {
        guard let client else { return }
        page.buffered = []
        defer {
            for chunk in page.buffered ?? [] { page.terminal.feed(chunk) }
            page.buffered = nil
        }
        let pane = page.pane
        guard let paneState = PaneState(try await client.command(TmuxCommand.paneState(pane: pane))) else { return }

        var bytes: [UInt8] = Array("\u{1b}c".utf8) // full reset
        if paneState.alternateScreen {
            // Normal screen + history first, then switch to the alternate screen.
            if let normal = try? await client.command(
                "capture-pane -p -e -J -a -t \(pane) -S -\(restoreLines)") {
                bytes += Self.join(normal.lines)
            }
            bytes += Array("\u{1b}[0m\r\n\u{1b}[?1049h\u{1b}[H".utf8)
            let screen = try await client.command("capture-pane -p -e -t \(pane)")
            bytes += Self.join(screen.lines)
        } else {
            let history = try await client.command(TmuxCommand.captureHistory(pane: pane, lines: restoreLines))
            bytes += Self.join(history.lines)
        }
        bytes += Array("\u{1b}[0m\u{1b}[\(paneState.cursorY + 1);\(paneState.cursorX + 1)H".utf8)
        page.terminal.reset(with: bytes)
    }

    private static func join(_ lines: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for (i, line) in lines.enumerated() {
            if i > 0 { out += Array("\u{1b}[0m\r\n".utf8) }
            out += line
        }
        return out
    }

    // MARK: - Events

    private func handle(_ event: ControlEvent) {
        switch event {
        case .output(let pane, let data), .extendedOutput(let pane, _, let data):
            guard let page = windows.first(where: { $0.pane == pane }) else { return }
            if page.buffered != nil {
                page.buffered!.append(data)
            } else {
                page.terminal.feed(data)
            }
            if page.id != currentWindowID {
                page.hasActivity = true
                if data.contains(0x07) && !page.hasBell {
                    page.hasBell = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        case .windowRenamed(let id, let name):
            log.add("event: \(event)")
            windows.first { $0.id == id }?.name = name
        case .windowAdd, .windowClose, .unlinkedWindowClose, .windowPaneChanged, .sessionChanged, .layoutChange:
            log.add("event: \(event)")
            scheduleReload()
        case .exit(let reason):
            log.add("tmux %exit \(reason ?? "")")
        default:
            log.add("event: \(event)")
        }
    }

    private func clearBadges() {
        guard let page = currentWindow else { return }
        page.hasActivity = false
        page.hasBell = false
    }

    // MARK: - Input and size

    func send(_ bytes: [UInt8], to page: WindowPage) {
        guard let client, state == .connected else { return }
        let commands = TmuxCommand.sendKeys(pane: page.pane, bytes: bytes)
        Task { for c in commands { await client.post(c) } }
    }

    func sendText(_ text: String, pressEnter: Bool) {
        guard let page = currentWindow else { return }
        send(Array(text.utf8) + (pressEnter ? [0x0D] : []), to: page)
    }

    /// Debounced 150 ms (SPEC §2.5).
    private func terminalResized(cols: Int, rows: Int) {
        guard cols > 1, rows > 1 else { return }
        terminalSize = (cols, rows)
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let client, let size = terminalSize else { return }
            if let sent = sentSize, sent == size { return }
            sentSize = size
            log.add("Resize \(size.cols)x\(size.rows)")
            await client.post(TmuxCommand.refreshClientSize(columns: size.cols, rows: size.rows))
        }
    }
}
