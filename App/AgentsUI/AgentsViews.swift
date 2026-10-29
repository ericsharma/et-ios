import SwiftUI

// Agents views for the Mac and iOS (PLAN-agents).

/// A usage limit: its name, a bar, the percent and when it resets.
struct UsageMeter: View {
    let limit: Agents.Limit
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Text(limit.compactLabel)
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

/// A Claude or Antigravity CLI login: who, the plan, its limits, and the
/// machines that use it. Limits from an earlier ask show "as of".
struct AccountCard: View {
    let usage: Agents.AccountUsage

    private var profile: AgentProfile? { AgentProfile.profile(id: usage.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let profile { AgentMark(profile: profile).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 } }
                VStack(alignment: .leading, spacing: 2) {
                    Text(usage.account.email ?? usage.account.name ?? "\(profile?.name ?? "Claude") account").font(.headline).lineLimit(1)
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
            } else if usage.isStale, let fetched = usage.fetched {
                Label("As of \(UsageMeter.resetText(fetched))" + (usage.usageError.map { " · \($0)" } ?? ""),
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("On " + usage.machines.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A running agent: its title, where it runs, the model and context.
struct AgentRow: View {
    let agent: Agents.Agent
    var title: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LogbookStatusDot(status: agent.status).padding(.top, 5)
            if let profile = agent.profile { AgentMark(profile: profile).padding(.top, 1) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? (agent.mmSession.isEmpty ? "\(agent.profile?.shortName ?? "Claude") (pid \(agent.pid))" : agent.mmSession))
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
        var parts = agent.status.isEmpty ? [agent.profile?.name ?? agent.agent] : [agent.status]
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
                ForEach(agents.machines.filter { !$0.noClaude || $0.agy != nil }) { machine in
                    machineSection(machine)
                }
                let others = agents.machines.filter { $0.noClaude && $0.agy == nil }.map(\.name)
                if !others.isEmpty {
                    Text("No agents on " + others.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if !agents.installed.isEmpty {
                    WhatWorks(installed: agents.installed)
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
                let limits = agents.limits(machine: machine.name)
                if !limits.isEmpty {
                    HStack(spacing: 10) { ForEach(limits.prefix(2)) { UsageMeter(limit: $0, compact: true) } }
                }
            }
            if let error = machine.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if live.isEmpty {
                Text("No agent running in a session").font(.caption).foregroundStyle(.secondary)
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
                    Text("\(orphans.count) agent process\(orphans.count == 1 ? "" : "es") with no session")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Per machine and per agent: installed, transcript, alerts
/// (PLAN-multi-agent §4.2). A "·" opens what is missing and how to turn it on.
struct WhatWorks: View {
    let installed: [String: [AgentOnMachine]]
    @State private var picked: Picked?

    struct Picked: Equatable {
        var machine: String
        var agent: AgentOnMachine
    }

    private var machineNames: [String] {
        installed.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What works").font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Agents").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(machineNames, id: \.self) { name in
                            Text(Nicknames.shared.machine(name)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(agentProfiles()) { profile in
                        GridRow {
                            HStack(spacing: 6) {
                                AgentMark(profile: profile)
                                Text(profile.name).font(.callout)
                            }
                            ForEach(machineNames, id: \.self) { name in
                                cell(machine: name, agent: installed[name]?.first { $0.id == profile.id })
                            }
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text("installed · transcript · alerts").font(.caption2).foregroundStyle(.secondary)
                            .gridCellColumns(max(machineNames.count, 1))
                    }
                }
            }
            if let picked {
                hint(picked)
            } else {
                Text("Tap a \"·\" to see what is missing.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func cell(machine: String, agent: AgentOnMachine?) -> some View {
        if let agent, agent.version != nil {
            Button {
                picked = picked == Picked(machine: machine, agent: agent) ? nil : Picked(machine: machine, agent: agent)
            } label: {
                HStack(spacing: 6) {
                    mark(true)
                    mark(agent.transcript)
                    mark(agent.alerts)
                }
                .font(.callout.monospaced())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(agent.version.map { "Version \($0)" } ?? "")
        } else {
            Button {
                if let agent { picked = Picked(machine: machine, agent: agent) }
            } label: {
                Text("—").font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func mark(_ works: Bool) -> some View {
        Text(works ? "✓" : "·").foregroundStyle(works ? Color.green : .secondary)
    }

    private func hint(_ picked: Picked) -> some View {
        let profile = AgentProfile.profile(id: picked.agent.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let profile { AgentMark(profile: profile) }
                Text("\(profile?.name ?? picked.agent.id) on \(Nicknames.shared.machine(picked.machine))")
                    .font(.callout.weight(.semibold))
                if let version = picked.agent.version {
                    Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text(picked.agent.setupHint ?? "Everything works.").font(.caption)
            if let hint = picked.agent.setupHint {
                Button("Copy") { copy(hint) }.font(.caption)
            }
        }
    }
}

/// One line over a session's terminal when an agent runs in it: status,
/// model, context, the login and its limits (the login's newest).
struct AgentStrip: View {
    let agent: Agents.Agent
    let machine: Agents.Machine?
    let limits: [Agents.Limit]

    private var isAgy: Bool { agent.agent == "antigravity" }

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
                if let profile = agent.profile { AgentMark(profile: profile, size: 13) }
                Text(agent.modelName ?? agent.profile?.name ?? "Claude").font(.caption.weight(.semibold))
            }
            if let context = agent.contextText {
                Text(context).font(.caption).foregroundStyle(.secondary)
            }
            if full, let email = isAgy ? machine?.agy?.email : machine?.account?.email {
                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if full, !isAgy, let plan = machine?.plan {
                Text(plan).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ForEach(limits.prefix(2)) { UsageMeter(limit: $0, compact: true) }
        }
        .lineLimit(1)
    }
}

// MARK: - New session (PLAN-multi-agent §4.2)

/// What + starts: a shell, an agent installed on the machine, or a command.
enum SpawnChoice: Hashable {
    case shell
    case agent(String)
    case command

    /// The command for manymux; nil for `.command` (the typed one).
    var launch: [String]? {
        switch self {
        case .shell: []
        case .agent(let id): AgentProfile.profile(id: id)?.launch
        case .command: nil
        }
    }
}

/// The + sheet's rows: Shell, the agents on the machine with their
/// versions, "X is not on <machine>", Command.
struct SpawnChoices: View {
    let agents: Agents?
    let machine: String
    @Binding var choice: SpawnChoice
    @State private var loading = false
    @State private var unknown = false

    var body: some View {
        let found = agents?.installed[machine]
        row(.shell) { Text("Shell") }
        Text("Agents").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(agentProfiles()) { profile in
            let version = found?.first { $0.id == profile.id }?.version
            if found != nil, version == nil {
                HStack(spacing: 8) {
                    AgentMark(profile: profile).opacity(0.4)
                    Text("\(profile.name) is not on \(Nicknames.shared.machine(machine))")
                        .foregroundStyle(.secondary)
                }
            } else {
                row(.agent(profile.id)) {
                    AgentMark(profile: profile)
                    Text(profile.name)
                    Spacer()
                    if let version { Text(version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
        }
        if found == nil {
            Text(loading ? "Looking for agents on \(Nicknames.shared.machine(machine))…"
                 : "Couldn't ask \(Nicknames.shared.machine(machine)) which agents it has.")
                .font(.caption).foregroundStyle(.secondary)
        }
        row(.command) { Text("Command…") }
            .task(id: machine) {
                guard let agents, !machine.isEmpty else { return }
                loading = true
                let found = await agents.loadInstalled(on: machine)
                loading = false
                if case .agent(let id) = choice, let found, found.first(where: { $0.id == id })?.version == nil {
                    choice = .shell
                }
            }
    }

    private func row(_ value: SpawnChoice, @ViewBuilder label: () -> some View) -> some View {
        Button { choice = value } label: {
            HStack(spacing: 8) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Color.accentColor : .secondary)
                label()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
