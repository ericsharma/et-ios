import ETCore
import ETSSH
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.session {
                SessionView(session: session)
            } else {
                NavigationStack { ServerListView() }
            }
        }
        .sheet(item: Binding(get: { model.pendingPairing }, set: { if $0 == nil { model.cancelPairing() } })) { pending in
            NavigationStack { PairingSheet(pending: pending) }
                .presentationDetents([.medium])
                .interactiveDismissDisabled(model.isPairing)
        }
        .alert("Pairing", isPresented: Binding(
            get: { model.pendingPairing == nil && model.pairingStatus != nil },
            set: { if !$0 { model.cancelPairing() } })) {
            Button("OK", role: .cancel) { model.cancelPairing() }
        } message: {
            Text(model.pairingStatus ?? "")
        }
    }
}

/// Confirms an `et://pair` link before E.T. sends its secret (PLAN-iroh §6.1).
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    let pending: PendingPairing

    var body: some View {
        Form {
            Section {
                LabeledContent("Machine", value: pending.ticket.hostName)
                LabeledContent("ID", value: String(pending.ticket.endpointId.prefix(8)))
                    .font(.body.monospaced())
            } footer: {
                Text("Check that the ID matches the start of the one `etd pair` printed. After pairing, this iPhone can use tmux and run commands on \(pending.ticket.hostName).")
            }
            if let status = model.pairingStatus {
                Section { Text(status).foregroundStyle(model.isPairing ? Color.secondary : Color.red) }
            }
        }
        .navigationTitle("Pair with \(pending.ticket.hostName)?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancelPairing() }.disabled(model.isPairing)
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.isPairing { ProgressView() } else { Button("Pair") { model.confirmPairing() } }
            }
        }
    }
}

// MARK: - Servers

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ServerConfig?
    @State private var adding = false
    @State private var scanning = false

    var body: some View {
        Group {
            if model.servers.isEmpty {
                // No servers yet: the scanner is the start screen.
                VStack(spacing: 0) {
                    PairScannerView()
                    HStack {
                        Button("Paste pairing link") { pastePairingLink() }
                        Spacer()
                        Button("Add SSH server") { adding = true }
                    }
                    .padding()
                }
            } else {
                serverList
            }
        }
        .navigationTitle("E.T.")
        .toolbar {
            Menu {
                Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                Button("Paste pairing link", systemImage: "link") { pastePairingLink() }
                Button("Add SSH server", systemImage: "terminal") { adding = true }
            } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { ServerEditView(server: nil) }
        }
        .sheet(item: $editing) { server in
            NavigationStack { ServerEditView(server: server) }
        }
        // Pushed, not presented: RootView presents the confirm sheet.
        .navigationDestination(isPresented: $scanning) {
            PairScannerView().navigationTitle("Scan QR code").navigationBarTitleDisplayMode(.inline)
        }
        // Back to the list once a link is read.
        .onChange(of: model.pendingPairing?.id) { _, id in if id != nil { scanning = false } }
    }

    private var serverList: some View {
        List {
            if let file = model.incomingFile {
                Section {
                    Label("Connect to a server to send \(file.name) to a window.", systemImage: "doc")
                    Button("Discard", role: .destructive) { model.incomingFile = nil }
                }
            }
            Section("Servers") {
                ForEach(model.servers) { server in
                    Button { model.connect(server) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName).font(.headline)
                            Text(server.addressLabel)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Edit") { editing = server }
                        Button("Delete", role: .destructive) { model.delete(server) }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.delete(server) }
                        Button("Edit") { editing = server }
                    }
                }
            }
            Section {
                NavigationLink("This device's key") { KeyView() }
                NavigationLink("Dictation words") { VocabularyView(session: nil) }
                NavigationLink("Read aloud") { ReadAloudSettingsView(session: nil) }
                NavigationLink("Debug log") { DebugLogView() }
            } footer: {
                Text(AppInfo.buildLabel).font(.caption.monospaced())
            }
        }
    }
}

extension ServerListView {
    func pastePairingLink() {
        model.receivePairingLink(UIPasteboard.general.string ?? "")
    }
}

