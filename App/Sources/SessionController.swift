import ETCore
import ETSSH
import Foundation
import Observation
import UIKit

/// Opens `ComposeSheet` for a window, optionally with dictated text.
struct ComposeRequest: Identifiable {
    let id = UUID()
    let page: WindowPage
    let text: String
}

/// One tmux window shown as a page.
@MainActor @Observable
final class WindowPage: Identifiable {
    let id: WindowID
    var index: Int
    var name: String
    var pane: PaneID
    /// The pane's foreground program, e.g. "bash", "ssh", "claude".
    var currentCommand: String
    var hasActivity = false
    var hasBell = false
    /// Keyboard dictation started here; showing "Edit first / Into terminal".
    var dictationPrompt = false
    /// Set briefly when this window rings its bell (in-app banner).
    var lastBell: Date?
    @ObservationIgnored let terminal: TerminalHost
    /// Output that arrived while history was being restored (SPEC §2.4).
    @ObservationIgnored var buffered: [[UInt8]]? = nil

    init(info: WindowInfo, terminal: TerminalHost) {
        id = info.id
        index = info.index
        name = info.name
        pane = info.activePane
        currentCommand = info.currentCommand
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
        didSet {
            guard currentWindowID != oldValue else { return }
            clearBadges()
            for page in windows where page.id != currentWindowID { page.terminal.dismissDictationPrompt() }
            // Keep the keyboard up across a switch if it was up.
            if let old = windows.first(where: { $0.id == oldValue }), old.terminal.view.isFirstResponder {
                _ = currentWindow?.terminal.view.becomeFirstResponder()
            }
        }
    }
    /// Set while asking the user to trust a new host key.
    private(set) var pendingHostKey: HostKey?
    /// Text the server sent during login, for example Tailscale SSH asking
    /// the user to approve the connection in a browser.
    private(set) var authBanner: String?
    /// The first https link in `authBanner`.
    private(set) var approvalURL: URL?
    /// Set to open the compose editor.
    var composeRequest: ComposeRequest?
    /// The window whose bell just rang, for the in-app banner.
    private(set) var bellBanner: WindowPage?
    /// True between an unexpected disconnect and the next successful attach.
    private(set) var isReconnecting = false
    /// Key-row presets the user picked, by window name (SPEC §5.4).
    private var presetChoices: [String: KeyPreset] = [:]

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
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    @ObservationIgnored private var loggedFirstInput = false
    @ObservationIgnored private var restoreLines = 2000
    /// Set by `disconnect()` so the end of the control client isn't treated
    /// as a lost connection.
    @ObservationIgnored private var intentionalDisconnect = false
    @ObservationIgnored private var reconnectStarted: Date?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    init(server: ServerConfig, identity: SSHIdentity, log: DebugLog,
         onServerChanged: @escaping (ServerConfig) -> Void) {
        self.server = server
        self.identity = identity
        self.log = log
        self.onServerChanged = onServerChanged
        if let saved = UserDefaults.standard.dictionary(forKey: presetKey) as? [String: String] {
            presetChoices = saved.compactMapValues(KeyPreset.init(rawValue:))
        }
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
        intentionalDisconnect = false
        tasks.append(Task { await self.run() })
    }

    /// Drops the current connection (if any) and connects again, keeping the
    /// window pages so nothing flashes; their content is restored in place.
    func reconnect() {
        reconnectTask?.cancel()
        closeConnection()
        intentionalDisconnect = false
        tasks.append(Task { await self.run() })
    }

