import ETCore
import SwiftUI

// Logbook views for the Mac and iOS (PLAN-logbook §4.6).

/// Orange ring = needs you, green = busy, grey ring = idle, dashed red =
/// a blocked project, nothing = gone.
struct LogbookStatusDot: View {
    let status: String

    var body: some View {
        Group {
            switch status {
            case "needs-you": Circle().fill(.orange).overlay(Circle().strokeBorder(.orange.opacity(0.4), lineWidth: 3).padding(-3))
            case "busy": Circle().fill(.green)
            case "idle": Circle().strokeBorder(.secondary, lineWidth: 1.5)
            case "blocked": Circle().strokeBorder(.red, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            default: Circle().fill(.clear)
            }
        }
        .frame(width: 8, height: 8)
        .help(status)
    }
}

// MARK: - Transcript

/// A session's live transcript: turns with folded tool calls; select turns
/// to send them to a session.
struct LogbookTranscriptView: View {
    let key: LogbookKey
    let logbook: Logbook
    let machines: [MmMachine]
    @State private var transcript: LogbookTranscript?
    @State private var selected: Set<String> = []
    @State private var sending: LogbookSendTarget?
    @State private var atBottom = true
    /// The turn to keep in view after Load earlier.
    @State private var anchor: String?
    /// A friction mark was picked: scroll to its turn (B5).
    @State private var jump: String?
    /// The turn just jumped to, outlined for a moment.
    @State private var flashed: String?

    private var session: LogbookSession? { logbook.session(key) }
    private var signals: [LogbookSignal] { logbook.signals[key.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let session {
                    Button {
                        logbook.setPaused(session, !session.paused)
                    } label: {
                        Label(session.paused ? "Record" : "Do not record",
                              systemImage: session.paused ? "record.circle" : "pause.circle")
                    }
                    .help(session.paused ? "Record this session again" : "Stop copying this session's transcript to the archive")
                    .disabled(logbook.pausing.contains(session.id) || session.mmSession.isEmpty)
                }
                Button {
                    sendSelection()
                } label: {
                    Label(selected.isEmpty ? "Send last turn…" : "Send \(selected.count) turn\(selected.count == 1 ? "" : "s")…",
                          systemImage: "paperplane")
                }
                .help("Send to session…: the turns as a Markdown file, its path typed into a session")
                .disabled(!(transcript?.turns.contains { $0.id != Transcript.leadingTurnID } ?? false))
            }
        }
        .sheet(item: $sending) { target in
            LogbookSendSheet(target: target, machines: machines, logbook: logbook)
        }
        // Starts once the list has the session: its size picks the tail.
        .task(id: session != nil) {
            guard transcript == nil, let session else { return }
            let t = logbook.transcript(key)
            t.start(size: session.bytes)
            transcript = t
        }
        .onDisappear { transcript?.stop() }
        .onChange(of: transcript?.turns.count) { _, _ in followPending() }
        .onChange(of: transcript?.loadingEarlier) { _, _ in followPending() }
        .onChange(of: logbook.pendingTurn) { _, _ in followPending() }
    }

    /// An evidence link's turn: jump once it is loaded; load earlier parts
    /// until it is, or the start is reached.
    private func followPending() {
        guard let pending = logbook.pendingTurn, pending.key == key, let transcript,
              !transcript.loading, !transcript.loadingEarlier else { return }
        if transcript.turns.contains(where: { $0.id == pending.turn }) {
            logbook.pendingTurn = nil
            jump = pending.turn
        } else if transcript.isPartial {
            transcript.loadEarlier()
        } else {
            logbook.pendingTurn = nil
            logbook.notice = "That turn is not in the transcript any more"
        }
    }

