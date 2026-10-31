import SwiftUI

// The Findings place (PLAN-logbook-v2 B6): the meta agent's findings, each
// with evidence (links into transcripts) and proposed changes to the
// agents' instruction files. Nothing changes without the owner (D8).

/// The last meta run, a Run in progress, and what the owner did with it.
@MainActor @Observable
final class LogbookFindings {
    private(set) var run: MetaRun?
    /// A Run in progress (the report's progress frames).
    private(set) var running: Logbook.ReportRun?
    private(set) var error: String?
    private(set) var loaded = false
    /// etd answers "not built yet" (before A4): `run` is the sample.
    private(set) var isSample = false
    /// Findings and proposals the owner rejected in this run.
    private(set) var rejected: Set<String> = []
    /// Per target ("proposal|machine|path"): writing, applied or failed.
    private(set) var writes: [String: WriteState] = [:]
    /// The owner's edit of a target's new content, by target key.
    var edited: [String: String] = [:]

    enum WriteState: Equatable {
        case writing
        case applied(backup: String)
        case failed(String)
    }

    @ObservationIgnored private let archive: @MainActor () -> IrohHost?
    @ObservationIgnored private let hosts: @MainActor () -> [String: IrohHost]
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private let notify: @MainActor (String) -> Void
    @ObservationIgnored private let signals: @MainActor () -> [LogbookSignal]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(archive: @escaping @MainActor () -> IrohHost?, hosts: @escaping @MainActor () -> [String: IrohHost],
         log: @escaping @MainActor (String) -> Void, notify: @escaping @MainActor (String) -> Void,
         signals: @escaping @MainActor () -> [LogbookSignal]) {
        self.archive = archive
        self.hosts = hosts
        self.log = log
        self.notify = notify
        self.signals = signals
    }

    /// Findings the owner has not rejected.
    var shown: [MetaRun.Finding] {
        (run?.findings ?? []).filter { !rejected.contains($0.id) }
    }

    static func targetKey(_ proposal: MetaRun.Proposal, _ target: MetaRun.Target) -> String {
        proposal.id + "|" + target.machine + "|" + target.path
    }

