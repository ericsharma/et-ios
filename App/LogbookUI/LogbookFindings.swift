import SwiftUI

// The Findings place (PLAN-logbook-v2 B6): the meta agent's findings, each
// with evidence (links into transcripts) and proposed changes to the
// agents' instruction files. The owner chose (2026-10-31) not to review
// them: every `write` proposal is applied on its machines as a run comes
// in. etd still checks each one (allow-list, base, secrets) and keeps a
// backup of each file it replaces.

/// The last meta run, a Run in progress, and what the owner did with it.
@MainActor @Observable
final class LogbookFindings {
    private(set) var run: MetaRun?
    /// A Run in progress (the report's progress frames).
    private(set) var running: Logbook.ReportRun?
    private(set) var error: String?
    private(set) var loaded = false
    /// Findings and proposals the owner rejected in this run.
    private(set) var rejected: Set<String> = []
    /// Per target ("proposal|machine|path"): writing, applied or failed.
    private(set) var writes: [String: WriteState] = [:]

    enum WriteState: Equatable {
        case writing
        case applied(backup: String)
        /// etd refused: the file changed after the run read it (most
        /// likely another device applied it first).
        case stale
        case failed(String)
    }

    @ObservationIgnored private let archive: @MainActor () -> IrohHost?
    @ObservationIgnored private let hosts: @MainActor () -> [String: IrohHost]
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private let notify: @MainActor (String) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// "run|proposal" applied from this device, so a reload or a restart
    /// does not write them again.
    @ObservationIgnored private var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "logbook.metaApplied") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: "logbook.metaApplied") }
    }

    init(archive: @escaping @MainActor () -> IrohHost?, hosts: @escaping @MainActor () -> [String: IrohHost],
         log: @escaping @MainActor (String) -> Void, notify: @escaping @MainActor (String) -> Void) {
        self.archive = archive
        self.hosts = hosts
        self.log = log
        self.notify = notify
    }

    /// Findings the owner has not rejected.
    var shown: [MetaRun.Finding] {
        (run?.findings ?? []).filter { !rejected.contains($0.id) }
    }

    static func targetKey(_ proposal: MetaRun.Proposal, _ target: MetaRun.Target) -> String {
        proposal.key + "|" + target.machine + "|" + target.path
    }

    /// The last run, without making a new one (a nightly run, or one from
    /// another device, shows up here).
    func load() async {
        guard running == nil, let host = archive() else { return }
        do {
            set(try MetaRun.decode(try await host.meta(refresh: false) { _, _, _ in }))
        } catch {
            self.error = Logbook.describe(error)
        }
        if !loaded { log("Findings: \(run?.findings.count ?? 0) findings\(error.map { ", " + $0 } ?? "")") }
        loaded = true
    }

    /// A new run (minutes: a headless agent reads the signals); a second
    /// click while it runs does nothing.
    func runNow() {
        guard task == nil else { return }
        guard let host = archive() else {
            notify("No archive machine connected")
            return
        }
        running = Logbook.ReportRun()
        error = nil
        log("Findings: run")
        task = Task {
            defer {
                running = nil
                task = nil
            }
            do {
                let json = try await host.meta(refresh: true) { stage, done, total in
                    Task { @MainActor in
                        if self.running != nil { self.running = Logbook.ReportRun(stage: stage, done: done, total: total) }
                    }
                }
                set(try MetaRun.decode(json))
            } catch {
                log("Findings: run failed: \(error)")
                self.error = Logbook.describe(error)
            }
        }
    }

    private func set(_ run: MetaRun) {
        if run.id != self.run?.id {
            rejected = []
            writes = [:]
        }
        self.run = run.id.isEmpty ? nil : run
        error = nil
        applyAll()
    }

    /// Every `write` proposal of the run that this device has not applied
    /// and etd does not list as applied on all its machines.
    private func applyAll() {
        guard let run else { return }
        for finding in run.findings {
            for proposal in finding.proposals where proposal.route == "write" {
                let id = run.id + "|" + proposal.key
                guard !done.contains(id), !proposal.targets.allSatisfy({ proposal.applied.contains($0.machine) }) else { continue }
                done.insert(id)
                apply(proposal, in: finding)
            }
        }
    }

    // MARK: - Decisions

    func reject(_ finding: MetaRun.Finding) {
        rejected.insert(finding.id)
        decide(["decision": "reject", "finding": finding.id])
    }

    /// Writes each target's new content on its machine (only where it is
    /// not applied yet), then tells the archive what was applied.
    func apply(_ proposal: MetaRun.Proposal, in finding: MetaRun.Finding) {
        let targets = proposal.targets.filter {
            if proposal.applied.contains($0.machine) { return false }
            if case .applied = writes[Self.targetKey(proposal, $0)] { return false }
            return true
        }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask { await self.write(target, of: proposal) }
                }
            }
            let applied = proposal.targets.filter {
                if case .applied = writes[Self.targetKey(proposal, $0)] { return true }
                return false
            }
            guard !applied.isEmpty else { return }
            decide(["decision": "applied", "finding": finding.id, "proposal": proposal.id, "machines": applied.map(\.machine)])
            notify(applied.count == proposal.targets.count ? "Applied on \(applied.map(\.machine).joined(separator: ", "))"
                                                           : "Applied on \(applied.count) of \(proposal.targets.count) machines")
        }
    }

    func retry(_ target: MetaRun.Target, of proposal: MetaRun.Proposal, in finding: MetaRun.Finding) {
        Task {
            await write(target, of: proposal)
            if case .applied = writes[Self.targetKey(proposal, target)] {
                decide(["decision": "applied", "finding": finding.id, "proposal": proposal.id, "machines": [target.machine]])
            }
        }
    }

    private func write(_ target: MetaRun.Target, of proposal: MetaRun.Proposal) async {
        let key = Self.targetKey(proposal, target)
        guard let content = target.content else {
            writes[key] = .failed("no new content in the proposal")
            return
        }
        guard let host = hosts()[target.machine] else {
            writes[key] = .failed("offline")
            return
        }
        writes[key] = .writing
        log("Findings: write \(target.path) on \(target.machine) (base \(target.base.prefix(12)))")
        do {
            let backup = try await host.configWrite(path: target.path, base: target.base, content: content)
            writes[key] = .applied(backup: backup)
        } catch {
            log("Findings: write on \(target.machine) failed: \(error)")
            let text = Logbook.describe(error)
            writes[key] = text.contains("changed since it was read") ? .stale : .failed(text)
        }
    }

    private func decide(_ decision: [String: Any]) {
        guard let run, let host = archive() else { return }
        var decision = decision
        decision["run"] = run.id
        let data = (try? JSONSerialization.data(withJSONObject: decision, options: [.sortedKeys])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        log("Findings: decision \(json)")
        Task {
            do {
                try await host.metaDecision(json)
            } catch {
                notify("Decision not saved: \(Logbook.describe(error))")
            }
        }
    }

}

