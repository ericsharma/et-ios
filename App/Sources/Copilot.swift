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

/// The Copilot: Claude's exchanges in a window (from its transcript), which
/// the user picks and hands to the summary model for a summary, an answer,
/// or a drafted next prompt to review and send into the window.
struct CopilotView: View {
    let session: SessionController
    let page: WindowPage
    @Environment(\.dismiss) private var dismiss

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

    enum Action { case summarize, ask, draft }

    enum Output: Equatable {
        case text(title: String, String)
        case draft(String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            turnList
            Divider()
            bottomPanel
        }
        .navigationTitle(page.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Model", selection: $provider) {
                        ForEach(SummarySettings.Provider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                } label: {
                    Label(modelLabel, systemImage: "cpu")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                }
            }
        }
        .task { await load() }
        .onDisappear { task?.cancel() }
    }

    private var modelLabel: String {
        switch SummarySettings.Provider(rawValue: provider) ?? .local {
        case .local: "Mac mini"
        case .grok: "Grok"
        case .custom: "Custom"
        }
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
                        Text("\(turns.count) exchanges on \(host) · tap to expand, tick to include")
                            .font(.caption).foregroundStyle(.secondary)
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

    private func card(_ turn: Transcript.Turn) -> some View {
        let isSelected = selected.contains(turn.id)
        let isExpanded = expanded.contains(turn.id)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if isSelected { selected.remove(turn.id) } else { selected.insert(turn.id) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "Included" : "Not included")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("You").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Spacer()
                    if let date = turn.timestamp {
                        Text(date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(turn.prompt).font(.callout).lineLimit(isExpanded ? nil : 3)
                Text("Claude").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                Text(turn.reply.isEmpty ? "(no reply yet)" : turn.reply)
                    .font(.callout)
                    .foregroundStyle(turn.reply.isEmpty ? .secondary : .primary)
                    .lineLimit(isExpanded ? nil : 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) {
                    if isExpanded { expanded.remove(turn.id) } else { expanded.insert(turn.id) }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
        }
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
                TextField("Instruction or question (optional)", text: $instruction, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                HStack(spacing: 8) {
                    actionButton("Summarize", "text.badge.checkmark", .summarize)
                    actionButton("Ask", "questionmark.bubble", .ask)
                        .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    actionButton("Draft prompt", "square.and.pencil", .draft)
                }
                Text(selected.isEmpty ? "Tick at least one exchange" : "\(selected.count) of \(turns.count) exchanges included")
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
                        dismiss()
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
        editing = false
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
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
