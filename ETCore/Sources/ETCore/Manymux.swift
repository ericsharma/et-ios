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