// MARK: - Views

/// The Findings place: Run, then a short card per finding.
struct LogbookFindingsView: View {
    let logbook: Logbook
    let machines: [MmMachine]
    @State private var sending: LogbookSendTarget?

    private var findings: LogbookFindings { logbook.findings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let error = findings.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if findings.run != nil && findings.shown.isEmpty {
                    ContentUnavailableView("No findings", systemImage: "checkmark.seal",
                                           description: Text("Nothing went wrong often enough to change the agents' instructions."))
                } else if findings.run == nil && findings.loaded && findings.running == nil && findings.error == nil {
                    ContentUnavailableView("No run yet", systemImage: "flag",
                                           description: Text("Run reads every machine's friction and changes the agents' instructions to avoid it."))
                }
                ForEach(findings.shown) { finding in
                    FindingCard(finding: finding, logbook: logbook) {
                        sending = LogbookSendTarget(selection: .finding(runId: findings.run?.id ?? "", findingId: finding.id),
                                                    title: "the finding “\(finding.title)”")
                    }
                }
            }
            .padding(14)
        }
        .navigationTitle("Findings")
        .task { await findings.load() }
        .sheet(item: $sending) { LogbookSendSheet(target: $0, machines: machines, logbook: logbook) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Findings").font(.title2.weight(.semibold))
                Text(findings.run.map { "Run \($0.takenDate.formatted(.relative(presentation: .named))) · changes apply by themselves" }
                     ?? "Changes apply by themselves")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let running = findings.running {
                VStack(alignment: .trailing, spacing: 2) {
                    if let fraction = running.fraction {
                        ProgressView(value: fraction).frame(width: 140)
                    } else {
                        ProgressView().progressViewStyle(.linear).frame(width: 140)
                    }
                    Text(running.total > 0 ? "\(running.stage) \(running.done)/\(running.total)" : running.stage)
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Button { findings.runNow() } label: { Label("Run", systemImage: "play.fill") }
                .disabled(findings.running != nil)
                .help("Read every transcript's friction and change the agents' instructions (minutes; uses the subscription)")
        }
    }
}

