import ETCore
import ETSSH
import Foundation
import Observation

/// The Logbook (PLAN-logbook §4.6), for the Mac sidebar and the iOS
/// Logbook screen: every recorded Claude session, the watcher's report,
/// and its grouping. It asks the archive machine only.
@MainActor @Observable
final class Logbook {
    private(set) var sessions: [LogbookSession] = []
    private(set) var report: LogbookReport?
    /// A Refresh in progress.
    private(set) var run: ReportRun?
    private(set) var loaded = false
    private(set) var error: String?
    /// Sessions with a Do not record change on the way.
    private(set) var pausing: Set<String> = []
    /// The last action's result, for a short notice.
    var notice: String?

    struct ReportRun: Equatable {
        var stage = "starting"
        var done = 0
        var total = 0
        var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
    }

    @ObservationIgnored private let archive: @MainActor () -> IrohHost?
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var lastList: UInt64 = 0
    @ObservationIgnored private var reportTask: Task<Void, Never>?

    init(archive: @escaping @MainActor () -> IrohHost?, log: @escaping @MainActor (String) -> Void) {
        self.archive = archive
        self.log = log
    }

    // MARK: - Sessions

    /// The session list again every 5 s, while the caller's task runs.
    func watch() async {
        if report == nil { await loadReport() }
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func reload() async {
        guard let host = archive() else {
            error = "No archive machine connected"
            return
        }
        let since = lastList
        do {
            let list = try await host.logbookSessions(since: since)
            lastList = UInt64(Date().timeIntervalSince1970)
            // `since` > 0 lists only the sessions that changed.
            var merged = since == 0 ? [:] : Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, $0) })
            for session in list { merged[session.key] = session }
            let sorted = merged.values.sorted { $0.last > $1.last }
            if sorted != sessions { sessions = sorted }
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
        loaded = true
    }

    func session(_ key: LogbookKey) -> LogbookSession? {
        sessions.first { $0.key == key }
    }

    func session(id: String) -> LogbookSession? {
        sessions.first { $0.id == id }
    }

    /// Sessions to show: live ones, and the ones of the last 7 days.
    var recent: [LogbookSession] {
        let week = Date().addingTimeInterval(-7 * 86400)
        return sessions.filter { $0.isLive || $0.last > week }
    }

    /// The sidebar's groups: the report's projects once there is a report,
    /// else the git repo.
    var groups: [LogbookGroup] {
        let shown = recent
        guard let report else {
            let byRepo = Dictionary(grouping: shown, by: \.repoName)
            return byRepo.map { LogbookGroup(id: "repo:" + $0.key, name: $0.key, sessions: $0.value.sorted(by: Self.liveFirst), project: nil) }
                .sorted { ($0.busy, $0.last) > ($1.busy, $1.last) }
        }
        var placed = Set<String>()
        var groups: [LogbookGroup] = report.projects.map { project in
            let members = project.sessions.compactMap { session(id: $0.key) }
            placed.formUnion(members.map(\.id))
            return LogbookGroup(id: "project:" + project.id, name: project.name, sessions: members.sorted(by: Self.liveFirst), project: project)
        }
        let rest = shown.filter { !placed.contains($0.id) }
        if !rest.isEmpty {
            groups.append(LogbookGroup(id: "unassigned", name: "Not in a project", sessions: rest.sorted(by: Self.liveFirst), project: nil))
        }
        return groups
    }

    private static func liveFirst(_ a: LogbookSession, _ b: LogbookSession) -> Bool {
        if a.isLive != b.isLive { return a.isLive }
        return a.last > b.last
    }

    // MARK: - Do not record

    func setPaused(_ session: LogbookSession, _ paused: Bool) {
        guard let host = archive(), !session.mmSession.isEmpty else {
            notice = "Only sessions that run in manymux can be paused"
            return
        }
        pausing.insert(session.id)
        log("Logbook: \(paused ? "do not record" : "record") \(session.label)")
        Task {
            defer { pausing.remove(session.id) }
            do {
                try await host.logbookPause(machine: session.key.machine, mmSession: session.mmSession, paused: paused)
                // Same mm session = same switch, for every transcript in it.
                for i in sessions.indices where sessions[i].key.machine == session.key.machine && sessions[i].mmSession == session.mmSession {
                    sessions[i].paused = paused
                }
                notice = paused ? "\(session.label) is not recorded" : "\(session.label) is recorded again"
            } catch {
                notice = "Do not record failed: \(Self.describe(error))"
            }
        }
    }

    // MARK: - Report

    /// The last report, without making a new one.
    func loadReport() async {
        guard let host = archive() else { return }
        do {
            report = try LogbookReport.decode(try await host.logbookReport(refresh: false) { _, _, _ in })
        } catch {
            // No report yet: the Refresh button makes the first.
        }
    }

    /// Makes a new report (1–3 min); a second click while it runs does nothing.
    func refreshReport() {
        guard reportTask == nil else { return }
        guard let host = archive() else {
            notice = "No archive machine connected"
            return
        }
        run = ReportRun()
        log("Logbook: refresh report")
        reportTask = Task {
            defer {
                run = nil
                reportTask = nil
            }
            do {
                let json = try await host.logbookReport(refresh: true) { stage, done, total in
                    Task { @MainActor in
                        if self.run != nil { self.run = ReportRun(stage: stage, done: done, total: total) }
                    }
                }
                report = try LogbookReport.decode(json)
                await reload()
            } catch {
                log("Logbook: report failed: \(error)")
                notice = "Report failed: \(Self.describe(error))"
            }
        }
    }

    // MARK: - Grouping (D4)

    func accept(_ proposal: LogbookReport.Proposal) {
        sendGrouping(["decision": "accept", "kind": proposal.kind, "detail": proposal.detail, "why": proposal.why]) {
            $0.proposals.removeAll { $0 == proposal }
        }
    }

    func reject(_ proposal: LogbookReport.Proposal) {
        sendGrouping(["decision": "reject", "kind": proposal.kind, "detail": proposal.detail, "why": proposal.why]) {
            $0.proposals.removeAll { $0 == proposal }
        }
    }

    func rename(project id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        sendGrouping(["decision": "edit", "kind": "rename", "project": id, "name": name]) { report in
            if let i = report.projects.firstIndex(where: { $0.id == id }) { report.projects[i].name = name }
        }
    }

    /// Moves a session to a project (`project` nil: out of every project).
    func move(session key: String, to project: String?) {
        sendGrouping(["decision": "edit", "kind": "move", "key": key, "to": project ?? ""]) { report in
            var role = "Moved here by the owner"
            for i in report.projects.indices {
                if let old = report.projects[i].sessions.first(where: { $0.key == key }) { role = old.role }
                report.projects[i].sessions.removeAll { $0.key == key }
            }
            report.unassigned.removeAll { $0 == key }
            if let project, let i = report.projects.firstIndex(where: { $0.id == project }) {
                report.projects[i].sessions.append(.init(key: key, role: role))
            } else {
                report.unassigned.append(key)
            }
        }
    }

    /// Sends one change; on success, shows it in the report at once (the
    /// next report has it as a fixed choice).
    private func sendGrouping(_ change: [String: String], apply: @escaping (inout LogbookReport) -> Void) {
        guard let host = archive() else {
            notice = "No archive machine connected"
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: change, options: [.sortedKeys])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        log("Logbook: grouping \(json)")
        Task {
            do {
                try await host.logbookGrouping(json)
                if var report {
                    apply(&report)
                    self.report = report
                }
            } catch {
                notice = "Grouping failed: \(Self.describe(error))"
            }
        }
    }

    // MARK: - Send to session (D7)

    func send(_ selection: LogbookSelection, to machine: String, session: String) {
        guard let host = archive() else {
            notice = "No archive machine connected"
            return
        }
        log("Logbook: send \(selection) to \(machine)/\(session)")
        notice = "Sending to \(machine)/\(session)…"
        Task {
            do {
                let sent = try await host.logbookSend(selection, to: machine, session: session)
                notice = sent.typed ? "Typed into \(machine)/\(session)" : "Sent to \(machine): \(sent.paths.joined(separator: " "))"
            } catch {
                notice = "Send failed: \(Self.describe(error))"
            }
        }
    }

    // MARK: - Transcripts

    func transcript(_ key: LogbookKey) -> LogbookTranscript {
        LogbookTranscript(key: key, archive: archive, log: log)
    }

    nonisolated static func describe(_ error: any Error) -> String {
        guard let error = error as? HostError else { return String(describing: error) }
        return switch error {
        case .notPaired: "not paired"
        case .unreachable(let text), .closed(let text), .other(let text): text
        }
    }
}

