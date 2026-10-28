import SwiftUI

/// ⋯ → Agents (PLAN-agents): every machine's Claude login, its usage
/// limits and its running agents. The views are the Mac's (App/AgentsUI).
struct AgentsScreen: View {
    let agents: Agents
    let open: (Agents.Agent) -> Void
    let done: () -> Void

    var body: some View {
        NavigationStack {
            AgentsPage(agents: agents) { agent in
                open(agent)
                done()
            }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
    }
}

/// Over a session's terminal when Claude runs in it; refreshes while shown.
struct SessionAgentStrip: View {
    let agents: Agents
    let machine: String
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            if let agent = agents.agent(machine: machine, mmSession: name) {
                AgentStrip(agent: agent, machine: agents.machine(machine))
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task { await agents.watch() }
    }
}