    /// Backoff after an unexpected disconnect (SPEC §7): 0.5, 1, 2, 4 s,
    /// then every 8 s; give up after 2 minutes.
    private func scheduleReconnect() {
        let started = reconnectStarted ?? Date()
        reconnectStarted = started
        guard Date().timeIntervalSince(started) < 120 else {
            isReconnecting = false
            reconnectStarted = nil
            reconnectAttempt = 0
            state = .failed("Lost the connection to \(server.host) and couldn't get it back.")
            return
        }
        isReconnecting = true
        let delays = [0.5, 1, 2, 4]
        let delay = reconnectAttempt < delays.count ? delays[reconnectAttempt] : 8
        reconnectAttempt += 1
        log.add("Reconnecting in \(delay) s (attempt \(reconnectAttempt))")
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.reconnect()
        }
    }

    private func run() async {
        state = .connecting(isReconnecting ? "Reconnecting…" : "Connecting to \(server.host)…")
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
            log.add("tmux: \(tmux.path) (\(tmux.version)), TMUX_TMPDIR=\(tmux.tmpDir ?? "default")")

            let sessions = try await connection.listSessions(tmux: tmux)
            log.add("Sessions: \(sessions.map(\.name))")
            if sessions.isEmpty {
                // Never create a session silently; a wrong socket would look
                // exactly like this. The picker offers "New session".
                state = .choosingSession([])
            } else if let current = sessionName, sessions.contains(where: { $0.name == current }) {
                await attach(.attach(current), name: current)
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
            try await serializedReload(restoreAll: true)
            if client === self.client {
                state = .connected
                isReconnecting = false
                reconnectStarted = nil
                reconnectAttempt = 0
                log.add("Ready: \(windows.count) windows")
                openPendingWindow()
                Task { await registerPushToken() }
            }
        } catch {
            fail(error)
        }
    }

    /// Closes the connection on purpose (app in background, user left).
    func disconnect() {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        isReconnecting = false
        reconnectStarted = nil
        reconnectAttempt = 0
        closeConnection()
        if !isDisconnected { state = .disconnected }
        log.add("Disconnected")
    }

    private func closeConnection() {
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
    }

    private func connectionEnded() {
        guard client != nil else { return }
        log.add("Control client ended")
        client = nil
        state = .disconnected
        if !intentionalDisconnect { scheduleReconnect() }
    }

    private func fail(_ error: Error) {
        log.add("Error: \(error)")
        if isReconnecting, !intentionalDisconnect, Self.isTransient(error) {
            state = .disconnected
            scheduleReconnect()
            return
        }
        isReconnecting = false
        var message = Self.describe(error, server: server)
        if let banner = authBanner, approvalURL == nil {
            message += "\n\nThe server said:\n" + banner
        }
        approvalURL = nil
        state = .failed(message)
    }

    /// Network trouble worth retrying, as opposed to auth or host-key problems.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case SSHConnectionError.unreachable, SSHConnectionError.timedOut, TmuxError.disconnected: true
        case is SSHConnectionError: false
        default: true
        }
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
        case SSHConnectionError.tmuxNotFound(let output):
            "tmux not found on \(server.host). Set its path in the server settings.\n\nDiscovery output:\n\(output)"
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

    /// Re-reads the window list and restores new or changed windows. With
    /// `restoreAll` (attach / reconnect) every window is restored and
    /// progress is shown in `state`.
    private func reloadWindows(restoreAll: Bool = false) async throws {
        guard let client else { return }
        let infos = TmuxCommand.parseWindowList(try await client.command(TmuxCommand.listWindows()))
            .sorted { $0.index < $1.index }
        var pages: [WindowPage] = []
        var toRestore: [WindowPage] = []
        for info in infos {
            if let page = windows.first(where: { $0.id == info.id }) {
                page.index = info.index
                page.name = info.name
                page.currentCommand = info.currentCommand
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
                page.terminal.onSwipe = { [weak self] next in self?.switchWindow(next: next) }
                page.terminal.onBell = { [weak self, weak page] in
                    guard let self, let page else { return }
                    self.bellRang(in: page)
                }
                page.terminal.onDictationPrompt = { [weak page] text in
                    page?.dictationPrompt = text != nil
                }
                page.terminal.onEditDictation = { [weak self, weak page] text in
                    guard let self, let page else { return }
                    self.composeRequest = ComposeRequest(page: page, text: text)
                }
                pages.append(page)
                toRestore.append(page)
            }
        }
        // Reconnect: existing pages keep their views but get fresh content.
        if restoreAll {
            toRestore = pages
        }
        windows = pages
        if currentWindowID == nil || !pages.contains(where: { $0.id == currentWindowID }) {
            currentWindowID = (infos.first(where: \.isActive) ?? infos.first)?.id
        }

        // Visible window first, then the rest (SPEC §2.4).
        toRestore.sort { a, _ in a.id == currentWindowID }
        for (i, page) in toRestore.enumerated() {
            if restoreAll { state = .restoring(done: i, total: toRestore.count) }
            try await restore(page)
        }
    }

    /// Runs reloads one at a time. Two overlapping reloads would interleave
    /// restores of the same pane.
    private func serializedReload(restoreAll: Bool = false) async throws {
        let previous = reloadTask
        let task = Task { () -> Void in
            await previous?.value
            do { try await reloadWindows(restoreAll: restoreAll) } catch {
                log.add("Reload failed: \(error)")
                if restoreAll { throw error }
            }
        }
        reloadTask = Task { _ = try? await task.value }
        try await task.value
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            try? await serializedReload()
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
            }
        case .windowRenamed(let id, let name):
            log.add("event: \(event)")
            windows.first { $0.id == id }?.name = name
        case .windowAdd, .windowClose, .unlinkedWindowClose, .windowPaneChanged, .sessionChanged:
            log.add("event: \(event)")
            scheduleReload()
        case .layoutChange:
            break
        case .exit(let reason):
            log.add("tmux %exit \(reason ?? "")")
        default:
            log.add("event: \(event)")
        }
    }

    /// A command finished or Claude wants input (both ring the bell; see
    /// nixos-config et-notify). In the app: vibrate and show a banner.
    private func bellRang(in page: WindowPage) {
        guard state == .connected else { return }
        if page.id != currentWindowID { page.hasBell = true }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        bellBanner = page
        let shown = page
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.bellBanner === shown { self.bellBanner = nil }
        }
    }

    func dismissBellBanner() { bellBanner = nil }

    /// Opens the window a tapped notification named, once it exists.
    func openPendingWindow() {
        guard let name = Push.shared.pendingWindowName,
              let page = windows.first(where: { $0.name == name }) else { return }
        Push.shared.pendingWindowName = nil
        currentWindowID = page.id
    }

    /// Writes this phone's push token to ~/.config/et/devices on the server,
    /// where et-notify reads it. Runs after each attach.
    private func registerPushToken() async {
        guard let connection, let token = Push.shared.token else { return }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let json = #"{"token":"\#(token)","environment":"\#(Push.environment)","bundle":"xyz.ericsharma.et","name":"\#(UIDevice.current.name)"}"#
        let command = "mkdir -p ~/.config/et/devices && printf '%s\\n' '\(json.replacingOccurrences(of: "'", with: ""))' > ~/.config/et/devices/\(id).json"
        do {
            let result = try await connection.run(command)
            log.add(result.exitCode == 0 ? "Push token registered on \(server.host)" : "Push token not saved: \(result.output)")
        } catch {
            log.add("Push token not saved: \(error)")
        }
    }

    private func clearBadges() {
        guard let page = currentWindow else { return }
        page.hasActivity = false
        page.hasBell = false
    }

    /// Two-finger swipe: next or previous window, no wrap-around.
    func switchWindow(next: Bool) {
        guard let i = windows.firstIndex(where: { $0.id == currentWindowID }) else { return }
        let j = next ? i + 1 : i - 1
        guard windows.indices.contains(j) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        currentWindowID = windows[j].id
    }

    // MARK: - Presets

    private var presetKey: String { "presets.\(server.id.uuidString)" }

    func preset(for page: WindowPage) -> KeyPreset {
        if let chosen = presetChoices[page.name] { return chosen }
        // A window running claude over ssh shows "ssh", so the name matters too.
        let looksLikeClaude = page.currentCommand == "claude" || page.name.localizedCaseInsensitiveContains("claude")
        return looksLikeClaude ? .claude : .shell
    }

    func setPreset(_ preset: KeyPreset, for page: WindowPage) {
        presetChoices[page.name] = preset
        UserDefaults.standard.set(presetChoices.mapValues(\.rawValue), forKey: presetKey)
    }

    // MARK: - Windows (new, rename, close)

    /// SPEC §6.4: create the window without switching the server's current
    /// window, then type each command into its shell.
    func createWindow(name: String, commands: [String]) {
        guard let client, !name.isEmpty else { return }
        Task {
            do {
                let reply = try await client.command(TmuxCommand.newWindow(name: name))
                guard let (window, pane) = TmuxCommand.parseNewWindow(reply) else { return }
                log.add("Created window \(name) \(window)")
                for line in commands {
                    for c in TmuxCommand.sendKeys(pane: pane, bytes: Array(line.utf8) + [0x0D]) {
                        await client.post(c)
                    }
                }
                try await serializedReload()
                currentWindowID = window
            } catch {
                log.add("New window failed: \(error)")
            }
        }
    }

    func renameWindow(_ page: WindowPage, to name: String) {
        guard let client, !name.isEmpty else { return }
        Task { await client.post(TmuxCommand.renameWindow(page.id, to: name)) }
    }

    func closeWindow(_ page: WindowPage) {
        guard let client else { return }
        Task { await client.post(TmuxCommand.killWindow(page.id)) }
    }

    // MARK: - Input and size

    func send(_ bytes: [UInt8], to page: WindowPage) {
        guard let client else {
            log.add("Input dropped: not connected")
            return
        }
        if !loggedFirstInput {
            loggedFirstInput = true
            log.add("First input: \(bytes.count) bytes to \(page.name) (\(page.pane))")
        }
        let commands = TmuxCommand.sendKeys(pane: page.pane, bytes: bytes)
        Task { for c in commands { await client.post(c) } }
    }

    /// E.T.'s mic finished: type the text into the window (no Enter), then
    /// offer Edit, same as after keyboard dictation.
    func sendDictated(_ text: String, to page: WindowPage) {
        guard !text.isEmpty else { return }
        send(Array(text.utf8), to: page)
        page.terminal.offerEdit(text)
    }

    /// Hints for the speech recognizer: window names and common commands.
    var dictationVocabulary: [String] {
        windows.map(\.name) + [server.host, "tmux", "ssh", "sudo", "git", "grep", "claude",
                                "systemctl", "journalctl", "nixos-rebuild", "docker", "vim", "ls", "cd"]
    }

    /// Sends compose-bar text (SPEC §6.2). Multi-line text goes to Claude
    /// windows as a bracketed paste, so Claude gets one message instead of
    /// one per line; in shells each line runs.
    func sendComposed(_ text: String, to page: WindowPage, pressEnter: Bool) {
        var bytes: [UInt8]
        if text.contains("\n") && preset(for: page) == .claude {
            bytes = Array("\u{1b}[200~".utf8) + Array(text.utf8) + Array("\u{1b}[201~".utf8)
        } else {
            bytes = Array(text.replacingOccurrences(of: "\n", with: "\r").utf8)
        }
        if pressEnter { bytes.append(0x0D) }
        send(bytes, to: page)
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