    /// The last run, without making a new one.
    func load() async {
        guard !loaded, let host = archive() else { return }
        do {
            set(try MetaRun.decode(try await host.meta(refresh: false) { _, _, _ in }), sample: false)
        } catch {
            fallBack(error)
        }
        loaded = true
        log("Findings: \(run?.findings.count ?? 0) findings\(isSample ? " (sample)" : "")\(error.map { ", " + $0 } ?? "")")
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
                set(try MetaRun.decode(json), sample: false)
            } catch {
                log("Findings: run failed: \(error)")
                fallBack(error)
            }
        }
    }

    private func set(_ run: MetaRun, sample: Bool) {
        if run.id != self.run?.id {
            rejected = []
            writes = [:]
            edited = [:]
        }
        self.run = run.id.isEmpty ? nil : run
        isSample = sample
        error = nil
    }

    /// STUB until A4: an etd that answers "not built yet" gets the sample
    /// made from the real signals, so evidence links can be tried.
    private func fallBack(_ error: any Error) {
        let text = Logbook.describe(error)
        if text.contains("not built yet"), let sample = try? MetaRun.decode(LogbookFindings.sample(signals(), machines: hosts().keys.sorted())) {
            set(sample, sample: true)
        } else {
            self.error = text
        }
    }

    // MARK: - Decisions

    func reject(_ finding: MetaRun.Finding) {
        rejected.insert(finding.id)
        decide(["decision": "reject", "finding": finding.id])
    }

    func reject(_ proposal: MetaRun.Proposal, in finding: MetaRun.Finding) {
        rejected.insert(proposal.id)
        decide(["decision": "reject", "finding": finding.id, "proposal": proposal.id])
    }

    /// Writes each target's new content on its machine (only where it is
    /// not applied yet), then tells the archive what was applied.
    func apply(_ proposal: MetaRun.Proposal, in finding: MetaRun.Finding) {
        let targets = proposal.targets.filter {
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
            var decision: [String: Any] = ["decision": edited.isEmpty ? "accept" : "edit", "finding": finding.id, "proposal": proposal.id,
                                           "applied": applied.map(\.machine)]
            let edits = proposal.targets.compactMap { t in edited[Self.targetKey(proposal, t)].map { (t.machine, $0) } }
            if !edits.isEmpty { decision["content"] = Dictionary(edits, uniquingKeysWith: { a, _ in a }) }
            decide(decision)
            notify(applied.count == proposal.targets.count ? "Applied on \(applied.map(\.machine).joined(separator: ", "))"
                                                           : "Applied on \(applied.count) of \(proposal.targets.count) machines")
        }
    }

    func retry(_ target: MetaRun.Target, of proposal: MetaRun.Proposal) {
        Task { await write(target, of: proposal) }
    }

    private func write(_ target: MetaRun.Target, of proposal: MetaRun.Proposal) async {
        let key = Self.targetKey(proposal, target)
        guard let content = edited[key] ?? target.content else {
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
            writes[key] = .failed(Logbook.describe(error))
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
                // The sample's decisions have nowhere to go before A4.
                if !isSample { notify("Decision not saved: \(Logbook.describe(error))") }
            }
        }
    }

    // MARK: - Sample (STUB until A4)

    /// Findings JSON in the §4.3 shape from the real signals: one finding
    /// per signal kind, with a `write`, an `agent` and a `note` proposal.
    /// Each `base` is a value no file has, so an Apply is always refused.
    static func sample(_ signals: [LogbookSignal], machines: [String]) -> String {
        let texts: [String: (String, String)] = [
            "interrupt": ("Claude keeps going after it should stop and ask", "- Before a long or risky step, say what you will do in one line and wait."),
            "denied": ("Claude runs tools the owner then denies", "- Do not run a command that changes another machine without asking first."),
            "tool-error": ("The same kind of tool call fails again and again", "- After a tool error, read the error and change the call; never repeat it unchanged."),
            "compact": ("Long sessions run out of context", "- Keep tool output short: use head, tail and grep instead of printing whole files."),
        ]
        let byKind = Dictionary(grouping: signals, by: \.kind).sorted { $0.value.count > $1.value.count }
        var findings: [[String: Any]] = []
        for (kind, list) in byKind.prefix(3) {
            let (title, line) = texts[kind] ?? ("Friction: \(kind)", "- (sample rule for \(kind))")
            let targets: [[String: Any]] = machines.map {
                ["machine": $0, "path": "~/.claude/CLAUDE.md", "base": "sample-base-matches-no-file",
                 "content": "# (sample: E.T. writes this only if the base matches, and no file has this base)\n" + line + "\n"]
            }
            let patch = "--- a/~/.claude/CLAUDE.md\n+++ b/~/.claude/CLAUDE.md\n@@ -1,3 +1,4 @@\n # Rules\n \n-(old line)\n+(old line)\n+" + line.dropFirst(2) + "\n"
            findings.append([
                "id": "sample-\(kind)", "title": title, "kind": kind, "count": list.count, "sessions": Set(list.map(\.key)).count,
                "evidence": list.suffix(6).reversed().map { ["key": $0.key, "turn": $0.turn, "excerpt": $0.excerpt] },
                "proposals": [
                    ["id": "sample-\(kind)-write", "route": "write", "targets": targets, "patch": patch,
                     "why": "\(list.count) \(kind) signals in \(Set(list.map(\.key)).count) sessions.",
                     "expect": "\(kind) drops in new sessions"],
                    ["id": "sample-\(kind)-agent", "route": "agent",
                     "targets": [["machine": machines.first ?? "trigkey", "path": "~/.claude/skills/example/SKILL.md", "base": "sample"]],
                     "patch": "--- a/SKILL.md\n+++ b/SKILL.md\n@@ -1 +1,2 @@\n # Example\n+" + line.dropFirst(2) + "\n",
                     "why": "The skills repo is in git: an agent commits and pushes the change (D8).", "expect": ""],
                    ["id": "sample-\(kind)-note", "route": "note", "targets": [], "patch": "",
                     "why": "Add `Bash(cargo test:*)` to the allow list in ~/.claude/settings.json. E.T. never writes settings (D9).", "expect": ""],
                ],
            ])
        }
        let json: [String: Any] = ["id": "sample", "taken": Date().timeIntervalSince1970, "findings": findings]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), as: UTF8.self)
    }
}

