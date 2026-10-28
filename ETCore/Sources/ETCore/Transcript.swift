import Foundation

/// Claude Code's own record of a session: the JSONL transcript in
/// ~/.claude/projects/<dir>/<session>.jsonl on the machine Claude runs on.
/// Exact text, unlike the screen, which wraps and scrolls away.
public enum Transcript {
    /// One exchange: what the user typed, and Claude's text replies until the
    /// next prompt (thinking left out). `id` is the prompt's entry uuid.
    /// `reply` has only text; the tool calls are in `tools`, in order.
    public struct Turn: Identifiable, Equatable, Sendable {
        public let id: String
        public var prompt: String
        public var reply: String
        public var timestamp: Date?
        public var tools: [ToolCall]

        public init(id: String, prompt: String, reply: String, timestamp: Date? = nil, tools: [ToolCall] = []) {
            self.id = id
            self.prompt = prompt
            self.reply = reply
            self.timestamp = timestamp
            self.tools = tools
        }
    }

    /// A tool call in a turn: the tool, its input on one line, and its
    /// output once the result line is there.
    public struct ToolCall: Identifiable, Equatable, Sendable {
        /// The tool_use id (`toolu_…`).
        public let id: String
        public var name: String
        /// The main input (command, file path, pattern…), one line, at most 160 characters.
        public var summary: String
        public var output: String?
        public var isError: Bool

        public init(id: String, name: String, summary: String, output: String? = nil, isError: Bool = false) {
            self.id = id
            self.name = name
            self.summary = summary
            self.output = output
            self.isError = isError
        }
    }

    /// Shell script (POSIX sh, run on the transcript's machine) that picks
    /// the window's transcript and prints its path, a line with
    /// `ET_TRANSCRIPT`, then the useful lines gzipped and base64'd.
    ///
    /// The transcript is the newest of the last 20 that contains `needle`
    /// (a piece of the user's last prompt on screen); without a match, the
    /// newest. grep keeps only prompts and Claude's text, which cuts a 5 MB
    /// file to ~85 KB; `parse` does the exact filtering.
    public static func fetchScript(needle: String?, maxLines: Int = 3000) -> String {
        let quotedNeedle = needle.map(shellQuote) ?? "''"
        return """
        n=\(quotedNeedle); best=; files=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -n 20)
        [ -n "$files" ] || { echo ET_NO_TRANSCRIPT; exit 3; }
        if [ -n "$n" ]; then for f in $files; do if grep -qF -- "$n" "$f"; then best=$f; break; fi; done; fi
        [ -n "$best" ] || best=$(printf '%s\\n' "$files" | head -n 1)
        printf '%s\\nET_TRANSCRIPT\\n' "$best"
        grep -E '"role":"user","content":("|\\[\\{"type":"(text|image)")|"role":"assistant","content":\\[\\{"type":"text"' "$best" \\
          | grep -v '^{"type":"api-request' | grep -v '"isSidechain":true' | tail -n \(maxLines) | gzip -c | base64
        """
    }

    /// The fetch script's output: (transcript path, its JSONL lines).
    public static func decodeFetchOutput(_ output: String) -> (path: String, lines: [String])? {
        guard let marker = output.range(of: "\nET_TRANSCRIPT\n") else { return nil }
        let path = String(output[..<marker.lowerBound]).components(separatedBy: "\n").last ?? ""
        let encoded = String(output[marker.upperBound...])
        guard let gz = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let raw = gunzip(gz) else { return nil }
        let text = String(decoding: raw, as: UTF8.self)
        return (path, text.split(separator: "\n").map(String.init))
    }

    /// The id of the turn `parse(lines:leading: true)` makes for replies
    /// whose prompt is before the first line.
    public static let leadingTurnID = "leading"

