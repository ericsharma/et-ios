import ETCore
import SwiftUI

/// What the Copilot asks the summary model (SummarySettings: Mac mini or
/// Grok) about the exchanges the user picked.
enum CopilotPrompts {
    static let context = """
    You help a developer who is supervising Claude Code (an AI coding agent working in a terminal) \
    from their phone. You get some of their exchanges with it: what the developer typed, and Claude's \
    replies (its tool calls and their output are left out).
    """

    static let summarize = context + """
     Summarize them for the developer: what was asked, what Claude did or found, any problem or open \
    question, and what Claude is waiting for. Plain text, short paragraphs, no markdown headings.
    """

    static let ask = context + """
     Answer the developer's question about them. Be brief and concrete. Plain text.
    """

    static let draft = context + """
     Write the developer's next message to Claude Code, following their instruction if they gave one. \
    Write it as the developer, in the first person, direct and specific: say what to do, which files or \
    names matter, and what done looks like. Output only the message itself: no preamble, no quotes, \
    no explanation.
    """
}

/// Copilot mode (✨ on the key row): in place of the terminal, the
/// window's exchanges with Claude from its transcript, as steps to tick.
/// The ticked steps go to the summary model (Mac mini or Grok) for a
/// summary, an answer, or a drafted next prompt to review and send.
struct CopilotView: View {
    let session: SessionController
    let page: WindowPage

    @AppStorage(SummarySettings.providerKey) private var provider = SummarySettings.provider.rawValue
    @State private var turns: [Transcript.Turn] = []
    @State private var host = ""
    @State private var loading = true
    @State private var loadError: String?
    @State private var selected: Set<String> = []
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
        .task { await load() }
        .onDisappear { task?.cancel() }
        .onChange(of: session.copilotDictation) { _, heard in
            guard let heard, !heard.isEmpty else { return }
            session.copilotDictation = nil
            instruction += (instruction.isEmpty ? "" : " ") + heard
        }
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
                Text("Copilot · \(page.name)").font(.subheadline.weight(.semibold))
                Text(loading ? "Reading transcript…" : "\(turns.count) exchanges on \(host)")
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
                .disabled(loading)
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
        if loading {
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
                Text(selected.isEmpty ? "Tap the steps to include" : "\(selected.count) of \(turns.count) steps included")
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
        .disabled(selected.isEmpty || loading)
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
                Text("Draft for \(page.name) · edit before sending").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                        Label("Send to \(page.name)", systemImage: "paperplane.fill")
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
        loading = true
        loadError = nil
        do {
            let result = try await session.transcript(for: page)
            turns = result.turns
            host = result.host
            // Keep picks across reloads; start with the latest exchange.
            selected = selected.intersection(turns.map(\.id))
            if selected.isEmpty, let last = turns.last { selected = [last.id] }
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func run(_ action: Action) {
        let picked = turns.filter { selected.contains($0.id) }
        guard !picked.isEmpty, task == nil else { return }
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
        var user = Transcript.render(picked, budget: budget)
        let system: String
        let maxTokens: Int
        switch action {
        case .summarize:
            system = CopilotPrompts.summarize
            maxTokens = 500
            if !ask.isEmpty { user += "\n\n### Focus\n\(ask)" }
        case .ask:
            system = CopilotPrompts.ask
            maxTokens = 600
            user += "\n\n### Question\n\(ask)"
        case .draft:
            system = CopilotPrompts.draft
            maxTokens = 1000
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