struct ServerEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var tmuxPath = ""

    var body: some View {
        if let server, let endpointId = server.irohEndpointId {
            irohForm(server, endpointId: endpointId)
        } else {
            sshForm
        }
    }

    /// iroh servers come from pairing; only the name can change.
    private func irohForm(_ server: ServerConfig, endpointId: String) -> some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name)
                LabeledContent("Machine", value: server.host)
                LabeledContent("etd ID", value: String(endpointId.prefix(8))).font(.body.monospaced())
            }
        }
        .navigationTitle("Edit server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var updated = server
                    updated.name = name.trimmingCharacters(in: .whitespaces)
                    model.save(updated)
                    dismiss()
                }
            }
        }
        .onAppear { name = server.name }
    }

    private var sshForm: some View {
        Form {
            Section("Server") {
                TextField("Host or IP (e.g. trigkey)", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("User", text: $user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("Name (optional)", text: $name)
            }
            Section {
                TextField("tmux path (found automatically)", text: $tmuxPath)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: { Text("Advanced") }
            Section {
                KeyBox()
            } header: {
                Text("Add this key on the server")
            } footer: {
                Text("Append it to ~/.ssh/authorized_keys for this user on the server.")
            }
        }
        .navigationTitle(server == nil ? "Add server" : "Edit server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || user.isEmpty || Int(port) == nil)
            }
        }
        .onAppear {
            guard let server else { return }
            name = server.name
            host = server.host
            port = String(server.port)
            user = server.user
            tmuxPath = server.tmuxPath ?? ""
        }
    }

    private func save() {
        var updated = server ?? ServerConfig(host: "", user: "")
        let newHost = host.trimmingCharacters(in: .whitespaces)
        let newPort = Int(port) ?? 22
        // A different address is a different machine: forget the pinned key.
        if updated.host != newHost || updated.port != newPort { updated.hostKey = nil }
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.host = newHost
        updated.port = newPort
        updated.user = user.trimmingCharacters(in: .whitespaces)
        updated.tmuxPath = tmuxPath.isEmpty ? nil : tmuxPath
        model.save(updated)
        dismiss()
    }
}

struct KeyBox: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        if let error = model.identityError {
            Text("Key error: \(error)").foregroundStyle(.red)
        } else {
            Text(model.publicKey)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            HStack {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = model.publicKey
                    copied = true
                }
                Spacer()
                ShareLink(item: model.publicKey)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct KeyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                KeyBox()
            } footer: {
                Text(model.identity?.isHardwareBacked == true
                     ? "Stored in this iPhone's Secure Enclave. It can't be copied off the device. One key for all servers."
                     : "Software key (no Secure Enclave available).")
            }
        }
        .navigationTitle("This device's key")
    }
}

struct DebugLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            List(Array(model.log.lines.enumerated()), id: \.offset) { item in
                Text(item.element).font(.caption2.monospaced()).id(item.offset)
            }
            .listStyle(.plain)
            .onAppear { proxy.scrollTo(model.log.lines.count - 1, anchor: .bottom) }
        }
        .navigationTitle("Debug log")
        .toolbar { ShareLink(item: model.log.text) }
    }
}

