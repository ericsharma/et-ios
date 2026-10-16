import Foundation

/// Where a dictation name came from. Lower is trusted more: it wins ties
/// and is allowed looser (sound-alike) matches.
enum TermSource: Int, Comparable, Codable {
    case custom, window, repo, file, screen

    static func < (a: TermSource, b: TermSource) -> Bool { a.rawValue < b.rawValue }
}

/// Fixes names in dictated text (SPEC §6.3): finds runs of words that sound
/// like a known name ("nam shub", "key row dot swift") and writes the exact
/// spelling (`nam-shub`, `KeyRow.swift`). Pure, so it can be tested off-device.
struct VocabMatcher {
    struct Term {
        var text: String
        var soundsLike: [String] = []
        var source: TermSource
        /// For files: the path to tag with "@" (repo-relative), when the
        /// file name is unique.
        var path: String? = nil
    }

    private struct Entry {
        let term: Term
        let keyLength: Int
    }

    private var exact: [String: Entry] = [:]
    /// nil = two different names sound alike; never guess between them.
    private var phonetic: [String: Entry?] = [:]
    /// Trusted names, also matched by spelling distance.
    private var fuzzy: [(key: String, entry: Entry)] = []
    private var maxWords = 1
    private let isCommonWord: (String) -> Bool

    init(terms: [Term], isCommonWord: @escaping (String) -> Bool) {
        self.isCommonWord = isCommonWord
        for term in terms.sorted(by: { $0.source < $1.source }) {
            let spoken = Self.words(term.text)
            guard !spoken.isEmpty else { continue }
            var forms = [spoken, Self.words(term.text, sayDashes: true),
                         spoken.filter { !Self.separatorWords.contains($0) }]
            forms += term.soundsLike.map { Self.words($0) }
            for form in forms where !form.isEmpty {
                let key = form.joined()
                guard key.count >= 3 else { continue }
                maxWords = max(maxWords, form.count)
                let entry = Entry(term: term, keyLength: key.count)
                if exact[key] == nil { exact[key] = entry }
                guard term.source <= .file else { continue }
                let sound = Self.phonetic(key)
                if sound.count >= (term.source == .file ? 4 : 3) {
                    if let existing = phonetic[sound] {
                        if let e = existing, e.term.text != term.text, e.term.source == term.source {
                            phonetic[sound] = .some(nil)
                        }
                    } else {
                        phonetic[sound] = entry
                    }
                }
                if term.source <= .repo { fuzzy.append((key, entry)) }
            }
        }
    }

    var isEmpty: Bool { exact.isEmpty }

    // MARK: - Correcting text

    private struct Token {
        var lead: String
        var core: String
        var trail: String
        var space: String  // whitespace after the token
    }

