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