// MARK: - Views

/// The Findings place: Run, then a card per finding.
struct LogbookFindingsView: View {
    let logbook: Logbook
    let machines: [MmMachine]
    @State private var sending: LogbookSendTarget?
    @State private var editing: FindingEdit?

    private var findings: LogbookFindings { logbook.findings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if findings.isSample {
                    Label("Sample findings: the meta agent (A4) is not built yet. The evidence links are real signals; Apply is always refused.",
                          systemImage: "flask")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = findings.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if findings.run != nil && findings.shown.isEmpty {
                    ContentUnavailableView("No findings", systemImage: "checkmark.seal",
                                           description: Text("Nothing went wrong often enough to change the agents' instructions."))
                } else if findings.run == nil && findings.loaded && findings.running == nil && findings.error == nil {
                    ContentUnavailableView("No run yet", systemImage: "flag",
                                           description: Text("Run reads every machine's transcripts and proposes changes to the agents' instructions."))
                }
                ForEach(findings.shown) { finding in
                    FindingCard(finding: finding, logbook: logbook,
                                send: { sending = LogbookSendTarget(selection: .finding(runId: findings.run?.id ?? "", findingId: finding.id),
                                                                    title: "the finding “\(finding.title)”") },
                                edit: { editing = FindingEdit(finding: finding, proposal: $0) })
                }
            }
            .padding(14)
        }
        .navigationTitle("Findings")
        .task { await findings.load() }
        .sheet(item: $sending) { LogbookSendSheet(target: $0, machines: machines, logbook: logbook) }
        .sheet(item: $editing) { FindingEditSheet(edit: $0, findings: findings) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Findings").font(.title2.weight(.semibold))
                if let run = findings.run, !findings.isSample {
                    Text("Run \(run.takenDate.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
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
                .help("Read every transcript's friction and propose changes (minutes; uses the subscription)")
        }
    }
}

/// A finding: what goes wrong, where (evidence), and the proposals.
struct FindingCard: View {
    let finding: MetaRun.Finding
    let logbook: Logbook
    let send: () -> Void
    let edit: (MetaRun.Proposal) -> Void
    @State private var allEvidence = false

