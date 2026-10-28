import SwiftUI

// Agents views for the Mac and iOS (PLAN-agents).

/// A usage limit: its name, a bar, the percent and when it resets.
struct UsageMeter: View {
    let limit: Agents.Limit
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Text(limit.name == "five_hour" ? "5h" : limit.name == "seven_day" ? "wk" : limit.label)
                    .foregroundStyle(.secondary)
                UsageBar(percent: limit.percent).frame(width: 36, height: 5)
                Text("\(Int(limit.percent.rounded()))%").monospacedDigit()
            }
            .font(.caption2)
            .help(helpText)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(limit.label).font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(limit.percent.rounded()))%").font(.caption.monospacedDigit())
                }
                UsageBar(percent: limit.percent).frame(height: 6)
                if let resets = limit.resets {
                    Text("Resets \(Self.resetText(resets))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var helpText: String {
        "\(limit.label): \(Int(limit.percent.rounded()))% used" + (limit.resets.map { ", resets \(Self.resetText($0))" } ?? "")
    }

    /// "7:00 PM" today, else "Thu 11:00 PM".
    static func resetText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * min(max(percent, 0), 100) / 100)
            }
        }
    }

    private var color: Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : .green
    }
}

/// A Claude login: who, the plan, its limits, and the machines that use it.
struct AccountCard: View {
    let usage: Agents.AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(usage.account.email ?? usage.account.name ?? "Claude account").font(.headline).lineLimit(1)
                    if let org = usage.account.org {
                        Text(org).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let plan = usage.plan {
                    Text(plan).font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
            }
            ForEach(usage.limits) { UsageMeter(limit: $0) }
            if let error = usage.usageError, usage.limits.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Text("On " + usage.machines.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A running Claude: its title, where it runs, the model and context.
struct AgentRow: View {
    let agent: Agents.Agent
    var title: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LogbookStatusDot(status: agent.status).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? (agent.mmSession.isEmpty ? "Claude (pid \(agent.pid))" : agent.mmSession))
                    .font(.callout).lineLimit(1)
                Text(agent.mmSession.isEmpty ? agent.machine : "\(agent.machine)/\(agent.mmSession)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts = [agent.status]
        if let model = agent.modelName { parts.append(model) }
        if let context = agent.contextText { parts.append(context) }
        if let version = agent.version { parts.append("v\(version)") }
        parts.append(LogbookSession.tilde(agent.cwd))
        return parts.joined(separator: " · ")
    }
}

/// Every machine's Claude login, its limits and its running agents.
struct AgentsPage: View {
    let agents: Agents
    /// Claude's title for an agent (from the Logbook), if known.
    var title: (Agents.Agent) -> String? = { _ in nil }
    /// Opens the agent's terminal.
    let open: (Agents.Agent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if agents.machines.isEmpty {
                    if agents.refreshing {
                        ProgressView("Asking the machines…").frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ContentUnavailableView("No machines", systemImage: "desktopcomputer",
                                               description: Text("No machine of the network is connected."))
                    }
                }
                if !agents.accounts.isEmpty {
                    Text("Accounts").font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(agents.accounts) { AccountCard(usage: $0) }
                    }
                }
                ForEach(agents.machines.filter { !$0.noClaude }) { machine in
                    machineSection(machine)
                }
                let others = agents.machines.filter(\.noClaude).map(\.name)
                if !others.isEmpty {
                    Text("No Claude on " + others.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .task { await agents.watch() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents").font(.title2.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if agents.refreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await agents.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(agents.refreshing)
        }
    }

    private var summary: String {
        let running = agents.running
        let busy = running.filter { $0.status == "busy" }.count
        var text = "\(running.count) running, \(busy) busy"
        if let refreshed = agents.refreshed {
            text += " · updated \(refreshed.formatted(date: .omitted, time: .shortened))"
        }
        return text
    }

    private func machineSection(_ machine: Agents.Machine) -> some View {
        let live = machine.agents.filter { !$0.isOrphan }
        let orphans = machine.agents.filter(\.isOrphan)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(machine.name).font(.headline)
                if let email = machine.account?.email {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !machine.limits.isEmpty {
                    HStack(spacing: 10) { ForEach(machine.limits.prefix(2)) { UsageMeter(limit: $0, compact: true) } }
                }
            }
            if let error = machine.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if live.isEmpty {
                Text("No Claude running in a session").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(live) { agent in
                Button { open(agent) } label: {
                    AgentRow(agent: agent, title: title(agent)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(agent.machine)/\(agent.mmSession)")
            }
            if !orphans.isEmpty {
                DisclosureGroup {
                    ForEach(orphans) { AgentRow(agent: $0, title: title($0)) }
                } label: {
                    Text("\(orphans.count) Claude process\(orphans.count == 1 ? "" : "es") with no session")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One line over a session's terminal when Claude runs in it: status,
/// model, context, the login and its limits.
struct AgentStrip: View {
    let agent: Agents.Agent
    let machine: Agents.Machine?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(full: true)
            line(full: false)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func line(full: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                LogbookStatusDot(status: agent.status)
                Text(agent.modelName ?? "Claude").font(.caption.weight(.semibold))
            }
            if let context = agent.contextText {
                Text(context).font(.caption).foregroundStyle(.secondary)
            }
            if full, let email = machine?.account?.email {
                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if full, let plan = machine?.plan {
                Text(plan).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ForEach(machine?.limits.prefix(2) ?? []) { UsageMeter(limit: $0, compact: true) }
        }
        .lineLimit(1)
    }
}
