import SwiftUI

/// The sidebar's Agents row (PLAN-agents): how many Claude agents run, and
/// the fullest usage limit. A click opens the Agents page.
struct AgentsSection: View {
    @Environment(Agents.self) private var agents
    @Binding var selection: SessionRef?
    @Binding var page: LogbookPage?

    var body: some View {
        Section("Agents") {
            HStack(spacing: 6) {
                Image(systemName: "person.2.wave.2").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("All agents")
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let fullest {
                    UsageMeter(limit: fullest, compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(page == .agents ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onTapGesture {
                selection = nil
                page = .agents
            }
        }
    }

    private var caption: String {
        let running = agents.running
        let accounts = agents.accounts.count
        return "\(running.count) running · \(accounts) account\(accounts == 1 ? "" : "s")"
    }

    /// The most used 5-hour limit of all accounts (Claude and Antigravity).
    private var fullest: Agents.Limit? {
        agents.accounts.compactMap { $0.limits.first(where: \.isFiveHour) }.max { $0.percent < $1.percent }
    }
}

/// Over a session's terminal, when Claude runs in it.
struct TerminalAgentStrip: View {
    @Environment(Agents.self) private var agents
    let ref: SessionRef

    var body: some View {
        if let agent = agents.agent(machine: ref.machine, mmSession: ref.name) {
            AgentStrip(agent: agent, machine: agents.machine(ref.machine), limits: agents.limits(machine: ref.machine, agent: agent.agent))
            Divider()
        }
    }
}
