import ETCore
import QuickLook
import SwiftUI

/// One window: every machine's sessions on the left, the selected session's
/// terminal on the right.
struct MainWindow: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Setup.self) private var setup
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SessionRef?
    /// A Logbook page in place of the terminal (PLAN-logbook §4.6).
    @State private var logbookPage: LogbookPage?
    @State private var showingNewSession = false
    @State private var renaming: SessionRef?
    @State private var newName = ""
    @State private var ending: SessionRef?
    @State private var nicknaming: NicknameTarget?
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var voice = VoiceInput()

    init(initial: SessionRef?) {
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(selection: $selection, logbookPage: $logbookPage, rename: { nicknaming = $0 }, renameOnMachine: startRename, end: { ending = $0 })
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            detail
        }
        .navigationTitle(logbookPage == nil ? title : logbookPage == .agents ? "Agents" : "Logbook")
        .navigationSubtitle(logbookPage == nil ? selection.map { Nicknames.shared.machine($0.machine) } ?? "" : logbookSubtitle)
        .onChange(of: selection) { _, ref in if ref != nil { logbookPage = nil } }
        .toolbar {
            // Also in the sidebar, under Files (it can be below the fold).
            ToolbarItemGroup(placement: .navigation) {
                Button { selection = nil; logbookPage = .agents } label: { Label("Agents", systemImage: "person.2.wave.2") }
                    .help("Agents: every Claude, its login and usage limits")
                Button { selection = nil; logbookPage = .report } label: { Label("Logbook", systemImage: "book.pages") }
                    .help("Logbook: the report and every Claude transcript")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewSession = true } label: { Label("New Session", systemImage: "plus") }
                    .help("New Session (⌘T)")
                    .disabled(fleet.phase != .ready)
            }
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet(defaultMachine: selection?.machine) { ref in selection = ref }
        }
        .alert("Rename on \(renaming?.machine ?? "machine")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let ref = renaming {
                    fleet.rename(ref, to: newName)
                    if selection == ref { selection?.name = newName }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device sees the new name.")
        }
        .nicknameAlert($nicknaming)
        .confirmationDialog("End \(ending?.name ?? "")?", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } })) {
            Button("End Session", role: .destructive) { if let ref = ending { fleet.end(ref) } }
        } message: {
            Text("This stops the program in \(ending?.name ?? "the session") on \(ending?.machine ?? "its machine").")
        }
        .overlay(alignment: .bottom) {
            if let notice = fleet.notice {
                Text(notice)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: fleet.notice)
        // A drop on the Dock icon: pick a machine for it.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            fleet.queueSend([url])
            openWindow(id: "send")
        }
        .onChange(of: fleet.requestedLogbook) { _, page in
            guard let page else { return }
            selection = nil
            logbookPage = page
            fleet.requestedLogbook = nil
        }
        .onChange(of: fleet.requestedRef) { _, ref in
            guard let ref else { return }
            selection = ref
            fleet.requestedRef = nil
        }
        .focusedSceneValue(\.windowActions, WindowActions(
            selection: selection,
            newSession: { showingNewSession = true },
            rename: { if let ref = selection { nicknaming = .session(ref) } },
            renameMachine: { if let ref = selection { nicknaming = .machine(ref.machine) } },
            renameOnMachine: { if let ref = selection { startRename(ref) } },
            end: { ending = selection },
            select: { selection = $0 },
            step: step
        ))
    }


    private var title: String {
        guard let selection else { return "E.T." }
        if let nickname = Nicknames.shared.nickname(for: .session(selection)) { return nickname }
        let info = fleet.info(for: selection)
        return info.map { $0.title.isEmpty ? $0.name : $0.title } ?? selection.name
    }

    @Environment(Logbook.self) private var logbook

    private var logbookSubtitle: String {
        switch logbookPage {
        case .session(let key): logbook.session(key)?.label ?? key.id
        case .report: "Report"
        case .agents, nil: ""
        }
    }

    @ViewBuilder private var detail: some View {
        if setup.stage != .done {
            SetupView()
        } else if let logbookPage {
            LogbookDetail(page: logbookPage)
                .id(logbookPage)
        } else {
            VStack(spacing: 0) {
                SessionTabs(selection: $selection, newSession: { showingNewSession = true },
                            rename: { nicknaming = .session($0) }, renameOnMachine: startRename, end: { ending = $0 })
                Divider()
                if let selection {
                    TerminalScreen(selection: $selection, voice: voice, step: step)
                        .id(selection)
                } else {
                    Placeholder()
                }
            }
        }
    }

    private func startRename(_ ref: SessionRef) {
        newName = ref.name
        renaming = ref
    }

    /// Next / previous session across every machine (⌘⇧] / ⌘⇧[), wrapping.
    private func step(_ by: Int) {
        let all = fleet.machines.flatMap { m in m.sessions.map { SessionRef(machine: m.name, name: $0.name) } }
        guard !all.isEmpty else { return }
        let i = selection.flatMap { all.firstIndex(of: $0) } ?? (by > 0 ? -1 : 0)
        selection = all[(i + by + all.count) % all.count]
    }
}

