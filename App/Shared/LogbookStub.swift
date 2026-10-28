// STUB: delete when Vendor/etd has the Logbook API (PLAN-logbook)
//
// et-link's Logbook API (PLAN-logbook §4.5), with its exact names, until it
// lands in Vendor/etd. When the generated et_link.swift has these names,
// this file stops compiling (redeclarations). Then delete it, and the
// fixtures in App/Resources/LogbookFixtures.
//
// It does not ask the machine. It answers from this device:
// - macOS: this Mac's ~/.claude (machine "mac-mini"). Live sessions are the
//   Claude processes under the manymux node; a followed file is read
//   again every second.
// - iOS: two fixture transcripts; a follow adds one line every 3 s.
// - report: a fixture in the §4.4 schema, after 3 s of fake progress.
// - grouping, logbook_pause, logbook_send: log a line and succeed.

import EtLink
import Foundation

extension NetworkInfo {
    /// Machine names, first = the one to use.
    public var archive: [String] { ["trigkey"] }
}

public struct LogKey: Equatable, Hashable, Sendable {
    public var machine: String
    public var sessionId: String

    public init(machine: String, sessionId: String) {
        self.machine = machine
        self.sessionId = sessionId
    }
}

public struct LogEntry: Equatable, Hashable, Sendable {
    public var key: LogKey
    /// The manymux session name on that machine.
    public var mmSession: String
    public var cwd: String
    /// The git remote URL, else the repo root path.
    public var repo: String?
    public var branch: String?
    /// "busy" | "idle" | "gone"
    public var status: String
    /// Unix seconds.
    public var first: UInt64
    public var last: UInt64
    public var bytes: UInt64
    /// The session id before /clear or --resume.
    public var previous: String?
    /// Do not record.
    public var paused: Bool

    public init(key: LogKey, mmSession: String, cwd: String, repo: String?, branch: String?, status: String,
                first: UInt64, last: UInt64, bytes: UInt64, previous: String?, paused: Bool) {
        self.key = key
        self.mmSession = mmSession
        self.cwd = cwd
        self.repo = repo
        self.branch = branch
        self.status = status
        self.first = first
        self.last = last
        self.bytes = bytes
        self.previous = previous
        self.paused = paused
    }
}

/// Whole JSONL lines only. `offset`: the byte offset after the last line.
public struct LogChunk: Equatable, Hashable, Sendable {
    public var offset: UInt64
    public var lines: [String]

    public init(offset: UInt64, lines: [String]) {
        self.offset = offset
        self.lines = lines
    }
}

public enum LogSelection: Equatable, Hashable, Sendable {
    /// Claude entry uuids of the prompts.
    case turns(key: LogKey, turnIds: [String])
    case reportSection(reportId: String, projectId: String)
}

public protocol ReportProgress: AnyObject, Sendable {
    func onProgress(stage: String, done: UInt32, total: UInt32)
}

/// A followed transcript: the stored bytes first, then live.
open class LogStream: @unchecked Sendable {
    private let source: LogbookStubSource
    private var offset: UInt64
    private var first = true

    init(source: LogbookStubSource, from: UInt64) {
        self.source = source
        self.offset = from
    }

    open func next() async throws -> LogChunk {
        while true {
            try Task.checkCancellation()
            if let chunk = try source.read(from: offset, alignToLine: first) {
                first = false
                offset = chunk.offset
                return chunk
            }
            first = false
            try await Task.sleep(for: source.poll)
        }
    }
}

extension RemoteHost {
    public func logbookSessions(since: UInt64) async throws -> [LogEntry] {
        LogbookStub.shared.sessions()
    }

    public func logbookFollow(key: LogKey, from: UInt64) async throws -> LogStream {
        guard let source = LogbookStub.shared.source(for: key) else {
            throw LinkError.Remote(message: "No transcript \(key.machine)/\(key.sessionId)")
        }
        return LogStream(source: source, from: from)
    }

    public func logbookPause(machine: String, mmSession: String, paused: Bool) async throws {
        LogbookStub.log("logbook_pause \(machine)/\(mmSession) paused=\(paused)")
        LogbookStub.shared.setPaused(machine + "/" + mmSession, paused)
    }

