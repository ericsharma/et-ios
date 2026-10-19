import Foundation
import Testing
@testable import ETCore

struct TranscriptTests {
    static let lines = [
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"},"isMeta":true,"uuid":"m1","timestamp":"2026-10-19T19:21:52.230Z"}"#,
        #"{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"c1","timestamp":"2026-10-19T19:21:53.230Z"}"#,
        #"{"parentUuid":"b","isSidechain":false,"type":"user","message":{"role":"user","content":"Read the E.T. app and say \"hi\""},"uuid":"u1","timestamp":"2026-10-19T19:22:00.000Z"}"#,
        #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"m","id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"Reading now."}]},"type":"assistant","uuid":"a1","timestamp":"2026-10-19T19:22:01.000Z"}"#,
        #"{"parentUuid":"a1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent noise"}]},"type":"assistant","uuid":"s1"}"#,
        #"{"parentUuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Found it."}]},"type":"assistant","uuid":"a2"}"#,
        #"{"parentUuid":"a2","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"Second prompt with an image"},{"type":"image","source":{}}]},"uuid":"u2"}"#,
    ]

    @Test func parsesPromptsAndJoinsReplies() {
        let turns = Transcript.parse(lines: Self.lines)
        #expect(turns.map(\.id) == ["u1", "u2"])
        #expect(turns[0].prompt == #"Read the E.T. app and say "hi""#)
        #expect(turns[0].reply == "Reading now.\n\nFound it.")
        #expect(turns[0].timestamp != nil)
        #expect(turns[1].prompt == "Second prompt with an image")
        #expect(turns[1].reply.isEmpty)
    }

    @Test func needleStopsBeforeEscapedCharacters() {
        #expect(Transcript.needle(fromPrompt: "Read the E.T. app and say \"hi\"") == "Read the E.T. app and say ")
        #expect(Transcript.needle(fromPrompt: "ok") == nil)
        #expect(Transcript.needle(fromPrompt: "Let's go with   option\n one mac-mini can handle it, really") == "Let's go with option one mac-mini can ha")
    }

    @Test func renderShortensOldRepliesToFit() {
        let long = String(repeating: "a", count: 5000)
        let turns = [Transcript.Turn(id: "1", prompt: "p1", reply: long), Transcript.Turn(id: "2", prompt: "p2", reply: "short")]
        let text = Transcript.render(turns, budget: 2000)
        #expect(text.count <= 2000)
        #expect(text.contains("[…]"))
        #expect(text.hasSuffix("Claude:\nshort"))
    }

    /// The real script, against a fake HOME with two transcripts.
    @Test func fetchScriptPicksTheTranscriptWithThePrompt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("et-transcript-\(UUID().uuidString)")
        let project = home.appendingPathComponent(".claude/projects/-Users-x")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let wanted = project.appendingPathComponent("wanted.jsonl")
        try (Self.lines.joined(separator: "\n") + "\n").write(to: wanted, atomically: true, encoding: .utf8)
        // Newer, but without the prompt.
        let other = project.appendingPathComponent("other.jsonl")
        try (Self.lines[1] + "\n").write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: other.path)

        func run(_ needle: String?) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", Transcript.fetchScript(needle: needle)]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        let found = try #require(Transcript.decodeFetchOutput(try run("Read the E.T. app and say ")))
        #expect(found.path.hasSuffix("wanted.jsonl"))
        #expect(Transcript.parse(lines: found.lines).map(\.id) == ["u1", "u2"])
        // Without a needle: the newest.
        let newest = try #require(Transcript.decodeFetchOutput(try run(nil)))
        #expect(newest.path.hasSuffix("other.jsonl"))
    }
}
