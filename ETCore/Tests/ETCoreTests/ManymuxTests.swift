import Testing
@testable import ETCore

@Suite struct ManymuxTests {
    @Test func idleLabels() {
        #expect(Manymux.idleLabel(seconds: 0) == "now")
        #expect(Manymux.idleLabel(seconds: 45) == "45s")
        #expect(Manymux.idleLabel(seconds: 750) == "12m")
        #expect(Manymux.idleLabel(seconds: 3 * 3600 + 5) == "3h")
        #expect(Manymux.idleLabel(seconds: 2 * 86400) == "2d")
    }

    @Test func splitCommand() {
        #expect(Manymux.splitCommand("claude") == ["claude"])
        #expect(Manymux.splitCommand("  vim  \"my file\" ") == ["vim", "my file"])
        #expect(Manymux.splitCommand("sh -c 'echo $HOME; ls'") == ["sh", "-c", "echo $HOME; ls"])
        #expect(Manymux.splitCommand(#"a\ b "" c"#) == ["a b", "", "c"])
        #expect(Manymux.splitCommand("   ") == [])
    }

    @Test func programName() {
        #expect(Manymux.programName("/usr/bin/claude --resume") == "claude")
        #expect(Manymux.programName("bash") == "bash")
        #expect(Manymux.programName("") == "")
    }
}

@Suite struct MmCheckpointTests {
    static let show = """
    6 sessions, saved 3m ago
    shell a login shell in /home/eric
    claude @ws claude in /home/eric/nixos-config
      claude --continue
    gmktec/shell a login shell in /home/eric
    mac-mini/claude claude in /Users/ericsharma/tmux-ios
      claude --continue
    """

    @Test func parsesTargets() throws {
        let checkpoint = try #require(MmCheckpoint(show: Self.show))
        #expect(checkpoint.savedAgo == "3m")
        #expect(checkpoint.targets == ["shell", "claude", "gmktec/shell", "mac-mini/claude"])
        #expect(checkpoint.missing(running: ["shell", "claude", "mac-mini/claude"]) == ["gmktec/shell"])
    }

    @Test func colouredAndEmpty() throws {
        let coloured = "\u{1B}[2m2 sessions, saved 1h ago\u{1B}[0m\n\u{1B}[1mgmktec/x\u{1B}[0m htop \u{1B}[2min /\u{1B}[0m\n"
        #expect(MmCheckpoint(show: coloured)?.targets == ["gmktec/x"])
        #expect(MmCheckpoint(show: "nothing has been checkpointed; `mm checkpoint save` writes one\n") == nil)
    }
}