    var body: some View {
        let kind = LogbookSignalKind(finding.kind)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: kind.symbol).foregroundStyle(kind.color)
                Text(finding.title).font(.headline)
                Spacer()
                Menu {
                    Button("Send to Agent…", systemImage: "paperplane", action: send)
                    Button("Reject Finding", systemImage: "xmark", role: .destructive) { logbook.findings.reject(finding) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text("\(finding.count) time\(finding.count == 1 ? "" : "s") in \(finding.sessions) session\(finding.sessions == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if !finding.evidence.isEmpty { evidence }
            ForEach(finding.proposals.filter { !logbook.findings.rejected.contains($0.id) }) { proposal in
                ProposalView(proposal: proposal, finding: finding, findings: logbook.findings, send: send) { edit(proposal) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private var evidence: some View {
        let shown = allEvidence ? finding.evidence : Array(finding.evidence.prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Evidence").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(shown, id: \.self) { item in
                Button { open(item) } label: {
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
            if finding.evidence.count > 3 {
                Button(allEvidence ? "Fewer" : "All \(finding.evidence.count)") { allEvidence.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
    }

    /// The transcript beside the findings, scrolled to the turn.
    private func open(_ item: MetaRun.Evidence) {
        guard let key = LogbookKey(id: item.key) else { return }
        logbook.pendingTurn = LogbookTurnRef(key: key, turn: item.turn)
        logbook.selected = key
    }
}

/// One proposed change: targets with their state, the diff, why, and the
/// buttons its route allows (D8, D9).
struct ProposalView: View {
    let proposal: MetaRun.Proposal
    let finding: MetaRun.Finding
    let findings: LogbookFindings
    let send: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(routeName).font(.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            if !proposal.targets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(proposal.targets, id: \.self) { target in targetChip(target) }
                    }
                }
            }
            if !proposal.patch.isEmpty { DiffView(patch: proposal.patch) }
            if !proposal.why.isEmpty { Text(proposal.why).font(.callout) }
            if !proposal.expect.isEmpty {
                Text("Expect: \(proposal.expect)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                switch proposal.route {
                case "write":
                    Button("Apply on All Machines") { findings.apply(proposal, in: finding) }
                        .buttonStyle(.borderedProminent)
                        .disabled(proposal.targets.allSatisfy { state($0) == .writing || isApplied($0) })
                    Button("Edit…", action: edit)
                case "agent":
                    Button("Send to Agent…", action: send).buttonStyle(.borderedProminent)
                default:
                    Text("Change this by hand: E.T. never writes settings, hooks or keys.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Reject") { findings.reject(proposal, in: finding) }
            }
            .controlSize(.small)
            ForEach(proposal.targets.filter(isFailed), id: \.self) { target in
                if case .failed(let error) = state(target) {
                    HStack(spacing: 6) {
                        Text("Not applied on \(target.machine): \(error)").font(.caption).foregroundStyle(.red).lineLimit(2)
                        Button("Retry") { findings.retry(target, of: proposal) }.controlSize(.mini)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var routeName: String {
        switch proposal.route {
        case "write": "Direct write"
        case "agent": "Via an agent (git)"
        default: "Note"
        }
    }

    private func state(_ target: MetaRun.Target) -> LogbookFindings.WriteState? {
        findings.writes[LogbookFindings.targetKey(proposal, target)]
    }

    private func isApplied(_ target: MetaRun.Target) -> Bool {
        if case .applied = state(target) { return true }
        return false
    }

    private func isFailed(_ target: MetaRun.Target) -> Bool {
        if case .failed = state(target) { return true }
        return false
    }

    private func targetChip(_ target: MetaRun.Target) -> some View {
        let edited = findings.edited[LogbookFindings.targetKey(proposal, target)] != nil
        return HStack(spacing: 3) {
            switch state(target) {
            case .writing: ProgressView().controlSize(.mini)
            case .applied: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case nil: EmptyView()
            }
            Text(target.machine + (edited ? " (edited)" : "")).lineLimit(1).fixedSize()
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(.quaternary, in: Capsule())
        .help(target.path + (state(target).flatMap { if case .applied(let backup) = $0, !backup.isEmpty { "\nBackup: " + backup } else { nil } } ?? ""))
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

/// The edit sheet's subject.
struct FindingEdit: Identifiable {
    var finding: MetaRun.Finding
    var proposal: MetaRun.Proposal
    var id: String { proposal.id }
}

/// Edit a proposal's new file content, per target machine, before Apply.
struct FindingEditSheet: View {
    let edit: FindingEdit
    let findings: LogbookFindings
    @Environment(\.dismiss) private var dismiss
    @State private var target = 0
    @State private var texts: [String] = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if edit.proposal.targets.count > 1 {
                    Picker("Machine", selection: $target) {
                        ForEach(Array(edit.proposal.targets.enumerated()), id: \.offset) { i, t in Text(t.machine).tag(i) }
                    }
                    .pickerStyle(.segmented)
                }
                if let t = edit.proposal.targets[safe: target] {
                    Text(t.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if texts.indices.contains(target) {
                    TextEditor(text: $texts[target])
                        .font(.caption.monospaced())
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding()
            .navigationTitle("Edit the new file")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        for (i, t) in edit.proposal.targets.enumerated() where texts.indices.contains(i) && texts[i] != (t.content ?? "") {
                            findings.edited[LogbookFindings.targetKey(edit.proposal, t)] = texts[i]
                        }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
        .onAppear {
            texts = edit.proposal.targets.map { findings.edited[LogbookFindings.targetKey(edit.proposal, $0)] ?? $0.content ?? "" }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
