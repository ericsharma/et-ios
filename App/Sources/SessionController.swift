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
    /// The text came from dictation (the editor offers to learn names
    /// the user corrects).
    var dictated = false
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
    @ObservationIgnored let terminal: TerminalHost
    /// Output that arrived while history was being restored (SPEC §2.4).
    @ObservationIgnored var buffered: [[UInt8]]? = nil
    /// tmux resized this window since we last copied its screen; our copy
    /// may have drifted (see SessionController.repaint).
    @ObservationIgnored var needsRepaint = false
    @ObservationIgnored var repaintTask: Task<Void, Never>?
    /// manymux: the program's terminal title (Claude Code's current task).
    var title = ""
    /// manymux: attached view-only (no typing, no resize).
    var readOnly = false
    /// Set for a manymux session page; nil for a tmux window.
    @ObservationIgnored let mm: MmPage?

    init(info: WindowInfo, terminal: TerminalHost) {
        id = info.id
        index = info.index
        name = info.name
        pane = info.activePane
        currentCommand = info.currentCommand
        self.terminal = terminal
        mm = nil
    }

    init(mm: MmPage, id: WindowID, terminal: TerminalHost) {
        self.id = id
        index = 0
        name = mm.name
        pane = PaneID(-1)
        currentCommand = ""
        self.terminal = terminal
        self.mm = mm
    }
}

/// The manymux side of a page: which session it shows, and its attachment
/// while it is the visible page (only that one is attached, so other
/// sessions keep their size for other devices).
@MainActor
final class MmPage {
    /// The machine's host name (the hub's own name for the hub).
    let machine: String
    var name: String
    var attachment: MmAttachHandle?
    /// Keystrokes, in order; typed while attaching, they wait here.
    var input: AsyncStream<[UInt8]>.Continuation?
    var task: Task<Void, Never>?
    /// Changes on each attach, so a late answer from an old one is ignored.
    var generation: UUID?
    var sentSize: (cols: Int, rows: Int)?
    /// The size the session took (the smallest of its clients).
    var sessionSize: (cols: Int, rows: Int)?
    /// Attaches again after the stream closed, in a row.
    var retries = 0
    /// The full command line (key-row preset).
    var command = ""
    /// The last `mmPeek` screen, painted at once when the page opens.
    var peek: MmScreen?
    /// Attached, but no output yet: the peek stays on screen until then.
    var awaitingOutput = false

    init(machine: String, name: String) {
        self.machine = machine
        self.name = name
    }
}

/// Connects to one server, attaches to a tmux session in control mode, and
/// keeps one `WindowPage` per tmux window.
@MainActor @Observable
final class SessionController {
    /// iroh servers start on the manymux Machines screen; tmux is behind
    /// its "tmux" entry. SSH servers are tmux only.
    enum Mode { case tmux, manymux }

    enum State: Equatable {
        case connecting(String)
        case choosingSession([SessionInfo])
        case restoring(done: Int, total: Int)
        case connected
        case failed(String)
        case disconnected
    }

