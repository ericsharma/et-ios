import ETCore
import ETSSH
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.session {
            SessionView(session: session)
        } else {
            NavigationStack { ServerListView() }
        }
    }
}

// MARK: - Servers

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ServerConfig?
    @State private var adding = false

    var body: some View {
        List {
            if model.servers.isEmpty {
                Section {
                    Text("Add the server that runs tmux. E.T. connects over SSH with its own key.")
                        .foregroundStyle(.secondary)
                    Button("Add server") { adding = true }
                }
            }
            Section("Servers") {
                ForEach(model.servers) { server in
                    Button { model.connect(server) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName).font(.headline)
                            Text("\(server.user)@\(server.host):\(server.port)")
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
                NavigationLink("Debug log") { DebugLogView() }
            } footer: {
                Text(AppInfo.buildLabel).font(.caption.monospaced())
            }
        }
        .navigationTitle("E.T.")
        .toolbar {
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { ServerEditView(server: nil) }
        }
        .sheet(item: $editing) { server in
            NavigationStack { ServerEditView(server: server) }
        }
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
    @State private var newSessionName = ""
    @State private var voice = VoiceInput()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sidebar: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad, full width (SPEC §5.9): window list beside the terminal.
                NavigationSplitView(columnVisibility: $sidebar) {
                    WindowSidebar(session: session)
                        .navigationTitle(session.server.displayName + (session.sessionName.map { " · \($0)" } ?? ""))
                        .toolbar { sidebarToolbar }
                } detail: {
                    content
                        .toolbar(.hidden, for: .navigationBar)
                        .background(Color(Theme.background))
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                VStack(spacing: 0) {
                    header
                    content
                }
            }
        }
        .background(Color(Theme.background))
        .background { ShortcutKeys(session: session, toggleSidebar: toggleSidebar) }
        .sheet(isPresented: $session.showNewWindow) {
            NavigationStack { NewWindowSheet(session: session) }
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
        .sheet(isPresented: $showLog) {
            NavigationStack {
                DebugLogView().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { showLog = false } }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(session.server.displayName + (session.sessionName.map { " · \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if case .restoring(let done, let total) = session.state {
                    Text("Restoring \(done)/\(total)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(AppInfo.shortBuild)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Button { session.showOverview = true } label: {
                    Image(systemName: "square.grid.2x2").font(.title3)
                }
                .disabled(session.windows.isEmpty)
                .accessibilityLabel("Overview")
                Menu {
                    Button("Overview", systemImage: "square.grid.2x2") { session.showOverview = true }
                        .disabled(session.windows.isEmpty)
                    Button("New window…", systemImage: "plus") { session.showNewWindow = true }
                        .disabled(session.state != .connected)
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
            if !session.windows.isEmpty {
                WindowTabs(session: session)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Theme.surface)
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
                .disabled(session.windows.isEmpty)
            Menu {
                Button("Debug log", systemImage: "doc.text") { showLog = true }
                if session.isDisconnected { Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() } }
                Button("Servers", systemImage: "server.rack", role: .destructive) { model.closeSession() }
                Section { Text(AppInfo.buildLabel) }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    @ViewBuilder private var content: some View {
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
            WindowPager(session: session)
                .overlay { if session.state != .connected { Color.black.opacity(0.3) } }
                .overlay(alignment: .top) { statusBanner }
                .allowsHitTesting(session.state == .connected)
            if let page = session.currentWindow, session.state == .connected {
                KeyRow(session: session, page: page, voice: voice)
                    .padding(.bottom, 6)
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
                Label(status, systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8).padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.uploadStatus)
        .onChange(of: Push.shared.pendingWindowName) { session.openPendingWindow() }
        .alert("Dictation", isPresented: Binding(get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(voice.error ?? "")
        }
        .sheet(item: $session.composeRequest) { request in
            ComposeSheet(session: session, page: request.page, text: request.text)
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
                            Button("New window…") { session.showNewWindow = true }
                            Button("Close window…", role: .destructive) { closing = page }
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
                Button("Close window", role: .destructive) { if let page = closing { session.closeWindow(page) } }
            } message: {
                Text("This kills the window and everything running in it, on the server.")
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
                        Text(page.currentCommand).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(page.index)").font(.caption.monospaced()).foregroundStyle(.tertiary)
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
            Button("Overview") { session.showOverview.toggle() }.keyboardShortcut("o", modifiers: .command)
            Button("Toggle sidebar", action: toggleSidebar).keyboardShortcut("\\", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

enum AppInfo {
    /// "E.T. 0.1 (202610151757)", shown in the ⋯ menu.
    /// "b 10-15 18:28" from build 202610151828 (UTC), for the header.
    static var shortBuild: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard build.count == 12 else { return "b \(build)" }
        let c = Array(build)
        return "b \(String(c[4...5]))-\(String(c[6...7])) \(String(c[8...9])):\(String(c[10...11]))"
    }

    static var buildLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "E.T. \(version) (\(build))"
    }
}
