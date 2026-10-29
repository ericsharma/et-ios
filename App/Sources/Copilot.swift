import ETCore
import SwiftUI

/// What the Copilot asks the summary model (SummarySettings: Mac mini or
/// Grok) about the exchanges the user picked, with the agent's name
/// (PLAN-multi-agent).
enum CopilotPrompts {
    static func context(_ agent: AgentProfile) -> String { """
    You help a developer who is supervising \(agent.name) (an AI coding agent working in a terminal) \
    from their phone. You get some of their exchanges with it: what the developer typed, and \(agent.shortName)'s \
    replies (its tool calls and their output are left out).
    """ }

    static func summarize(_ agent: AgentProfile) -> String { context(agent) + """
     Summarize them for the developer: what was asked, what \(agent.shortName) did or found, any problem or open \
    question, and what \(agent.shortName) is waiting for. Plain text, short paragraphs, no markdown headings.
    """ }

    static func ask(_ agent: AgentProfile) -> String { context(agent) + """
     Answer the developer's question about them. Be brief and concrete. Plain text.
    """ }

    static func draft(_ agent: AgentProfile) -> String { context(agent) + """
     Write the developer's next message to \(agent.name), following their instruction if they gave one. \
    Write it as the developer, in the first person, direct and specific: say what to do, which files or \
    names matter, and what done looks like. Output only the message itself: no preamble, no quotes, \
    no explanation.
    """ }
}

/// Copilot mode (✨ on the key row): in place of the terminal, the
/// window's exchanges with Claude from its transcript, as steps to tick.
/// Swipe (or tap a tab) to another window and tick more there: the ticked
/// steps from every window go to the summary model (Mac mini or Grok)
/// together, for a summary, an answer, or a drafted next prompt to review
/// and send into the current window.
struct CopilotView: View {
    let session: SessionController
    let page: WindowPage

    @AppStorage(SummarySettings.providerKey) private var provider = SummarySettings.provider.rawValue
    @State private var loading: WindowID?
    @State private var loadErrors: [WindowID: String] = [:]
    @State private var expanded: Set<String> = []
    @State private var instruction = ""
    @State private var output: Output?
    @State private var task: Task<Void, Never>?
    @State private var started: Date?
    @FocusState private var editing: Bool
    /// Ask was tapped with no question: the box asks for one.
    @State private var askHint = false

    enum Action { case summarize, ask, draft }

    enum Output: Equatable {
        case text(title: String, String)
        case draft(String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            turnList
            Divider()
            bottomPanel
        }
        .background(Color(Theme.background))
        // Each visit: cached steps at once, then refreshed (ticks kept).
        .task(id: page.id) { await load() }
        .onDisappear { task?.cancel() }
        .onChange(of: session.copilotDictation) { _, heard in
            guard let heard, !heard.isEmpty else { return }
            session.copilotDictation = nil
            instruction += (instruction.isEmpty ? "" : " ") + heard
        }
    }

    // This window's part of the store.
    private var turns: [Transcript.Turn] { session.copilotWindows[page.id]?.turns ?? [] }
    private var host: String { session.copilotWindows[page.id]?.host ?? "" }
    private var isLoading: Bool { loading == page.id }
    private var loadError: String? { loadErrors[page.id] }
    private var selected: Set<String> {
        get { session.copilotWindows[page.id]?.selected ?? [] }
        nonmutating set { session.copilotWindows[page.id]?.selected = newValue }
    }

    /// Ticked steps in every window, in window order.
    private var pool: [(page: WindowPage, window: SessionController.CopilotWindow)] {
        session.windows.compactMap { p in
            guard let w = session.copilotWindows[p.id], !w.selected.isEmpty else { return nil }
            return (p, w)
        }
    }
    private var poolCount: Int { pool.reduce(0) { $0 + $1.window.selected.count } }
    private var elsewhere: [(page: WindowPage, window: SessionController.CopilotWindow)] {
        pool.filter { $0.page.id != page.id }
    }