    private(set) var server: ServerConfig
    private(set) var mode: Mode
    private(set) var state: State = .connecting("Connecting…")
    private(set) var sessionName: String?
    private(set) var windows: [WindowPage] = []
    var currentWindowID: WindowID? {
        didSet {
            guard currentWindowID != oldValue else { return }
            keyWheelOpen = false
            // Switching windows closes select mode (its selection is
            // already on the clipboard, ready to paste in the new window).
            if let mode = selectMode, mode.page.id != currentWindowID {
                mode.page.terminal.view.clearSelection()
                selectMode = nil
            }
            if let old = windows.first(where: { $0.id == oldValue }) { release(old) }
            if let page = currentWindow { claim(page) }
            clearBadges()
            if let page = currentWindow, page.needsRepaint { scheduleRepaint(page, after: 0) }
            if mode == .manymux { mmCurrentChanged() }
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
    var composeRequest: ComposeRequest? {
        didSet { if composeRequest != nil { keyWheelOpen = false } }
    }
    var showNewWindow = false {
        didSet { if showNewWindow { keyWheelOpen = false } }
    }
    var showOverview = false {
        didSet { if showOverview { keyWheelOpen = false } }
    }
    /// Select mode for a window, while open.
    var selectMode: SelectModeRequest?
    /// The key row's ⋯ key wheel. Any other action closes it; only taps on
    /// its own keys keep it open.
    var keyWheelOpen = false

    func enterSelectMode(_ page: WindowPage, initial: String?) {
        keyWheelOpen = false
        selectMode = SelectModeRequest(page: page, initialSelection: initial)
    }
    /// The window whose bell just rang, for the in-app banner.
    private(set) var bellBanner: WindowPage?
    /// True between an unexpected disconnect and the next successful attach.
    private(set) var isReconnecting = false
    /// Key-row presets the user picked, by window name (SPEC §5.4).
    private var presetChoices: [String: KeyPreset] = [:]

    @ObservationIgnored private let identity: SSHIdentity
    @ObservationIgnored let log: DebugLog
    @ObservationIgnored private let onServerChanged: (ServerConfig) -> Void
    @ObservationIgnored private var hostKeyAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var connection: (any HostConnection)?
    /// Set for iroh servers: shows "direct" or "relay" in the header.
    private(set) var pathLabel: String?
    @ObservationIgnored private var pathTask: Task<Void, Never>?
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
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// Windows E.T. sized to the phone with resize-window (see claim).
    @ObservationIgnored private var claimed: Set<WindowID> = []

    // manymux (PLAN-manymux §3)
    /// The hub's own host name (trigkey).
    private(set) var hubName: String?
    /// The hub first, then the machines it watches.
    private(set) var machines: [MmMachine] = []
    /// The machine whose sessions are the pages (swipe moves among them).
    private(set) var mmMachine: String?
    /// A short message (session ended, rename refused).
    private(set) var mmNotice: String?
    private(set) var mmSpawning = false
    /// Saved sessions not running (`mm checkpoint show` on the hub), for
    /// the Machines screen's Restore row; nil when none are missing.
    private(set) var mmMissing: (checkpoint: MmCheckpoint, targets: [String])?
    private(set) var mmRestoring = false
    /// What the last `mm checkpoint restore` printed, until dismissed.
    var mmRestoreOutput: String?
    @ObservationIgnored private var mmPages: [String: WindowPage] = [:]
    @ObservationIgnored private var nextMmID = 0
    /// Pages whose sessions are attached, the most recent last: the visible
    /// one and the one before (a swipe back is instant).
    @ObservationIgnored private var mmAttachedPages: [WindowPage] = []
    /// One event feed per machine connection: the hub's, and each network machine's.
    @ObservationIgnored private var mmEventFeeds: [String: MmEventFeed] = [:]
    @ObservationIgnored private var mmRefreshTask: Task<Void, Never>?
    /// What the pending refresh lists: every machine, or only these.
    @ObservationIgnored private var mmRefreshAll = false
    @ObservationIgnored private var mmRefreshNames: Set<String> = []

    // The etd network (PLAN-network §4.7, N5)
    /// The network from the hub's etd; nil until loaded, or if its etd has none.
    private(set) var network: NetInfo?
    private(set) var networkError: String?
    @ObservationIgnored private var networkLoaded: Date?
    /// The hub's host name (hello), which its node puts on its own events.
    @ObservationIgnored private var hubHostName: String?
    /// Network machines other than the hub, connected directly, by network name.
    @ObservationIgnored private var mmHosts: [String: IrohHost] = [:]
    /// A network machine's host name (hello), which its node puts on its own events.
    @ObservationIgnored private var mmHostNames: [String: String] = [:]
    /// Why a network machine is not connected.
    @ObservationIgnored private var mmHostErrors: [String: String] = [:]
    @ObservationIgnored private var mmConnecting: Set<String> = []
    @ObservationIgnored private var mmLastTry: [String: Date] = [:]

    init(server: ServerConfig, identity: SSHIdentity, log: DebugLog,
         onServerChanged: @escaping (ServerConfig) -> Void) {
        self.server = server
        self.identity = identity
        self.log = log
        self.onServerChanged = onServerChanged
        mode = server.isIroh ? .manymux : .tmux
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
        do {
            let connection: any HostConnection
            if let endpointId = server.irohEndpointId {
                log.add("Connecting to \(server.host) over iroh (\(endpointId.prefix(8)))")
                if !IrohLink.shared.isStarted { state = .connecting("Starting network…") }
                let host = try await IrohLink.shared.connect(endpointId: endpointId, relayURL: server.irohRelayURL)
                connection = host
                watchPath(host)
            } else {
                log.add("Connecting to \(server.user)@\(server.host):\(server.port)")
                connection = try await SSHConnection.connect(
                    server, identity: identity,
                    trustNewHostKey: { [weak self] key in await self?.askToTrust(key) ?? false },
                    onAuthBanner: { [weak self] text in
                        Task { @MainActor in self?.received(banner: text) }
                    })
            }
            authBanner = nil
            approvalURL = nil
            self.connection = connection
            if mode == .manymux, let host = connection as? IrohHost {
                try await startManymux(host)
                return
            }
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

    private func attach(_ target: ControlTarget, name: String) async {
        guard let connection, let tmux else { return }
        state = .connecting("Attaching to \(name)…")
        do {
            let opened = try await connection.openControlChannel(tmux: tmux, target: target)
            tasks.append(Task { [log] in
                for await text in opened.stderr { log.add("tmux stderr: \(text)") }
            })
            let client = TmuxClient(channel: opened.channel)
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
                releaseStaleClaims()
                if let page = currentWindow { claim(page) }
                detachStaleClients()
                startHeartbeat()
                openPendingWindow()
                Task { await discoverVocabulary() }
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
        // Give claimed windows back to the other clients (the laptop).
        let release = Array(claimed)
        claimed.removeAll()
        saveClaims()
        closeConnection(releasing: release)
        if !isDisconnected { state = .disconnected }
        log.add("Disconnected")
    }

    private func closeConnection(releasing windows: [WindowID] = []) {
        heartbeatTask?.cancel()
        pathTask?.cancel()
        pathLabel = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        mmRefreshTask?.cancel()
        let client = client
        let connection = connection
        let attachments = mmAttachedPages.compactMap { releaseMm($0) }
        let events = Array(mmEventFeeds.values)
        let members = Array(mmHosts.values)
        let wasManymux = mode == .manymux && connection != nil
        mmEventFeeds = [:]
        mmHosts = [:]
        mmHostNames = [:]
        mmHostErrors = [:]
        mmConnecting = []
        mmLastTry = [:]
        networkLoaded = nil
        self.client = nil
        self.connection = nil
        Task {
            // Leave the session running for its other clients.
            for attachment in attachments { await attachment.detach() }
            for feed in events { await feed.close() }
            if wasManymux, let connection {
                // No longer open: pushes resume right away.
                for host in members + [connection as? IrohHost].compactMap({ $0 }) {
                    try? await host.foreground(seconds: 0)
                }
                _ = try? await connection.run(Self.heartbeatClearScript)
            }
            for host in members { await host.close() }
            if let client {
                for id in windows { await client.post(TmuxCommand.releaseWindowSize(id)) }
                // No longer open: notifications resume right away.
                await client.post(Self.heartbeatClear)
                // Let the writer send them before the channel closes.
                try? await Task.sleep(for: .milliseconds(200))
            }
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

    /// Polls the iroh path ("direct" / "relay") for the header.
    private func watchPath(_ host: IrohHost) {
        pathTask?.cancel()
        pathTask = Task {
            while !Task.isCancelled {
                let label = host.pathLabel
                if label != self.pathLabel {
                    if let label { self.log.add("iroh path: \(label)") }
                    self.pathLabel = label
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
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

    /// LAN addresses need iOS's Local Network permission (Tailscale's don't).
    static func isPrivateAddress(_ host: String) -> Bool {
        host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasSuffix(".local")
            || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
    }

    /// Network trouble worth retrying, as opposed to auth or host-key problems.
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case SSHConnectionError.unreachable, SSHConnectionError.timedOut, TmuxError.disconnected: true
        case is SSHConnectionError: false
        case HostError.notPaired: false
        default: true
        }
    }

    static func describe(_ error: Error, server: ServerConfig) -> String {
        switch error {
        case SSHConnectionError.unreachable(let detail):
            Self.isPrivateAddress(server.host)
                ? "Can't reach \(server.host). If this is the first time on this device, allow it in Settings → Privacy & Security → Local Network → E.T.\n\n(\(detail))"
                : "Can't reach \(server.host). Check your network or VPN.\n\n(\(detail))"
        case SSHConnectionError.authenticationFailed:
            "\(server.host) didn't accept this app's key. Add it to ~/.ssh/authorized_keys for \(server.user)."
        case SSHConnectionError.hostKeyRejected:
            "Host key not trusted."
        case SSHConnectionError.timedOut:
            "\(server.host) answered but the SSH login didn't finish in time. If it asked you to approve the login, retry and approve within 5 minutes."
        case SSHConnectionError.hostKeyChanged(_, let presented):
            "\(server.host)'s host key changed (now \(presented.fingerprint)). Not connecting. If this is expected, delete and re-add the server."
        case HostError.notPaired:
            "This iPhone is not paired with \(server.host), or it was removed. Run `etd pair` on \(server.host)."
        case HostError.unreachable(let detail):
            "Can't reach \(server.host).\n\n(\(detail))"
        case HostError.closed(let detail), HostError.other(let detail):
            detail
        case SSHConnectionError.tmuxNotFound(let output) where server.isIroh:
            "tmux not found on \(server.host).\n\netd said:\n\(output)"
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
                wire(page)
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

    /// Connects a new page's terminal to the controller.
    private func wire(_ page: WindowPage) {
        page.terminal.onInput = { [weak self, weak page] bytes in
            guard let self, let page else { return }
            self.send(bytes, to: page)
        }
        page.terminal.onSizeChange = { [weak self] cols, rows in
            self?.terminalResized(cols: cols, rows: rows)
        }
        page.terminal.onSwipe = { [weak self] next in self?.switchWindow(next: next) }
        page.terminal.onTap = { [weak self] in self?.keyWheelOpen = false }
        page.terminal.onBell = { [weak self, weak page] in
            guard let self, let page else { return }
            self.bellRang(in: page)
        }
        page.terminal.onDictationPrompt = { [weak page] text in
            page?.dictationPrompt = text != nil
        }
        page.terminal.onEditDictation = { [weak self, weak page] text in
            guard let self, let page else { return }
            self.composeRequest = ComposeRequest(page: page, text: text, dictated: true)
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

    /// Re-copies a window's screen from tmux after a resize (debounced).
    private func scheduleRepaint(_ page: WindowPage, after delay: Double) {
        page.repaintTask?.cancel()
        page.repaintTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, state == .connected, page.needsRepaint else { return }
            page.needsRepaint = false
            do { try await restore(page) } catch { log.add("Repaint failed: \(error)") }
        }
    }

    /// Replays a pane's history and screen into its terminal (SPEC §2.4).
    private func restore(_ page: WindowPage) async throws {
        guard let client else { return }
        page.needsRepaint = false
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
        // The reset cleared the program's modes (arrow-key mode, mouse
        // reporting, hidden cursor); put them back.
        bytes += Array(paneState.modeSequences.utf8)
        // tmux doesn't report bracketed paste; keep what the program set.
        if page.terminal.terminal.bracketedPasteMode { bytes += Array("\u{1b}[?2004h".utf8) }
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
        case .layoutChange(let id, _, _, _):
            // tmux resized the window; the program in it redraws for the new
            // size, but tmux never sends us its screen, so ours drifts. Copy
            // tmux's screen once things settle (now for the visible window,
            // on switch for the rest).
            guard let page = windows.first(where: { $0.id == id }) else { return }
            page.needsRepaint = true
            if page.id == currentWindowID { scheduleRepaint(page, after: 0.4) }
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
        if mode == .manymux {
            if let target = Push.shared.pendingManymux {
                // startManymux calls this again once connected.
                guard state == .connected, hubName != nil else { return }
                Push.shared.pendingManymux = nil
                openMm(machine: mmMachineName(for: target.machine), name: target.session)
            } else if Push.shared.pendingWindowName != nil {
                setMode(.tmux)
            }
            return
        }
        if Push.shared.pendingManymux != nil, server.isIroh {
            setMode(.manymux)
            return
        }
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
        let json = #"{"token":"\#(token)","environment":"\#(Push.environment)","bundle":"xyz.ericsharma.et","server":"\#(server.id.uuidString)","name":"\#(UIDevice.current.name)"}"#
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

    /// ⌘1…⌘9: the window at that position in the list.
    func selectWindow(at position: Int) {
        guard windows.indices.contains(position) else { return }
        currentWindowID = windows[position].id
    }

    /// Two-finger swipe: next or previous window, no wrap-around.
    func switchWindow(next: Bool) {
        guard let i = windows.firstIndex(where: { $0.id == currentWindowID }) else { return }
        // manymux: one ring of every session on every machine.
        if mode == .manymux {
            guard windows.count > 1 else { return }
            currentWindowID = windows[(i + (next ? 1 : -1) + windows.count) % windows.count].id
            return
        }
        let j = next ? i + 1 : i - 1
        guard windows.indices.contains(j) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        currentWindowID = windows[j].id
    }

    // MARK: - Image upload

    /// Copilot mode (✨): the current window's transcript replaces its
    /// terminal (CopilotView).
    var copilotMode = false
    /// Copilot's per-window state: the transcript as loaded and the steps
    /// ticked. Kept across window switches, so steps from several windows
    /// (machines) can go to the model together.
    struct CopilotWindow {
        var host: String
        var turns: [Transcript.Turn]
        var selected: Set<String>
        var picked: [Transcript.Turn] { turns.filter { selected.contains($0.id) } }
    }
    var copilotWindows: [WindowID: CopilotWindow] = [:]

    /// Dictated with the mic while Copilot is open; CopilotView adds it to
    /// its instruction box and clears it.
    var copilotDictation: String?

    /// Shown while an upload runs or after it finishes.
    private(set) var uploadStatus: String?
    /// Share-extension outbox jobs being sent, and ones that failed this run
    /// (tried again at the next launch).
    @ObservationIgnored private var shareJobsSending: Set<String> = []
    @ObservationIgnored private var shareJobsFailed: Set<String> = []

    /// A photo from the key row. A manymux session gets it pasted (Claude
    /// sees an image); a tmux window gets it sent like a file.
    func uploadImage(_ data: Data, fileExtension: String, to page: WindowPage) {
        if page.mm != nil {
            pasteMm(data, ext: fileExtension, to: page)
            return
        }
        do {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            sendFiles([try Self.stage(data, name: "image-\(stamp).\(fileExtension)")], to: page, staged: true)
        } catch {
            flashUpload("Couldn't send: \(error.localizedDescription)")
        }
    }

    /// Files to ~/etd-downloads on the window's machine (PLAN-files F6),
    /// any type and size; the paths are typed into the window (quoted, a
    /// space, no Enter) unless etd typed them. `staged`: our own copies,
    /// deleted after.
    func sendFiles(_ urls: [URL], to page: WindowPage, staged: Bool) {
        guard !urls.isEmpty else { return }
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        Task {
            // The machine reads the files during the send.
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for url in scoped { url.stopAccessingSecurityScopedResource() }
                if staged { for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
            }
            do {
                let target = try await sendTarget(for: page)
                uploadStatus = "Sending \(label) to \(target.machine)…"
                log.add("Sending \(label) to \(target.machine)\(target.session.map { "/" + $0 } ?? "")")
                let sent = try await target.host.sendFiles(urls.map(\.path), session: target.session,
                                                           progress: showProgress(label, to: target.machine))
                log.add("Sent to \(target.machine): \(sent.paths.joined(separator: " "))\(sent.typed ? " (typed by etd)" : "")")
                if !sent.typed, !sent.paths.isEmpty {
                    send(Array((sent.paths.map(Self.shellQuoted).joined(separator: " ") + " ").utf8), to: page)
                }
                flashUpload("\(label) sent; path typed into \(page.name)")
            } catch {
                log.add("Send failed: \(error)")
                flashUpload("Couldn't send: \(Self.describeMm(error))")
            }
        }
    }

    /// Where a window's files go: a manymux session's machine (etd types
    /// the paths there); for a tmux window, the machine its ssh points at
    /// when that is a machine of the network, else this server.
    private func sendTarget(for page: WindowPage) async throws -> (host: IrohHost, machine: String, session: String?) {
        if let mm = page.mm {
            let (host, api) = try route(mm.machine)
            guard api == nil else { throw HostError.other("\(mm.machine) is reached by ssh; files can't be sent there yet") }
            return (host, mm.machine, mm.name)
        }
        guard let hub = connection as? IrohHost else {
            throw HostError.other("Sending files needs etd on \(server.displayName)")
        }
        if page.currentCommand == "ssh", let client,
           let destination = try? await sshDestination(of: page, client: client) {
            let name = String(destination.split(separator: "@").last ?? Substring(destination))
            if networkMachines.contains(where: { $0.name == name }), let routed = try? route(name), routed.machine == nil {
                return (routed.host, name, nil)
            }
            log.add("\(destination) isn't a machine of the network: sending to \(server.displayName)")
        }
        return (hub, hubName ?? server.displayName, nil)
    }

    /// Progress of a send, in the status line.
    private func showProgress(_ label: String, to machine: String) -> @Sendable (UInt64, UInt64) -> Void {
        { done, total in
            guard total > 0 else { return }
            let percent = Int(Double(done) / Double(total) * 100)
            Task { @MainActor in
                if self.uploadStatus?.hasPrefix("Sending \(label)") == true {
                    self.uploadStatus = "Sending \(label) to \(machine)… \(percent)%"
                }
            }
        }
    }

    private func flashUpload(_ text: String) {
        uploadStatus = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if uploadStatus == text { uploadStatus = nil }
        }
    }

    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? path : TmuxCommand.quote(path)
    }

    /// A copy of `data` in our temporary folder, for `sendFiles`.
    static func stage(_ data: Data, name: String) throws -> URL {
        let url = try stagingFolder().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A copy of a file in our temporary folder (same name), for `sendFiles`.
    static func stage(copyOf file: URL) throws -> URL {
        let url = try stagingFolder().appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: url)
        return url
    }

    private static func stagingFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("et-send/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The host an ssh session in this window points at ("gmktec",
    /// "user@host"), from the ssh process's arguments.
    private func sshDestination(of page: WindowPage, client: TmuxClient) async throws -> String? {
        guard let connection else { return nil }
        let pidReply = try await client.command("display-message -p -t \(page.pane) '#{pane_pid}'")
        guard let pid = pidReply.textLines.first.flatMap({ Int($0) }) else { return nil }
        let (output, _) = try await connection.run("for p in $(pgrep -P \(pid)); do ps -o args= -p $p; done")
        guard let line = output.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("ssh ") }) else { return nil }
        return Self.sshDestination(fromArguments: line.split(separator: " ").map(String.init))
    }

    /// Picks the destination out of `ssh [options] destination [command]`.
    static func sshDestination(fromArguments args: [String]) -> String? {
        let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")
        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("-") {
                if arg.count == 2, let flag = arg.last, takesValue.contains(flag) { i += 1 }
                i += 1
                continue
            }
            return arg
        }
        return nil
    }

    // MARK: - "E.T. is open" signal for push notifications

    // et-notify (nixos-config) skips pushes while E.T. is open. tmux can't
    // tell a live control client from one whose SSH session lingers after
    // iOS killed the app (control commands don't update client_activity),
    // so E.T. touches a heartbeat file every 20 s while connected and
    // removes it when it disconnects. et-notify treats E.T. as open only
    // if the file is under a minute old.

    private static let heartbeatTouch =
        "run-shell -b 'mkdir -p ~/.local/state/et-notify && touch ~/.local/state/et-notify/foreground'"
    private static let heartbeatClear = "run-shell -b 'rm -f ~/.local/state/et-notify/foreground'"
    private static let heartbeatTouchScript = "mkdir -p ~/.local/state/et-notify && touch ~/.local/state/et-notify/foreground"
    private static let heartbeatClearScript = "rm -f ~/.local/state/et-notify/foreground"

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        guard let client else { return }
        heartbeatTask = Task {
            while !Task.isCancelled {
                await client.post(Self.heartbeatTouch)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Detaches E.T.'s own leftover control clients (TERM=et-ios) from
    /// sessions that ended without closing, e.g. when iOS killed the app.
    private func detachStaleClients() {
        guard let client else { return }
        Task {
            do {
                guard let me = try await client.command("display-message -p '#{client_name}'").textLines.first else { return }
                let rows = try await client.command("list-clients -F '#{client_name} #{client_termname}'").textLines
                for row in rows {
                    let parts = row.split(separator: " ")
                    guard parts.count == 2, parts[1] == "et-ios", parts[0] != me else { continue }
                    log.add("Detaching stale E.T. client \(parts[0])")
                    await client.post("detach-client -t \(TmuxCommand.quote(String(parts[0])))")
                }
            } catch {
                log.add("Stale client check failed: \(error)")
            }
        }
    }

    // MARK: - Window size

    // tmux's window-size "latest" sizes a window for the client that last
    // typed in it, and E.T.'s commands don't count. A window last used on
    // the laptop stays laptop-wide, so programs draw past the phone's edge.
    // So E.T. claims the window it shows (resize-window = fixed size) and
    // releases it (unset window-size = back to automatic) when it stops.

    private var claimsKey: String { "claims.\(server.id.uuidString)" }

    private func claim(_ page: WindowPage) {
        guard let client, let size = terminalSize else { return }
        claimed.insert(page.id)
        saveClaims()
        Task { await client.post(TmuxCommand.claimWindowSize(page.id, columns: size.cols, rows: size.rows)) }
    }

    private func release(_ page: WindowPage) {
        guard let client, claimed.remove(page.id) != nil else { return }
        saveClaims()
        Task { await client.post(TmuxCommand.releaseWindowSize(page.id)) }
    }

    /// Claims left over from a connection that ended without releasing.
    private func releaseStaleClaims() {
        guard let client else { return }
        let stale = (UserDefaults.standard.array(forKey: claimsKey) as? [Int] ?? []).map(WindowID.init)
        for id in stale where id != currentWindowID && windows.contains(where: { $0.id == id }) {
            Task { await client.post(TmuxCommand.releaseWindowSize(id)) }
        }
        claimed = []
        saveClaims()
    }

    private func saveClaims() {
        UserDefaults.standard.set(claimed.map(\.rawValue), forKey: claimsKey)
    }

    // MARK: - Presets

    private var presetKey: String { "presets.\(server.id.uuidString)" }

    func preset(for page: WindowPage) -> KeyPreset {
        if let chosen = presetChoices[page.name] { return chosen }
        // A window running claude over ssh shows "ssh", so the name matters too.
        let looksLikeClaude = page.currentCommand == "claude" || page.name.localizedCaseInsensitiveContains("claude")
            || page.title.localizedCaseInsensitiveContains("claude")
            || page.mm?.command.localizedCaseInsensitiveContains("claude") == true
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
        if let link = page.mm {
            renameMm(machine: link.machine, name: link.name, to: name)
            return
        }
        guard let client, !name.isEmpty else { return }
        Task { await client.post(TmuxCommand.renameWindow(page.id, to: name)) }
    }

    func closeWindow(_ page: WindowPage) {
        if let link = page.mm {
            endMm(machine: link.machine, name: link.name)
            return
        }
        guard let client else { return }
        Task { await client.post(TmuxCommand.killWindow(page.id)) }
    }

    // MARK: - Input and size

    func send(_ bytes: [UInt8], to page: WindowPage) {
        // Anything typed after dictation means the dictated text is no
        // longer at the end of the input line, so Edit can't take it back.
        page.terminal.dismissDictationPrompt()
        if let link = page.mm {
            guard !page.readOnly else { return }
            guard let input = link.input else {
                log.add("Input dropped: \(page.name) not attached")
                return
            }
            input.yield(bytes)
            return
        }
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
        page.terminal.dismissDictationPrompt()
        guard !text.isEmpty else { return }
        send(Array(text.utf8), to: page)
        page.terminal.offerEdit(text)
    }

    /// Hints for the speech recognizer: window names and common commands.
    /// The window's last "Next:" paragraph, for the speaker button. Reads
    /// the pane from tmux (screen plus recent history, wrapped lines
    /// joined), which is right even if our copy of a full-screen program
    /// drifted; falls back to our copy. A miss logs the screen's tail.
    func nextStep(in page: WindowPage) async -> String? {
        var tmuxText: String?
        if let client {
            tmuxText = try? await client.command("capture-pane -p -J -t \(page.pane) -S -300").textLines.joined(separator: "\n")
        }
        if let text = tmuxText, let next = NextStep.extract(from: text) { return next }
        let local = page.terminal.frozenText().text
        if let next = NextStep.extract(from: local) { return next }
        let tail = (tmuxText ?? local).split(separator: "\n", omittingEmptySubsequences: false).suffix(15)
        log.add("No Next: in \(page.name) (\(tmuxText == nil ? "local copy" : "tmux")). Last lines:\n" + tail.joined(separator: "\n"))
        return nil
    }

    /// Claude's whole last reply in the window, summarized for listening.
    func summarizeLastReply(in page: WindowPage) async throws -> String {
        let text: String
        if page.mm != nil {
            text = page.terminal.frozenText().text
        } else {
            guard let client else { throw SummaryError.notConnected }
            text = (try? await client.command("capture-pane -p -J -t \(page.pane) -S -300").textLines.joined(separator: "\n"))
                ?? page.terminal.frozenText().text
        }
        guard let reply = ClaudeReply.extract(from: text) else { throw SummaryError.noReply }
        return try await summarize(reply)
    }

    /// Asks the summary model (SummarySettings) via curl on the tmux server.
    func summarize(_ text: String) async throws -> String {
        try await complete(system: SummarySettings.prompt, user: text, maxTokens: 200)
    }

    /// One chat completion on the summary model (SummarySettings), via curl
    /// on the tmux server: summaries and the Copilot.
    func complete(system: String, user text: String, maxTokens: Int) async throws -> String {
        guard let connection else { throw SummaryError.notConnected }
        let provider = SummarySettings.provider
        var body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": text]],
            // Grok models may reason first, and that counts against the limit.
            "max_tokens": provider == .grok ? max(4000, maxTokens * 4) : maxTokens,
            "temperature": 0.3,
        ]
        // llama-server / Qwen: answer directly, no thinking pass.
        if provider != .grok { body["chat_template_kwargs"] = ["enable_thinking": false] }
        if SummarySettings.isConfigured, !SummarySettings.model.isEmpty {
            body["model"] = SummarySettings.model
        } else if !SummarySettings.isConfigured {
            // Filled in on the server from <prefix>_MODEL; llama-server
            // takes an empty one.
            body["model"] = "__ET_MODEL__"
        }
        let payload = try JSONSerialization.data(withJSONObject: body).base64EncodedString()
        var script = "set --; k=; m=; "
        if SummarySettings.isConfigured {
            // Set in the app.
            script += "u=\(TmuxCommand.quote(SummarySettings.url)); "
            if !SummarySettings.keyFile.isEmpty {
                script += "f=\(TmuxCommand.quote(SummarySettings.keyFile)); k=$(sed -n 's/^[A-Za-z_]*KEY=//p' \"$f\" | head -1); " +
                    "[ -n \"$k\" ] || k=$(cat \"$f\"); "
            }
        } else {
            // The server's own file (<prefix>_URL, _KEY or _KEY_CMD, _MODEL),
            // so the key never has to be typed on the phone. _KEY_CMD prints
            // a fresh token (Grok: Hermes's xAI sign-in).
            let p = provider.envPrefix
            script += "u=; c=; for f in \"${XDG_CONFIG_HOME:-$HOME/.config}/et/summary.env\" /run/secrets/rendered/et-summary.env; do " +
                "[ -r \"$f\" ] || continue; u=$(sed -n 's/^\(p)_URL=//p' \"$f\" | head -1); " +
                "k=$(sed -n 's/^\(p)_KEY=//p' \"$f\" | head -1); c=$(sed -n 's/^\(p)_KEY_CMD=//p' \"$f\" | head -1); " +
                "m=$(sed -n 's/^\(p)_MODEL=//p' \"$f\" | head -1); break; done; " +
                "[ -n \"$u\" ] || { echo ET_NO_SUMMARY_CONFIG; exit 3; }; " +
                "if [ -n \"$c\" ]; then k=$(\"$c\" 2>/dev/null | tail -n 1); " +
                "[ -n \"$k\" ] || { echo ET_KEY_CMD_FAILED; \"$c\" 2>&1 | tail -n 3; exit 4; }; fi; "
        }
        // Model names are plain [A-Za-z0-9._-], safe inside sed.
        script += "[ -n \"$k\" ] && set -- -H \"Authorization: Bearer $k\"; " +
            "printf %s \(TmuxCommand.quote(payload)) | base64 -d | " +
            "sed \"s/__ET_MODEL__/$m/\" | " +
            "curl -sS -m 120 -H 'Content-Type: application/json' \"$@\" -d @- \"$u\""
        let started = Date()
        let (output, code) = try await connection.run(script)
        try Task.checkCancellation()
        if code == 3, output.contains("ET_NO_SUMMARY_CONFIG") { throw SummaryError.notConfigured }
        if code == 4, output.hasPrefix("ET_KEY_CMD_FAILED") {
            log.add("Summary key command failed: \(output.suffix(300))")
            throw SummaryError.failed(provider == .grok
                ? "Grok sign-in failed: run hermes auth add xai-oauth on the server"
                : "The summary key command failed")
        }
        guard code == 0, let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.add("Summary failed (exit \(code)): \(output.prefix(300))")
            throw SummaryError.failed(code == 0 ? "Unexpected answer from the summary model" : "Summary model unreachable: \(output.prefix(120))")
        }
        // OpenAI style: {"error": {"message": …}}; xAI: {"error": "…"}.
        if let error = json["error"] as? [String: Any] {
            throw SummaryError.failed("Summary model: \(error["message"] as? String ?? "error")")
        }
        if let error = json["error"] as? String {
            throw SummaryError.failed("Summary model: \(error)")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var summary = message["content"] as? String else {
            throw SummaryError.failed("Unexpected answer from the summary model")
        }
        // Some models still emit a thinking block.
        if let end = summary.range(of: "</think>") { summary = String(summary[end.upperBound...]) }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        log.add("Summary in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (\(text.count) chars in)")
        guard !summary.isEmpty else { throw SummaryError.failed("The summary model returned nothing") }
        return summary
    }

    /// Claude's transcript for the window, from the machine Claude runs on
    /// (the window's ssh host, else the tmux server). Picks the transcript
    /// holding the last prompt on screen.
    func transcript(for page: WindowPage) async throws -> (host: String, turns: [Transcript.Turn]) {
        guard let connection else { throw SummaryError.notConnected }
        let screen: String
        if page.mm != nil {
            // The terminal's copy: attach asked for 1000 lines of history.
            screen = page.terminal.frozenText().text
        } else {
            guard let client else { throw SummaryError.notConnected }
            screen = (try? await client.command("capture-pane -p -J -t \(page.pane) -S -300").textLines.joined(separator: "\n"))
                ?? page.terminal.frozenText().text
        }
        let needle = ClaudeReply.lastPrompt(from: screen).flatMap(Transcript.needle(fromPrompt:))
        let script = Transcript.fetchScript(needle: needle)
        var host = server.displayName
        let started = Date()
        let output: String
        let code: Int
        if let link = page.mm {
            // On the session's own machine (ExecOn for machines other than the hub).
            host = link.machine
            (output, code) = try await mmRun(script, on: link.machine)
        } else {
            var command = script
            if page.currentCommand == "ssh", let client, let destination = try await sshDestination(of: page, client: client) {
                host = destination
                command = "printf '%s\\n' \(TmuxCommand.quote(script)) | ssh -o BatchMode=yes -o ConnectTimeout=5 \(TmuxCommand.quote(destination)) sh"
            }
            (output, code) = try await connection.run(command)
        }
        if code == 3, output.contains("ET_NO_TRANSCRIPT") { throw SummaryError.failed("No Claude transcripts on \(host)") }
        guard code == 0, let fetched = Transcript.decodeFetchOutput(output) else {
            log.add("Transcript fetch failed on \(host) (exit \(code)): \(output.prefix(300))")
            throw SummaryError.failed("Couldn't read Claude's transcript on \(host)")
        }
        let turns = Transcript.parse(lines: fetched.lines)
        log.add("Transcript \(fetched.path) on \(host): \(turns.count) turns in \(String(format: "%.1f", Date().timeIntervalSince(started))) s" +
            (needle == nil ? " (no prompt on screen; newest)" : ""))
        return (host, turns)
    }

    /// Reads `text` aloud: the server's natural voice if there is one
    /// (VoiceSettings), else the phone's own.
    func say(_ text: String) async {
        if VoiceSettings.natural, let audio = try? await speech(for: text) {
            guard !Task.isCancelled else { return }
            if Speaker.shared.play(audio) { return }
        }
        guard !Task.isCancelled else { return }
        Speaker.shared.speak(text)
    }

    /// mp3 from the speech model at ET_TTS_URL in the server's summary.env,
    /// via curl on the tmux server; nil if none is set up.
    func speech(for text: String) async throws -> Data? {
        guard let connection else { throw SummaryError.notConnected }
        let body: [String: Any] = [
            "model": "mlx-community/Kokoro-82M-bf16", "input": text,
            "voice": VoiceSettings.voice, "response_format": "mp3",
        ]
        let payload = try JSONSerialization.data(withJSONObject: body).base64EncodedString()
        let script = "set --; u=; k=; for f in \"${XDG_CONFIG_HOME:-$HOME/.config}/et/summary.env\" /run/secrets/rendered/et-summary.env; do " +
            "[ -r \"$f\" ] || continue; u=$(sed -n 's/^ET_TTS_URL=//p' \"$f\" | head -1); " +
            "k=$(sed -n 's/^ET_TTS_KEY=//p' \"$f\" | head -1); [ -n \"$k\" ] || k=$(sed -n 's/^ET_SUMMARY_KEY=//p' \"$f\" | head -1); " +
            "[ -n \"$u\" ] && break; done; " +
            "[ -n \"$u\" ] || { echo ET_NO_TTS_CONFIG; exit 3; }; " +
            "[ -n \"$k\" ] && set -- -H \"Authorization: Bearer $k\"; t=$(mktemp) || exit 4; " +
            "printf %s \(TmuxCommand.quote(payload)) | base64 -d | curl -sSf -m 60 -H 'Content-Type: application/json' \"$@\" -d @- -o \"$t\" \"$u\" " +
            "&& base64 < \"$t\"; c=$?; rm -f \"$t\"; exit $c"
        let started = Date()
        let (output, code) = try await connection.run(script)
        try Task.checkCancellation()
        if code == 3, output.contains("ET_NO_TTS_CONFIG") { return nil }
        guard code == 0, let audio = Data(base64Encoded: output, options: .ignoreUnknownCharacters), audio.count > 1000 else {
            log.add("Speech failed (exit \(code)): \(output.prefix(300))")
            throw SummaryError.failed("Voice model unreachable")
        }
        log.add("Speech in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (\(audio.count / 1024) KB)")
        return audio
    }

    /// Window names and the last ~400 lines of each window, for dictation
    /// names (Vocabulary).
    func refreshVocabularyFromScreens() {
        let screens = windows.map { page in
            page.terminal.frozenText().text.split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(400).joined(separator: "\n")
        }
        Vocabulary.shared.refreshFromScreens(windowNames: windows.map(\.name) + [server.host], screens: screens)
    }

    /// Finds git repos and their files for dictation (Vocabulary): on the
    /// tmux host (pane directories first), and on each host a window has
    /// ssh'd to, reached from the tmux host with its own keys.
    func discoverVocabulary() async {
        if mode == .manymux {
            await discoverMmVocabulary()
            return
        }
        guard let connection, let client else { return }
        Vocabulary.shared.setDiscoveryStatus("Searching \(server.displayName)…")
        do {
            let format = TmuxCommand.quote("#{pane_pid} #{pane_current_path}")
            let reply = try await client.command("list-panes -s -F \(format)")
            var pids: [Int] = []
            var dirs: [String] = []
            for line in reply.textLines {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if let pid = parts.first.flatMap({ Int($0) }) { pids.append(pid) }
                if parts.count == 2, !dirs.contains(parts[1]) { dirs.append(parts[1]) }
            }
            var destinations: [(label: String, args: [String])] = []
            if !pids.isEmpty {
                let ssh = try await connection.run(VocabDiscovery.sshScript(pids: pids)).output
                for line in ssh.split(separator: "\n") where line.hasPrefix("S ") {
                    if let dest = VocabDiscovery.destination(fromSSH: String(line.dropFirst(2))),
                       !destinations.contains(where: { $0.label == dest.label }) {
                        destinations.append(dest)
                    }
                }
            }
            let script = VocabDiscovery.searchScript(localDirs: dirs, destinations: Array(destinations.prefix(6)))
            let output = try await connection.run(script).output
            let host = server.displayName
            let repos = VocabDiscovery.parse(output, localLabel: host)
            Vocabulary.shared.setRepos(repos, hosts: [host] + destinations.prefix(6).map(\.label))
            log.add("Dictation names: \(repos.count) repos on \(([host] + destinations.map(\.label)).joined(separator: ", "))")
        } catch {
            Vocabulary.shared.setDiscoveryStatus("Search failed: \(error.localizedDescription)")
            log.add("Dictation name search failed: \(error)")
        }
    }

    /// Pastes clipboard text into the window. When the program asked for
    /// bracketed paste (shells, Claude Code), the text is marked as a paste,
    /// so a multi-line paste arrives as one block instead of running line by
    /// line.
    func paste(_ text: String, to page: WindowPage) {
        guard !text.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if page.terminal.terminal.bracketedPasteMode {
            send(Array("\u{1b}[200~".utf8) + Array(text.utf8) + Array("\u{1b}[201~".utf8), to: page)
        } else {
            send(Array(text.replacingOccurrences(of: "\n", with: "\r").utf8), to: page)
        }
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
            guard !Task.isCancelled else { return }
            if mode == .manymux {
                mmResized()
                return
            }
            guard let client, let size = terminalSize else { return }
            if let sent = sentSize, sent == size { return }
            sentSize = size
            log.add("Resize \(size.cols)x\(size.rows)")
            await client.post(TmuxCommand.refreshClientSize(columns: size.cols, rows: size.rows))
            if let page = currentWindow { claim(page) }
        }
    }
}

// MARK: - manymux (PLAN-manymux §3, §4 B3)

extension SessionController {
    /// Moves between the Machines screen (manymux) and tmux. Reconnects.
    func setMode(_ newMode: Mode) {
        guard mode != newMode, newMode == .tmux || server.isIroh else { return }
        log.add("Mode: \(newMode == .tmux ? "tmux" : "manymux")")
        disconnect()
        currentWindowID = nil
        windows = []
        mmPages = [:]
        mmMachine = nil
        machines = []
        sessionName = nil
        mode = newMode
        reconnect()
    }

    /// Where a machine's calls go: the hub and network machines answer for
    /// themselves (`machine: nil`); machines reached by ssh from the hub
    /// go through the hub by name (until they join the network, N6).
    private func route(_ machine: String) throws -> (host: IrohHost, machine: String?) {
        guard let hub = connection as? IrohHost else { throw SummaryError.notConnected }
        if machine == hubName { return (hub, nil) }
        guard networkMachines.contains(where: { $0.name == machine }) else { return (hub, machine) }
        guard let host = mmHosts[machine] else {
            throw HostError.unreachable(mmConnecting.contains(machine) ? "Connecting…" : "Not reachable: \(mmHostErrors[machine] ?? "not connected")")
        }
        return (host, nil)
    }

    /// Every machine with its own connection (hub and network machines),
    /// by name: the Files screen asks each.
    func directHosts() -> [String: IrohHost] {
        var hosts = mmHosts
        if let hub = connection as? IrohHost, let hubName { hosts[hubName] = hub }
        return hosts
    }

    /// The network's machines other than the hub, by name.
    private var networkMachines: [NetMember] {
        (network?.members ?? [])
            .filter { $0.isMachine && $0.endpointId != server.irohEndpointId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A machine name from a push or an event (a network name, or a node's
    /// host name for itself) → the name on the Machines screen.
    func mmMachineName(for name: String) -> String {
        if name == hubHostName, let hubName { return hubName }
        if mmHostNames[name] != nil { return name }
        return mmHostNames.first { $0.value == name }?.key ?? name
    }

    private func startManymux(_ host: IrohHost) async throws {
        state = .connecting("Loading machines…")
        let hostName = try await host.hostName()
        hubHostName = hostName
        await loadNetwork(host)
        hubName = network?.members.first { $0.endpointId == server.irohEndpointId }?.name ?? hostName
        // Give the network machines a moment, so the first list has them.
        connectNetworkMachines()
        for _ in 0..<25 where !mmConnecting.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await refreshMachines()
        guard (connection as? IrohHost) === host else { return }
        state = .connected
        isReconnecting = false
        reconnectStarted = nil
        reconnectAttempt = 0
        log.add("Ready: manymux on \(machines.map { "\($0.name) (\($0.error == nil ? "\($0.sessions.count)" : "error"))" }.joined(separator: ", "))")
        tasks.append(Task { [weak self] in
            let error = await host.waitClosed()
            self?.mmConnectionEnded(host, error: error)
        })
        startMmEvents(host, machine: hubName ?? hostName, hub: host)
        // Each machine's events refresh its list; a full list every 30 s in
        // case an event was missed. (Every `mm` call is an `mm agent` start.)
        tasks.append(Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, (self.connection as? IrohHost) === host else { return }
                await self.refreshMachines()
            }
        })
        // "E.T. is open" to every connected machine: none sends a push for
        // 60 s. An etd without `Foreground` gets the heartbeat file instead.
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await host.foreground(seconds: 60)
                } catch {
                    _ = try? await host.run(Self.heartbeatTouchScript)
                }
                for member in self.mmHosts.values {
                    Task { try? await member.foreground(seconds: 60) }
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
        // Back from the background, or a reconnect: the visible session again.
        if let page = currentWindow, page.mm != nil { attachMm(page) }
        openPendingWindow()
        Task { await registerPushToken() }
        Task { await discoverVocabulary() }
    }

    /// A script on a machine: `exec` on the machine itself, or `execOn`
    /// through the hub for a machine reached by ssh.
    func mmRun(_ script: String, on machine: String) async throws -> (output: String, exitCode: Int) {
        let route = try route(machine)
        if let name = route.machine { return try await route.host.run(script, on: name) }
        return try await route.host.run(script)
    }

    // MARK: The etd network

    /// The member list from the hub (`Network`); again every 30 s on refresh.
    private func loadNetwork(_ hub: IrohHost) async {
        networkLoaded = Date()
        do {
            let info = try await hub.network()
            guard (connection as? IrohHost) === hub else { return }
            if info != network {
                log.add("Network \(info.name): \(info.members.map { "\($0.name)\($0.isMachine ? "" : " (device)")" }.joined(separator: ", "))")
                network = info
            }
            networkError = nil
        } catch {
            guard (connection as? IrohHost) === hub else { return }
            if networkError == nil { log.add("Network: \(error)") }
            networkError = Self.describeMm(error)
        }
    }

    /// Connects to each network machine that has no connection (one try
    /// per 15 s each), and drops machines that left the network.
    private func connectNetworkMachines() {
        guard let hub = connection as? IrohHost else { return }
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
                    guard (self.connection as? IrohHost) === hub, self.networkMachines.contains(member) else {
                        await host.close()
                        return
                    }
                    self.log.add("Connected to \(name) (\(hostName)) over iroh, \(host.pathLabel ?? "no path yet")")
                    self.mmHosts[name] = host
                    self.mmHostNames[name] = hostName
                    self.mmHostErrors[name] = nil
                    try? await host.foreground(seconds: 60)
                    self.startMmEvents(host, machine: name, hub: hub)
                    self.tasks.append(Task { [weak self] in
                        let error = await host.waitClosed()
                        guard let self, self.mmHosts[name] === host else { return }
                        self.log.add("\(name): connection ended: \(error)")
                        self.dropMember(name)
                        self.mmHostErrors[name] = Self.describeMm(error)
                        self.scheduleMmRefresh(name)
                    })
                    self.scheduleMmRefresh(name)
                } catch {
                    self.log.add("\(name): \(error)")
                    self.mmHostErrors[name] = Self.describeMm(error)
                }
            }
        }
    }

    private func dropMember(_ name: String) {
        let host = mmHosts.removeValue(forKey: name)
        let feed = mmEventFeeds.removeValue(forKey: name)
        mmHostNames[name] = nil
        Task {
            await feed?.close()
            await host?.close()
        }
    }

    /// Dictation names: git repos and files on every machine.
    private func discoverMmVocabulary() async {
        let names = machines.filter { $0.error == nil }.map(\.name)
        guard !names.isEmpty else { return }
        Vocabulary.shared.setDiscoveryStatus("Searching \(names.joined(separator: ", "))…")
        let script = VocabDiscovery.searchScript(localDirs: [], destinations: [])
        var repos: [DiscoveredRepo] = []
        var searched: [String] = []
        for name in names {
            do {
                let output = try await mmRun(script, on: name).output
                repos += VocabDiscovery.parse(output, localLabel: name)
                searched.append(name)
            } catch {
                log.add("Dictation name search on \(name) failed: \(error)")
            }
        }
        guard !searched.isEmpty else {
            Vocabulary.shared.setDiscoveryStatus("Search failed")
            return
        }
        Vocabulary.shared.setRepos(repos, hosts: searched)
        log.add("Dictation names: \(repos.count) repos on \(searched.joined(separator: ", "))")
    }

    private func mmConnectionEnded(_ host: IrohHost, error: any Error) {
        guard (connection as? IrohHost) === host else { return }
        log.add("Connection ended: \(error)")
        closeConnection()
        state = .disconnected
        if !intentionalDisconnect { scheduleReconnect() }
    }

    /// Lists every machine's sessions (in parallel; each call is its own stream).
    /// Order: the hub, the network's machines by name, then the machines
    /// the hub reaches by ssh. A machine that fails shows its error.
    func refreshMachines() async {
        guard let host = connection as? IrohHost, let hub = hubName else { return }
        if networkLoaded.map({ Date().timeIntervalSince($0) > 30 }) ?? true { await loadNetwork(host) }
        connectNetworkMachines()
        let networkNames = networkMachines.map(\.name)
        var names = [hub] + networkNames
        do {
            names += try await host.machines().filter { $0 != hub && $0 != hubHostName && !networkNames.contains($0) }
        } catch {
            log.add("manymux machines: \(error)")
        }
        let routes = names.map { name in Result { try route(name) } }
        let listed = await withTaskGroup(of: (Int, MmMachine).self) { group in
            for (i, name) in names.enumerated() {
                let route = routes[i]
                let direct = networkNames.contains(name)
                group.addTask {
                    do {
                        let (host, machine) = try route.get()
                        return (i, MmMachine(name: name, sessions: try await host.mmList(machine: machine)))
                    } catch {
                        return (i, MmMachine(name: name, sessions: [], error: Self.listError(error, direct: direct)))
                    }
                }
            }
            var out: [(Int, MmMachine)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard (connection as? IrohHost) === host else { return }
        if listed != machines { machines = listed }
        syncPages()
        publishForShare()
        if currentWindow == nil { await checkCheckpoint(host) }
    }

    /// One machine's list, after one of its events; the others stay as
    /// they are. A machine not on the screen yet gets the full list.
    private func refreshMachine(_ name: String) async {
        guard let host = connection as? IrohHost else { return }
        guard machines.contains(where: { $0.name == name }) else {
            await refreshMachines()
            return
        }
        let direct = networkMachines.contains { $0.name == name }
        let listed: MmMachine
        do {
            let (target, machine) = try route(name)
            listed = MmMachine(name: name, sessions: try await target.mmList(machine: machine))
        } catch {
            listed = MmMachine(name: name, sessions: [], error: Self.listError(error, direct: direct))
        }
        guard (connection as? IrohHost) === host, let i = machines.firstIndex(where: { $0.name == name }) else { return }
        if machines[i] != listed { machines[i] = listed }
        syncPages()
        publishForShare()
    }

    nonisolated private static func listError(_ error: any Error, direct: Bool) -> String {
        let text = describeMm(error)
        return !direct || text.hasPrefix("Not reachable") || text == "Connecting…" ? text : "Not reachable: \(text)"
    }

    /// Machines screen: compares the hub's checkpoint with the ring.
    private func checkCheckpoint(_ host: IrohHost) async {
        guard let hub = hubName, let output = try? await host.run("mm checkpoint show").output else { return }
        guard (connection as? IrohHost) === host else { return }
        var running: Set<String> = []
        for machine in machines {
            for session in machine.sessions {
                running.insert(machine.name == hub ? session.name : machine.name + "/" + session.name)
            }
        }
        if let checkpoint = MmCheckpoint(show: output) {
            let missing = checkpoint.missing(running: running)
            mmMissing = missing.isEmpty ? nil : (checkpoint, missing)
        } else {
            mmMissing = nil
        }
    }

    /// Starts the saved sessions that are not running (running ones are
    /// left alone), shows what it printed, and lists again.
    func restoreCheckpoint() {
        guard let host = connection as? IrohHost, !mmRestoring else { return }
        mmRestoring = true
        Task {
            defer { mmRestoring = false }
            do {
                let (output, code) = try await host.run("mm checkpoint restore")
                log.add("Checkpoint restore (exit \(code)): \(output.suffix(300))")
                let text = MmCheckpoint.stripANSI(output).trimmingCharacters(in: .whitespacesAndNewlines)
                mmRestoreOutput = (text.isEmpty ? "No output" : text) + (code == 0 ? "" : "\n\n(exit \(code))")
            } catch {
                log.add("Checkpoint restore failed: \(error)")
                mmRestoreOutput = "Restore failed: \(Self.describeMm(error))"
            }
            await refreshMachines()
        }
    }

    nonisolated static func describeMm(_ error: any Error) -> String {
        switch error {
        case HostError.other(let detail), HostError.closed(let detail), HostError.unreachable(let detail): detail
        default: "\(error)"
        }
    }

    /// Events come in bursts (title changes); one list a second is enough.
    /// `machine`: only that machine's list; nil: every machine's.
    private func scheduleMmRefresh(_ machine: String? = nil) {
        if let machine { mmRefreshNames.insert(machine) } else { mmRefreshAll = true }
        guard mmRefreshTask == nil else { return }
        mmRefreshTask = Task {
            try? await Task.sleep(for: .seconds(1))
            mmRefreshTask = nil
            let all = mmRefreshAll, names = mmRefreshNames
            mmRefreshAll = false
            mmRefreshNames = []
            guard !Task.isCancelled else { return }
            if all {
                await refreshMachines()
            } else {
                for name in names.sorted() { await refreshMachine(name) }
            }
        }
    }

    /// The pages are one ring of every session on every machine: the hub's
    /// first, then each machine in `machines()` order, sessions in list
    /// order. The visible page stays even if a list misses it.
    private func syncPages() {
        guard mode == .manymux else { return }
        var pages: [WindowPage] = []
        var keep: Set<String> = []
        for machine in machines {
            for (i, info) in machine.sessions.enumerated() {
                keep.insert(machine.name + "/" + info.name)
                let page = mmPage(machine: machine.name, name: info.name)
                page.index = i
                page.mm?.command = info.command
                if page.title != info.title { page.title = info.title }
                let program = Manymux.programName(info.command)
                if page.currentCommand != program { page.currentCommand = program }
                if page.id != currentWindowID, page.hasBell != (info.bells > 0) { page.hasBell = info.bells > 0 }
                pages.append(page)
            }
        }
        if let current = currentWindow, !pages.contains(where: { $0 === current }) { pages.append(current) }
        for (key, page) in mmPages where !keep.contains(key) && page !== currentWindow && !isAttached(page) { mmPages[key] = nil }
        if pages.map(\.id) != windows.map(\.id) { windows = pages }
    }

    private func mmPage(machine: String, name: String) -> WindowPage {
        let key = machine + "/" + name
        if let page = mmPages[key] { return page }
        nextMmID += 1
        let page = WindowPage(mm: MmPage(machine: machine, name: name), id: WindowID(nextMmID), terminal: TerminalHost(log: log))
        wire(page)
        mmPages[key] = page
        return page
    }

    /// The machine shown in the header (the visible page's).
    var mmMachineName: String? { currentWindow?.mm?.machine ?? mmMachine }

    /// Opens a session page (tap on the Machines screen).
    func openMm(machine: String, name: String, readOnly: Bool = false) {
        mmMachine = machine
        syncPages()
        let page = mmPage(machine: machine, name: name)
        if !windows.contains(where: { $0 === page }) { windows.append(page) }
        if page.readOnly != readOnly {
            if isAttached(page) { detachMm(page) }
            page.readOnly = readOnly
        }
        if currentWindowID == page.id {
            if !isAttached(page) { attachMm(page) }
        } else {
            currentWindowID = page.id
        }
    }

    /// The header's machine picker: that machine's first session, or the
    /// Machines screen if it has none.
    func openMachine(_ name: String) {
        guard let machine = machines.first(where: { $0.name == name }) else { return }
        if let first = machine.sessions.first {
            openMm(machine: name, name: first.name)
        } else {
            showMachines()
            flash("No sessions on \(name)")
        }
    }

    /// Back to the Machines screen; the session keeps running.
    func showMachines() {
        currentWindowID = nil
    }

    private func isAttached(_ page: WindowPage) -> Bool {
        mmAttachedPages.contains { $0 === page }
    }

    /// From `currentWindowID`'s didSet. A page still attached is current
    /// already; another paints its peek at once, then attaches. The page
    /// before stays attached (at most two). Back to Machines detaches all.
    fileprivate func mmCurrentChanged() {
        guard let page = currentWindow, page.mm != nil else {
            for attached in mmAttachedPages {
                detachMm(attached)
                attached.readOnly = false
            }
            Task { await refreshMachines() }
            return
        }
        mmMachine = page.mm?.machine
        if isAttached(page) {
            mmAttachedPages.removeAll { $0 === page }
            mmAttachedPages.append(page)
            page.hasActivity = false
            mmResized()
        } else {
            attachMm(page)
            paintPeek(page)
        }
        prefetchPeeks(around: page)
    }

    /// The cached screen now, then a fresh one, until the attach's first output.
    private func paintPeek(_ page: WindowPage) {
        guard let link = page.mm, let (host, machine) = try? route(link.machine) else { return }
        if let screen = link.peek {
            page.terminal.setSize(cols: screen.cols, rows: screen.rows)
            page.terminal.reset(with: screen.bytes)
        }
        let generation = link.generation
        let name = link.name
        Task {
            guard let screen = try? await host.mmPeek(machine: machine, names: [name]).first else { return }
            link.peek = screen
            guard link.generation == generation, link.awaitingOutput else { return }
            page.terminal.setSize(cols: screen.cols, rows: screen.rows)
            page.terminal.reset(with: screen.bytes)
        }
    }

    /// Peeks of the sessions on either side in the ring, so the next swipe
    /// paints at once.
    private func prefetchPeeks(around page: WindowPage) {
        guard windows.count > 1, let i = windows.firstIndex(where: { $0 === page }) else { return }
        let neighbours = [windows[(i + 1) % windows.count], windows[(i - 1 + windows.count) % windows.count]]
            .filter { !isAttached($0) }
        var byMachine: [String: [WindowPage]] = [:]
        for neighbour in neighbours where neighbour.mm != nil {
            if byMachine[neighbour.mm!.machine]?.contains(where: { $0 === neighbour }) == true { continue }
            byMachine[neighbour.mm!.machine, default: []].append(neighbour)
        }
        for (machine, pages) in byMachine {
            guard let (host, api) = try? route(machine) else { continue }
            let names = pages.map(\.name)
            Task {
                guard let screens = try? await host.mmPeek(machine: api, names: names) else { return }
                for screen in screens {
                    pages.first { $0.name == screen.name }?.mm?.peek = screen
                }
            }
        }
    }

    /// Forgets a page's attachment; returns it so the caller can detach it.
    @discardableResult
    fileprivate func releaseMm(_ page: WindowPage) -> MmAttachHandle? {
        guard let link = page.mm else { return nil }
        link.generation = nil
        link.task?.cancel()
        link.task = nil
        link.input?.finish()
        link.input = nil
        link.sentSize = nil
        link.awaitingOutput = false
        let attachment = link.attachment
        link.attachment = nil
        mmAttachedPages.removeAll { $0 === page }
        return attachment
    }

    private func detachMm(_ page: WindowPage) {
        guard let attachment = releaseMm(page) else { return }
        log.add("Detached \(page.mm?.machine ?? "")/\(page.name)")
        Task { await attachment.detach() }
    }

    private func attachMm(_ page: WindowPage) {
        guard let hub = connection as? IrohHost, let link = page.mm, state == .connected else { return }
        let host: IrohHost, machine: String?
        do {
            (host, machine) = try route(link.machine)
        } catch {
            flash("\(link.machine): \(Self.describeMm(error))")
            if currentWindowID == page.id { currentWindowID = nil }
            return
        }
        detachMm(page)
        mmAttachedPages.append(page)
        while mmAttachedPages.count > 2, let oldest = mmAttachedPages.first(where: { $0 !== page }) {
            detachMm(oldest)
            oldest.readOnly = false
        }
        let generation = UUID()
        link.generation = generation
        link.awaitingOutput = true
        let (input, continuation) = AsyncStream<[UInt8]>.makeStream()
        link.input = continuation
        let size = terminalSize ?? (cols: page.terminal.terminal.cols, rows: page.terminal.terminal.rows)
        let name = link.name
        let readOnly = page.readOnly
        log.add("Attaching \(link.machine)/\(name) \(size.cols)x\(size.rows)\(readOnly ? " view-only" : "")")
        link.task = Task {
            do {
                let attachment = try await host.mmAttach(machine: machine, name: name, cols: size.cols, rows: size.rows,
                                                         history: 1000, readOnly: readOnly)
                guard link.generation == generation else {
                    await attachment.detach()
                    return
                }
                link.attachment = attachment
                link.sentSize = size
                link.sessionSize = (attachment.cols, attachment.rows)
                page.terminal.setSize(cols: attachment.cols, rows: attachment.rows)
                // One writer, so keystrokes stay in order.
                Task {
                    for await bytes in input {
                        do { try await attachment.write(bytes) } catch { break }
                    }
                }
                while true {
                    let output = try await attachment.next()
                    guard link.generation == generation else { return }
                    link.retries = 0
                    if !handleMm(output, page: page) { return }
                }
            } catch {
                guard link.generation == generation else { return }
                mmAttachEnded(page, hub: hub, error: error)
            }
        }
    }

    /// One output of the attached session; false after `exit`.
    private func handleMm(_ output: MmOut, page: WindowPage) -> Bool {
        guard let link = page.mm else { return false }
        switch output {
        case .history(let bytes), .data(let bytes):
            if link.awaitingOutput {
                // The peek was a stand-in; the attach repaints from scratch.
                link.awaitingOutput = false
                page.terminal.reset(with: [])
            }
            page.terminal.feed(bytes)
            if page.id != currentWindowID { page.hasActivity = true }
        case .resync(let bytes):
            link.awaitingOutput = false
            page.terminal.reset(with: bytes)
        case .size(let cols, let rows):
            link.sessionSize = (cols, rows)
            page.terminal.setSize(cols: cols, rows: rows)
        case .event:
            scheduleMmRefresh(link.machine)
        case .renamed(let name, let refused):
            if let name {
                log.add("Renamed \(link.name) → \(name)")
                mmPages[link.machine + "/" + link.name] = nil
                link.name = name
                page.name = name
                mmPages[link.machine + "/" + name] = page
                scheduleMmRefresh(link.machine)
            } else {
                flash("Rename refused: \(refused ?? "?")")
            }
        case .exit(let code):
            log.add("\(link.machine)/\(link.name) exited (\(code))")
            flash("\(link.name) ended (\(code))")
            releaseMm(page)
            page.readOnly = false
            mmPages[link.machine + "/" + link.name] = nil
            if currentWindowID == page.id { currentWindowID = nil }
            windows.removeAll { $0 === page }
            Task { await refreshMachines() }
            return false
        }
        return true
    }

    /// The attach stream failed. A lost connection reconnects (and attaches
    /// again); a closed stream on a live connection attaches again, up to
    /// three times; anything else goes back to the Machines screen.
    private func mmAttachEnded(_ page: WindowPage, hub: IrohHost, error: any Error) {
        log.add("Attach \(page.name) ended: \(error)")
        releaseMm(page)
        guard (connection as? IrohHost) === hub, state == .connected, let link = page.mm else { return }
        if case HostError.closed = error, link.retries < 3 {
            link.retries += 1
            Task {
                try? await Task.sleep(for: .seconds(1))
                if self.currentWindow === page, !self.isAttached(page) { self.attachMm(page) }
            }
            return
        }
        flash("\(page.name): \(Self.describeMm(error))")
        if currentWindowID == page.id {
            page.readOnly = false
            currentWindowID = nil
        }
    }

    /// The view changed size: ask the session for it (not view-only). The
    /// answer (`size`) sets the terminal.
    fileprivate func mmResized() {
        guard let page = currentWindow, let link = page.mm, let attachment = link.attachment,
              let size = terminalSize else { return }
        if page.readOnly || link.sentSize.map({ $0 == size }) == true {
            // Not asking: keep showing the session's size.
            if let taken = link.sessionSize { page.terminal.setSize(cols: taken.cols, rows: taken.rows) }
            return
        }
        link.sentSize = size
        log.add("Resize \(link.name) \(size.cols)x\(size.rows)")
        Task {
            do { try await attachment.resize(cols: size.cols, rows: size.rows) } catch { log.add("Resize failed: \(error)") }
        }
    }

    /// One machine connection's feed (`machine`: its name here). A node
    /// also reports the machines it watches; each event is taken from the
    /// feed of the machine it happened on, so a bell counts once.
    private func startMmEvents(_ host: IrohHost, machine: String, hub: IrohHost) {
        let alive = { [weak self] in
            guard let self, (self.connection as? IrohHost) === hub else { return false }
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
                    self.mmEventFeeds[machine] = feed
                    while true {
                        var event = try await feed.next()
                        if host === hub {
                            // The hub's own events, and those of the machines it reaches by ssh.
                            if event.machine == self.hubHostName { event.machine = machine }
                            if self.networkMachines.contains(where: { $0.name == event.machine })
                                || self.mmHostNames.values.contains(event.machine) { continue }
                        } else {
                            guard event.machine == self.mmHostNames[machine] || event.machine == machine else { continue }
                            event.machine = machine
                        }
                        self.mmEvent(event)
                    }
                } catch {
                    guard alive() else { return }
                    self.log.add("manymux events (\(machine)): \(error)")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        })
    }

    /// A bell sets the page's dot (no list); a session that started, ended
    /// or changed its title lists its machine again.
    private func mmEvent(_ event: MmEventInfo) {
        switch event.kind {
        case .bell, .notify:
            // The attached session's own bell arrives in its output.
            let page = mmPages[event.machine + "/" + event.session]
            if let page, isAttached(page) { break }
            if let page, windows.contains(where: { $0 === page }) {
                bellRang(in: page)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                flash("\(event.machine)/\(event.session) needs you")
                scheduleMmRefresh(event.machine)
            }
        case .titleChanged, .exited, .started:
            scheduleMmRefresh(event.machine)
        }
    }

    func flash(_ text: String) {
        mmNotice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if mmNotice == text { mmNotice = nil }
        }
    }

    // MARK: Spawn, rename, end, paste

    /// Starts a session and opens it. `command` empty = the login shell.
    func spawnMm(machine: String, name: String?, command: [String]) {
        guard !mmSpawning else { return }
        let host: IrohHost, api: String?
        do {
            (host, api) = try route(machine)
        } catch {
            flash("Couldn't start: \(Self.describeMm(error))")
            return
        }
        let size = terminalSize ?? (cols: 80, rows: 24)
        mmSpawning = true
        Task {
            defer { mmSpawning = false }
            do {
                let got = try await host.mmSpawn(machine: api, name: name, command: command,
                                                 cols: size.cols, rows: size.rows)
                log.add("Spawned \(machine)/\(got): \(command.isEmpty ? "shell" : command.joined(separator: " "))")
                await refreshMachines()
                openMm(machine: machine, name: got)
            } catch {
                log.add("Spawn failed: \(error)")
                flash("Couldn't start: \(Self.describeMm(error))")
            }
        }
    }

    /// The attached page renames through its attachment (the answer updates
    /// the page); others through `mmRename`.
    func renameMm(machine: String, name: String, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != name else { return }
        if let link = mmAttachedPages.compactMap(\.mm).first(where: { $0.machine == machine && $0.name == name }),
           let attachment = link.attachment {
            Task {
                do { try await attachment.rename(to: newName) } catch { flash("Rename failed: \(Self.describeMm(error))") }
            }
            return
        }
        Task {
            do {
                let (host, api) = try route(machine)
                try await host.mmRename(machine: api, name: name, to: newName)
            } catch {
                flash("Rename failed: \(Self.describeMm(error))")
            }
            await refreshMachines()
        }
    }

    /// Ends the session (kills its program). An attached page gets `exit`.
    func endMm(machine: String, name: String) {
        Task {
            do {
                let (host, api) = try route(machine)
                try await host.mmKill(machine: api, name: name)
                log.add("Ended \(machine)/\(name)")
            } catch {
                flash("Couldn't end \(name): \(Self.describeMm(error))")
            }
            await refreshMachines()
        }
    }

    /// Images go in manymux's PASTE frame: the session's machine saves the
    /// file and types its path, and Claude sees it inline.
    fileprivate func pasteMm(_ data: Data, ext: String, to page: WindowPage) {
        let ext = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
        Task {
            if let attachment = page.mm?.attachment, !page.readOnly {
                uploadStatus = "Sending image…"
                do {
                    try await attachment.paste(kind: ext, bytes: data)
                    log.add("Pasted \(data.count) bytes (\(ext)) into \(page.name)")
                    flashUpload("Image sent to \(page.name)")
                } catch {
                    log.add("Paste failed: \(error)")
                    flashUpload("Couldn't send: \(Self.describeMm(error))")
                }
            } else {
                flashUpload(page.readOnly ? "View only" : "\(page.name) isn't attached")
            }
        }
    }
}

// MARK: - The share extension (PLAN-files F7)

extension SessionController {
    /// The machines the share extension offers: the hub and the network's
    /// machines, each with its own endpoint (the extension connects to it
    /// directly), and their sessions. Then sends what the extension left.
    func publishForShare() {
        guard let hubName, let hubId = server.irohEndpointId else { return }
        let shared: [ShareStore.Machine] = machines.compactMap { machine in
            let endpoint: (id: String, relay: String?)
            if machine.name == hubName {
                endpoint = (hubId, server.irohRelayURL)
            } else if let member = networkMachines.first(where: { $0.name == machine.name }) {
                endpoint = (member.endpointId, nil)
            } else {
                return nil // reached by ssh through the hub: no sendFiles there
            }
            return ShareStore.Machine(name: machine.name, endpointId: endpoint.id, relayURL: endpoint.relay,
                                      sessions: machine.sessions.map { ShareStore.Session(name: $0.name, title: $0.title) })
        }
        ShareStore.saveMachines(shared)
        sendShareOutbox()
    }

    /// Large files the share extension left in the App Group: each job is
    /// sent once its machine is connected, then deleted.
    private func sendShareOutbox() {
        for (folder, job, files) in ShareStore.jobs() {
            let id = folder.lastPathComponent
            guard !shareJobsSending.contains(id), !shareJobsFailed.contains(id) else { continue }
            guard !files.isEmpty else {
                ShareStore.removeJob(folder)
                continue
            }
            // Not connected yet: the next refresh tries again.
            guard let route = try? route(job.machine), route.machine == nil else { continue }
            shareJobsSending.insert(id)
            let label = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            let place = job.machine + (job.session.map { "/" + $0 } ?? "")
            Task {
                defer { shareJobsSending.remove(id) }
                uploadStatus = "Sending \(label) to \(job.machine)…"
                log.add("Share outbox: sending \(label) to \(place)")
                do {
                    let sent = try await route.host.sendFiles(files.map(\.path), session: job.session,
                                                              progress: showProgress(label, to: job.machine))
                    ShareStore.removeJob(folder)
                    log.add("Share outbox: sent to \(job.machine): \(sent.paths.joined(separator: " "))\(sent.typed ? " (typed by etd)" : "")")
                    if !sent.typed, let session = job.session,
                       let page = windows.first(where: { $0.mm?.machine == job.machine && $0.mm?.name == session }) {
                        send(Array((sent.paths.map(Self.shellQuoted).joined(separator: " ") + " ").utf8), to: page)
                    }
                    flashUpload("\(label) sent to \(place)")
                } catch {
                    shareJobsFailed.insert(id)
                    log.add("Share outbox: \(label) to \(place) failed: \(error)")
                    if Date().timeIntervalSince(job.created) > 7 * 24 * 3600 { ShareStore.removeJob(folder) }
                    flashUpload("Couldn't send \(label): \(Self.describeMm(error))")
                }
            }
        }
    }
}

// MARK: - The etd network screen (PLAN-network §4.7)

extension SessionController {
    /// The member list again, for the Network screen.
    func reloadNetwork() async {
        guard let hub = connection as? IrohHost else { return }
        await loadNetwork(hub)
    }

    /// An invite link from the hub: `machine` for `etd join <link>`, else a phone or tablet.
    func invite(machine: Bool) async throws -> String {
        guard let hub = connection as? IrohHost else { throw SummaryError.notConnected }
        let url = try await hub.invite(machine: machine)
        log.add("Invite (\(machine ? "machine" : "device")) from \(hubName ?? server.host)")
        return url
    }
}
