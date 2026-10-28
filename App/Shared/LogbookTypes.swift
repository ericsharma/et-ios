import Foundation

// The Logbook's app types (PLAN-logbook §4.5), so the views don't see EtLink.

/// A Claude transcript: its machine and Claude session id.
struct LogbookKey: Hashable, Sendable, Codable {
    var machine: String
    var sessionId: String

    /// "machine/sessionId", as the report names sessions.
    var id: String { machine + "/" + sessionId }

    init(machine: String, sessionId: String) {
        self.machine = machine
        self.sessionId = sessionId
    }

    init?(id: String) {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        self.init(machine: parts[0], sessionId: parts[1])
    }
}

/// One recorded Claude session (EtLink's `LogEntry`).
struct LogbookSession: Identifiable, Hashable, Sendable {
    var key: LogbookKey
    /// The manymux session on its machine; empty if not known.
    var mmSession: String
    var cwd: String
    /// The git remote URL, else the repo root.
    var repo: String?
    var branch: String?
    /// "busy", "idle" or "gone".
    var status: String
    var first: Date
    var last: Date
    var bytes: UInt64
    var previous: String?
    /// Do not record.
    var paused: Bool
    /// Claude's title for the session.
    var title: String?

    var id: String { key.id }
    var isLive: Bool { status != "gone" }

    /// machine/mm session, or machine/folder and a short id for a session
    /// that is gone.
    var label: String {
        guard mmSession.isEmpty else { return key.machine + "/" + mmSession }
        return key.machine + "/" + (cwd as NSString).lastPathComponent + " " + key.sessionId.prefix(8)
    }

    /// The repo's short name (`et-ios` from `git@github.com:x/et-ios.git`),
    /// else the folder.
    var repoName: String {
        guard let repo else { return cwd.isEmpty ? "No folder" : Self.tilde(cwd) }
        var name = (repo as NSString).lastPathComponent
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? repo : name
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// What "Send to session…" sends.
enum LogbookSelection: Sendable, Equatable {
    /// Turns of one transcript, by prompt uuid.
    case turns(LogbookKey, [String])
    case reportSection(reportId: String, projectId: String)
}

/// The watcher's report (PLAN-logbook §4.4).
struct LogbookReport: Codable, Equatable, Sendable {
    var id: String
    /// Unix seconds.
    var taken: Double
    var projects: [Project]
    var unassigned: [String]
    var proposals: [Proposal]

    struct Project: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var goal: String
        /// "active", "blocked" or "done".
        var status: String
        var sessions: [Member]
        var progress: String
        var next: [String]
    }

    struct Member: Codable, Equatable, Sendable {
        /// "machine/sessionId".
        var key: String
        var role: String
    }

    struct Proposal: Codable, Equatable, Sendable, Hashable {
        /// "merge", "split", "move" or "rename".
        var kind: String
        var detail: String
        var why: String
    }

    var takenDate: Date { Date(timeIntervalSince1970: taken) }

    static func decode(_ json: String) throws -> LogbookReport {
        try JSONDecoder().decode(LogbookReport.self, from: Data(json.utf8))
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // "id": null = no report yet.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        taken = try c.decodeIfPresent(Double.self, forKey: .taken) ?? Date().timeIntervalSince1970
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        unassigned = try c.decodeIfPresent([String].self, forKey: .unassigned) ?? []
        proposals = try c.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
    }
}
