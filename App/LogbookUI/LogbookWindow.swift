import ETCore
import SwiftUI

/// The Logbook window (PLAN-logbook-v2 §4.1): places → cards → transcript.
/// The Mac's window and the iPad's split view; an iPhone gets a stack.
struct LogbookWindow: View {
    @Bindable var logbook: Logbook
    let machines: [MmMachine]
    /// Shows a live session's terminal; nil hides Show Terminal.
    var showTerminal: ((LogbookSession) -> Void)?
    /// iOS: closes the Logbook (a Done button over the places).
    var done: (() -> Void)?
    @State private var search = ""
    /// The places list shows its selection. An iPhone's stack clears it on
    /// Back, so that a tap on the same place opens it again.
    @State private var placeChosen = true
    /// An iPhone starts at the places (D3: places → cards → transcript).
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var editing: LogbookEdit?
    @State private var sending: LogbookSendTarget?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            places
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
                .toolbar {
                    if let done {
                        ToolbarItem(placement: .cancellationAction) { Button("Done", action: done) }
                    }
                }
        } content: {
            cards
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let run = logbook.run {
                            ProgressView(value: run.fraction ?? 0).frame(width: 80)
                                .help(run.total > 0 ? "\(run.stage) \(run.done)/\(run.total)" : run.stage)
                        }
                        Button { logbook.refreshReport() } label: { Label("Refresh Report", systemImage: "arrow.clockwise") }
                            .disabled(logbook.run != nil)
                            .help("Read every session again and group them by project (1–3 min)")
                    }
                }
        } detail: {
            detail
                #if os(macOS)
                .toolbar {
                    Button { logbook.inspector.toggle() } label: { Label("Inspector", systemImage: "info.circle") }
                        .keyboardShortcut("i", modifiers: .command)
                        .disabled(logbook.selected == nil)
                        .help("Machine, folder, ids (⌘I)")
                }
                #endif
        }
        // An evidence link from Findings: show the transcript (an iPhone pushes it).
        .onChange(of: logbook.selected) { _, key in if key != nil { compactColumn = .detail } }
        .sheet(item: $editing) { LogbookEditSheet(edit: $0, logbook: logbook) }
        .sheet(item: $sending) { LogbookSendSheet(target: $0, machines: machines, logbook: logbook) }
    }

    // MARK: - Places

    private var places: some View {
        List(selection: Binding(get: { placeChosen ? logbook.place : nil }, set: { place in
            placeChosen = place != nil
            if let place { logbook.place = place }
        })) {
            placeRow(.now, "Now", systemImage: "circle.fill", tint: .green)
            placeRow(.findings, "Findings", systemImage: "flag", tint: .orange)
            Section("Projects") {
                if let report = logbook.report {
                    ForEach(report.projects) { project in
                        HStack(spacing: 6) {
                            LogbookStatusDot(status: logbook.projectState(project))
                            Text(project.name).lineLimit(1)
                            Spacer()
                            let n = logbook.cards(.project(project.id)).count
                            if n > 0 { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .tag(LogbookPlace.project(project.id))
                    }
                } else {
                    Text(logbook.run == nil ? "No report yet. Refresh Report groups the sessions by project."
                                            : "Making the report…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                placeRow(.unsorted, "Unsorted", systemImage: "tray", tint: .secondary)
                placeRow(.archive, "Archive", systemImage: "archivebox", tint: .secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Logbook")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await logbook.reload() }
        #endif
    }

    private func placeRow(_ place: LogbookPlace, _ title: String, systemImage: String, tint: Color) -> some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: systemImage).foregroundStyle(tint) }
            Spacer()
            let n = logbook.count(place)
            if n > 0 { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
        }
        .tag(place)
    }

    // MARK: - Cards

    @ViewBuilder private var cards: some View {
        switch logbook.place {
        case .findings:
            LogbookFindingsView(logbook: logbook, machines: machines)
        default:
            cardList
        }
    }

    private var cardList: some View {
        let shown = logbook.cards(logbook.place, search: search)
        return List(selection: Binding(get: { logbook.selected }, set: { logbook.selected = $0 })) {
            if case .project(let id) = logbook.place, let project = logbook.project(id: id) {
                LogbookProjectHeader(project: project, logbook: logbook,
                                     send: logbook.report.map { report in {
                                         sending = LogbookSendTarget(selection: .reportSection(reportId: report.id, projectId: project.id),
                                                                     title: "the report on \(project.name)")
                                     } },
                                     edit: { editing = LogbookEdit(project: project, session: nil) })
                    .listRowSeparator(.hidden)
            }
            ForEach(shown) { session in
                LogbookCard(session: session, logbook: logbook)
                    .tag(session.key)
                    .contextMenu { menu(session) }
            }
            if shown.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
            }
            if case .project(let id) = logbook.place, let project = logbook.project(id: id), logbook.hiddenCount(project) > 0 {
                Text("\(logbook.hiddenCount(project)) older or short sessions are in the Archive")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await logbook.reload()
            await logbook.reloadOverview()
        }
        #endif
        .modifier(ArchiveSearch(on: logbook.place == .archive, text: $search))
    }

    @ViewBuilder private func menu(_ session: LogbookSession) -> some View {
        if let showTerminal, !session.mmSession.isEmpty {
            Button("Show Terminal") { showTerminal(session) }.disabled(!session.isLive)
        }
        if logbook.report != nil {
            Button("Move to Project…") {
                editing = LogbookEdit(project: logbook.project(of: session), session: session.id)
            }
        }
        if !session.mmSession.isEmpty {
            Button(session.paused ? "Record" : "Do Not Record") { logbook.setPaused(session, !session.paused) }
        }
        Button("Copy Session ID") { LogbookInspector.copy(session.key.sessionId) }
    }

    private var title: String {
        switch logbook.place {
        case .now: "Now"
        case .findings: "Findings"
        case .project(let id): logbook.project(id: id)?.name ?? "Project"
        case .unsorted: "Unsorted"
        case .archive: "Archive"
        }
    }

    private var emptyText: String {
        if let error = logbook.error, logbook.sessions.isEmpty { return error }
        if !logbook.loaded { return "Loading…" }
        return switch logbook.place {
        case .now: "Nothing runs now."
        case .archive: search.isEmpty ? "No sessions recorded yet." : "No session matches."
        default: "No sessions here."
        }
    }

    // MARK: - Transcript

    @ViewBuilder private var detail: some View {
        if let key = logbook.selected {
            LogbookTranscriptView(key: key, logbook: logbook, machines: machines)
                .id(key)
                #if os(iOS)
                .navigationTitle(logbook.session(key).map(logbook.headline) ?? "Transcript")
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .inspector(isPresented: $logbook.inspector) {
                    if let session = logbook.session(key) {
                        LogbookInspector(session: session, entry: logbook.entry(session))
                            .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
                    }
                }
        } else {
            ContentUnavailableView("No session selected", systemImage: "text.bubble",
                                   description: Text("Pick a card to read its transcript."))
        }
    }
}

/// Search only in the Archive (D3).
private struct ArchiveSearch: ViewModifier {
    let on: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if on {
            content.searchable(text: $text, prompt: "Headline, prompt, reply")
        } else {
            content
        }
    }
}

// MARK: - Card

/// D4: headline, the last prompt, the first line of the last reply, state,
/// machine and when. Friction marks once etd counts them (A2).
struct LogbookCard: View {
    let session: LogbookSession
    let logbook: Logbook

    var body: some View {
        let entry = logbook.entry(session)
        let state = logbook.state(session)
        HStack(alignment: .top, spacing: 8) {
            LogbookStatusDot(status: state).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(logbook.headline(session)).fontWeight(.medium).lineLimit(1)
                    if session.paused {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.caption).help("Do not record")
                    }
                    Spacer(minLength: 4)
                    Text(session.key.machine)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if let asked = entry?.asked, !asked.isEmpty {
                    line("You", asked)
                }
                if let said = entry?.said, !said.isEmpty {
                    line((entry?.agent ?? "claude").capitalized, said)
                }
                HStack(spacing: 8) {
                    Text(stateText(state)).foregroundStyle(state == "needs-you" ? .orange : .secondary)
                    LogbookFrictionMarks(friction: logbook.friction(session))
                    Spacer()
                    Text(session.last, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }

    private func line(_ who: String, _ text: String) -> some View {
        (Text(who + ": ").fontWeight(.semibold) + Text(text))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private func stateText(_ state: String) -> String {
        switch state {
        case "needs-you": "needs you"
        case "gone": logbook.isTrivial(session) ? "ended · short" : "ended"
        default: state
        }
    }
}

// MARK: - Project header

/// A project's goal, status, progress and Next, over its cards.
struct LogbookProjectHeader: View {
    let project: LogbookReport.Project
    let logbook: Logbook
    let send: (() -> Void)?
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(statusColor)
                if let report = logbook.report {
                    Text("Report \(report.takenDate.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if let send { Button("Send to Session…", systemImage: "paperplane", action: send) }
                    Button("Rename or Move Sessions…", systemImage: "pencil", action: edit)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if !project.goal.isEmpty {
                section("Goal") { Text(project.goal) }
            }
            if !project.done.isEmpty {
                section("Done") { bullets(project.done, numbered: false) }
            }
            // Before the watcher writes `now`: its 2–3 sentence progress.
            if !(project.now.isEmpty ? project.progress : project.now).isEmpty {
                section("Where we are") { Text(project.now.isEmpty ? project.progress : project.now) }
            }
            if !project.next.isEmpty {
                section("Next") { bullets(project.next, numbered: true) }
            }
            Text("The sessions below have the details: tap one for its transcript.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 4)
    }

    private var statusColor: Color {
        switch project.status {
        case "blocked": .red
        case "done": .secondary
        default: .green
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            content().font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullets(_ items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(numbered ? "\(i + 1)." : "•").foregroundStyle(.secondary)
                    Text(item)
                }
            }
        }
    }
}

// MARK: - Inspector

/// ⌘I: what the cards leave out (D5).
struct LogbookInspector: View {
    let session: LogbookSession
    let entry: LogbookOverviewEntry?

    var body: some View {
        Form {
            Section("Session") {
                LabeledContent("Machine", value: session.key.machine)
                if !session.mmSession.isEmpty { LabeledContent("manymux", value: session.mmSession) }
                LabeledContent("State", value: session.status)
                if let entry {
                    LabeledContent("Prompts", value: "\(entry.prompts)")
                    if let from = entry.headlineFrom { LabeledContent("Headline from", value: from) }
                }
            }
            Section("Where") {
                LabeledContent("Folder", value: session.cwd.isEmpty ? "–" : LogbookSession.tilde(session.cwd))
                if let repo = session.repo { LabeledContent("Repo", value: repo) }
                if let branch = session.branch { LabeledContent("Branch", value: branch) }
            }
            Section("Transcript") {
                LabeledContent("Session ID") { Text(session.key.sessionId).font(.caption.monospaced()).textSelection(.enabled) }
                if let previous = session.previous {
                    LabeledContent("Previous") { Text(previous).font(.caption.monospaced()).textSelection(.enabled) }
                }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(session.bytes), countStyle: .file))
                LabeledContent("First", value: session.first.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last", value: session.last.formatted(date: .abbreviated, time: .shortened))
                Button("Copy Session ID") { Self.copy(session.key.sessionId) }
            }
        }
        .formStyle(.grouped)
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
