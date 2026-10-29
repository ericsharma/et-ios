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

// MARK: - Page parts

/// One look for every block of the Agents page.
private extension View {
    func agentsCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A titled block: the same header for every section of the page.
struct AgentsBlock<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
    }
}

extension AgentsBlock where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A problem with what to do about it, in one style everywhere.
struct AgentsNotice: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A Claude, Antigravity CLI or Grok login: who, the plan, its limits in
/// pairs (5-hour beside weekly), and the machines that use it.
struct AccountCard: View {
    let usage: Agents.AccountUsage
    /// Hides the login from this page (an old one).
    var hide: (() -> Void)?

    private var profile: AgentProfile? { AgentProfile.profile(id: usage.agent) }

    /// The organization, else the agent; "login not readable" when E.T.
    /// has no email for it.
    private var subtitle: String {
        if let org = usage.account.org, !org.hasSuffix("'s Organization"), org != profile?.name { return org }
        return profile?.name ?? ""
    }

    /// The limits by model group, in their order.
    private var groups: [(name: String?, limits: [Agents.Limit])] {
        var result: [(name: String?, limits: [Agents.Limit])] = []
        for limit in usage.limits {
            if let i = result.firstIndex(where: { $0.name == limit.group }) {
                result[i].limits.append(limit)
            } else {
                result.append((limit.group, [limit]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if let profile { AgentMark(profile: profile, size: 22) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(usage.account.email ?? usage.account.name ?? "\(profile?.name ?? "Claude") account")
                        .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let plan = usage.plan {
                    Text(plan).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((profile?.accentColor ?? .accentColor).opacity(0.22), in: Capsule())
                }
                if let hide {
                    Menu {
                        Button("Hide Account", systemImage: "eye.slash", action: hide)
                    } label: {
                        Image(systemName: "ellipsis").font(.callout).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Hide this login (an old one) from the Agents page")
                }
            }
            if usage.limits.isEmpty {
                AgentsNotice(text: usage.usageError ?? "No usage yet")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            if let name = group.name {
                                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                                ForEach(Array(stride(from: 0, to: group.limits.count, by: 2)), id: \.self) { i in
                                    GridRow {
                                        if i + 1 < group.limits.count {
                                            LimitGauge(limit: group.limits[i])
                                            LimitGauge(limit: group.limits[i + 1])
                                        } else {
                                            LimitGauge(limit: group.limits[i]).gridCellColumns(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if usage.isStale, let fetched = usage.fetched {
                    AgentsNotice(text: "As of \(UsageMeter.resetText(fetched))" + (usage.usageError.map { " · \($0)" } ?? ""),
                                 systemImage: "clock.arrow.circlepath", tint: .secondary)
                }
            }
            Spacer(minLength: 0)
            Divider()
            Label(usage.machines.map(Nicknames.shared.machine).joined(separator: ", "), systemImage: "desktopcomputer")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .agentsCard()
        .contextMenu {
            if let hide { Button("Hide Account", systemImage: "eye.slash", action: hide) }
        }
    }
}

/// One limit in a card: window, percent, bar, reset.
struct LimitGauge: View {
    let limit: Agents.Limit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.windowLabel).font(.caption)
                Spacer(minLength: 4)
                Text("\(Int(limit.percent.rounded()))%").font(.caption.weight(.semibold).monospacedDigit())
            }
            UsageBar(percent: limit.percent).frame(height: 6)
            Text(limit.resets.map { "Resets \(UsageMeter.resetText($0))" } ?? " ")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A running agent: state, mark, title, where it runs and what it uses,
/// and its login's meters in one column on the right.
struct AgentRow: View {
    let agent: Agents.Agent
    var title: String?
    var limits: [Agents.Limit] = []
    var opens = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                lead
                Spacer(minLength: 8)
                meters.frame(width: 190, alignment: .trailing)
                chevron
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { lead; Spacer(minLength: 0); chevron }
                if !limits.isEmpty { meters.padding(.leading, 46) }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var lead: some View {
        HStack(spacing: 10) {
            LogbookStatusDot(status: agent.status)
            if let profile = agent.profile { AgentMark(profile: profile, size: 20) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? agent.profile?.name ?? agent.agent).font(.callout).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(agent.version.map { "\(agent.profile?.name ?? agent.agent) v\($0)" } ?? "")
    }

    @ViewBuilder private var meters: some View {
        HStack(spacing: 12) { ForEach(limits.prefix(2)) { UsageMeter(limit: $0, compact: true) } }
    }

    @ViewBuilder private var chevron: some View {
        if opens {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private var details: String {
        var parts = [agent.mmSession.isEmpty ? "pid \(agent.pid)" : agent.mmSession]
        if !agent.status.isEmpty { parts.append(agent.status) }
        if let model = agent.modelName { parts.append(model) }
        if let context = agent.contextText { parts.append(context) }
        parts.append(LogbookSession.tilde(agent.cwd))
        return parts.joined(separator: " · ")
    }
}

/// Every machine's agents, the logins they use with their limits, and
/// what E.T. can do with each agent where.
struct AgentsPage: View {
    let agents: Agents
    /// Claude's title for an agent (from the Logbook), if known.
    var title: (Agents.Agent) -> String? = { _ in nil }
    /// Opens the agent's terminal.
    let open: (Agents.Agent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if agents.machines.isEmpty {
                    if agents.refreshing {
                        ProgressView("Asking the machines…").frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ContentUnavailableView("No machines", systemImage: "desktopcomputer",
                                               description: Text("No machine of the network is connected."))
                    }
                } else {
                    running
                    usage
                    if !agents.installed.isEmpty {
                        AgentsBlock(title: "What works", subtitle: "per machine") {
                            WhatWorks(installed: agents.installed)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await agents.watch() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                #if os(macOS)
                // iOS has the navigation title.
                Text("Agents").font(.largeTitle.weight(.bold))
                #endif
                HStack(spacing: 8) {
                    chip("\(agents.running.count) running", systemImage: "terminal")
                    chip("\(agents.running.filter { $0.status == "busy" }.count) busy", systemImage: "bolt.fill", tint: .green)
                    if let tightest {
                        chip("\(tightest.profile.shortName) \(tightest.limit.compactLabel) \(Int(tightest.limit.percent.rounded()))%",
                             systemImage: "gauge.with.dots.needle.67percent",
                             tint: tightest.limit.percent >= 90 ? .red : tightest.limit.percent >= 70 ? .orange : .secondary)
                            .help("The most used limit: \(tightest.account)")
                    }
                    let problems = problems
                    if !problems.isEmpty {
                        chip("\(problems.count) to look at", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            .help(problems.joined(separator: "\n"))
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    Task { await agents.refresh() }
                } label: {
                    if agents.refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(agents.refreshing)
                if let refreshed = agents.refreshed {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chip(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .labelStyle(ChipLabelStyle(tint: tint))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }

    /// The most used limit of all shown logins.
    private var tightest: (limit: Agents.Limit, profile: AgentProfile, account: String)? {
        agents.accounts.flatMap { usage in
            usage.limits.compactMap { limit in
                AgentProfile.profile(id: usage.agent).map { (limit, $0, usage.account.email ?? usage.id) }
            }
        }
        .max { $0.0.percent < $1.0.percent }
    }

    /// Machines that did not answer, and shown logins with no limits.
    private var problems: [String] {
        agents.machines.compactMap { machine in machine.error.map { "\(Nicknames.shared.machine(machine.name)): \($0)" } }
            + agents.accounts.filter { $0.limits.isEmpty && $0.usageError != nil }.map {
                "\($0.account.email ?? AgentProfile.profile(id: $0.agent)?.name ?? $0.id): \($0.usageError ?? "")"
            }
    }

    // MARK: Running now

    private var running: some View {
        let withAgents = agents.machines.filter { machine in machine.agents.contains { !$0.isOrphan } }
        let quiet = agents.machines.filter { machine in machine.error == nil && !machine.agents.contains { !$0.isOrphan } }
        let failed = agents.machines.filter { $0.error != nil }
        return AgentsBlock(title: "Running now", subtitle: "tap to open its terminal") {
            VStack(alignment: .leading, spacing: 0) {
                if withAgents.isEmpty {
                    Text("No agent runs in a session.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(Array(withAgents.enumerated()), id: \.element.id) { index, machine in
                    if index > 0 { Divider().padding(.vertical, 8) }
                    machineBlock(machine)
                }
                if !failed.isEmpty || !quiet.isEmpty {
                    Divider().padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(failed) { machine in
                            AgentsNotice(text: "\(Nicknames.shared.machine(machine.name)): \(machine.error ?? "")" + Self.fix(for: machine.error))
                        }
                        if !quiet.isEmpty {
                            AgentsNotice(text: "Nothing running on " + quiet.map { Nicknames.shared.machine($0.name) }.joined(separator: ", "),
                                         systemImage: "moon.zzz", tint: .secondary)
                        }
                    }
                }
            }
            .agentsCard()
        }
    }

    /// What to do about a machine's error, when there is a clear step.
    private static func fix(for error: String?) -> String {
        guard let error else { return "" }
        if error.contains("jq is not installed") { return ". Install jq there to see its agents." }
        return ""
    }

    private func machineBlock(_ machine: Agents.Machine) -> some View {
        let live = machine.agents.filter { !$0.isOrphan }
        let orphans = machine.agents.filter(\.isOrphan)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
                Text(Nicknames.shared.machine(machine.name)).font(.subheadline.weight(.semibold))
                Text("\(live.count)").font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.bottom, 2)
            ForEach(live) { agent in
                Button { open(agent) } label: {
                    AgentRow(agent: agent, title: title(agent),
                             limits: agents.limits(machine: machine.name, agent: agent.agent), opens: true)
                }
                .buttonStyle(AgentRowButtonStyle())
                .help("Open \(agent.machine)/\(agent.mmSession)")
            }
            if !orphans.isEmpty {
                DisclosureGroup {
                    ForEach(orphans) { AgentRow(agent: $0, title: title($0)) }
                } label: {
                    Text("\(orphans.count) agent process\(orphans.count == 1 ? "" : "es") with no session")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Usage

    private var usage: some View {
        let order = agentProfiles().map(\.id)
        let shown = agents.accounts.sorted { (order.firstIndex(of: $0.agent) ?? 99) < (order.firstIndex(of: $1.agent) ?? 99) }
        // A login E.T. could not read (no email) is a note, not a card.
        let cards = shown.filter { $0.account.email != nil }
        let unreadable = shown.filter { $0.account.email == nil }
        let hidden = agents.hiddenAccounts
        return AgentsBlock(title: "Usage", subtitle: "each login once, with the machines that use it") {
            VStack(alignment: .leading, spacing: 14) {
                if cards.isEmpty {
                    Text("No logins yet.").font(.callout).foregroundStyle(.secondary).agentsCard()
                }
                CardGrid(items: cards, minWidth: 320) { usage in
                    AccountCard(usage: usage) { agents.setHidden(usage, true) }
                }
                if !unreadable.isEmpty || !hidden.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(unreadable) { usage in
                            HStack(alignment: .center, spacing: 8) {
                                if let profile = AgentProfile.profile(id: usage.agent) { AgentMark(profile: profile, size: 14) }
                                Text(usage.machines.map(Nicknames.shared.machine).joined(separator: ", ")).font(.caption.weight(.semibold))
                                Text(usage.usageError ?? "Login not readable").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Spacer()
                                Button("Hide") { agents.setHidden(usage, true) }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                        if !hidden.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(hidden) { usage in
                                        HStack(spacing: 8) {
                                            if let profile = AgentProfile.profile(id: usage.agent) { AgentMark(profile: profile, size: 14) }
                                            Text(usage.account.email ?? AgentProfile.profile(id: usage.agent)?.name ?? usage.id)
                                                .font(.callout).lineLimit(1)
                                            Text(usage.machines.map(Nicknames.shared.machine).joined(separator: ", "))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            Spacer()
                                            Button("Show") { agents.setHidden(usage, false) }.font(.caption).buttonStyle(.borderless)
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            } label: {
                                Label("\(hidden.count) hidden login\(hidden.count == 1 ? "" : "s")", systemImage: "eye.slash")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .agentsCard()
                }
            }
        }
    }
}

/// Cards in rows of equal height: as many columns as fit at `minWidth`,
/// the last row padded so every card has the same width.
struct CardGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var minWidth: CGFloat = 300
    var spacing: CGFloat = 12
    @ViewBuilder let card: (Item) -> Card
    @State private var width: CGFloat = 0

    var body: some View {
        let columns = max(1, Int((width + spacing) / (minWidth + spacing)))
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(rows[r]) { card($0) }
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct ChipLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// A row that opens something: a soft highlight on hover and press.
private struct AgentRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -8)
            .onHover { hovering = $0 }
    }
}

/// Per machine and per agent: installed, transcript, alerts
/// (PLAN-multi-agent §4.2). Tap a cell for what is missing.
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
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Text("Agent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(minWidth: 170, alignment: .leading)
                        ForEach(machineNames, id: \.self) { name in
                            Text(Nicknames.shared.machine(name)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).frame(minWidth: 104).gridColumnAlignment(.center)
                        }
                    }
                    .padding(.bottom, 8)
                    ForEach(agentProfiles()) { profile in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            HStack(spacing: 8) {
                                AgentMark(profile: profile)
                                Text(profile.name).font(.callout)
                            }
                            ForEach(machineNames, id: \.self) { name in
                                cell(machine: name, agent: installed[name]?.first { $0.id == profile.id })
                            }
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
            HStack(spacing: 14) {
                legend("checkmark.circle.fill", .green, "works")
                legend("circle.dashed", .secondary, "not yet")
                legend("minus", .secondary, "not installed")
                Text("Columns: installed · transcript · alerts").font(.caption2).foregroundStyle(.secondary)
            }
            if let picked { hint(picked) }
        }
        .agentsCard()
    }

    private func legend(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .font(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private func cell(machine: String, agent: AgentOnMachine?) -> some View {
        let selected = agent.map { picked == Picked(machine: machine, agent: $0) } ?? false
        Button {
            if let agent { picked = selected ? nil : Picked(machine: machine, agent: agent) }
        } label: {
            Group {
                if let agent, agent.version != nil {
                    HStack(spacing: 5) {
                        dot(true)
                        dot(agent.transcript)
                        dot(agent.alerts)
                    }
                } else {
                    Image(systemName: "minus").foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .frame(minWidth: 104, minHeight: 22)
            .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agent?.version.map { "Version \($0)" } ?? "Not installed")
    }

    private func dot(_ works: Bool) -> some View {
        Image(systemName: works ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(works ? Color.green : .secondary)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func hint(_ picked: Picked) -> some View {
        let profile = AgentProfile.profile(id: picked.agent.id)
        return HStack(alignment: .top, spacing: 10) {
            if let profile { AgentMark(profile: profile, size: 20) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(profile?.name ?? picked.agent.id) on \(Nicknames.shared.machine(picked.machine))")
                        .font(.callout.weight(.semibold))
                    if let version = picked.agent.version {
                        Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(picked.agent.setupHint ?? "Everything works.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let hint = picked.agent.setupHint {
                Button("Copy") { copy(hint) }.font(.caption)
            }
        }
        .padding(10)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One line over a session's terminal when an agent runs in it: status,
/// model, context, the login and its limits (the login's newest).
struct AgentStrip: View {
    let agent: Agents.Agent
    let machine: Agents.Machine?
    let limits: [Agents.Limit]

    private var login: Agents.AgentLogin? { machine?.logins.first { $0.agent == agent.agent } }
    private var isClaude: Bool { agent.agent == "claude" }

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
            if full, let email = isClaude ? machine?.account?.email : login?.email {
                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if full, let plan = isClaude ? machine?.plan : login?.plan {
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
