import Foundation

/// Small helpers for the manymux Machines screen (PLAN-manymux §4 B3).
public enum Manymux {
    /// "now", "45s", "12m", "3h", "2d": time since a session's last output.
    public static func idleLabel(seconds: Int) -> String {
        switch seconds {
        case ..<5: "now"
        case ..<60: "\(seconds)s"
        case ..<3600: "\(seconds / 60)m"
        case ..<86400: "\(seconds / 3600)h"
        default: "\(seconds / 86400)d"
        }
    }

    /// Splits a typed command into arguments, as a shell would for plain
    /// words and quotes: `vim "my file"` → ["vim", "my file"]. No
    /// variables, globs or escapes beyond `\` before a character.
    public static func splitCommand(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for c in text {
            if escaped {
                current.append(c)
                escaped = false
            } else if c == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c.isWhitespace {
                if inWord { args.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(c)
                inWord = true
            }
        }
        if inWord { args.append(current) }
        return args
    }

    /// The program's name in a session's command line, for key-row presets:
    /// "/usr/bin/claude --resume" → "claude".
    public static func programName(_ command: String) -> String {
        let first = splitCommand(command).first ?? command
        return first.split(separator: "/").last.map(String.init) ?? first
    }
}

/// `mm checkpoint show` on the hub: what a restore would put back.
public struct MmCheckpoint: Equatable, Sendable {
    /// "3m": how long ago it was saved.
    public var savedAgo: String
    /// Saved sessions: a bare name on the hub, "machine/name" elsewhere.
    public var targets: [String]

    /// First line "6 sessions, saved 3m ago", then one line per session
    /// starting with its target; indented lines are the command it runs.
    /// nil for "nothing has been checkpointed" or anything else.
    public init?(show output: String) {
        let lines = Self.stripANSI(output).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, let saved = first.range(of: ", saved "), first.hasSuffix(" ago"),
              Int(first.prefix(while: \.isNumber)) != nil else { return nil }
        savedAgo = String(first[saved.upperBound...].dropLast(4))
        targets = lines.dropFirst().compactMap { line in
            guard let c = line.first, !c.isWhitespace else { return nil }
            return line.split(separator: " ").first.map(String.init)
        }
    }

    /// The saved sessions not in `running` (targets spelled the same way).
    public func missing(running: Set<String>) -> [String] {
        targets.filter { !running.contains($0) }
    }

    /// manymux colours only on a terminal; strip escapes anyway.
    public static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}