    private var modelLabel: String {
        switch SummarySettings.Provider(rawValue: provider) ?? .local {
        case .local: "Mac mini"
        case .grok: "Grok"
        case .custom: "Custom"
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Copilot · \(page.displayName)").font(.subheadline.weight(.semibold))
                Text(isLoading ? "Reading transcript…" : "\(turns.count) exchanges on \(host) · swipe for other windows")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Latest") { select(last: 1) }
                Button("Last 3") { select(last: 3) }
                Button("All") { selected = Set(turns.map(\.id)) }
                Button("None") { selected = [] }
            } label: {
                Label("Select", systemImage: "checklist").font(.subheadline)
            }
            .disabled(turns.isEmpty)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(isLoading)
                .accessibilityLabel("Reload")
            Button { session.copilotMode = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .accessibilityLabel("Close Copilot")
        }
        .font(.title3)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface)
    }

    // MARK: Turns

    @ViewBuilder private var turnList: some View {
        Group { turnListContent }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Swipe sideways to the next or previous window, as on the terminal.
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { drag in
                let dx = drag.translation.width, dy = drag.translation.height
                guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
                session.switchWindow(next: dx < 0)
            })
    }

    @ViewBuilder private var turnListContent: some View {
        if isLoading && turns.isEmpty {
            ProgressView("Reading Claude's transcript…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("No transcript", systemImage: "text.page.slash")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if turns.isEmpty {
            ContentUnavailableView("No exchanges yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Nothing typed to Claude in this session on \(host)."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(turns) { turn in
                            card(turn).id(turn.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
                .onChange(of: page.id) { proxy.scrollTo(turns.last?.id, anchor: .bottom) }
            }
        }
    }

    /// One step: tap anywhere to include it; the chevron shows the whole
    /// reply (the transcript has it all, not just what fit on screen).
    private func card(_ turn: Transcript.Turn) -> some View {
        let isSelected = selected.contains(turn.id)
        let isExpanded = expanded.contains(turn.id)
        let number = (turns.firstIndex(of: turn) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                Text("Step \(number)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let date = turn.timestamp {
                    Text(date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if turn.reply.count > 280 || turn.prompt.count > 200 {
                    Button {
                        withAnimation(.snappy) {
                            if isExpanded { expanded.remove(turn.id) } else { expanded.insert(turn.id) }
                        }
                    } label: {
                        Label(isExpanded ? "Less" : "All \(turn.reply.count / 1000 + 1)k", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            Text(turn.prompt)
                .font(.callout.weight(.medium))
                .lineLimit(isExpanded ? nil : 4)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            Text(turn.reply.isEmpty ? "(no reply yet)" : turn.reply)
                .font(.callout)
                .foregroundStyle(turn.reply.isEmpty ? .secondary : .primary)
                .lineLimit(isExpanded ? nil : 6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selected.remove(turn.id) } else { selected.insert(turn.id) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(last count: Int) {
        selected = Set(turns.suffix(count).map(\.id))
    }

    // MARK: Bottom panel

    @ViewBuilder private var bottomPanel: some View {
        VStack(spacing: 10) {
            if !elsewhere.isEmpty { poolBar }
            if let output { outputView(output) }
            if let started {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    HStack {
                        ProgressView()
                        Text("Asking \(modelLabel)… \(Int(context.date.timeIntervalSince(started))) s").monospacedDigit()
                        Spacer()
                        Button("Cancel") { cancel() }
                    }
                    .font(.subheadline)
                }
            } else if output.map({ if case .draft = $0 { true } else { false } }) != true {
                Picker("Model", selection: $provider) {
                    Text("Mac mini").tag(SummarySettings.Provider.local.rawValue)
                    Text("Grok").tag(SummarySettings.Provider.grok.rawValue)
                    if provider == SummarySettings.Provider.custom.rawValue {
                        Text("Custom").tag(SummarySettings.Provider.custom.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                TextField(askHint ? "Your question about the ticked steps…" : "Instruction or question · or use the mic",
                          text: $instruction, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                HStack(spacing: 8) {
                    actionButton("Summarize", "text.badge.checkmark", .summarize)
                    actionButton("Ask", "questionmark.bubble", .ask)
                    actionButton("Draft prompt", "square.and.pencil", .draft)
                }
                Text(poolCount == 0 ? "Tap the steps to include"
                     : pool.count > 1 ? "\(poolCount) steps from \(pool.count) windows included"
                     : "\(poolCount) of \(turns.count) steps included")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.surface)
    }

    private func actionButton(_ title: String, _ icon: String, _ action: Action) -> some View {
        Button { run(action) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(poolCount == 0)
    }

    /// Steps ticked in other windows, which go along too.
    private var poolBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.accent)
            Text("Also: " + elsewhere.map { "\($0.window.selected.count) from \($0.page.name)" }.joined(separator: ", "))
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("Clear all") {
                for id in session.copilotWindows.keys { session.copilotWindows[id]?.selected = [] }
            }
            .font(.caption)
        }
        .padding(8)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func outputView(_ output: Output) -> some View {
        switch output {
        case .text(let title, let text):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Read aloud", systemImage: "speaker.wave.2") { Task { await session.say(text) } }
                        .labelStyle(.iconOnly)
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        .labelStyle(.iconOnly)
                    Button("Close", systemImage: "xmark.circle.fill") { self.output = nil }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
                ScrollView { Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
            }
        case .draft(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text("Draft for \(page.displayName) · edit before sending").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { text }, set: { self.output = .draft($0) }))
                    .font(.callout)
                    .frame(minHeight: 120, maxHeight: 260)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Discard", role: .destructive) { self.output = nil }
                    Spacer()
                    Button("Redo") { run(.draft) }
                    Button {
                        session.sendComposed(text.trimmingCharacters(in: .whitespacesAndNewlines), to: page, pressEnter: true)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        session.copilotMode = false
                    } label: {
                        Label("Send to \(page.displayName)", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        case .failure(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill") { self.output = nil }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        let id = page.id
        loading = id
        loadErrors[id] = nil
        do {
            let result = try await session.transcript(for: page)
            // Keep picks across reloads. The first time, start with the
            // latest exchange, unless steps are already ticked elsewhere.
            var picks = (session.copilotWindows[id]?.selected ?? []).intersection(result.turns.map(\.id))
            if session.copilotWindows[id] == nil, elsewhere.isEmpty, let last = result.turns.last { picks = [last.id] }
            session.copilotWindows[id] = .init(host: result.host, turns: result.turns, selected: picks)
        } catch {
            loadErrors[id] = error.localizedDescription
        }
        if loading == id { loading = nil }
    }

    private func run(_ action: Action) {
        let groups = pool
        guard !groups.isEmpty, task == nil else { return }
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .ask, ask.isEmpty {
            // Nothing to ask yet: type it, or tap the mic and say it.
            askHint = true
            editing = true
            return
        }
        askHint = false
        editing = false
        // The Mac mini has a 32k context; Grok far more.
        let budget = SummarySettings.provider == .grok ? 120_000 : 60_000
        // Several windows: one section each, so the model knows which
        // machine and session each step came from.
        var user = groups.count == 1 && groups[0].page.id == page.id
            ? Transcript.render(groups[0].window.picked, budget: budget)
            : groups.map { group in
                "## Window \(group.page.name) (\(session.copilotAgent(for: group.page).shortName) on \(group.window.host))"
                    + (group.page.id == page.id ? ", where the developer is now" : "") + "\n\n"
                    + Transcript.render(group.window.picked, budget: budget / groups.count)
            }.joined(separator: "\n\n")
        let system: String
        let maxTokens: Int
        let agent = session.copilotAgent(for: page)
        switch action {
        case .summarize:
            system = CopilotPrompts.summarize(agent)
            maxTokens = 500
            if !ask.isEmpty { user += "\n\n### Focus\n\(ask)" }
        case .ask:
            system = CopilotPrompts.ask(agent)
            maxTokens = 600
            user += "\n\n### Question\n\(ask)"
        case .draft:
            system = CopilotPrompts.draft(agent)
            maxTokens = 1000
            if groups.count > 1 { user += "\n\nThe message goes to the \(agent.shortName) in window \(page.name)." }
            user += "\n\n### Instruction\n\(ask.isEmpty ? "Write the most useful next prompt." : ask)"
        }
        started = Date()
        task = Task {
            defer {
                task = nil
                started = nil
            }
            do {
                let answer = try await session.complete(system: system, user: user, maxTokens: maxTokens)
                guard !Task.isCancelled else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                switch action {
                case .summarize: output = .text(title: "Summary", answer)
                case .ask: output = .text(title: "Answer", answer)
                case .draft: output = .draft(answer)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                output = .failure(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        started = nil
    }
}