/// A finding: its title and where its change went. Evidence and the diff
/// are behind Details.
struct FindingCard: View {
    let finding: MetaRun.Finding
    let logbook: Logbook
    let send: () -> Void
    @State private var details = false

    private var findings: LogbookFindings { logbook.findings }

    var body: some View {
        let kind = LogbookSignalKind(finding.kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: kind.symbol).foregroundStyle(kind.color)
                Text(finding.title).font(.headline)
                Spacer()
                Menu {
                    if finding.proposals.contains(where: { $0.route == "agent" }) {
                        Button("Send to Agent…", systemImage: "paperplane", action: send)
                    }
                    Button("Don't Propose Again", systemImage: "xmark", role: .destructive) { findings.reject(finding) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            ForEach(finding.proposals) { proposal in status(proposal) }
            DisclosureGroup(isExpanded: $details) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(finding.count) time\(finding.count == 1 ? "" : "s") in \(finding.sessions) session\(finding.sessions == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(finding.evidence, id: \.self) { item in evidenceRow(item) }
                    ForEach(finding.proposals) { proposal in
                        if !proposal.patch.isEmpty { DiffView(patch: proposal.patch) }
                        if !proposal.why.isEmpty { Text(proposal.why).font(.callout) }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Details").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// One line per proposal: applied where, failed where (Retry), or what
    /// the owner has to do (agent, note).
    @ViewBuilder private func status(_ proposal: MetaRun.Proposal) -> some View {
        switch proposal.route {
        case "write":
            let applied = proposal.targets.filter { isApplied($0, proposal) }.map(\.machine)
            let writing = proposal.targets.contains { findings.writes[LogbookFindings.targetKey(proposal, $0)] == .writing }
            let stale = proposal.targets.filter { findings.writes[LogbookFindings.targetKey(proposal, $0)] == .stale }.map(\.machine)
            HStack(spacing: 6) {
                if writing { ProgressView().controlSize(.mini) }
                if !applied.isEmpty || stale.isEmpty {
                    Text(applied.isEmpty ? (writing ? "Applying…" : "Not applied") : "Applied on " + applied.joined(separator: ", "))
                        .font(.caption).foregroundStyle(applied.isEmpty ? Color.secondary : Color.green)
                }
                if !stale.isEmpty {
                    Text("Already changed on " + stale.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                        .help("The file changed after this run read it, most likely because another device applied it first.")
                }
            }
            ForEach(proposal.targets, id: \.self) { target in
                if case .failed(let error) = findings.writes[LogbookFindings.targetKey(proposal, target)] {
                    HStack(spacing: 6) {
                        Text("Not on \(target.machine): \(error)").font(.caption).foregroundStyle(.red).lineLimit(2)
                        Button("Retry") { findings.retry(target, of: proposal, in: finding) }.controlSize(.mini)
                    }
                }
            }
        case "agent":
            HStack(spacing: 6) {
                Text("In git: an agent has to commit it").font(.caption).foregroundStyle(.secondary)
                Button("Send to Agent…", action: send).controlSize(.mini)
            }
        default:
            Text("By hand: \(proposal.why)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private func isApplied(_ target: MetaRun.Target, _ proposal: MetaRun.Proposal) -> Bool {
        if proposal.applied.contains(target.machine) { return true }
        if case .applied = findings.writes[LogbookFindings.targetKey(proposal, target)] { return true }
        return false
    }

    private func evidenceRow(_ item: MetaRun.Evidence) -> some View {
        Button {
            guard let key = LogbookKey(id: item.key) else { return }
            logbook.pendingTurn = LogbookTurnRef(key: key, turn: item.turn)
            logbook.selected = key
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.right.circle").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(logbook.session(id: item.key).map(logbook.headline) ?? item.key).font(.callout).lineLimit(1)
                    Text(item.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the transcript at this turn")
    }
}

/// A unified diff: + green, - red, @@ blue.
struct DiffView: View {
    let patch: String

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(6)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }

    private func background(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return .green.opacity(0.1) }
        if line.hasPrefix("-") { return .red.opacity(0.1) }
        return .clear
    }
}
