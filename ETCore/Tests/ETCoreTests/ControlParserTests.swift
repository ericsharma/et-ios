import Foundation
import Testing
@testable import ETCore

@Suite struct ControlParserTests {
    /// Recorded from `tmux -C attach` on tmux 3.5a (no PTY). See SPEC.md §10.1.
    static func fixture(_ name: String) throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return Array(try Data(contentsOf: url))
    }

    static func parse(_ text: String) -> [ControlEvent] {
        var parser = ControlParser()
        return parser.feed(Array(text.utf8))
    }

    @Test func recordedSession() throws {
        var parser = ControlParser()
        let events = parser.feed(try Self.fixture("session1"))

        let replies = events.compactMap { if case .reply(let r) = $0 { r } else { nil } }
        #expect(replies.count == 8)
        // The initial attach-session reply comes from tmux itself.
        #expect(replies[0].isFromClient == false)
        #expect(replies[1].isFromClient)
        #expect(replies[1].textLines == ["@0_0_trigkey", "@1_1_trigkey-claude"])

        let errors = replies.filter(\.isError)
        #expect(errors.map(\.textLines) == [["parse error: unknown command: bogus-cmd"]])

        // A body line that starts with "%" is body, not a notification.
        #expect(replies.contains { $0.textLines == ["%fake line"] })

        #expect(events.contains(.sessionChanged(SessionID(0), name: "0")))
        #expect(events.contains(.windowAdd(WindowID(2))))
        #expect(events.contains(.windowRenamed(WindowID(2), name: "gm2")))
        #expect(events.contains(.sessionWindowChanged(SessionID(0), WindowID(2))))
        #expect(events.contains(.unlinkedWindowClose(WindowID(2))))
        #expect(events.last == .exit(reason: nil))
        #expect(!events.contains { if case .unknown = $0 { true } else { false } })
    }

    @Test func recordedOutputRebuildsUTF8SplitAcrossLines() throws {
        var parser = ControlParser()
        let events = parser.feed(try Self.fixture("session1"))
        let pane0 = events.flatMap { event -> [UInt8] in
            if case .output(PaneID(0), let data) = event { data } else { [] }
        }
        let text = String(decoding: pane0, as: UTF8.self)
        // The first line echoes what send-keys typed: "echo é\" then CR.
        #expect(text.hasPrefix("echo \u{e9}\\\r\n"))
        // zsh redraws the line; there "é" (c3 a9) is split over two %output
        // lines. Joined, the bytes must decode.
        #expect(text.contains("e\u{8}echo \u{e9}\\"))
    }

    @Test func chunkingDoesNotMatter() throws {
        let bytes = try Self.fixture("session1")
        var whole = ControlParser()
        let expected = whole.feed(bytes)

        var byByte = ControlParser()
        var actual: [ControlEvent] = []
        for b in bytes { actual += byByte.feed([b]) }
        #expect(actual == expected)

        var odd = ControlParser()
        var chunked: [ControlEvent] = []
        var i = 0
        while i < bytes.count {
            let n = min(7, bytes.count - i)
            chunked += odd.feed(bytes[i..<i + n])
            i += n
        }
        #expect(chunked == expected)
    }

    @Test func octalEscapes() {
        #expect(ControlParser.unescape(Array(#"a\134b\033[1m\015\012"#.utf8)) == Array("a\\b\u{1b}[1m\r\n".utf8))
        // Not a valid escape: left as is.
        #expect(ControlParser.unescape(Array(#"\9ab\12"#.utf8)) == Array(#"\9ab\12"#.utf8))
        #expect(ControlParser.unescape(Array(#"end\"#.utf8)) == Array(#"end\"#.utf8))
        #expect(ControlParser.unescape(Array(#"\000\177\377"#.utf8)) == [0x00, 0x7F, 0xFF])
    }

    @Test func outputWithTrailingSpacesAndEmptyData() {
        #expect(Self.parse("%output %3 a  \n") == [.output(pane: PaneID(3), data: Array("a  ".utf8))])
        #expect(Self.parse("%output %3 \n") == [.output(pane: PaneID(3), data: [])])
        #expect(Self.parse("%output %3\n") == [.output(pane: PaneID(3), data: [])])
    }

    @Test func extendedOutput() {
        #expect(Self.parse("%extended-output %7 1500 : hi\\015\n")
                == [.extendedOutput(pane: PaneID(7), ageMilliseconds: 1500, data: Array("hi\r".utf8))])
        #expect(Self.parse("%extended-output %7 0 x y : a : b\n")
                == [.extendedOutput(pane: PaneID(7), ageMilliseconds: 0, data: Array("a : b".utf8))])
    }

    @Test func notifications() {
        let input = """
        %window-renamed @4 my window name
        %window-pane-changed @4 %9
        %layout-change @1 a19e,50x20,0,0,1 a19e,50x20,0,0,1 *
        %pause %2
        %continue %2
        %session-renamed $1 work
        %sessions-changed
        %client-session-changed /dev/ttys003 $0 0
        %client-detached /dev/ttys003
        %subscription-changed act $0 @1 1 %1 - : 1792028041
        %exit detached
        %something-new 1 2 3
        not a control line

        """
        #expect(Self.parse(input) == [
            .windowRenamed(WindowID(4), name: "my window name"),
            .windowPaneChanged(WindowID(4), pane: PaneID(9)),
            .layoutChange(WindowID(1), layout: "a19e,50x20,0,0,1", visibleLayout: "a19e,50x20,0,0,1", flags: "*"),
            .pause(pane: PaneID(2)),
            .continue(pane: PaneID(2)),
            .sessionRenamed(SessionID(1), name: "work"),
            .sessionsChanged,
            .clientSessionChanged(client: "/dev/ttys003", SessionID(0), name: "0"),
            .clientDetached(client: "/dev/ttys003"),
            .subscriptionChanged(name: "act", value: "1792028041"),
            .exit(reason: "detached"),
            .unknown("%something-new 1 2 3"),
            .unknown("not a control line"),
        ])
    }

    @Test func replyBlockOnlyEndsOnMatchingGuard() {
        let input = """
        %begin 100 5 1
        %end 100 4 1
        %output %1 not output
        %end 100 5 1

        """
        #expect(Self.parse(input) == [
            .reply(ControlReply(time: 100, number: 5, flags: 1, isError: false,
                                lines: [Array("%end 100 4 1".utf8), Array("%output %1 not output".utf8)])),
        ])
    }

    @Test func crlfFromPTYIsTolerated() {
        #expect(Self.parse("%window-add @1\r\n%begin 1 2 1\r\nok\r\n%end 1 2 1\r\n") == [
            .windowAdd(WindowID(1)),
            .reply(ControlReply(time: 1, number: 2, flags: 1, isError: false, lines: [Array("ok".utf8)])),
        ])
    }
}
