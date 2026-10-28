import ETCore
import SwiftUI

// Logbook views for the Mac and iOS (PLAN-logbook §4.6).

/// Green = busy, grey ring = idle, nothing = gone.
struct LogbookStatusDot: View {
    let status: String

    var body: some View {
        Group {
            switch status {
            case "busy": Circle().fill(.green)
            case "idle": Circle().strokeBorder(.secondary, lineWidth: 1.5)
            default: Circle().fill(.clear)
            }
        }
        .frame(width: 8, height: 8)
        .help(status)
    }
}

/// machine/mm session, a dot, and when it last wrote.
struct LogbookSessionRow: View {
    let session: LogbookSession
    var role: String?

    var body: some View {
        HStack(spacing: 8) {
            LogbookStatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.label).font(.callout.monospaced()).lineLimit(1)
                    if session.paused {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.caption)
                            .help("Do not record")
                    }
                }
                Text(role ?? caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    private var caption: String {
        let when = session.isLive ? session.status : session.last.formatted(.relative(presentation: .named))
        return [session.branch, when].compactMap { $0 }.joined(separator: " · ")
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
    @State private var atBottom = true

    private var session: LogbookSession? { logbook.session(key) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
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
                .help("Send to session… (PLAN-logbook L4)")
                .disabled(true)
            }
        }
        .onAppear {
            let t = logbook.transcript(key)
            t.start(size: session?.bytes ?? 0)
            transcript = t
        }
        .onDisappear { transcript?.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LogbookStatusDot(status: session?.status ?? "gone")
            Text(headerText).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            if !selected.isEmpty {
                Button("Clear selection") { selected = [] }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.secondary)
    }

    private var headerText: String {
        guard let session else { return key.id }
        return [session.label, LogbookSession.tilde(session.cwd), session.branch, session.status]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
                            Text("Showing the last \(ByteCountFormatter.string(fromByteCount: Int64(LogbookTranscript.tail), countStyle: .file)).")
                            Button("Load all") { transcript.loadAll() }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(transcript.turns) { turn in
                        LogbookTurnView(turn: turn, selected: selected.contains(turn.id)) {
                            if selected.contains(turn.id) { selected.remove(turn.id) } else { selected.insert(turn.id) }
                        }
                        .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(14)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            // New lines: stay at the end if the reader is there.
            .onChange(of: transcript.turns.last) { _, _ in
                if atBottom { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func sendSelection() {}
}

/// One exchange: the prompt (tap the circle to select it), the reply, and
/// the tool calls folded.
struct LogbookTurnView: View {
    let turn: Transcript.Turn
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(selected ? "Deselect" : "Select this turn to send it")
                VStack(alignment: .leading, spacing: 2) {
                    if let date = turn.timestamp {
                        Text(date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(turn.prompt).foregroundStyle(.blue).textSelection(.enabled)
                }
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
