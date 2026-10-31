import SwiftUI

/// What the main window shows in place of the terminal. The Logbook has
/// its own window (PLAN-logbook-v2 D2).
enum LogbookPage: Hashable {
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

    private var needYou: Int { logbook.sessions.filter { logbook.state($0) == "needs-you" }.count }

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

/// The Agents page in the detail column.
struct LogbookDetail: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Logbook.self) private var logbook
    @Environment(Agents.self) private var agents
    let page: LogbookPage

    var body: some View {
        switch page {
        case .agents:
            AgentsPage(agents: agents, title: { logbook.title(for: $0) }) { agent in
                fleet.requestedRef = SessionRef(machine: agent.machine, name: agent.mmSession)
            }
        }
    }
}

/// The Logbook window's content on the Mac: Show Terminal brings a main
/// window forward with the session.
struct LogbookScene: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Logbook.self) private var logbook
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LogbookWindow(logbook: logbook, machines: fleet.machines) { session in
            let ref = SessionRef(machine: session.key.machine, name: session.mmSession)
            let main = NSApp.windows.first { $0.isVisible && !["Logbook", "Debug Log", "Send Files"].contains($0.title) && $0.contentView != nil }
            if let main {
                fleet.requestedRef = ref
                main.makeKeyAndOrderFront(nil)
            } else {
                openWindow(value: ref)
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .task(id: fleet.phase) {
            guard fleet.phase == .ready else { return }
            await logbook.watch()
        }
        // The main window's sidebar turns Logbook notices into these.
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
    }
}
