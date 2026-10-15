import Foundation

/// Turns the byte stream of `tmux -C` into `ControlEvent`s.
///
/// Pure: no I/O. Feed it bytes in any chunking; it keeps partial lines until
/// their newline arrives. See SPEC.md §2.2.
public struct ControlParser: Sendable {
    private struct OpenBlock: Sendable {
        var time: Int
        var number: Int
        var flags: Int
        var lines: [[UInt8]] = []
    }

    private var buffer: [UInt8] = []
    private var block: OpenBlock?

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [ControlEvent] {
        buffer.append(contentsOf: bytes)
        var events: [ControlEvent] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: .newline) {
            var end = newline
            // A PTY (the -CC fallback) turns \n into \r\n. %output data never
            // carries a raw \r (it is escaped), so dropping one is safe.
            if end > start, buffer[end - 1] == .carriageReturn { end -= 1 }
            if let event = parseLine(Array(buffer[start..<end])) {
                events.append(event)
            }
            start = newline + 1
        }
        buffer.removeSubrange(..<start)
        return events
    }

    private mutating func parseLine(_ line: [UInt8]) -> ControlEvent? {
        if let open = block {
            // Inside a reply, every line is body except the matching guard.
            // Body lines may themselves start with "%".
            if let guardLine = Guard(line), guardLine.kind != .begin,
               guardLine.number == open.number, guardLine.time == open.time {
                block = nil
                return .reply(ControlReply(
                    time: open.time, number: open.number, flags: open.flags,
                    isError: guardLine.kind == .error, lines: open.lines))
            }
            block!.lines.append(line)
            return nil
        }

        guard line.first == .percent else {
            return line.isEmpty ? nil : .unknown(String(decoding: line, as: UTF8.self))
        }

        if let guardLine = Guard(line), guardLine.kind == .begin {
            block = OpenBlock(time: guardLine.time, number: guardLine.number, flags: guardLine.flags)
            return nil
        }

        // Pane output is bytes, not text: a UTF-8 sequence may be split over
        // two lines, so decode the octal escapes without going through String.
        if line.starts(with: Self.outputPrefix) {
            return parseOutput(line)
        }
        if line.starts(with: Self.extendedOutputPrefix) {
            return parseExtendedOutput(line)
        }

        return parseNotification(String(decoding: line, as: UTF8.self))
    }

    // MARK: - Output

    private static let outputPrefix = Array("%output ".utf8)
    private static let extendedOutputPrefix = Array("%extended-output ".utf8)

    private func parseOutput(_ line: [UInt8]) -> ControlEvent {
        let rest = line[Self.outputPrefix.count...]
        let (paneToken, data) = splitFirstSpace(rest)
        guard let pane = PaneID(token: String(decoding: paneToken, as: UTF8.self)) else {
            return .unknown(String(decoding: line, as: UTF8.self))
        }
        return .output(pane: pane, data: Self.unescape(data))
    }

    /// `%extended-output %<pane> <age> [reserved...] : <data>`
    private func parseExtendedOutput(_ line: [UInt8]) -> ControlEvent {
        let rest = line[Self.extendedOutputPrefix.count...]
        let (paneToken, afterPane) = splitFirstSpace(rest)
        let (ageToken, _) = splitFirstSpace(afterPane)
        guard let pane = PaneID(token: String(decoding: paneToken, as: UTF8.self)),
              let age = Int(String(decoding: ageToken, as: UTF8.self)),
              let colon = findColonSeparator(afterPane) else {
            return .unknown(String(decoding: line, as: UTF8.self))
        }
        return .extendedOutput(pane: pane, ageMilliseconds: age,
                               data: Self.unescape(afterPane[(colon + 3)...]))
    }

    private func splitFirstSpace(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        guard let space = bytes.firstIndex(of: .space) else {
            return (bytes, bytes[bytes.endIndex...])
        }
        return (bytes[..<space], bytes[(space + 1)...])
    }

    /// Index of the first " : " in `bytes`.
    private func findColonSeparator(_ bytes: ArraySlice<UInt8>) -> Int? {
        var i = bytes.startIndex
        while i + 2 < bytes.endIndex {
            if bytes[i] == .space, bytes[i + 1] == .colon, bytes[i + 2] == .space { return i }
            i += 1
        }
        return nil
    }

    /// Decodes tmux's `\ooo` octal escapes (used for bytes < 0x20 and `\`).
    public static func unescape(_ bytes: some Collection<UInt8>) -> [UInt8] {
        let input = Array(bytes)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let b = input[i]
            if b == .backslash, i + 3 < input.count,
               let value = octal(input[i + 1], input[i + 2], input[i + 3]) {
                out.append(value)
                i += 4
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    private static func octal(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8? {
        func digit(_ x: UInt8) -> Int? { (0x30...0x37).contains(x) ? Int(x - 0x30) : nil }
        guard let a = digit(a), let b = digit(b), let c = digit(c) else { return nil }
        let value = a * 64 + b * 8 + c
        return value <= 0xFF ? UInt8(value) : nil
    }

    // MARK: - Notifications

    private func parseNotification(_ line: String) -> ControlEvent {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let keyword = parts[0]
        let rest = parts.count > 1 ? String(parts[1]) : ""

        /// Splits `rest` into at most `count` fields; the last keeps its spaces.
        func fields(_ count: Int) -> [String] {
            rest.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: false).map(String.init)
        }
        func field(_ f: [String], _ i: Int) -> String { f.count > i ? f[i] : "" }

        switch keyword {
        case "%window-add", "%window-close", "%unlinked-window-add", "%unlinked-window-close":
            guard let w = WindowID(token: field(fields(1), 0)) else { break }
            switch keyword {
            case "%window-add": return .windowAdd(w)
            case "%window-close": return .windowClose(w)
            case "%unlinked-window-add": return .unlinkedWindowAdd(w)
            default: return .unlinkedWindowClose(w)
            }
        case "%window-renamed", "%unlinked-window-renamed":
            let f = fields(2)
            guard let w = WindowID(token: field(f, 0)) else { break }
            return keyword == "%window-renamed"
                ? .windowRenamed(w, name: field(f, 1))
                : .unlinkedWindowRenamed(w, name: field(f, 1))
        case "%window-pane-changed":
            let f = fields(2)
            guard let w = WindowID(token: field(f, 0)), let p = PaneID(token: field(f, 1)) else { break }
            return .windowPaneChanged(w, pane: p)
        case "%layout-change":
            let f = fields(4)
            guard let w = WindowID(token: field(f, 0)), f.count > 1 else { break }
            return .layoutChange(w, layout: f[1],
                                 visibleLayout: f.count > 2 ? f[2] : nil,
                                 flags: f.count > 3 ? f[3] : nil)
        case "%session-changed":
            let f = fields(2)
            guard let s = SessionID(token: field(f, 0)) else { break }
            return .sessionChanged(s, name: field(f, 1))
        case "%session-renamed":
            let f = fields(2)
            if let s = SessionID(token: field(f, 0)) { return .sessionRenamed(s, name: field(f, 1)) }
            return .sessionRenamed(nil, name: rest)
        case "%session-window-changed":
            let f = fields(2)
            guard let s = SessionID(token: field(f, 0)), let w = WindowID(token: field(f, 1)) else { break }
            return .sessionWindowChanged(s, w)
        case "%sessions-changed":
            return .sessionsChanged
        case "%client-session-changed":
            let f = fields(3)
            guard let s = SessionID(token: field(f, 1)) else { break }
            return .clientSessionChanged(client: field(f, 0), s, name: field(f, 2))
        case "%client-detached":
            return .clientDetached(client: rest)
        case "%pause", "%continue", "%pane-mode-changed":
            guard let p = PaneID(token: field(fields(1), 0)) else { break }
            switch keyword {
            case "%pause": return .pause(pane: p)
            case "%continue": return .continue(pane: p)
            default: return .paneModeChanged(pane: p)
            }
        case "%subscription-changed":
            // %subscription-changed <name> <$s> <@w> <idx> <%p> ... : <value>
            guard let separator = rest.range(of: " : ") else { break }
            return .subscriptionChanged(name: field(fields(2), 0),
                                        value: String(rest[separator.upperBound...]))
        case "%message":
            return .message(rest)
        case "%config-error":
            return .configError(rest)
        case "%exit":
            return .exit(reason: rest.isEmpty ? nil : rest)
        default:
            break
        }
        return .unknown(line)
    }
}

/// A `%begin` / `%end` / `%error` line: `<kind> <time> <number> <flags>`.
private struct Guard {
    enum Kind { case begin, end, error }
    var kind: Kind
    var time: Int
    var number: Int
    var flags: Int

    init?(_ line: [UInt8]) {
        let text = String(decoding: line, as: UTF8.self)
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let time = Int(parts[1]), let number = Int(parts[2]), let flags = Int(parts[3])
        else { return nil }
        switch parts[0] {
        case "%begin": kind = .begin
        case "%end": kind = .end
        case "%error": kind = .error
        default: return nil
        }
        self.time = time
        self.number = number
        self.flags = flags
    }
}

private extension UInt8 {
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let percent = UInt8(ascii: "%")
    static let space = UInt8(ascii: " ")
    static let colon = UInt8(ascii: ":")
    static let backslash = UInt8(ascii: "\\")
}