    /// Turns from transcript lines, oldest first. Tool calls go into the
    /// turn they belong to, and their results into the calls (by id).
    /// `leading`: the lines start inside a turn (a tail of the file); keep
    /// the replies before the first prompt in a turn with an empty prompt.
    public static func parse(lines: [String], leading: Bool = false) -> [Turn] {
        var turns: [Turn] = leading ? [Turn(id: leadingTurnID, prompt: "", reply: "")] : []
        /// Tool call id → (turn, index in its tools).
        var calls: [String: (Int, Int)] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = entry["type"] as? String,
                  entry["isSidechain"] as? Bool != true,
                  entry["isMeta"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            if let blocks = message["content"] as? [[String: Any]], !turns.isEmpty {
                let last = turns.count - 1
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_use" where type == "assistant":
                        guard let id = block["id"] as? String else { continue }
                        let name = block["name"] as? String ?? "tool"
                        calls[id] = (last, turns[last].tools.count)
                        turns[last].tools.append(ToolCall(id: id, name: name, summary: summary(of: block["input"])))
                    case "tool_result" where type == "user":
                        guard let id = block["tool_use_id"] as? String, let at = calls[id] else { continue }
                        turns[at.0].tools[at.1].output = resultText(of: block["content"])
                        turns[at.0].tools[at.1].isError = block["is_error"] as? Bool ?? false
                    default:
                        continue
                    }
                }
            }
            let text = Self.text(of: message["content"])
            guard !text.isEmpty else { continue }
            switch type {
            case "user":
                // Slash commands and their output aren't prompts.
                if text.hasPrefix("<command-") || text.hasPrefix("<local-command") || text.hasPrefix("[Request interrupted") { continue }
                let id = entry["uuid"] as? String ?? UUID().uuidString
                let date = (entry["timestamp"] as? String).flatMap { iso.date(from: $0) }
                turns.append(Turn(id: id, prompt: text, reply: "", timestamp: date))
            case "assistant":
                guard !turns.isEmpty else { continue }
                let last = turns.count - 1
                turns[last].reply += (turns[last].reply.isEmpty ? "" : "\n\n") + text
            default:
                continue
            }
        }
        if leading, let first = turns.first, first.reply.isEmpty, first.tools.isEmpty { turns.removeFirst() }
        return turns
    }

    /// A piece of the user's last prompt that appears verbatim in the
    /// transcript: the longest start without characters JSON escapes, if
    /// it is long enough to be distinctive.
    public static func needle(fromPrompt prompt: String) -> String? {
        let flat = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let safe = flat.prefix { $0 != "\"" && $0 != "\\" && $0 != "\t" }
        let piece = String(safe.prefix(40))
        return piece.count >= 12 ? piece : nil
    }

    /// The selected turns as text for a model, newest kept whole: older
    /// replies are shortened in the middle to fit `budget` characters.
    public static func render(_ turns: [Turn], budget: Int) -> String {
        func block(_ i: Int, _ turn: Turn, replyLimit: Int) -> String {
            var reply = turn.reply
            if reply.count > replyLimit {
                let half = max(replyLimit / 2, 1)
                reply = reply.prefix(half) + "\n[…]\n" + reply.suffix(half)
            }
            return "### Exchange \(i + 1)\nDeveloper:\n\(turn.prompt)\n\nClaude:\n\(reply.isEmpty ? "(no reply yet)" : reply)"
        }
        var limit = Int.max
        while true {
            let text = turns.enumerated().map { block($0.offset, $0.element, replyLimit: limit) }.joined(separator: "\n\n")
            if text.count <= budget || limit < 400 { return String(text.suffix(budget)) }
            limit = limit == Int.max ? (turns.map(\.reply.count).max() ?? 0) / 2 : limit / 2
        }
    }

    // MARK: -

    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tool input as one line: the field that says what it does, else
    /// the first string field.
    private static func summary(of input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        let keys = ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt", "skill"]
        let value = keys.lazy.compactMap { input[$0] as? String }.first
            ?? input.keys.sorted().lazy.compactMap { input[$0] as? String }.first
            ?? ""
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let flat = line.trimmingCharacters(in: .whitespaces)
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    /// A tool result's text: a string, or the text blocks of a list.
    private static func resultText(of content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.map { block in
            block["type"] as? String == "text" ? block["text"] as? String ?? "" : "[\(block["type"] as? String ?? "item")]"
        }.joined(separator: "\n")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// gzip (RFC 1952) → bytes, via Foundation's raw-deflate decoder.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0, bytes.count > i + 2 { i += 2 + Int(bytes[i]) | Int(bytes[i + 1]) << 8 }  // FEXTRA
        if flags & 0x08 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }  // FNAME
        if flags & 0x10 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }  // FHCRC
        guard i < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[i..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
