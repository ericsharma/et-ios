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
    /// Why the last Refresh failed.
    private(set) var reportError: String?
    private(set) var loaded = false
    private(set) var error: String?
    /// Sessions with a Do not record change on the way.
    private(set) var pausing: Set<String> = []
    /// The last action's result, for a short notice.
    var notice: String?
    /// Per transcript: headline, asked, said (PLAN-logbook-v2 §4.5), by "machine/sessionId".
    private(set) var overview: [String: LogbookOverviewEntry] = [:]
    /// Friction signals (§4.3) per transcript, oldest first, by "machine/sessionId".
    private(set) var signals: [String: [LogbookSignal]] = [:]
    /// The Logbook window's place and open transcript (one window per app).
    var place: LogbookPlace = .now
    var selected: LogbookKey?
    /// ⌘I: machine, folder, ids of the open transcript.
    var inspector = false

    struct ReportRun: Equatable {
        var stage = "starting"
        var done = 0
        var total = 0
        var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }
    }

    @ObservationIgnored private let archive: @MainActor () -> IrohHost?
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var lastList: UInt64 = 0
    @ObservationIgnored private var lastOverview: UInt64 = 0
    @ObservationIgnored private var overviewFailed = false
    @ObservationIgnored private var lastSignals: UInt64 = 0
    @ObservationIgnored private var signalsFailed = false
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var reportTask: Task<Void, Never>?

    init(archive: @escaping @MainActor () -> IrohHost?, log: @escaping @MainActor (String) -> Void) {
        self.archive = archive
        self.log = log
    }

    // MARK: - Sessions

    /// The session list again every 5 s, while the caller's task runs. A
    /// second caller (the Logbook window beside the main window's sidebar)
    /// returns at once.
    func watch() async {
        guard !watching else { return }
        watching = true
        defer { watching = false }
        if report == nil { await loadReport() }
        while !Task.isCancelled {
            await reload()
            await reloadOverview()
            await reloadSignals()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The overview entries changed since the last call. An etd without
    /// the API leaves `overview` empty: the cards fall back to the title.
    func reloadOverview() async {
        guard let host = archive() else { return }
        let since = lastOverview
        do {
            let started = UInt64(Date().timeIntervalSince1970)
            let entries = try await host.logbookOverview(since: since)
            lastOverview = started
            if since == 0 { log("Logbook: overview: \(entries.count) entries") }
            var merged = overview
            for entry in entries { merged[entry.key] = entry }
            if merged != overview { overview = merged }
        } catch {
            if !overviewFailed { log("Logbook: overview: \(Self.describe(error))") }
            overviewFailed = true
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

    /// The signals of the transcripts changed since the last call; each
    /// one's list replaces the old one. Empty until etd has A2.
    func reloadSignals() async {
        guard let host = archive() else { return }
        let since = lastSignals
        do {
            let started = UInt64(Date().timeIntervalSince1970)
            let found = try await host.logbookSignals(since: since)
            lastSignals = started
            if since == 0 { log("Logbook: signals: " + Dictionary(grouping: found, by: \.key).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")) }
            var merged = signals
            for (key, list) in Dictionary(grouping: found, by: \.key) { merged[key] = list.sorted { $0.time < $1.time } }
            if merged != signals { signals = merged }
        } catch {
            if !signalsFailed { log("Logbook: signals: \(Self.describe(error))") }
            signalsFailed = true
        }
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
            let last = try LogbookReport.decode(try await host.logbookReport(refresh: false) { _, _, _ in })
            // "id": null = no report yet.
            report = last.id.isEmpty ? nil : last
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
        reportError = nil
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
                reportError = Self.describe(error)
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
            // etd drops a project with no sessions left.
            report.projects.removeAll { $0.sessions.isEmpty && $0.id != project }
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

/// One transcript, followed live: lines from the archive, parsed into turns.
@MainActor @Observable
final class LogbookTranscript {
    let key: LogbookKey
    private(set) var turns: [Transcript.Turn] = []
    private(set) var loading = true
    private(set) var error: String?
    /// The loaded part starts here; earlier turns load on request, 3 MB at a time.
    private(set) var startOffset: UInt64 = 0
    /// "Load earlier" is running; the shown turns stay until it is done.
    private(set) var loadingEarlier = false

    /// Bytes a view loads first, and per "Load earlier" (sessions reach 75 MB+).
    static let tail: UInt64 = 3 * 1024 * 1024

    @ObservationIgnored private let archive: @MainActor () -> IrohHost?
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var lines: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var feed: LogbookFeed?
    @ObservationIgnored private var parsing = false
    @ObservationIgnored private var dirty = false
    /// The stored part is all read (a chunk said `live`).
    @ObservationIgnored private var caughtUp = false

    init(key: LogbookKey, archive: @escaping @MainActor () -> IrohHost?, log: @escaping @MainActor (String) -> Void) {
        self.key = key
        self.archive = archive
        self.log = log
    }

    var isPartial: Bool { startOffset > 0 }

    /// Follows from the last `tail` bytes of a `size`-byte transcript.
    func start(size: UInt64) {
        follow(from: size > Self.tail ? size - Self.tail : 0, keep: false)
    }

    /// 3 MB more before the loaded part.
    func loadEarlier() {
        guard startOffset > 0, !loadingEarlier else { return }
        follow(from: earlier, keep: true)
    }

    func stop() {
        task?.cancel()
        task = nil
        feed?.close()
        feed = nil
    }

    private var earlier: UInt64 { startOffset > Self.tail ? startOffset - Self.tail : 0 }

    /// `keep`: show the current turns until the new follow has read its
    /// stored part (no jump back to a half-loaded list).
    private func follow(from offset: UInt64, keep: Bool) {
        stop()
        startOffset = offset
        lines = []
        caughtUp = false
        loadingEarlier = keep
        if !keep {
            turns = []
            loading = true
        }
        error = nil
        log("Logbook: follow \(key.id) from \(offset)")
        task = Task {
            guard let host = archive() else {
                error = "No archive machine connected"
                loading = false
                loadingEarlier = false
                return
            }
            do {
                let feed = try await host.logbookFollow(key, from: offset)
                guard !Task.isCancelled else {
                    feed.close()
                    return
                }
                self.feed = feed
                while !Task.isCancelled {
                    let chunk = try await feed.next()
                    guard !Task.isCancelled else { return }
                    // The archive starts at the next whole line: its offset is the real start.
                    if lines.isEmpty, chunk.lines.first != nil, chunk.offset >= startOffset {
                        startOffset = chunk.offset - UInt64(chunk.lines.reduce(0) { $0 + $1.utf8.count + 1 })
                    }
                    // Claude's summary after /compact is not a prompt the owner typed.
                    lines += chunk.lines.filter { !$0.contains(#""isCompactSummary":true"#) }
                    if chunk.live { caughtUp = true }
                    if !chunk.lines.isEmpty || chunk.live { reparse() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = Logbook.describe(error)
                log("Logbook: follow \(key.id) failed: \(error)")
                loading = false
                loadingEarlier = false
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
        let leading = startOffset > 0
        Task {
            let parsed = await Task.detached(priority: .userInitiated) { Transcript.parse(lines: snapshot, leading: leading) }.value
            parsing = false
            if dirty {
                dirty = false
                reparse()
                return
            }
            // Load earlier: keep the old turns until the stored part is read.
            if loadingEarlier && !caughtUp { return }
            // A loaded part without a prompt (large tool output, such as
            // images): start 3 MB earlier.
            if caughtUp, startOffset > 0, !parsed.contains(where: { $0.id != Transcript.leadingTurnID }) {
                log("Logbook: \(key.id): no prompt after \(startOffset), loading 3 MB more")
                follow(from: earlier, keep: loadingEarlier)
                return
            }
            if loading || loadingEarlier { log("Logbook: \(key.id): \(snapshot.count) lines, \(parsed.count) turns from \(startOffset)") }
            turns = parsed
            loading = false
            loadingEarlier = false
        }
    }
}