    /// The §4.4 JSON plus "id" and "taken".
    public func report(refresh: Bool, progress: ReportProgress) async throws -> String {
        LogbookStub.log("report refresh=\(refresh)")
        if !refresh {
            guard let last = LogbookStub.shared.lastReport else { throw LinkError.Remote(message: "No report yet") }
            return last
        }
        let sessions = LogbookStub.shared.sessions()
        let total: UInt32 = 6
        for done in 0...total {
            progress.onProgress(stage: done < total - 1 ? "digests" : "report", done: done, total: total)
            try await Task.sleep(for: .milliseconds(500))
        }
        let json = LogbookStub.reportJSON(sessions)
        LogbookStub.shared.lastReport = json
        return json
    }

    /// One §4.4 proposal, accepted or edited.
    public func grouping(changeJson: String) async throws {
        LogbookStub.log("grouping \(changeJson)")
    }

    public func logbookSend(selection: LogSelection, to: String, session: String,
                            progress: SendProgress) async throws -> Delivered {
        LogbookStub.log("logbook_send \(selection) to \(to)/\(session)")
        progress.onProgress(done: 1, total: 1)
        let stamp = Int(Date().timeIntervalSince1970)
        return Delivered(paths: ["~/etd-downloads/logbook/\(stamp)-mac-mini.md"], typed: true)
    }
}

// MARK: - The stub's data

final class LogbookStub: @unchecked Sendable {
    static let shared = LogbookStub()
    static let machine = "mac-mini"

    private let lock = NSLock()
    private var paused: Set<String> = []
    private var _lastReport: String?
    /// cwd → (repo, branch).
    private var repos: [String: (String?, String?)] = [:]

    var lastReport: String? {
        get { lock.withLock { _lastReport } }
        set { lock.withLock { _lastReport = newValue } }
    }

    func setPaused(_ id: String, _ on: Bool) {
        lock.withLock {
            if on { paused.insert(id) } else { paused.remove(id) }
        }
    }

    private func isPaused(_ mmSession: String) -> Bool {
        lock.withLock { paused.contains(Self.machine + "/" + mmSession) }
    }

    static func log(_ line: String) {
        NSLog("logbook stub: %@", line)
    }