// MARK: - Session

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: SessionController
    @State private var showLog = false
    @State private var showVocabulary = false
    @State private var showNetwork = false
    @State private var showFiles = false
    /// Brief message under the header (e.g. no "Next:" to read).
    @State private var notice: String?
    @State private var showReadAloud = false
    /// A running "hold the speaker" summary, and when it started.
    @State private var summaryTask: Task<Void, Never>?
    @State private var summaryStarted: Date?
    @State private var newSessionName = ""
    @State private var voice = VoiceInput()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sidebar: NavigationSplitViewVisibility = .all
    /// Remembered across launches.
    @AppStorage("sidebarHidden") private var sidebarHidden = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad, full width (SPEC §5.9): window list beside the terminal.
                NavigationSplitView(columnVisibility: $sidebar) {
                    WindowSidebar(session: session)
                        .navigationTitle(session.server.displayName + (session.sessionName.map { " · \($0)" } ?? ""))
                        .toolbar { sidebarToolbar }
                } detail: {
                    VStack(spacing: 0) {
                        if sidebar == .detailOnly {
                            // Sidebar hidden: the phone-style header with tabs.
                            header(sidebarToggle: true)
                        } else {
                            HStack {
                                sidebarToggleButton
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.surface)
                        }
                        content
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .background(Color(Theme.background))
                }
                .navigationSplitViewStyle(.balanced)
                .onAppear { sidebar = sidebarHidden ? .detailOnly : .all }
                .onChange(of: sidebar) { _, value in sidebarHidden = value == .detailOnly }
            } else {
                VStack(spacing: 0) {
                    header(sidebarToggle: false)
                    content
                }
            }
        }
        .background(Color(Theme.background))
        .background { ShortcutKeys(session: session, toggleSidebar: toggleSidebar) }
        .sheet(isPresented: $session.showNewWindow) {
            if session.mode == .manymux {
                NavigationStack { MmSpawnSheet(session: session) }
            } else {
                NavigationStack { NewWindowSheet(session: session) }
            }
        }
        .fullScreenCover(isPresented: $session.showOverview) {
            OverviewView(session: session)
        }
        .alert("Trust this server?", isPresented: .constant(session.pendingHostKey != nil), presenting: session.pendingHostKey) { _ in
            Button("Trust") { session.answerHostKey(trust: true) }
            Button("Cancel", role: .cancel) { session.answerHostKey(trust: false) }
        } message: { key in
            Text("First connection to \(session.server.host).\n\n\(key.algorithm)\n\(key.fingerprint)\n\nCheck it on the server with: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
        }
        .sheet(item: Binding(get: { session.state == .connected ? model.incomingFile : nil },
                             set: { if $0 == nil { model.incomingFile = nil } })) { file in
            SendFileSheet(session: session, file: file) { model.incomingFile = nil }
        }
        .sheet(isPresented: $showReadAloud) {
            NavigationStack {
                ReadAloudSettingsView(session: session).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showReadAloud = false } }
                }
            }
        }
        .sheet(isPresented: $showVocabulary) {
            NavigationStack {
                VocabularyView(session: session).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showVocabulary = false } }
                }
            }
        }
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                FilesView(session: session).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showFiles = false } }
                }
            }
        }
        .sheet(isPresented: $showNetwork) {
            NavigationStack {
                NetworkView(session: session).toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showNetwork = false } }
                }
            }
        }
        .sheet(isPresented: $showLog) {
            NavigationStack {
                DebugLogView().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { showLog = false } }
                }
            }
        }
    }

    private var sidebarToggleButton: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left").font(.title3)
        }
        .accessibilityLabel(sidebar == .detailOnly ? "Show sidebar" : "Hide sidebar")
    }

    private func header(sidebarToggle: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if sidebarToggle { sidebarToggleButton }
                Circle().fill(statusColor).frame(width: 8, height: 8)
                if let path = session.pathLabel {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(path == "direct" ? .green : .orange)
                }
                if session.mode == .manymux {
                    mmTitle
                } else {
                    Text(session.server.displayName + (session.sessionName.map { " · \($0)" } ?? ""))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text("Hi Isabel 👋")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .layoutPriority(1)
                if case .restoring(let done, let total) = session.state {
                    Text("Restoring \(done)/\(total)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(AppInfo.shortBuild)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                speakerButton
                if session.mode == .manymux {
                    Button { session.showNewWindow = true } label: {
                        Image(systemName: "plus").font(.title3)
                    }
                    .disabled(session.state != .connected || session.machines.isEmpty)
                    .accessibilityLabel("New session")
                } else {
                    Button { session.showOverview = true } label: {
                        Image(systemName: "square.grid.2x2").font(.title3)
                    }
                    .disabled(session.windows.isEmpty)
                    .accessibilityLabel("Overview")
                }
                Menu {
                    modeButton
                    if session.mode == .tmux {
                        Button("Overview", systemImage: "square.grid.2x2") { session.showOverview = true }
                            .disabled(session.windows.isEmpty)
                    }
                    Button(session.mode == .manymux ? "New session…" : "New window…", systemImage: "plus") { session.showNewWindow = true }
                        .disabled(session.state != .connected)
                    if session.server.isIroh {
                        Button("Network", systemImage: "point.3.connected.trianglepath.dotted") { showNetwork = true }
                            .disabled(session.state != .connected)
                        Button("Files", systemImage: "folder") { showFiles = true }
                            .disabled(session.state != .connected || session.mode != .manymux)
                    }
                    Button("Dictation words", systemImage: "character.book.closed") { showVocabulary = true }
                    Button(session.copilotMode ? "Close Copilot" : "Copilot", systemImage: "sparkles") { session.copilotMode.toggle() }
                        .disabled(session.currentWindow == nil || session.state != .connected)
                    Button("Read aloud", systemImage: "speaker.wave.2") { showReadAloud = true }
                    Button("Debug log", systemImage: "doc.text") { showLog = true }
                    if session.isDisconnected {
                        Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                    }
                    Button("Servers", systemImage: "server.rack", role: .destructive) { model.closeSession() }
                    Section { Text(AppInfo.buildLabel) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            .padding(.horizontal, 12)
            if !session.windows.isEmpty, session.mode == .tmux || session.currentWindow != nil {
                WindowTabs(session: session)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Theme.surface)
    }

    /// manymux: back to Machines, the machine (tap: move to another), and
    /// the session's title.
    @ViewBuilder private var mmTitle: some View {
        if let page = session.currentWindow {
            Button { session.showMachines() } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("Machines")
            Menu {
                ForEach(session.machines) { machine in
                    Button(machine.name + (machine.sessions.isEmpty ? " (no sessions)" : "")) { session.openMachine(machine.name) }
                        .disabled(machine.name == session.mmMachineName)
                }
            } label: {
                Text(session.mmMachineName ?? "?")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Text(page.readOnly ? "\(page.name) · view only" : page.title.isEmpty ? page.name : page.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(session.server.displayName + " · Machines")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }

    /// iroh servers: between the Machines screen and tmux.
    @ViewBuilder private var modeButton: some View {
        if session.server.isIroh {
            if session.mode == .manymux {
                Button("tmux", systemImage: "rectangle.split.3x1") { session.setMode(.tmux) }
            } else {
                Button("Machines", systemImage: "desktopcomputer") { session.setMode(.manymux) }
            }
        }
    }

    /// Tap: read the last "Next:" line. Hold: summarize Claude's whole
    /// last reply on the summary model, then read that. Tap again to stop
    /// or cancel.
    private var speakerButton: some View {
        let busy = summaryTask != nil
        return Group {
            if busy {
                ProgressView().frame(width: 24, height: 24)
            } else {
                Image(systemName: Speaker.shared.isSpeaking ? "stop.circle" : "speaker.wave.2").font(.title3)
            }
        }
        .foregroundStyle(session.currentWindow == nil ? Color.secondary : Theme.accent)
        .contentShape(Rectangle())
        .onTapGesture { speakerTapped() }
        .onLongPressGesture(minimumDuration: 0.4) { summarizeReply() }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(busy ? "Cancel summary" : Speaker.shared.isSpeaking ? "Stop reading" : "Read the Next: line")
        .accessibilityAction { speakerTapped() }
        .accessibilityAction(named: "Summarize last reply") { summarizeReply() }
    }

    private func speakerTapped() {
        if let task = summaryTask {
            task.cancel()
            summaryTask = nil
            summaryStarted = nil
            return
        }
        speakNext()
    }

    private func summarizeReply() {
        guard summaryTask == nil, let page = session.currentWindow else { return }
        Speaker.shared.stop()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        summaryStarted = Date()
        summaryTask = Task {
            defer {
                summaryTask = nil
                summaryStarted = nil
            }
            do {
                let summary = try await session.summarizeLastReply(in: page)
                guard !Task.isCancelled else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await session.say(summary)
            } catch is CancellationError {
            } catch SummaryError.notConfigured {
                // First hold: go straight to the setup screen.
                showReadAloud = true
            } catch {
                guard !Task.isCancelled else { return }
                showNotice(error.localizedDescription)
            }
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
        }
    }

    /// Reads the current window's last "Next:" line aloud; tap again to stop.
    private func speakNext() {
        if Speaker.shared.isSpeaking {
            Speaker.shared.stop()
            return
        }
        guard summaryTask == nil, let page = session.currentWindow else { return }
        // Under summaryTask so the button spins while the voice is fetched
        // (about a second) and a tap cancels it.
        summaryTask = Task {
            defer { summaryTask = nil }
            if let next = await session.nextStep(in: page) {
                await session.say(next)
            } else {
                showNotice("No \u{201C}Next:\u{201D} line in \(page.name) · hold for a summary")
            }
        }
    }

    private func toggleSidebar() {
        withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
    }

    @ToolbarContentBuilder private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { session.showNewWindow = true } label: { Image(systemName: "plus") }
                .disabled(session.state != .connected)
            Button { session.showOverview = true } label: { Image(systemName: "square.grid.2x2") }
                .disabled(session.windows.isEmpty || session.mode == .manymux)
            Menu {
                modeButton
                if session.mode == .manymux, session.currentWindow != nil {
                    Button("Machines", systemImage: "desktopcomputer") { session.showMachines() }
                }
                Button("Dictation words", systemImage: "character.book.closed") { showVocabulary = true }
                Button(session.copilotMode ? "Close Copilot" : "Copilot", systemImage: "sparkles") { session.copilotMode.toggle() }
                    .disabled(session.currentWindow == nil || session.state != .connected)
                Button("Read aloud", systemImage: "speaker.wave.2") { showReadAloud = true }
                Button("Debug log", systemImage: "doc.text") { showLog = true }
                if session.isDisconnected { Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() } }
                Button("Servers", systemImage: "server.rack", role: .destructive) { model.closeSession() }
                Section { Text(AppInfo.buildLabel) }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    @ViewBuilder private var content: some View {
        if session.mode == .manymux, session.currentWindow == nil, !session.machines.isEmpty {
            MachinesView(session: session)
                .overlay(alignment: .top) { statusBanner }
                .overlay(alignment: .top) { mmNoticeView }
                .animation(.snappy, value: session.mmNotice)
        } else {
            stateContent
        }
    }

    @ViewBuilder private var mmNoticeView: some View {
        if let notice = session.mmNotice {
            Label(notice, systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8).padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var stateContent: some View {
        switch session.state {
        case .connecting where !session.windows.isEmpty && session.approvalURL == nil:
            terminalArea
        case .failed where !session.windows.isEmpty:
            terminalArea
        case .connecting(let message):
            if let url = session.approvalURL {
                ApprovalView(host: session.server.displayName, banner: session.authBanner ?? "", url: url)
            } else {
                centered { ProgressView(); Text(message).foregroundStyle(.secondary) }
            }
        case .failed(let message):
            centered {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.active)
                Text(message).multilineTextAlignment(.center)
                Button("Retry") { session.reconnect() }.buttonStyle(.borderedProminent)
                Button("Debug log") { showLog = true }
            }
        case .choosingSession(let sessions):
            List {
                if sessions.isEmpty {
                    Section {
                        Text("No tmux sessions found on \(session.server.displayName). If you expected one, check the debug log for the TMUX_TMPDIR it used.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Sessions on \(session.server.displayName)") {
                    ForEach(sessions) { info in
                        Button { session.chooseSession(info.name) } label: {
                            HStack {
                                Text(info.name).font(.body.monospaced())
                                Spacer()
                                Text("\(info.windowCount) windows\(info.attachedClients > 0 ? " · attached" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("New session") {
                    TextField("Name", text: $newSessionName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Create") { session.chooseSession(newSessionName, create: true) }
                        .disabled(newSessionName.isEmpty)
                }
            }
        case .connected, .restoring, .disconnected:
            terminalArea
        }
    }

    /// Pages, key row and compose bar. While not connected, the last screen
    /// stays visible, dimmed, with a status banner (SPEC §5.7).
    private var terminalArea: some View {
        VStack(spacing: 6) {
            Group {
                if session.copilotMode, let page = session.currentWindow, session.state == .connected {
                    CopilotView(session: session, page: page)
                        .transition(.opacity)
                } else {
                    WindowPager(session: session)
                }
            }
                .overlay { if session.state != .connected { Color.black.opacity(0.3) } }
                .overlay(alignment: .top) { statusBanner }
                .allowsHitTesting(session.state == .connected)
                .animation(.snappy, value: session.copilotMode)
            if let page = session.currentWindow, session.state == .connected {
                if page.readOnly {
                    HStack {
                        Label("View only", systemImage: "eye").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open to type") {
                            if let link = page.mm { session.openMm(machine: link.machine, name: link.name) }
                        }
                    }
                    .padding(.horizontal, 16).frame(height: 40)
                    .padding(.bottom, 6)
                } else {
                    KeyRow(session: session, page: page, voice: voice)
                        .padding(.bottom, 6)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let page = session.currentWindow, voice.state != .idle {
                ListeningBubble(session: session, page: page, voice: voice)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let page = session.currentWindow, page.dictationPrompt {
                DictationEditButton(page: page)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.currentWindow?.dictationPrompt)
        .overlay {
            if let request = session.selectMode {
                SelectModeView(session: session, request: request)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: voice.state)
        .overlay(alignment: .top) {
            if let page = session.bellBanner {
                Button {
                    session.currentWindowID = page.id
                    session.dismissBellBanner()
                } label: {
                    Label(page.id == session.currentWindowID ? "\(page.name) is done" : "\(page.name) needs you — tap to open",
                          systemImage: "bell.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Theme.accent.opacity(0.9), in: Capsule())
                        .foregroundStyle(Color(Theme.background))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.bellBanner?.id)
        .overlay(alignment: .top) {
            if let status = session.uploadStatus, session.bellBanner == nil {
                Label(status, systemImage: "paperclip")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8).padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.uploadStatus)
        .overlay(alignment: .top) {
            if let notice {
                Label(notice, systemImage: "speaker.slash")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: notice)
        .overlay(alignment: .top) { mmNoticeView }
        .animation(.snappy, value: session.mmNotice)
        .overlay(alignment: .top) {
            if let started = summaryStarted {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Label("Summarizing Claude's reply… \(Int(context.date.timeIntervalSince(started))) s · tap 🔊 to cancel",
                          systemImage: "text.badge.checkmark")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: summaryStarted)
        .onChange(of: Push.shared.pendingWindowName) { session.openPendingWindow() }
        .alert("Dictation", isPresented: Binding(get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(voice.error ?? "")
        }
        .sheet(item: $session.composeRequest) { request in
            ComposeSheet(session: session, page: request.page, text: request.text,
                         dictated: request.dictated ? request.text : nil)
        }
    }

    @ViewBuilder private var statusBanner: some View {
        switch session.state {
        case .connected:
            EmptyView()
        case .failed(let message):
            banner(color: .red) {
                Text(message).font(.footnote)
                Button("Retry") { session.reconnect() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .disconnected where !session.isReconnecting:
            banner(color: .gray) {
                Text("Disconnected").font(.footnote)
                Button("Reconnect") { session.reconnect() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        case .restoring(let done, let total):
            banner(color: .orange) { ProgressView().controlSize(.small); Text("Restoring \(done)/\(total)").font(.footnote) }
        default:
            banner(color: .orange) { ProgressView().controlSize(.small); Text("Reconnecting…").font(.footnote) }
        }
    }

    private func banner<C: View>(color: Color, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10, content: content)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(color.opacity(0.85), in: Capsule())
            .padding(.top, 10)
            .allowsHitTesting(true)
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16, content: content)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .failed: .red
        case .disconnected: .gray
        default: .orange
        }
    }
}

struct WindowTabs: View {
    @Bindable var session: SessionController
    @State private var renaming: WindowPage?
    @State private var newName = ""
    @State private var closing: WindowPage?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.windows) { page in
                        let selected = page.id == session.currentWindowID
                        Button { session.currentWindowID = page.id } label: {
                            HStack(spacing: 4) {
                                if page.hasBell {
                                    Circle().fill(.red).frame(width: 6, height: 6)
                                } else if page.hasActivity {
                                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                }
                                if let machine = page.mm?.machine {
                                    Text(machine).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(page.name).font(.caption.monospaced())
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(selected ? Theme.accent.opacity(0.25) : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(selected ? Theme.accent : Color.secondary.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .id(page.id)
                        .contextMenu {
                            Button("Rename…") { newName = page.name; renaming = page }
                            Button(page.mm == nil ? "New window…" : "New session…") { session.showNewWindow = true }
                            Button(page.mm == nil ? "Close window…" : "End session…", role: .destructive) { closing = page }
                        }
                    }
                    Button { session.showNewWindow = true } label: {
                        Image(systemName: "plus").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .disabled(session.state != .connected)
                }
                .padding(.horizontal, 12)
            }
            .alert("Rename window", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Rename") { if let page = renaming { session.renameWindow(page, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Close \(closing?.name ?? "")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
                Button(closing?.mm == nil ? "Close window" : "End session", role: .destructive) { if let page = closing { session.closeWindow(page) } }
            } message: {
                Text(closing?.mm == nil ? "This kills the window and everything running in it, on the server."
                     : "This stops the program in the session, on \(closing?.mm?.machine ?? "its machine").")
            }
            .onChange(of: session.currentWindowID) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Shows the current window. All terminals stay alive and laid out (so
/// they keep receiving output and the right size); only one is visible.
/// Switch windows with a two-finger swipe or the tabs.
struct WindowPager: View {
    @Bindable var session: SessionController

    var body: some View {
        ZStack {
            ForEach(session.windows) { page in
                let current = page.id == session.currentWindowID
                TerminalPane(host: page.terminal)
                    .opacity(current ? 1 : 0)
                    .allowsHitTesting(current)
                    .accessibilityHidden(!current)
            }
        }
        .onChange(of: session.currentWindowID) {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

/// Shown while the server holds the login for approval, as Tailscale SSH
/// does in "check" mode. The login continues by itself once approved.
struct ApprovalView: View {
    let host: String
    let banner: String
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.badge.shield.checkmark").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Approve this login").font(.title3.weight(.semibold))
            Text("\(host) wants you to confirm it's you before the connection continues.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                openURL(url)
            } label: {
                Label("Approve in browser", systemImage: "safari").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for approval. Come back here when you're done.").font(.footnote).foregroundStyle(.secondary)
            }
            if !banner.isEmpty {
                Text(banner).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
        .padding(28)
        .frame(maxWidth: 480, maxHeight: .infinity)
    }
}

/// iPad sidebar: the session's windows, with activity and bell dots.
struct WindowSidebar: View {
    @Bindable var session: SessionController

    var body: some View {
        List(selection: $session.currentWindowID) {
            ForEach(session.windows) { page in
                HStack(spacing: 8) {
                    if page.hasBell {
                        Circle().fill(.red).frame(width: 7, height: 7)
                    } else if page.hasActivity {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    } else {
                        Color.clear.frame(width: 7, height: 7)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.name).font(.body.monospaced())
                        if let machine = page.mm?.machine {
                            Text(machine + (page.title.isEmpty ? "" : " · \(page.title)"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(page.currentCommand).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if page.mm == nil {
                        Text("\(page.index)").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .tag(Optional(page.id))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text(AppInfo.buildLabel).font(.caption2.monospaced()).foregroundStyle(.tertiary).padding(.bottom, 6)
        }
    }
}

/// Hardware-keyboard shortcuts (SPEC §5.9). Invisible buttons, so the
/// shortcuts work and show in the ⌘-hold overlay; everything else goes to
/// the terminal.
struct ShortcutKeys: View {
    let session: SessionController
    let toggleSidebar: () -> Void

    var body: some View {
        Group {
            Button("Previous window") { session.switchWindow(next: false) }.keyboardShortcut("[", modifiers: .command)
            Button("Next window") { session.switchWindow(next: true) }.keyboardShortcut("]", modifiers: .command)
            ForEach(1..<10) { n in
                Button("Window \(n)") { session.selectWindow(at: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("New window") { session.showNewWindow = true }.keyboardShortcut("t", modifiers: .command)
            Button("Compose") {
                if let page = session.currentWindow { session.composeRequest = ComposeRequest(page: page, text: "") }
            }.keyboardShortcut("k", modifiers: .command)
            Button("Overview") { if session.mode == .tmux { session.showOverview.toggle() } }.keyboardShortcut("o", modifiers: .command)
            Button("Toggle sidebar", action: toggleSidebar).keyboardShortcut("\\", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// "Open in E.T.": pick the window a file goes to. E.T. sends it to
/// ~/etd-downloads on that window's machine and its path is typed there
/// (no Enter).
struct SendFileSheet: View {
    let session: SessionController
    let file: IncomingFile
    let done: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.windows) { page in
                        Button {
                            session.currentWindowID = page.id
                            session.sendFiles([file.url], to: page, staged: true)
                            done()
                        } label: {
                            HStack {
                                Text(page.name)
                                Spacer()
                                Text(page.currentCommand).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Send to window")
                } footer: {
                    Text("The file goes to ~/etd-downloads on the window's machine, and its path is typed into the window, ready to send.")
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            }
        }
    }
}
