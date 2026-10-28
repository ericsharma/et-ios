import SwiftUI

/// What the Logbook (or Agents) shows in place of the terminal.
enum LogbookPage: Hashable {
    case session(LogbookKey)
    case report
    /// Every machine's Claude agents and usage limits (PLAN-agents).
    case agents
}

/// The sidebar's Logbook section, under Files: the sessions grouped by repo
/// (by project once there is a report). A click opens the live transcript.
struct LogbookSection: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Logbook.self) private var logbook
    @Binding var selection: SessionRef?
    @Binding var page: LogbookPage?
    /// Groups the user folded.
    @State private var folded: Set<String> = []

    var body: some View {
        Section {
            reportRow
            if let error = logbook.error, logbook.sessions.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else if logbook.loaded && logbook.groups.isEmpty {
                Text("No Claude sessions yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(logbook.groups) { group in
                DisclosureGroup(isExpanded: Binding(get: { !folded.contains(group.id) },
                                                    set: { if $0 { folded.remove(group.id) } else { folded.insert(group.id) } })) {
                    ForEach(group.sessions) { session in
                        row(session, role: group.project?.sessions.first { $0.key == session.id }?.role)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(group.name).lineLimit(1)
                        Spacer()
                        if group.live > 0 {
                            Text("●\(group.live)").font(.caption).monospacedDigit()
                                .foregroundStyle(group.busy > 0 ? .green : .secondary)
                                .help("\(group.live) running, \(group.busy) busy")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Logbook")
                Spacer()
                Button { Task { await logbook.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the session list")
            }
        }
    }

    /// "Report (12 min ago)", the suggestions, and Refresh.
    private var reportRow: some View {
        let open = page == .report
        return HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let report = logbook.report {
                    Text("Report (\(report.takenDate.formatted(.relative(presentation: .named))))").lineLimit(1)
                    if !report.proposals.isEmpty {
                        Text("⚠ \(report.proposals.count) suggestion\(report.proposals.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("Report")
                }
                if let run = logbook.run {
                    ProgressView(value: run.fraction ?? 0).controlSize(.mini)
                }
            }
            Spacer()
            Button { logbook.refreshReport() } label: { Image(systemName: "arrow.clockwise.circle") }
                .buttonStyle(.borderless)
                .disabled(logbook.run != nil)
                .help("Make a new report (1–3 min)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(open ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onTapGesture {
            selection = nil
            page = .report
        }
    }

    private func row(_ session: LogbookSession, role: String?) -> some View {
        let open = page == .session(session.key)
        return LogbookSessionRow(session: session, role: role)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 4)
            .background(open ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onTapGesture {
                selection = nil
                page = .session(session.key)
            }
            .contextMenu {
                if !session.mmSession.isEmpty {
                    Button("Show Terminal") { selection = SessionRef(machine: session.key.machine, name: session.mmSession) }
                        .disabled(!session.isLive)
                    Button(session.paused ? "Record" : "Do Not Record") { logbook.setPaused(session, !session.paused) }
                }
                Button("Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.key.sessionId, forType: .string)
                }
            }
            .help(LogbookSession.tilde(session.cwd))
    }
}

/// The Logbook page in the detail column.
struct LogbookDetail: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Logbook.self) private var logbook
    @Environment(Agents.self) private var agents
    let page: LogbookPage

    var body: some View {
        switch page {
        case .session(let key):
            LogbookTranscriptView(key: key, logbook: logbook, machines: fleet.machines)
        case .report:
            LogbookReportView(logbook: logbook, machines: fleet.machines) { key in
                fleet.requestedLogbook = .session(key)
            }
        case .agents:
            AgentsPage(agents: agents, title: { logbook.title(for: $0) }) { agent in
                fleet.requestedRef = SessionRef(machine: agent.machine, name: agent.mmSession)
            }
        }
    }
}
