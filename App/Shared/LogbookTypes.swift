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

/// One transcript in the Overview (PLAN-logbook-v2 §4.5): what it does,
/// the last thing asked and said. Fields are optional: etd may add some.
struct LogbookOverviewEntry: Decodable, Equatable, Sendable {
    /// "machine/sessionId".
    var key: String
    var agent: String
    var machine: String
    var mm: String
    var headline: String?
    /// "title", "prompt" or "digest".
    var headlineFrom: String?
    var asked: String?
    var said: String?
    /// "busy", "idle", "needs-you" or "gone".
    var state: String
    var prompts: Int
    /// Fewer than 2 prompts: hidden by default (D5).
    var trivial: Bool
    /// Signal kind → count ("interrupt", "denied", "tool-error"); empty until A2.
    var friction: [String: Int]

    enum CodingKeys: String, CodingKey {
        case key, agent, machine, mm, headline, headlineFrom = "headline_from", asked, said, state, prompts, trivial, friction
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        machine = try c.decodeIfPresent(String.self, forKey: .machine) ?? ""
        mm = try c.decodeIfPresent(String.self, forKey: .mm) ?? ""
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        headlineFrom = try c.decodeIfPresent(String.self, forKey: .headlineFrom)
        asked = try c.decodeIfPresent(String.self, forKey: .asked)
        said = try c.decodeIfPresent(String.self, forKey: .said)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "gone"
        prompts = try c.decodeIfPresent(Int.self, forKey: .prompts) ?? 0
        trivial = try c.decodeIfPresent(Bool.self, forKey: .trivial) ?? false
        friction = try c.decodeIfPresent([String: Int].self, forKey: .friction) ?? [:]
    }

    static func decode(_ json: String) throws -> [LogbookOverviewEntry] {
        struct Overview: Decodable { var sessions: [LogbookOverviewEntry]? }
        return try JSONDecoder().decode(Overview.self, from: Data(json.utf8)).sessions ?? []
    }
}

/// A friction signal (PLAN-logbook-v2 §4.3): where the owner interrupted,
/// denied a tool or corrected the agent, or a tool failed.
struct LogbookSignal: Decodable, Equatable, Hashable, Sendable {
    /// "interrupt", "denied", "tool-error", "repeat-error", "correction",
    /// "compact" or "asked-needlessly".
    var kind: String
    /// "machine/sessionId".
    var key: String
    /// The uuid of the prompt that starts the turn (Transcript.Turn.id).
    var turn: String
    /// Unix seconds.
    var time: Double
    var excerpt: String

    init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case kind, key, turn, time, excerpt }
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try c.decode(String.self, forKey: .kind)
        key = try c.decode(String.self, forKey: .key)
        turn = try c.decodeIfPresent(String.self, forKey: .turn) ?? ""
        time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
        excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
    }

    static func decode(_ json: String) throws -> [LogbookSignal] {
        struct Signals: Decodable { var signals: [LogbookSignal]? }
        return try JSONDecoder().decode(Signals.self, from: Data(json.utf8)).signals ?? []
    }
}
