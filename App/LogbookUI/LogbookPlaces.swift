import Foundation

/// A place in the Logbook window's first column (PLAN-logbook-v2 D3).
enum LogbookPlace: Hashable {
    /// Live sessions of every machine, needs-you first.
    case now
    /// The meta agent's findings (B6).
    case findings
    /// A report project, by id.
    case project(String)
    /// Sessions in no project (all of them before the first report).
    case unsorted
    /// Every session, newest first, with search.
    case archive
}

extension Logbook {
    func entry(_ session: LogbookSession) -> LogbookOverviewEntry? {
        overview[session.id]
    }

    /// The overview's headline (digest, title or first prompt), else Claude's title.
    func headline(_ session: LogbookSession) -> String {
        entry(session)?.headline ?? session.title ?? session.label
    }

    /// "needs-you" comes from the overview (M3); busy / idle / gone from the
    /// session list, which is newer.
    func state(_ session: LogbookSession) -> String {
        entry(session)?.state == "needs-you" && session.isLive ? "needs-you" : session.status
    }

    /// Signal counts by kind (the overview's, A2).
    func friction(_ session: LogbookSession) -> [String: Int] {
        entry(session)?.friction ?? [:]
    }

    func isTrivial(_ session: LogbookSession) -> Bool {
        entry(session)?.trivial ?? false
    }

    /// D5: shown outside the Archive. Live, or active in the last 7 days,
    /// and not trivial.
    func isShown(_ session: LogbookSession) -> Bool {
        guard !isTrivial(session) || session.isLive else { return false }
        return session.isLive || session.last > Date().addingTimeInterval(-7 * 86400)
    }

    func project(of session: LogbookSession) -> LogbookReport.Project? {
        report?.projects.first { $0.sessions.contains { $0.key == session.id } }
    }

    func project(id: String) -> LogbookReport.Project? {
        report?.projects.first { $0.id == id }
    }

    /// The cards of a place, in order.
    func cards(_ place: LogbookPlace, search: String = "") -> [LogbookSession] {
        switch place {
        case .now:
            return sessions.filter(\.isLive).sorted { a, b in
                let (ra, rb) = (Self.rank(state(a)), Self.rank(state(b)))
                return ra != rb ? ra < rb : a.last > b.last
            }
        case .project(let id):
            guard let project = project(id: id) else { return [] }
            return project.sessions.compactMap { session(id: $0.key) }.filter(isShown).sorted(by: Self.liveThenNewest)
        case .unsorted:
            let placed = Set(report?.projects.flatMap { $0.sessions.map(\.key) } ?? [])
            return sessions.filter { !placed.contains($0.id) && isShown($0) }.sorted(by: Self.liveThenNewest)
        case .archive:
            let words = search.lowercased().split(separator: " ")
            guard !words.isEmpty else { return sessions }
            return sessions.filter { session in
                let entry = entry(session)
                let text = [headline(session), entry?.asked, entry?.said, session.title, session.key.machine]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
        case .findings:
            return []
        }
    }

    /// A project's sessions that the default filter hides (they are in the Archive).
    func hiddenCount(_ project: LogbookReport.Project) -> Int {
        project.sessions.compactMap { session(id: $0.key) }.filter { !isShown($0) }.count
    }

    /// ● busy / needs you, ○ live, ◌ blocked, nothing otherwise.
    func projectState(_ project: LogbookReport.Project) -> String {
        let members = project.sessions.compactMap { session(id: $0.key) }
        if members.contains(where: { ["busy", "needs-you"].contains(state($0)) }) { return "busy" }
        if members.contains(where: \.isLive) { return "idle" }
        return project.status == "blocked" ? "blocked" : "gone"
    }

    func count(_ place: LogbookPlace) -> Int {
        switch place {
        case .findings: findings.shown.count
        case .archive: sessions.count
        default: cards(place).count
        }
    }

    /// Opens a transcript in the Logbook window, in the place that has it.
    func open(_ key: LogbookKey) {
        selected = key
        guard let session = session(key) else { return }
        if session.isLive {
            place = .now
        } else if let project = project(of: session), isShown(session) {
            place = .project(project.id)
        } else {
            place = isShown(session) ? .unsorted : .archive
        }
    }

    private static func rank(_ state: String) -> Int {
        switch state {
        case "needs-you": 0
        case "busy": 1
        case "idle": 2
        default: 3
        }
    }

    private static func liveThenNewest(_ a: LogbookSession, _ b: LogbookSession) -> Bool {
        if a.isLive != b.isLive { return a.isLive }
        return a.last > b.last
    }
}
