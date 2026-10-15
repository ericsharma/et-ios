import Testing
@testable import ETCore

@Suite struct TmuxCommandTests {
    @Test func quoting() {
        #expect(TmuxCommand.quote("plain") == "'plain'")
        #expect(TmuxCommand.quote("it's") == #"'it'\''s'"#)
        #expect(TmuxCommand.quoteName("a #{x} b") == "'a ##{x} b'")
    }

    @Test func sendKeysIsHexAndChunked() {
        #expect(TmuxCommand.sendKeys(pane: PaneID(3), bytes: [0x1B, 0x5B, 0x41, 0x0D])
                == ["send-keys -t %3 -H 1b 5b 41 0d"])
        let chunks = TmuxCommand.sendKeys(pane: PaneID(1), bytes: Array(repeating: 0x61, count: 600), chunkSize: 256)
        #expect(chunks.count == 3)
        #expect(chunks[2] == "send-keys -t %1 -H " + Array(repeating: "61", count: 88).joined(separator: " "))
        #expect(TmuxCommand.sendKeys(pane: PaneID(1), bytes: []).isEmpty)
    }

    @Test func windowListParsing() {
        let reply = ControlReply(time: 0, number: 0, flags: 1, isError: false, lines: [
            Array("@0 1 0 %0 1 80 24 bash trigkey".utf8),
            Array("@5 4 1 %7 2 50 20 ssh gmktec-claude".utf8),
            Array("@6 7 0 %8 1 50 20 my_cmd it's ~ a name".utf8),
            Array("garbage".utf8),
        ])
        #expect(TmuxCommand.parseWindowList(reply) == [
            WindowInfo(id: WindowID(0), index: 1, isActive: false, activePane: PaneID(0), paneCount: 1,
                       width: 80, height: 24, currentCommand: "bash", name: "trigkey"),
            WindowInfo(id: WindowID(5), index: 4, isActive: true, activePane: PaneID(7), paneCount: 2,
                       width: 50, height: 20, currentCommand: "ssh", name: "gmktec-claude"),
            WindowInfo(id: WindowID(6), index: 7, isActive: false, activePane: PaneID(8), paneCount: 1,
                       width: 50, height: 20, currentCommand: "my_cmd", name: "it's ~ a name"),
        ])
    }

    @Test func paneState() {
        let reply = ControlReply(time: 0, number: 0, flags: 1, isError: false, lines: [Array("2 5 1 80 24".utf8)])
        #expect(PaneState(reply) == PaneState(cursorX: 2, cursorY: 5, alternateScreen: true, width: 80, height: 24))
    }
}