/// A group in the sidebar: a report project, or a repo before the first report.
struct LogbookGroup: Identifiable {
    var id: String
    var name: String
    var sessions: [LogbookSession]
    var project: LogbookReport.Project?

    var busy: Int { sessions.filter { $0.status == "busy" }.count }
    var live: Int { sessions.filter(\.isLive).count }
    var last: Date { sessions.map(\.last).max() ?? .distantPast }
}

/// One transcript, followed live: lines from the archive, parsed into turns.
@MainActor @Observable
final class LogbookTranscript {
    let key: LogbookKey
    private(set) var turns: [Transcript.Turn] = []
    private(set) var loading = true
    private(set) var error: String?
    /// The view starts this far from the end; earlier turns load on request.
    private(set) var startOffset: UInt64 = 0

    /// Bytes from the end a view loads first (a long session is 5 MB+).
    static let tail: UInt64 = 3 * 1024 * 1024

    @ObservationIgnored private let archive: @MainActor () -> IrohHost?
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var lines: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var parsing = false
    @ObservationIgnored private var dirty = false

    init(key: LogbookKey, archive: @escaping @MainActor () -> IrohHost?, log: @escaping @MainActor (String) -> Void) {
        self.key = key
        self.archive = archive
        self.log = log
    }

    var isPartial: Bool { startOffset > 0 }

    /// Follows from the last `tail` bytes of a `size`-byte transcript.
    func start(size: UInt64) {
        follow(from: size > Self.tail ? size - Self.tail : 0)
    }

    func loadAll() {
        follow(from: 0)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func follow(from offset: UInt64) {
        stop()
        startOffset = offset
        lines = []
        turns = []
        loading = true
        error = nil
        log("Logbook: follow \(key.id) from \(offset)")
        task = Task {
            guard let host = archive() else {
                error = "No archive machine connected"
                loading = false
                return
            }
            do {
                let feed = try await host.logbookFollow(key, from: offset)
                while !Task.isCancelled {
                    let chunk = try await feed.next()
                    guard !Task.isCancelled else { return }
                    lines += chunk.lines
                    reparse()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = Logbook.describe(error)
                log("Logbook: follow \(key.id) failed: \(error)")
                loading = false
            }
        }
    }

    /// Parses off the main actor; chunks that come while it runs are
    /// parsed together after it.
    private func reparse() {
        guard !parsing else {
            dirty = true
            return
        }
        parsing = true
        let snapshot = lines
        Task {
            let parsed = await Task.detached(priority: .userInitiated) { Transcript.parse(lines: snapshot) }.value
            if loading { log("Logbook: \(key.id): \(snapshot.count) lines, \(parsed.count) turns") }
            turns = parsed
            loading = false
            parsing = false
            if dirty {
                dirty = false
                reparse()
            }
        }
    }
}