    /// `tagFiles`: "at <file>" becomes "@path" (Claude Code file mentions).
    func correct(_ text: String, tagFiles: Bool) -> String {
        guard !exact.isEmpty else { return text }
        let tokens = Self.tokenize(text)
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            let longest = min(maxWords + 2, tokens.count - i)
            for n in stride(from: longest, through: 1, by: -1) {
                let span = tokens[i..<(i + n)]
                // A span never runs across a comma or sentence end.
                if span.dropLast().contains(where: { !$0.trail.isEmpty || !$0.lead.isEmpty && $0.core.isEmpty }) { continue }
                if span.dropFirst().contains(where: { !$0.lead.isEmpty }) { continue }
                guard let term = match(span.map(\.core)) else { continue }
                var first = span.first!
                let last = span.last!
                var replacement = term.text
                let isFile = term.source == .file || term.text.contains("/")
                if tagFiles, isFile {
                    if first.lead.hasSuffix("@") {
                        replacement = term.path ?? term.text
                    } else if let previous = out.last, previous.core.lowercased() == "at",
                              previous.trail.isEmpty, previous.lead.isEmpty {
                        out.removeLast()
                        first.lead = "@"
                        replacement = term.path ?? term.text
                    }
                }
                out.append(Token(lead: first.lead, core: replacement, trail: last.trail, space: last.space))
                i += n
                matched = true
                break
            }
            if !matched {
                out.append(tokens[i])
                i += 1
            }
        }
        return out.map { $0.lead + $0.core + $0.trail + $0.space }.joined()
    }

    private func match(_ cores: [String]) -> Term? {
        let words = cores.flatMap { Self.words($0) }
        let key = words.joined()
        guard key.count >= 3 else { return nil }
        let single = cores.count == 1 ? cores[0] : nil
        // A plain English word on its own is left alone unless it is
        // literally the name (and then only its spelling changes).
        let commonSingle = single.map { $0.allSatisfy(\.isLetter) && isCommonWord($0.lowercased()) } ?? false
        if let entry = exact[key] {
            if commonSingle, entry.term.text.lowercased() == single!.lowercased() { return nil }
            if commonSingle, entry.term.source > .repo { return nil }
            return entry.term
        }
        if commonSingle { return nil }
        let sound = Self.phonetic(key)
        if let found = phonetic[sound], let entry = found {
            let ratio = Double(key.count) / Double(entry.keyLength)
            if ratio >= 0.6, ratio <= 1.7 { return entry.term }
        }
        if key.count >= 5 {
            var best: (distance: Int, term: Term)?
            for (k, entry) in fuzzy where abs(k.count - key.count) <= 2 {
                let allowed = max(1, k.count / 5)
                let d = Self.distance(k, key, limit: allowed)
                if d <= allowed, d < (best?.distance ?? .max) { best = (d, entry.term) }
            }
            if let best { return best.term }
        }
        return nil
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var scanner = Substring(text)
        let leading = scanner.prefix(while: \.isWhitespace)
        if !leading.isEmpty { tokens.append(Token(lead: "", core: "", trail: "", space: String(leading))) }
        scanner = scanner.dropFirst(leading.count)
        while !scanner.isEmpty {
            let word = scanner.prefix(while: { !$0.isWhitespace })
            scanner = scanner.dropFirst(word.count)
            let space = scanner.prefix(while: \.isWhitespace)
            scanner = scanner.dropFirst(space.count)
            var core = Substring(word)
            let trailSet: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "\"", "'", "”", "’"]
            let leadSet: Set<Character> = ["(", "\"", "'", "“", "‘", "@"]
            var trail = ""
            while let c = core.last, trailSet.contains(c) { trail = String(c) + trail; core = core.dropLast() }
            var lead = ""
            while let c = core.first, leadSet.contains(c) { lead.append(c); core = core.dropFirst() }
            tokens.append(Token(lead: lead, core: String(core), trail: trail, space: String(space)))
        }
        return tokens
    }

    // MARK: - Learning from edits

    /// Words the user replaced while editing dictated text: each
    /// (heard, spelling) pair is a candidate name, e.g. ("nom shub",
    /// "nam-shub"). Word-level diff; only short replacements count.
    static func replacements(from original: String, to edited: String) -> [(heard: String, spelling: String)] {
        func split(_ text: String) -> [String] {
            text.split(whereSeparator: \.isWhitespace).map { word in
                var w = Substring(word)
                while let c = w.last, ".,!?;:\"')”’".contains(c) { w = w.dropLast() }
                while let c = w.first, "\"'(“‘".contains(c) { w = w.dropFirst() }
                return String(w)
            }.filter { !$0.isEmpty }
        }
        let a = split(original), b = split(edited)
        let la = a.map { $0.lowercased() }, lb = b.map { $0.lowercased() }
        // Longest common subsequence table.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = la[i] == lb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [(String, String)] = []
        var removed: [String] = [], added: [String] = []
        func flush() {
            if !removed.isEmpty, !added.isEmpty, removed.count <= 6, added.count <= 3 {
                let heard = removed.joined(separator: " ").lowercased()
                let spelling = added.joined(separator: " ")
                if heard != spelling.lowercased(), spelling.count >= 2 { result.append((heard, spelling)) }
            }
            removed = []
            added = []
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, la[i] == lb[j] {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                added.append(b[j])
                j += 1
            } else {
                removed.append(a[i])
                i += 1
            }
        }
        flush()
        return result
    }

    // MARK: - Spoken forms

    static let separatorWords: Set<String> = ["dot", "slash", "at", "dash", "underscore"]

    private static let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                                  "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    /// The words someone says for `text`: "." is "dot", "/" is "slash",
    /// camelCase and letter/digit runs split ("KeyRow2.swift" →
    /// key row 2 dot swift). Lowercased; number words become digits.
    static func words(_ text: String, sayDashes: Bool = false) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let w = current.lowercased()
            result.append(numbers[w] ?? w)
            current = ""
        }
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber {
                if let p = current.last {
                    let next = i + 1 < chars.count ? chars[i + 1] : nil
                    let camel = p.isLowercase && c.isUppercase
                    let acronymEnd = p.isUppercase && c.isUppercase && (next?.isLowercase ?? false)
                    let digitEdge = p.isNumber != c.isNumber
                    if camel || acronymEnd || digitEdge { flush() }
                }
                current.append(c)
                continue
            }
            flush()
            switch c {
            case ".": if !result.isEmpty, i + 1 < chars.count { result.append("dot") }
            case "/": result.append("slash")
            case "@": result.append("at")
            case "-": if sayDashes { result.append("dash") }
            case "_": if sayDashes { result.append("underscore") }
            default: break
            }
        }
        flush()
        return result
    }

    /// A rough sound key: similar-sounding spellings collapse together
    /// ("tea mucks" and "tmux" are both "tmks").
    static func phonetic(_ key: String) -> String {
        var s = key.lowercased()
        for (a, b) in [("ph", "f"), ("ck", "k"), ("x", "ks"), ("q", "k"), ("c", "k"), ("z", "s"), ("w", "")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for (i, c) in s.enumerated() {
            if i > 0, "aeiouyh".contains(c) { continue }
            if out.last == c { continue }
            out.append(c)
        }
        return out
    }

    /// Levenshtein distance, giving up early past `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            var best = row[0]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = saved
                best = min(best, row[j])
            }
            if best > limit { return limit + 1 }
        }
        return row[b.count]
    }
}
