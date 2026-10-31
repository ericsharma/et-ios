import SwiftUI

// The Findings place: the meta agent's findings, each with evidence (links
// into transcripts) and changes to the agents' instruction files. Every
// `write` change is applied as a run comes in, without review; etd checks
// each write and keeps a backup.

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
    /// Undo per follow-up row (its id), and "Make the same" per drift
    /// file id: writing, applied or failed.
    private(set) var undos: [String: WriteState] = [:]
    private(set) var syncs: [String: WriteState] = [:]

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
    /// "machine|path" being written now: one write per file at a time.
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Targets ("run|finding/proposal|machine|path|base") last tried at.
    @ObservationIgnored private var tried: [String: Date] = [:]
    /// Targets written and recorded from this device: a restart does not
    /// write them again.
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

    /// Writes every `write` target etd still lists: etd drops a machine
    /// whose file has the change and rebuilds the rest against the file as
    /// it is now. One write per file per read; the next read (1 min) gives
    /// the next proposal on that file its new base. A failed target waits
    /// 10 minutes.
    private func applyAll() {
        guard let run else { return }
        var files = inFlight
        for finding in run.findings where !rejected.contains(finding.id) {
            for proposal in finding.proposals where proposal.route == "write" {
                let targets = proposal.targets.filter { target in
                    let file = target.machine + "|" + target.path
                    let id = Self.attempt(run, proposal, target)
                    guard target.route != "agent", !proposal.applied.contains(target.machine), !files.contains(file),
                          !done.contains(id), tried[id].map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return false }
                    files.insert(file)
                    tried[id] = Date()
                    return true
                }
                if !targets.isEmpty { apply(targets, of: proposal, in: finding, run: run) }
            }
        }
    }

    private static func attempt(_ run: MetaRun, _ proposal: MetaRun.Proposal, _ target: MetaRun.Target) -> String {
        [run.id, proposal.key, target.machine, target.path, target.base].joined(separator: "|")
    }

    // MARK: - Decisions

    func reject(_ finding: MetaRun.Finding) {
        rejected.insert(finding.id)
        decide(["decision": "reject", "finding": finding.id])
    }

    /// Writes each target's new content on its machine, then tells the
    /// archive where it was applied. Done (not written again after a
    /// restart) only once both succeeded.
    private func apply(_ targets: [MetaRun.Target], of proposal: MetaRun.Proposal, in finding: MetaRun.Finding, run: MetaRun) {
        let files = targets.map { $0.machine + "|" + $0.path }
        inFlight.formUnion(files)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask { await self.write(target, of: proposal) }
                }
            }
            inFlight.subtract(files)
            let applied = targets.filter {
                if case .applied = writes[Self.targetKey(proposal, $0)] { return true }
                return false
            }
            guard !applied.isEmpty else { return }
            notify("\(finding.title): applied on \(applied.map(\.machine).joined(separator: ", "))")
            if await decide(["decision": "applied", "finding": finding.id, "proposal": proposal.id,
                             "machines": applied.map(\.machine)], run: run.id) {
                done.formUnion(applied.map { Self.attempt(run, proposal, $0) })
            }
        }
    }

    func retry(_ target: MetaRun.Target, of proposal: MetaRun.Proposal, in finding: MetaRun.Finding) {
        guard let run else { return }
        Task {
            await write(target, of: proposal)
            if case .applied = writes[Self.targetKey(proposal, target)] {
                await decide(["decision": "applied", "finding": finding.id, "proposal": proposal.id, "machines": [target.machine]], run: run.id)
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

    // MARK: - Undo

    /// Machines the follow-up rows say a proposal is applied on (and not
    /// undone); all of the proposal's machines for a row without machines.
    func appliedOn(finding: String, proposal: String) -> Set<String> {
        var machines = Set<String>()
        for row in run?.followup ?? [] where row.finding == finding && row.proposal == proposal && !row.undone {
            if row.machines.isEmpty {
                let targets = run?.findings.first { $0.id == finding }?.proposals.first { $0.id == proposal }?.targets ?? []
                machines.formUnion(targets.map(\.machine))
            } else {
                machines.formUnion(row.machines)
            }
        }
        return machines
    }

    /// The applied proposal's targets in the current run, if it is there:
    /// Undo needs each file's old content and the new sha256.
    func undoTargets(_ row: MetaRun.Followup) -> [MetaRun.Target] {
        guard let finding = run?.findings.first(where: { $0.id == row.finding }),
              let proposal = finding.proposals.first(where: { $0.id == (row.proposal ?? "") }) else { return [] }
        let wanted = { (machine: String) in row.machines.isEmpty || row.machines.contains(machine) }
        // etd ≥ 0.0.24 lists how to undo each applied machine; before, the targets carried it.
        let undo = proposal.undo.filter { wanted($0.machine) }.map {
            MetaRun.Target(machine: $0.machine, path: $0.path, base: "", old: $0.content, after: $0.base)
        }
        return undo.isEmpty ? proposal.targets.filter { ($0.after ?? "").isEmpty == false && wanted($0.machine) } : undo
    }

    /// Writes each machine's old file back, if the file is still the one
    /// the proposal wrote; then tells the archive.
    func undo(_ row: MetaRun.Followup) {
        let targets = undoTargets(row)
        guard !targets.isEmpty else { return }
        undos[row.id] = .writing
        log("Findings: undo \(row.id) on \(targets.map(\.machine).joined(separator: ", "))")
        Task {
            var undone: [String] = []
            var errors: [String] = []
            for target in targets {
                guard let host = hosts()[target.machine] else {
                    errors.append("\(target.machine): offline")
                    continue
                }
                do {
                    _ = try await host.configWrite(path: target.path, base: target.after ?? "", content: target.old ?? "")
                    undone.append(target.machine)
                } catch {
                    errors.append("\(target.machine): \(Logbook.describe(error))")
                }
            }
            undos[row.id] = errors.isEmpty ? .applied(backup: "") : .failed(errors.joined(separator: "; "))
            guard !undone.isEmpty else { return }
            var decision: [String: Any] = ["decision": "undo", "finding": row.finding, "machines": undone]
            if let proposal = row.proposal { decision["proposal"] = proposal }
            decide(decision)
            notify("Undone on \(undone.joined(separator: ", "))")
        }
    }

    // MARK: - Make the same

    /// Copies `source`'s version of the file to every other machine that
    /// answered and has another version or none. Files in git and Nix
    /// links are left to an agent.
    func makeSame(_ drift: MetaRun.Drift, as source: String) {
        syncs[drift.id] = .writing
        log("Findings: make \(drift.id) the same as on \(source)")
        Task {
            let hosts = hosts()
            do {
                guard let sourceHost = hosts[source] else { throw SyncError(text: "\(source) is offline") }
                guard let file = try await sourceHost.agentConfig().first(where: { $0.id == drift.id }) else {
                    throw SyncError(text: "\(source) does not have it any more")
                }
                guard !file.git, file.link == nil else { throw SyncError(text: "in git or made by Nix: change it through an agent") }
                guard let content = file.content else { throw SyncError(text: "too big to copy") }
                var errors: [String] = []
                for machine in drift.machines.keys.sorted() where machine != source {
                    guard let host = hosts[machine] else {
                        errors.append("\(machine): offline")
                        continue
                    }
                    do {
                        let files = try await host.agentConfig()
                        let existing = files.first { $0.id == drift.id }
                        if existing?.sha256 == file.sha256 { continue }
                        if existing?.git == true || existing?.link != nil {
                            errors.append("\(machine): in git or made by Nix")
                            continue
                        }
                        guard let path = existing?.path ?? Self.path(of: drift.id, on: files) else {
                            errors.append("\(machine): its home folder is not known")
                            continue
                        }
                        _ = try await host.configWrite(path: path, base: existing?.sha256 ?? "", content: content)
                    } catch {
                        errors.append("\(machine): \(Logbook.describe(error))")
                    }
                }
                syncs[drift.id] = errors.isEmpty ? .applied(backup: "") : .failed(errors.joined(separator: "; "))
            } catch {
                syncs[drift.id] = .failed((error as? SyncError)?.text ?? Logbook.describe(error))
            }
        }
    }

    private struct SyncError: Error {
        var text: String
    }

    /// A file id's path on a machine that does not have the file: "<home>"
    /// is that machine's folder, as another of its files shows it.
    nonisolated static func path(of id: String, on files: [AgentFile]) -> String? {
        guard let marker = id.range(of: "<home>") else { return id }
        for file in files {
            guard let at = file.id.range(of: "<home>") else { continue }
            let prefix = file.id[..<at.lowerBound], rest = file.id[at.upperBound...]
            guard file.path.hasPrefix(prefix), file.path.hasSuffix(rest), file.path.count >= prefix.count + rest.count else { continue }
            let home = file.path.dropFirst(prefix.count).dropLast(rest.count)
            return id.replacingCharacters(in: marker, with: home)
        }
        return nil
    }

    private func decide(_ decision: [String: Any]) {
        guard let run else { return }
        Task { await decide(decision, run: run.id) }
    }

    /// `run`: the run the decision is about (a newer one may have loaded since).
    @discardableResult private func decide(_ decision: [String: Any], run: String) async -> Bool {
        guard let host = archive() else { return false }
        var decision = decision
        decision["run"] = run
        let data = (try? JSONSerialization.data(withJSONObject: decision, options: [.sortedKeys])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        log("Findings: decision \(json)")
        do {
            try await host.metaDecision(json)
            return true
        } catch {
            notify("Decision not saved: \(Logbook.describe(error))")
            return false
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
                if let run = findings.run, !run.followup.isEmpty {
                    LogbookAppliedSection(rows: run.followup, findings: findings)
                }
                if let run = findings.run, !run.drift.isEmpty {
                    LogbookDriftSection(drift: run.drift, findings: findings)
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
            // etd moves a machine that has the change from `targets` to `applied`.
            let applied = Set(proposal.applied)
                .union(findings.appliedOn(finding: finding.id, proposal: proposal.id))
                .union(proposal.targets.filter { isApplied($0, proposal) }.map(\.machine))
                .sorted()
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
        if findings.appliedOn(finding: finding.id, proposal: proposal.id).contains(target.machine) { return true }
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

/// Applied changes: what changed, where, the friction before and
/// after, and Undo.
struct LogbookAppliedSection: View {
    let rows: [MetaRun.Followup]
    let findings: LogbookFindings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applied").font(.headline).padding(.top, 6)
            ForEach(rows.sorted { $0.applied > $1.applied }) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title).font(.callout.weight(.medium)).strikethrough(row.undone).lineLimit(2)
                        Spacer()
                        undoButton(row)
                    }
                    Text(whereText(row)).font(.caption).foregroundStyle(.secondary)
                    if !row.undone { Text(effect(row)).font(.caption).foregroundStyle(row.after < row.before ? Color.green : Color.secondary) }
                    if case .failed(let error) = findings.undos[row.id] {
                        Text("Undo failed: \(error)").font(.caption).foregroundStyle(.red).lineLimit(3)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder private func undoButton(_ row: MetaRun.Followup) -> some View {
        if row.undone || findings.undos[row.id] == .applied(backup: "") {
            Text("Undone").font(.caption).foregroundStyle(.secondary)
        } else if findings.undos[row.id] == .writing {
            ProgressView().controlSize(.mini)
        } else if !findings.undoTargets(row).isEmpty {
            Button("Undo") { findings.undo(row) }.controlSize(.small)
                .help("Put the files back as they were before this change")
        }
    }

    private func whereText(_ row: MetaRun.Followup) -> String {
        let machines = row.machines.isEmpty ? "all machines" : row.machines.joined(separator: ", ")
        return "\(row.appliedDate.formatted(.relative(presentation: .named))) on \(machines)"
    }

    /// "Interrupted, Tool denied: 6 → 1 in the 7 days before and after".
    private func effect(_ row: MetaRun.Followup) -> String {
        let kinds = row.kinds.map { LogbookSignalKind($0).name }.joined(separator: ", ")
        let days = max(1, Int((row.span / 86400).rounded()))
        let window = days == 1 ? "the day" : "the \(days) days"
        return "\(kinds.isEmpty ? "Friction" : kinds): \(row.before) → \(row.after) in \(window) before and after"
    }
}

/// Agent files that differ between machines: folded, by kind; a file
/// can be made the same as on one machine.
struct LogbookDriftSection: View {
    let drift: [MetaRun.Drift]
    let findings: LogbookFindings
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Each machine has its own instruction and memory files. Pick a file to copy one machine's version to the others.")
                    .font(.caption).foregroundStyle(.secondary)
                let byKind = Dictionary(grouping: drift, by: \.kind).sorted { $0.key < $1.key }
                ForEach(byKind, id: \.key) { kind, files in
                    DisclosureGroup {
                        ForEach(files.sorted { $0.id < $1.id }) { file in row(file) }
                    } label: {
                        Text("\(kind.capitalized) · \(files.count)").font(.callout)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("\(drift.count) agent file\(drift.count == 1 ? "" : "s") differ between machines").font(.headline)
        }
        .padding(.top, 6)
    }

    private func row(_ file: MetaRun.Drift) -> some View {
        let groups = versions(file)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(file.id.replacingOccurrences(of: "~/.claude/", with: "")).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch findings.syncs[file.id] {
                case .writing: ProgressView().controlSize(.mini)
                case .applied: Text("Same now").font(.caption).foregroundStyle(.green)
                default:
                    Menu("Make the same as…") {
                        ForEach(file.machines.keys.sorted().filter { file.machines[$0] != nil }, id: \.self) { machine in
                            Button(machine) { findings.makeSame(file, as: machine) }
                        }
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .font(.caption)
                }
            }
            Text(groups).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if case .failed(let error) = findings.syncs[file.id] {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    /// "trigkey, gmktec same · MacBook other · mac-mini missing".
    private func versions(_ file: MetaRun.Drift) -> String {
        var bySha: [String: [String]] = [:]
        var missing: [String] = []
        for (machine, sha) in file.machines {
            if let sha { bySha[sha, default: []].append(machine) } else { missing.append(machine) }
        }
        var parts = bySha.values.map { $0.sorted() }.sorted { $0.count > $1.count }.enumerated().map { i, machines in
            machines.joined(separator: ", ") + (i == 0 ? (machines.count > 1 ? " same" : "") : " other")
        }
        if !missing.isEmpty { parts.append(missing.sorted().joined(separator: ", ") + " missing") }
        return parts.joined(separator: " · ")
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
