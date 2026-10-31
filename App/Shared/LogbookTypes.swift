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
    /// A meta finding and its proposals, for an agent to carry out (D8).
    case finding(runId: String, findingId: String)
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
        /// What the project is for, in plain words.
        var goal: String
        /// "active", "blocked" or "done".
        var status: String
        var sessions: [Member]
        /// 2 or 3 sentences (before `done` and `now`).
        var progress: String
        /// What works now, a plain bullet each (owner, 2026-10-31).
        var done: [String]
        /// Where things stand, 1 or 2 plain sentences.
        var now: String
        var next: [String]

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "active"
            sessions = try c.decodeIfPresent([Member].self, forKey: .sessions) ?? []
            progress = try c.decodeIfPresent(String.self, forKey: .progress) ?? ""
            done = try c.decodeIfPresent([String].self, forKey: .done) ?? []
            now = try c.decodeIfPresent(String.self, forKey: .now) ?? ""
            next = try c.decodeIfPresent([String].self, forKey: .next) ?? []
        }
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

/// The meta agent's answer (PLAN-logbook-v2 §4.3): findings with evidence
/// and proposed changes to the agents' instruction files.
struct MetaRun: Decodable, Equatable, Sendable {
    var id: String
    /// Unix seconds.
    var taken: Double
    var findings: [Finding]
    /// Applied proposals, with the friction before and after (A5).
    var followup: [Followup]
    /// Agent files that differ between the machines that answered (A3).
    var drift: [Drift]

    struct Followup: Decodable, Equatable, Sendable, Identifiable {
        var finding: String
        var proposal: String?
        var title: String
        /// Unix seconds: when it was first applied.
        var applied: Double
        /// Empty: all machines.
        var machines: [String]
        /// The finding's signal kinds that are counted.
        var kinds: [String]
        /// Seconds in each window, before and after.
        var span: Double
        var before: Int
        var after: Int
        var undone: Bool

        var id: String { finding + "/" + (proposal ?? "") }
        var appliedDate: Date { Date(timeIntervalSince1970: applied) }

        init(from decoder: any Decoder) throws {
            enum Keys: String, CodingKey { case finding, proposal, title, applied, machines, kinds, span, before, after, undone }
            let c = try decoder.container(keyedBy: Keys.self)
            finding = try c.decode(String.self, forKey: .finding)
            proposal = try c.decodeIfPresent(String.self, forKey: .proposal)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? finding
            applied = try c.decodeIfPresent(Double.self, forKey: .applied) ?? 0
            machines = try c.decodeIfPresent([String].self, forKey: .machines) ?? []
            kinds = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
            span = try c.decodeIfPresent(Double.self, forKey: .span) ?? 0
            before = try c.decodeIfPresent(Int.self, forKey: .before) ?? 0
            after = try c.decodeIfPresent(Int.self, forKey: .after) ?? 0
            undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
        }
    }

    struct Drift: Decodable, Equatable, Sendable, Identifiable {
        /// The same file on every machine ("<home>" for the home folder's project).
        var id: String
        /// "instructions", "import", "memory" or "skill".
        var kind: String
        /// Machine → sha256; nil: that machine does not have it.
        var machines: [String: String?]
    }

    struct Finding: Decodable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        /// A §4.3 signal kind, or "drift".
        var kind: String
        var count: Int
        var sessions: Int
        var evidence: [Evidence]
        var proposals: [Proposal]