    #if os(macOS)
    private static var claudeHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }

    func sessions() -> [LogEntry] {
        let live = liveSessions()
        let fm = FileManager.default
        let projects = Self.claudeHome.appendingPathComponent("projects")
        var entries: [LogEntry] = []
        for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jsonl" {
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      let size = attrs[.size] as? UInt64, size > 0 else { continue }
                let id = file.deletingPathExtension().lastPathComponent
                let running = live[id]
                let cwd = running?.cwd ?? Self.cwd(inHeadOf: file) ?? ""
                let (repo, branch) = repo(for: cwd)
                let created = (attrs[.creationDate] as? Date) ?? Date()
                let modified = (attrs[.modificationDate] as? Date) ?? Date()
                let mm = running?.mmSession ?? ""
                entries.append(LogEntry(
                    key: LogKey(machine: Self.machine, sessionId: id), mmSession: mm, cwd: cwd, repo: repo, branch: branch,
                    status: running?.status ?? "gone",
                    first: UInt64(created.timeIntervalSince1970), last: UInt64(modified.timeIntervalSince1970),
                    bytes: size, previous: nil, paused: !mm.isEmpty && isPaused(mm)))
            }
        }
        return entries.sorted { $0.last > $1.last }
    }

    func source(for key: LogKey) -> LogbookStubSource? {
        let projects = Self.claudeHome.appendingPathComponent("projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let file = dir.appendingPathComponent(key.sessionId + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return FileSource(url: file) }
        }
        return nil
    }

    private struct Live {
        var cwd: String
        var status: String
        var mmSession: String
    }

    /// Claude processes under the manymux node, by session id (§4.1 steps 1–3).
    private func liveSessions() -> [String: Live] {
        let table = Self.run("/bin/ps", ["-axo", "pid=,ppid=,command="])
        var parent: [Int32: Int32] = [:]
        var node: Int32?
        for line in table.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            parent[pid] = ppid
            if parts[2].hasSuffix("mm daemon") || parts[2].contains("mm daemon ") { node = pid }
        }
        guard let node else { return [:] }
        func underNode(_ pid: Int32) -> Bool {
            var p = pid
            for _ in 0..<32 {
                guard let up = parent[p], up > 1 else { return false }
                if up == node { return true }
                p = up
            }
            return false
        }
        var live: [String: Live] = [:]
        let dir = Self.claudeHome.appendingPathComponent("sessions")
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let id = json["sessionId"] as? String,
                  underNode(pid) else { continue }
            let env = Self.run("/bin/ps", ["-E", "-p", "\(pid)", "-o", "command="])
            let mm = env.split(separator: " ").first { $0.hasPrefix("MM_SESSION=") }.map { String($0.dropFirst(11)) } ?? ""
            live[id] = Live(cwd: json["cwd"] as? String ?? "", status: json["status"] as? String ?? "idle", mmSession: mm)
        }
        return live
    }

    private static func cwd(inHeadOf file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 64 * 1024), as: UTF8.self)
        guard let start = head.range(of: #""cwd":""#) else { return nil }
        let rest = head[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    private func repo(for cwd: String) -> (String?, String?) {
        guard !cwd.isEmpty else { return (nil, nil) }
        if let known = lock.withLock({ repos[cwd] }) { return known }
        let root = Self.run("/usr/bin/git", ["-C", cwd, "rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var found: (String?, String?) = (nil, nil)
        if !root.isEmpty {
            let remote = Self.run("/usr/bin/git", ["-C", cwd, "config", "--get", "remote.origin.url"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = Self.run("/usr/bin/git", ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            found = (remote.isEmpty ? root : remote, branch.isEmpty ? nil : branch)
        }
        lock.withLock { repos[cwd] = found }
        return found
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }
    #else
    private static let fixtures = ["logbook-1", "logbook-2"]

    func sessions() -> [LogEntry] {
        let now = UInt64(Date().timeIntervalSince1970)
        let meta: [(mm: String, cwd: String, repo: String, branch: String, status: String)] = [
            ("claude", "/Users/ericsharma/tmux-ios", "git@github.com:ericsharma/et-ios.git", "main", "busy"),
            ("claude2", "/Users/ericsharma/nixos-config", "git@github.com:ericsharma/nixos-config.git", "main", "idle"),
        ]
        return Self.fixtures.enumerated().map { i, name in
            let m = meta[i]
            let bytes = (Bundle.main.url(forResource: name, withExtension: "jsonl")
                .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64 }) ?? 0
            return LogEntry(key: LogKey(machine: Self.machine, sessionId: name), mmSession: m.mm, cwd: m.cwd, repo: m.repo,
                            branch: m.branch, status: m.status, first: now - 3600 * UInt64(i + 1), last: now - 60 * UInt64(i),
                            bytes: bytes, previous: nil, paused: isPaused(m.mm))
        }
    }

    func source(for key: LogKey) -> LogbookStubSource? {
        guard let url = Bundle.main.url(forResource: key.sessionId, withExtension: "jsonl"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return FixtureSource(lines: text.split(separator: "\n").map(String.init))
    }
    #endif

    /// Two projects and one proposal, from the sessions there are.
    static func reportJSON(_ sessions: [LogEntry]) -> String {
        func key(_ e: LogEntry) -> String { e.key.machine + "/" + e.key.sessionId }
        let live = sessions.filter { $0.status != "gone" }
        let older = sessions.filter { $0.status == "gone" }.prefix(3)
        let first = live.isEmpty ? Array(sessions.prefix(2)) : live
        let second = Array(older.filter { !first.contains($0) })
        let roles = ["Writes the Swift side of the Logbook", "Builds etd capture and the archive", "Checks the plan"]
        let report: [String: Any] = [
            "id": "stub-\(Int(Date().timeIntervalSince1970))",
            "taken": Int(Date().timeIntervalSince1970),
            "projects": [
                [
                    "id": "logbook", "name": "E.T. Logbook", "status": "active",
                    "goal": "Show every Claude session of the network in one place, grouped by goal, with a report.",
                    "sessions": first.enumerated().map { ["key": key($1), "role": roles[$0 % roles.count]] },
                    "progress": "Plan accepted (D1–D10). Mac UI runs on a stub. etd capture is in progress on trigkey.",
                    "next": ["Finish L1 capture in etd", "Swap the Swift stub for the real et-link API", "iOS Logbook screen"],
                ],
                [
                    "id": "nixos", "name": "nixos-config", "status": second.isEmpty ? "done" : "blocked",
                    "goal": "Keep the machines' NixOS and nix-darwin configs deployed.",
                    "sessions": second.map { ["key": key($0), "role": "Earlier deploy work"] },
                    "progress": "mac-mini PATH fix deployed. Waiting for the etd Logbook release.",
                    "next": ["Deploy etd with the Logbook to trigkey, gmktec and mac-mini together"],
                ],
            ],
            "unassigned": [String](),
            "proposals": [
                [
                    "kind": "move",
                    "detail": second.first.map { "Move \(key($0)) to E.T. Logbook" } ?? "Merge nixos-config into E.T. Logbook",
                    "why": "Its last turns are about the Logbook deploy, not about NixOS.",
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Followed sources

class LogbookStubSource: @unchecked Sendable {
    var poll: Duration { .seconds(1) }

    /// Whole lines from `from`, or nil when there is nothing new.
    /// `alignToLine`: `from` can be inside a line; skip to the next one.
    func read(from: UInt64, alignToLine: Bool) throws -> LogChunk? { nil }
}

/// A transcript on this Mac, read again on each poll.
final class FileSource: LogbookStubSource, @unchecked Sendable {
    private let url: URL
    private static let maxChunk = 512 * 1024

    init(url: URL) {
        self.url = url
    }

    override func read(from: UInt64, alignToLine: Bool) throws -> LogChunk? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var start = from
        if alignToLine, start > 0 {
            try handle.seek(toOffset: start - 1)
            if handle.readData(ofLength: 1) != Data("\n".utf8) {
                // Skip the rest of the line `from` is in.
                while true {
                    let piece = handle.readData(ofLength: 64 * 1024)
                    guard !piece.isEmpty else { return nil }
                    if let nl = piece.firstIndex(of: UInt8(ascii: "\n")) {
                        start += UInt64(nl - piece.startIndex) + 1
                        break
                    }
                    start += UInt64(piece.count)
                }
            }
        }
        try handle.seek(toOffset: start)
        var data = handle.readData(ofLength: Self.maxChunk)
        // A line longer than a chunk: read on to its end.
        while !data.isEmpty, !data.contains(UInt8(ascii: "\n")) {
            let more = handle.readData(ofLength: Self.maxChunk)
            if more.isEmpty { break }
            data.append(more)
        }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let whole = data[data.startIndex...lastNewline]
        let lines = String(decoding: whole, as: UTF8.self).split(separator: "\n").map(String.init)
        return LogChunk(offset: start + UInt64(whole.count), lines: lines)
    }
}

/// iOS: a fixture. First half at once, then one line every 3 s; after the
/// fixture's end, made-up exchanges.
final class FixtureSource: LogbookStubSource, @unchecked Sendable {
    private let lines: [String]
    /// One stream reads it, one call at a time.
    private var waited = false
    override var poll: Duration { .seconds(3) }

    init(lines: [String]) {
        self.lines = lines
    }

    /// Offsets here count lines, not bytes.
    override func read(from: UInt64, alignToLine: Bool) throws -> LogChunk? {
        let at = Int(from)
        if at == 0 {
            let half = max(lines.count / 2, 1)
            return LogChunk(offset: UInt64(half), lines: Array(lines.prefix(half)))
        }
        // Each line after the first half waits one poll.
        if !waited {
            waited = true
            return nil
        }
        waited = false
        if at < lines.count { return LogChunk(offset: UInt64(at + 1), lines: [lines[at]]) }
        let n = at - lines.count
        let uuid = "stub-\(n)"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = n % 2 == 0
            ? #"{"type":"user","isSidechain":false,"uuid":"\#(uuid)","timestamp":"\#(stamp)","message":{"role":"user","content":"Stub prompt \#(n / 2 + 1): what changed?"}}"#
            : #"{"type":"assistant","isSidechain":false,"uuid":"\#(uuid)","timestamp":"\#(stamp)","message":{"role":"assistant","content":[{"type":"text","text":"Stub reply \#(n / 2 + 1): one more line, 3 s later."}]}}"#
        return LogChunk(offset: UInt64(at + 1), lines: [line])
    }
}