/// What the menus act on: the front window's selection and sheets.
struct WindowActions {
    var selection: SessionRef?
    var newSession: () -> Void
    var rename: () -> Void
    var renameMachine: () -> Void
    var renameOnMachine: () -> Void
    var end: () -> Void
    var select: (SessionRef) -> Void
    var step: (Int) -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: SessionRef?
    @Binding var logbookPage: LogbookPage?
    let rename: (NicknameTarget) -> Void
    let renameOnMachine: (SessionRef) -> Void
    let end: (SessionRef) -> Void
    /// The machine a drag of files is over.
    @State private var dropTarget: String?
    @Environment(SharedFiles.self) private var files
    @Environment(Logbook.self) private var logbook
    @Environment(Agents.self) private var agents
    @State private var picking: SharedFilePick?

    var body: some View {
        List(selection: $selection) {
            ForEach(fleet.machines) { machine in
                Section {
                    if let error = machine.error {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                    } else if machine.sessions.isEmpty {
                        Text("No sessions").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(machine.sessions) { info in
                        let ref = SessionRef(machine: machine.name, name: info.name)
                        SessionRow(info: info, nickname: Nicknames.shared.nickname(for: .session(ref)))
                            .tag(ref)
                            .dropDestination(for: URL.self) { urls, _ in drop(urls, on: machine.name) }
                            .contextMenu {
                                Button("Open in New Window") { openWindow(value: ref) }
                                Button("Rename…") { rename(.session(ref)) }
                                Button("Rename on Machine…") { renameOnMachine(ref) }
                                Divider()
                                Button("End Session…", role: .destructive) { end(ref) }
                            }
                    }
                    ForEach(fleet.sends(to: machine.name, session: nil)) { send in
                        MachineSendRow(send: send)
                    }
                } header: {
                    // Files dropped on a machine go to its ~/etd-downloads.
                    Text(Nicknames.shared.machine(machine.name))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(dropTarget == machine.name ? Theme.accent.opacity(0.3) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .dropDestination(for: URL.self) { urls, _ in
                            drop(urls, on: machine.name)
                        } isTargeted: { over in
                            if over { dropTarget = machine.name } else if dropTarget == machine.name { dropTarget = nil }
                        }
                        .help("Drop files here to send them to \(machine.name)")
                        .contextMenu {
                            Button("Rename Machine…") { rename(.machine(machine.name)) }
                        }
                }
            }
            filesSection
            AgentsSection(selection: $selection, page: $logbookPage)
            LogbookSection(selection: $selection, page: $logbookPage)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { StatusLine() }
        .refreshable { await fleet.refreshMachines() }
        .quickLookPreview(Binding(get: { files.preview }, set: { files.preview = $0 }))
        .sheet(item: $picking) { pick in
            SharedFilePicker(pick: pick, files: files, machines: fleet.machines)
        }
        // The list again every 30 s, when connected, and after each send.
        .task(id: fleet.phase) {
            guard fleet.phase == .ready else { return }
            while !Task.isCancelled {
                files.reload()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: fleet.sends.count) { old, new in if new < old { files.reload() } }
        .onChange(of: files.notice) { _, notice in
            guard let notice else { return }
            fleet.flash(notice)
            files.notice = nil
        }
        // On the List, not the Logbook section: a List may not build a
        // section that is scrolled out of view.
        .task(id: fleet.phase) {
            guard fleet.phase == .ready else { return }
            await logbook.watch()
        }
        // Agents too: the Agents section can be scrolled out of view, and
        // the strip over a terminal needs it running.
        .task { await agents.watch() }
        .onChange(of: logbook.notice) { _, notice in
            guard let notice else { return }
            fleet.flash(notice)
            logbook.notice = nil
        }
    }

    /// Every file sent to any machine (PLAN-files §4.7): click for Quick
    /// Look, right-click for the rest.
    @ViewBuilder private var filesSection: some View {
        Section {
            if files.items.isEmpty {
                Text(files.loading ? "Loading…" : "No files yet. Drop one on a machine or a terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files.items) { item in
                SharedFileRow(item: item, progress: files.busy[item.id])
                    .contentShape(Rectangle())
                    .onTapGesture { files.open(item) }
                    .contextMenu {
                        SharedFileActions(item: item, files: files, machines: fleet.machines, picking: $picking)
                    }
                    .help(item.machine + ":" + item.path)
            }
            if !files.unanswered.isEmpty {
                Text("Not answering: \(files.unanswered.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Files")
                Spacer()
                if files.loading { ProgressView().controlSize(.mini) }
                Button { files.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the file list")
            }
        }
    }

    private func drop(_ urls: [URL], on machine: String) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        fleet.send(files, to: machine, session: nil)
        return true
    }
}

/// Nickname or title, then name · idle · attached; a red dot for a bell.
struct SessionRow: View {
    let info: MmSessionInfo
    var nickname: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(info.bells > 0 ? Theme.bell : Color.clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(nickname ?? (info.title.isEmpty ? info.name : info.title)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(info.name).font(.caption.monospaced())
                    Text("· \(Manymux.idleLabel(seconds: info.idleSecs))").font(.caption).monospacedDigit()
                    if info.attached > 0 {
                        Label("\(info.attached)", systemImage: "person.fill").font(.caption).labelStyle(.titleAndIcon)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The connection's state, under the sidebar.
struct StatusLine: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        HStack(spacing: 6) {
            switch fleet.phase {
            case .unpaired:
                Image(systemName: "link.badge.plus").foregroundStyle(.secondary)
                Text("Not paired")
            case .connecting(let text):
                ProgressView().controlSize(.small)
                Text(text)
            case .ready:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(fleet.hubName.map { "Connected via \($0)" } ?? "Connected")
            case .failed(let error):
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(error).lineLimit(2)
                Spacer()
                Button("Retry") { fleet.connect() }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct Placeholder: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.tertiary)
            switch fleet.phase {
            case .ready:
                Text("Pick a session, or start one with ⌘T").foregroundStyle(.secondary)
            case .connecting(let text):
                Text(text).foregroundStyle(.secondary)
            case .failed(let error):
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { fleet.connect() }
            case .unpaired:
                EmptyView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Terminal

/// The selected session: attached while shown.
struct TerminalScreen: View {
    @Environment(Fleet.self) private var fleet
    @Binding var selection: SessionRef?
    let voice: VoiceInput
    /// Next / previous tab, for a horizontal swipe on the terminal.
    let step: (Int) -> Void
    @State private var terminal: SessionTerminal?

    var body: some View {
        VStack(spacing: 0) {
            if let selection { TerminalAgentStrip(ref: selection) }
            ZStack {
                Color(nsColor: Theme.background)
                if let terminal {
                    TerminalPane(terminal: terminal)
                    overlay(for: terminal)
                    TerminalSends(ref: terminal.ref)
                    ListeningBubble(terminal: terminal, voice: voice)
                }
            }
            if let terminal {
                InputBar(terminal: terminal, voice: voice)
            }
        }
        .onAppear {
            guard let selection else { return }
            let t = fleet.terminal(for: selection)
            t.isVisible = true
            t.view.onSwipe = step
            terminal = t
        }
        .onDisappear { terminal?.isVisible = false }
        // A rename from the menu or another client: keep showing it.
        .onChange(of: terminal?.ref) { _, ref in
            if let ref, ref != selection { selection = ref }
        }
        .onChange(of: fleet.phase) { _, phase in
            if phase == .ready, let terminal, !terminal.isAttached, terminal.status != .ended(0) { fleet.reattach(terminal) }
        }
    }

    @ViewBuilder private func overlay(for terminal: SessionTerminal) -> some View {
        switch terminal.status {
        case .live:
            if let size = terminal.sessionSize {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button("\(size.cols)×\(size.rows) · Fit to Window") { terminal.fitToWindow() }
                            .controlSize(.small)
                            .help("Another client set this size. Click to take the window's size.")
                            .padding(8)
                    }
                }
            }
        case .attaching:
            ProgressView().controlSize(.small).padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        case .detached:
            EmptyView()
        case .failed(let message):
            Banner(text: message, button: "Reattach") { fleet.reattach(terminal) }
        case .ended(let code):
            Banner(text: "\(terminal.ref.name) ended\(code == 0 ? "" : " (exit \(code))")", button: nil) {}
        }
    }
}

struct Banner: View {
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Text(text).lineLimit(3)
                if let button { Button(button, action: action) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
            Spacer()
        }
    }
}

// MARK: - New session

struct NewSessionSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    let defaultMachine: String?
    let opened: (SessionRef) -> Void
    @State private var machine = ""
    @State private var kind: Kind = .shell
    @State private var command = ""
    @State private var name = ""
    @State private var starting = false

    enum Kind: String, CaseIterable, Identifiable {
        case shell = "Shell", claude = "Claude", custom = "Command"
        var id: String { rawValue }
    }

    private var arguments: [String] {
        switch kind {
        case .shell: []
        case .claude: ["claude"]
        case .custom: Manymux.splitCommand(command)
        }
    }

    var body: some View {
        Form {
            Picker("Machine", selection: $machine) {
                ForEach(fleet.machines) { Text(Nicknames.shared.machine($0.name)).tag($0.name) }
            }
            Picker("Run", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if kind == .custom {
                TextField("Command", text: $command, prompt: Text("e.g. htop"))
                    .font(.body.monospaced())
            }
            TextField("Name", text: $name, prompt: Text("Optional: named after the command"))
                .font(.body.monospaced())
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") { start() }
                    .disabled(machine.isEmpty || (kind == .custom && arguments.isEmpty) || starting)
            }
        }
        .onAppear {
            machine = defaultMachine ?? fleet.hubName ?? fleet.machines.first?.name ?? ""
        }
    }

    private func start() {
        starting = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            if let ref = await fleet.spawn(machine: machine, name: trimmed.isEmpty ? nil : trimmed, command: arguments,
                                           cols: 120, rows: 40) {
                opened(ref)
            }
            dismiss()
        }
    }
}

// MARK: - Menus

struct ETCommands: Commands {
    let fleet: Fleet
    @FocusedValue(\.windowActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Session…") { actions?.newSession() }
                .keyboardShortcut("t")
                .disabled(actions == nil)
            Button("Send File…") {
                guard let urls = SendFilesWindow.pick() else { return }
                fleet.queueSend(urls)
                openWindow(id: "send")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Session") {
            Button("Next Session") { actions?.step(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Session") { actions?.step(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Open in New Window") { if let ref = actions?.selection { openWindow(value: ref) } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions?.selection == nil)
            Button("Rename…") { actions?.rename() }
                .disabled(actions?.selection == nil)
            Button("Rename Machine…") { actions?.renameMachine() }
                .disabled(actions?.selection == nil)
            Button("Rename on Machine…") { actions?.renameOnMachine() }
                .disabled(actions?.selection == nil)
            Button("Fit to Window") {
                if let ref = actions?.selection { fleet.terminals[ref]?.fitToWindow() }
            }
            .disabled(actions?.selection == nil)
            Divider()
            Button("End Session…") { actions?.end() }
                .disabled(actions?.selection == nil)
            Divider()
            Button("Refresh") { Task { await fleet.refreshMachines() } }
                .keyboardShortcut("r")
            Button("Reconnect") { fleet.connect() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger") { resizeFont(by: 1) }.keyboardShortcut("+")
            Button("Smaller") { resizeFont(by: -1) }.keyboardShortcut("-")
            Button("Actual Size") { setFont(13) }.keyboardShortcut("0")
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Debug Log") { openWindow(id: "log") }
        }
    }

    private func resizeFont(by delta: CGFloat) {
        setFont(min(max(SessionTerminal.fontSize + delta, 8), 32))
    }

    private func setFont(_ size: CGFloat) {
        SessionTerminal.fontSize = size
        for terminal in fleet.terminals.values { terminal.applyFontSize() }
    }
}

struct LogView: View {
    @Environment(Fleet.self) private var fleet

    var body: some View {
        ScrollView {
            Text(fleet.log.text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .toolbar {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AppInfo.buildLabel + "\n" + fleet.log.text, forType: .string)
            }
        }
    }
}