        init(from decoder: any Decoder) throws {
            enum Keys: String, CodingKey { case id, title, kind, count, sessions, evidence, proposals }
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
            sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
            evidence = try c.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
            proposals = try c.decodeIfPresent([Proposal].self, forKey: .proposals) ?? []
            for i in proposals.indices { proposals[i].key = id + "/" + proposals[i].id }
        }
    }

    struct Evidence: Decodable, Equatable, Hashable, Sendable {
        /// "machine/sessionId".
        var key: String
        /// The turn's prompt uuid (as LogbookSignal.turn).
        var turn: String
        var excerpt: String

        init(from decoder: any Decoder) throws {
            enum Keys: String, CodingKey { case key, turn, excerpt }
            let c = try decoder.container(keyedBy: Keys.self)
            key = try c.decode(String.self, forKey: .key)
            turn = try c.decodeIfPresent(String.self, forKey: .turn) ?? ""
            excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        }
    }

    struct Proposal: Decodable, Equatable, Sendable, Identifiable {
        /// Per finding ("p1", "p2"…): what decisions name.
        var id: String
        /// "finding/proposal": unique in the run.
        var key = ""
        /// "write" (Apply on all machines), "agent" (Send to agent…) or
        /// "note" (text only: settings, hooks; D9).
        var route: String
        var targets: [Target]
        /// Unified diff, for the owner to read.
        var patch: String
        var why: String
        var expect: String
        /// Machines etd knows it is applied on (from its decisions; none
        /// when etd does not send it).
        var applied: [String]
        /// For machines in `applied`: Undo = config_write(path, base, content).
        var undo: [Undo]

        struct Undo: Decodable, Equatable, Sendable {
            var machine: String
            var path: String
            /// The file now, with the change.
            var base: String
            /// The file without the change.
            var content: String
        }

        init(from decoder: any Decoder) throws {
            enum Keys: String, CodingKey { case id, route, targets, patch, why, expect, applied, undo }
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id)
            route = try c.decodeIfPresent(String.self, forKey: .route) ?? "note"
            targets = try c.decodeIfPresent([Target].self, forKey: .targets) ?? []
            patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
            why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
            expect = try c.decodeIfPresent(String.self, forKey: .expect) ?? ""
            applied = try c.decodeIfPresent([String].self, forKey: .applied) ?? []
            undo = try c.decodeIfPresent([Undo].self, forKey: .undo) ?? []
        }
    }

    struct Target: Decodable, Equatable, Hashable, Sendable {
        var machine: String
        var path: String
        /// "agent" for a machine where the file is in git or a Nix link.
        var route: String?
        /// sha256 of the file the patch applies to ("" = a new file).
        var base: String
        /// The whole file after the patch: what Apply writes (config_write).
        var content: String?
        /// The file before (empty: a new file) and the new file's sha256:
        /// Undo is config_write(path, base: after, content: old) (A5).
        var old: String?
        var after: String?
    }

    var takenDate: Date { Date(timeIntervalSince1970: taken) }

    init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case id, taken, findings, followup, drift }
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        taken = try c.decodeIfPresent(Double.self, forKey: .taken) ?? 0
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        followup = try c.decodeIfPresent([Followup].self, forKey: .followup) ?? []
        drift = try c.decodeIfPresent([Drift].self, forKey: .drift) ?? []
    }

    static func decode(_ json: String) throws -> MetaRun {
        try JSONDecoder().decode(MetaRun.self, from: Data(json.utf8))
    }
}

/// A turn of a transcript, by its prompt uuid.
struct LogbookTurnRef: Equatable, Sendable {
    var key: LogbookKey
    var turn: String
}

/// One allow-listed agent file on a machine (A3's AgentConfig).
struct AgentFile: Decodable, Equatable, Sendable {
    /// The same file on every machine ("<home>" for the home folder's project).
    var id: String
    /// From the home directory: "~/.claude/CLAUDE.md".
    var path: String
    var kind: String
    var sha256: String
    /// In a git repository: only an agent changes it (D8).
    var git: Bool
    /// A Home Manager link: never written; its source is in nixos-config.
    var link: String?
    /// nil when too big.
    var content: String?

    init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case id, path, kind, sha256, git, link, content }
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? id
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        git = try c.decodeIfPresent(Bool.self, forKey: .git) ?? false
        link = try c.decodeIfPresent(String.self, forKey: .link)
        content = try c.decodeIfPresent(String.self, forKey: .content)
    }

    static func decode(_ json: String) throws -> [AgentFile] {
        struct Snapshot: Decodable { var files: [AgentFile]? }
        return try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8)).files ?? []
    }
}
