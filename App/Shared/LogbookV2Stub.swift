// STUB: delete when Vendor/etd has the Logbook v2 API (PLAN-logbook-v2 §4.5)
//
// et-link's Logbook v2 methods, with their exact names, until W0 + A1–A4
// land in Vendor/etd. When the generated et_link.swift has a name, this file
// stops compiling (redeclaration): delete that method here. Delete the file
// when it is empty.
//
// - logbook_overview: made on this device from the real archive: the
//   session list, plus the last 256 KB of each changed transcript (the
//   asked / said lines and a prompt count of that part). `friction` empty.
// - logbook_signals, meta, meta_decision, agent_config, config_write:
//   "not built yet: <package>", as W0's handlers answer.
// - LogSelection::Finding: not in the stub (an enum case can't be added);
//   LogbookSelection.finding throws the same error until A4 (Iroh.swift).

import ETCore
import EtLink
import Foundation

extension RemoteHost {
    /// §4.5 Overview JSON: one entry per transcript changed at or after `since`.
    public func logbookOverview(since: UInt64) async throws -> String {
        let entries = try await logbookSessions(since: since)
        var sessions: [[String: Any]] = []
        for entry in entries {
            let tail = await LogbookV2Stub.tail(of: entry, host: self)
            let headline = entry.title ?? tail.firstPrompt.map { String($0.prefix(60)) }
            var json: [String: Any] = [
                "key": entry.key.machine + "/" + entry.key.sessionId,
                "agent": "claude", "machine": entry.key.machine, "mm": entry.mmSession,
                "state": entry.status, "prompts": tail.prompts, "trivial": tail.whole && tail.prompts < 2,
                "friction": Dictionary(grouping: tail.signals, by: { $0["kind"] as? String ?? "" }).mapValues(\.count),
                "first": entry.first, "last": entry.last,
            ]
            if let headline {
                json["headline"] = headline
                json["headline_from"] = entry.title != nil ? "title" : "prompt"
            }
            if let asked = tail.asked { json["asked"] = asked }
            if let said = tail.said { json["said"] = said }
            sessions.append(json)
        }
        let data = try JSONSerialization.data(withJSONObject: ["sessions": sessions])
        return String(decoding: data, as: UTF8.self)
    }

    /// Signals JSON (B5's proposal for A2): every signal of each transcript
    /// changed at or after `since`, from the same tails as the overview.
    public func logbookSignals(since: UInt64) async throws -> String {
        var signals: [[String: Any]] = []
        for entry in try await logbookSessions(since: since) {
            signals += await LogbookV2Stub.tail(of: entry, host: self).signals
        }
        let data = try JSONSerialization.data(withJSONObject: ["signals": signals])
        return String(decoding: data, as: UTF8.self)
    }

    public func meta(refresh: Bool, progress: ReportProgress) async throws -> String {
        throw LinkError.Remote(message: "not built yet: A4")
    }

    public func metaDecision(decisionJson: String) async throws {
        throw LinkError.Remote(message: "not built yet: A4")
    }

    public func agentConfig() async throws -> String {
        throw LinkError.Remote(message: "not built yet: A3")
    }

    public func configWrite(path: String, base: String, content: String) async throws -> String {
        throw LinkError.Remote(message: "not built yet: A3")
    }
}

enum LogbookV2Stub {
    struct Tail: @unchecked Sendable {
        var firstPrompt: String?
        var asked: String?
        var said: String?
        var prompts = 0
        /// The tail is the whole transcript (so `prompts` is all of them).
        var whole = false
        /// §4.3 signals in the tail: interrupt, denied, tool-error, compact.
        var signals: [[String: Any]] = []
    }

    private static let size: UInt64 = 256 * 1024
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (bytes: UInt64, read: Date, tail: Tail)] = [:]

    /// The asked / said lines from the transcript's last 256 KB, or 1 MB or
    /// 4 MB when that part has no prompt (long tool output); cached by size,
    /// and read at most every 30 s while a session writes.
    static func tail(of entry: LogEntry, host: RemoteHost) async -> Tail {
        let id = entry.key.machine + "/" + entry.key.sessionId
        if let hit = lock.withLock({ cache[id] }), hit.bytes == entry.bytes || hit.read > Date().addingTimeInterval(-30) {
            return hit.tail
        }
        var tail = Tail()
        for size in [size, 4 * size, 16 * size] {
            let from = entry.bytes > size ? entry.bytes - size : 0
            guard let lines = await read(entry.key, from: from, host: host) else { return Tail() }
            let all = Transcript.parse(lines: lines, leading: from > 0)
            let turns = all.filter { $0.id != Transcript.leadingTurnID }
            tail = Tail(prompts: turns.count, whole: from == 0)
            tail.firstPrompt = from == 0 ? turns.first.map { oneLine($0.prompt) } : nil
            tail.asked = turns.last.map { oneLine($0.prompt) }
            tail.said = all.last(where: { !$0.reply.isEmpty }).map { oneLine($0.reply) }
            tail.signals = signals(in: lines, key: entry.key.machine + "/" + entry.key.sessionId)
            if !turns.isEmpty || from == 0 { break }
        }
        lock.withLock { cache[id] = (entry.bytes, Date(), tail) }
        return tail
    }

    private static func read(_ key: LogKey, from: UInt64, host: RemoteHost) async -> [String]? {
        var lines: [String] = []
        do {
            let stream = try await host.logbookFollow(key: key, from: from)
            defer { stream.close() }
            while true {
                let chunk = try await stream.next()
                lines += chunk.lines
                if chunk.live { return lines }
            }
        } catch {
            NSLog("LogbookV2Stub: tail of %@/%@: %@", key.machine, key.sessionId, "\(error)")
            return nil
        }
    }

    /// The signals A2 finds with no model, by the turn they are in (the
    /// prompt uuid that starts it, as Transcript.parse names turns).
    static func signals(in lines: [String], key: String) -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var turn = Transcript.leadingTurnID
        var found: [[String: Any]] = []
        for line in lines {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let time = (entry["timestamp"] as? String).flatMap { iso.date(from: $0) }.map { UInt64($0.timeIntervalSince1970) } ?? 0
            func add(_ kind: String, _ excerpt: String) {
                found.append(["kind": kind, "key": key, "turn": turn, "uuid": entry["uuid"] as? String ?? "",
                              "time": time, "excerpt": oneLine(excerpt)])
            }
            if entry["subtype"] as? String == "compact_boundary" { add("compact", "Context compacted"); continue }
            guard entry["type"] as? String == "user", entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String ?? (message["content"] as? [[String: Any]])?
                .first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                if text.hasPrefix("[Request interrupted by user") {
                    add("interrupt", text)
                } else if entry["isMeta"] as? Bool != true, !text.hasPrefix("<command-"), !text.hasPrefix("<local-command"),
                          entry["isCompactSummary"] as? Bool != true {
                    turn = entry["uuid"] as? String ?? turn
                }
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                let output = block["content"] as? String
                    ?? (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                if output.contains("The user doesn't want to proceed with this tool use") {
                    add("denied", output)
                } else if block["is_error"] as? Bool == true {
                    add("tool-error", output)
                }
            }
        }
        return found
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
    }
}
