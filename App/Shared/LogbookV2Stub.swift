// STUB: delete when etd has A2 (PLAN-logbook-v2 §4.3)
//
// Vendor/etd has every Logbook v2 method since 0.0.14 (W0 + A1). Until A2
// answers LogSignals, Iroh.swift falls back to this: the signals A2 finds
// with no model (interrupt, denied, tool-error, compact), found on this
// device in the last 256 KB–4 MB of each changed transcript.

import ETCore
import EtLink
import Foundation

enum LogbookV2Stub {
    /// Signals JSON (plan §8, B5) of each transcript changed at or after `since`.
    static func signals(since: UInt64, host: RemoteHost) async throws -> String {
        var signals: [[String: Any]] = []
        for entry in try await host.logbookSessions(since: since) {
            signals += await tail(of: entry, host: host).signals
        }
        let data = try JSONSerialization.data(withJSONObject: ["signals": signals])
        return String(decoding: data, as: UTF8.self)
    }

    struct Tail: @unchecked Sendable {
        /// §4.3 signals in the tail: interrupt, denied, tool-error, compact.
        var signals: [[String: Any]] = []
    }

    private static let size: UInt64 = 256 * 1024
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (bytes: UInt64, read: Date, tail: Tail)] = [:]

    /// The signals in the transcript's last 256 KB, or 1 MB or 4 MB when
    /// that part has no prompt (long tool output); cached by size, and read
    /// at most every 30 s while a session writes.
    static func tail(of entry: LogEntry, host: RemoteHost) async -> Tail {
        let id = entry.key.machine + "/" + entry.key.sessionId
        if let hit = lock.withLock({ cache[id] }), hit.bytes == entry.bytes || hit.read > Date().addingTimeInterval(-30) {
            return hit.tail
        }
        var tail = Tail()
        for size in [size, 4 * size, 16 * size] {
            let from = entry.bytes > size ? entry.bytes - size : 0
            guard let lines = await read(entry.key, from: from, host: host) else { return Tail() }
            tail.signals = signals(in: lines, key: id)
            if from == 0 || Transcript.parse(lines: lines, leading: true).contains(where: { $0.id != Transcript.leadingTurnID }) { break }
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
