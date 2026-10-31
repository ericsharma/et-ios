import SwiftUI

/// What the Logbook (or Agents) shows in place of the terminal.
enum LogbookPage: Hashable {
    case session(LogbookKey)
    case report
    /// Every machine's Claude agents and usage limits (PLAN-agents).
    case agents
}

/// The sidebar's one Logbook row (PLAN-logbook-v2 D1): what needs the
/// owner and what runs. A click opens the Logbook window.
struct LogbookRow: View {
    @Environment(Logbook.self) private var logbook
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "book.pages").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Logbook")
                    Text(caption).font(.caption).foregroundStyle(needYou > 0 ? .orange : .secondary).lineLimit(1)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 4).padding(.vertical, 2)
            .onTapGesture { openWindow(id: "logbook") }
            .help("Open the Logbook window (⌘⇧L)")
        }
    }

    private var needYou: Int { logbook.sessions.filter { $0.status == "needs-you" }.count }

    private var caption: String {
        if let error = logbook.error, logbook.sessions.isEmpty { return error }
        let running = logbook.sessions.filter(\.isLive).count
        let busy = logbook.sessions.filter { $0.status == "busy" }.count
        var parts: [String] = []
        if needYou > 0 { parts.append("\(needYou) need\(needYou == 1 ? "s" : "") you") }
        parts.append("\(running) running")
        if busy > 0 { parts.append("\(busy) busy") }
        return parts.joined(separator: " · ")
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