    /// Headline, state, project (PLAN-logbook-v2 §4.1); ids are in the inspector.
    private var header: some View {
        HStack(spacing: 8) {
            LogbookStatusDot(status: session.map(logbook.state) ?? "gone")
            VStack(alignment: .leading, spacing: 1) {
                Text(session.map(logbook.headline) ?? key.id).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !selected.isEmpty {
                Button("Clear selection") { selected = [] }.controlSize(.small)
            }
            if !signals.isEmpty { frictionMenu }
            Button { logbook.inspector.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("Machine, folder, ids (⌘I)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// "⚡3": every signal, newest first; a pick jumps to its turn.
    private var frictionMenu: some View {
        let loaded = Set(transcript?.turns.map(\.id) ?? [])
        return Menu {
            ForEach(Array(signals.reversed().enumerated()), id: \.offset) { _, signal in
                let kind = LogbookSignalKind(signal.kind)
                Button {
                    if loaded.contains(signal.turn) { jump = signal.turn } else { transcript?.loadEarlier() }
                } label: {
                    Label("\(kind.name): \(signal.excerpt)\(loaded.contains(signal.turn) ? "" : " (earlier: Load earlier)")",
                          systemImage: kind.symbol)
                }
            }
        } label: {
            LogbookFrictionMarks(friction: Dictionary(grouping: signals, by: \.kind).mapValues(\.count))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where the owner interrupted, denied or corrected, and where tools failed. Pick one to jump to its turn.")
    }

    private var subtitle: String {
        guard let session else { return "" }
        let state = logbook.state(session) == "needs-you" ? "needs you" : session.status == "gone" ? "ended" : session.status
        return [session.key.machine, state, logbook.project(of: session)?.name].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if let transcript {
            if let error = transcript.error {
                ContentUnavailableView("Can't read the transcript", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if transcript.loading {
                ProgressView("Loading transcript…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if transcript.turns.isEmpty {
                ContentUnavailableView("No turns yet", systemImage: "text.bubble")
            } else {
                turns(transcript)
            }
        } else {
            Color.clear
        }
    }

    private func turns(_ transcript: LogbookTranscript) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a LazyVStack draws nothing in the headless Mac
                // mini's offscreen window, and tool calls are folded anyway.
                VStack(alignment: .leading, spacing: 14) {
                    if transcript.isPartial {
                        HStack {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(transcript.startOffset), countStyle: .file)) earlier")
                            if transcript.loadingEarlier {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Load earlier") {
                                    anchor = transcript.turns.first { $0.id != Transcript.leadingTurnID }?.id
                                    transcript.loadEarlier()
                                }
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    let byTurn = Dictionary(grouping: signals, by: \.turn)
                    ForEach(transcript.turns) { turn in
                        LogbookTurnView(turn: turn, selected: selected.contains(turn.id), signals: byTurn[turn.id] ?? []) {
                            if selected.contains(turn.id) { selected.remove(turn.id) } else { selected.insert(turn.id) }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange, lineWidth: flashed == turn.id ? 2 : 0))
                        .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(14)
                .padding(.trailing, signals.isEmpty ? 0 : 8)
            }
            .overlay(alignment: .trailing) {
                LogbookFrictionStrip(turns: transcript.turns.map(\.id), signals: signals) { jump = $0 }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: jump) { _, id in
                guard let id else { return }
                jump = nil
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                flashed = id
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if flashed == id { flashed = nil }
                }
            }
            // Earlier turns came: keep the turn that was at the top in view.
            .onChange(of: transcript.turns.first?.id) { _, _ in
                guard let id = anchor, transcript.turns.contains(where: { $0.id == id }) else { return }
                anchor = nil
                proxy.scrollTo(id, anchor: .top)
            }
            // New lines: stay at the end if the reader is there.
            .onChange(of: transcript.turns.last) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// The selected turns, or the last one if none is selected.
    private func sendSelection() {
        let sendable = (transcript?.turns ?? []).filter { $0.id != Transcript.leadingTurnID }
        guard let last = sendable.last else { return }
        let ids = selected.isEmpty ? [last.id] : sendable.map(\.id).filter(selected.contains)
        let name = session?.label ?? key.id
        sending = LogbookSendTarget(selection: .turns(key, ids), title: ids.count == 1 ? "1 turn of \(name)" : "\(ids.count) turns of \(name)")
    }
}

/// One exchange: the prompt (tap the circle to select it), the reply, and
/// the tool calls folded.
struct LogbookTurnView: View {
    let turn: Transcript.Turn
    let selected: Bool
    /// Friction signals in this turn (B5).
    var signals: [LogbookSignal] = []
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.id == Transcript.leadingTurnID {
                Text("Its prompt is before the loaded part.").font(.caption).foregroundStyle(.secondary)
            } else {
                prompt
            }
            if !turn.tools.isEmpty {
                ToolCallsView(tools: turn.tools).padding(.leading, 26)
            }
            if !turn.reply.isEmpty {
                Text(Self.markdown(turn.reply)).textSelection(.enabled).padding(.leading, 26)
            } else if turn.tools.isEmpty {
                Text("No reply yet").font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var prompt: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(selected ? "Deselect" : "Select this turn to send it")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let date = turn.timestamp {
                        Text(date, format: .dateTime.hour().minute()).foregroundStyle(.secondary)
                    }
                    LogbookFrictionMarks(friction: Dictionary(grouping: signals, by: \.kind).mapValues(\.count))
                        .help(signals.map { LogbookSignalKind($0.kind).name + ": " + $0.excerpt }.joined(separator: "\n"))
                }
                .font(.caption2)
                Text(turn.prompt).foregroundStyle(.blue).textSelection(.enabled)
            }
        }
    }

    /// Inline Markdown (bold, code, links); the text as is if it doesn't parse.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// "3 tool calls", folded; open, a line per call; a call opens its output.
struct ToolCallsView: View {
    let tools: [Transcript.ToolCall]
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tools) { ToolCallRow(tool: $0) }
            }
            .padding(.top, 4)
        } label: {
            Text("\(tools.count) tool call\(tools.count == 1 ? "" : "s"): \(names)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var names: String {
        var seen: [String] = []
        for tool in tools where !seen.contains(tool.name) { seen.append(tool.name) }
        return seen.joined(separator: ", ")
    }
}

struct ToolCallRow: View {
    let tool: Transcript.ToolCall
    @State private var open = false
    @State private var all = false
    private static let limit = 20_000

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if let output = tool.output {
                VStack(alignment: .leading, spacing: 4) {
                    Text(all || output.count <= Self.limit ? output : String(output.prefix(Self.limit)))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    if !all && output.count > Self.limit {
                        Button("Show all \(output.count) characters") { all = true }.font(.caption)
                    }
                }
            } else {
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tool.isError ? "xmark.circle" : (tool.output == nil ? "clock" : "wrench.and.screwdriver"))
                    .foregroundStyle(tool.isError ? .red : .secondary)
                Text(tool.name).font(.caption.weight(.semibold))
                Text(tool.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
