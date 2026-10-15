#if os(macOS)
import Foundation
import Testing
@testable import ETCore

/// Drives `TmuxClient` against a throwaway local tmux server over a pipe, no
/// SSH (SPEC.md §10.1). Uses its own socket, never the user's sessions.
@Suite(.serialized) struct TmuxClientIntegrationTests {
    static let tmux = ["/opt/homebrew/bin/tmux", "/run/current-system/sw/bin/tmux", "/usr/local/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: tmux != nil, "tmux not installed"), .timeLimit(.minutes(1)))
    func windowLifecycleAndTyping() async throws {
        let server = try TestServer()
        defer { server.kill() }

        let client = TmuxClient(channel: try ProcessChannel(tmux: server.tmux, socket: server.socket, session: "et"))
        await client.start()
        let recorder = EventRecorder(client.events)

        let windows = TmuxCommand.parseWindowList(try await client.command(TmuxCommand.listWindows()))
        #expect(windows.map(\.name) == ["trigkey"])
        let pane = try #require(windows.first?.activePane)

        // Window added, renamed, closed: each shows up as a notification.
        let created = try #require(TmuxCommand.parseNewWindow(try await client.command(TmuxCommand.newWindow(name: "gm #1"))))
        try await recorder.waitFor(.windowAdd(created.0))
        try await client.command(TmuxCommand.renameWindow(created.0, to: "gmktec"))
        try await recorder.waitFor(.windowRenamed(created.0, name: "gmktec"))
        let names = TmuxCommand.parseWindowList(try await client.command(TmuxCommand.listWindows())).map(\.name)
        #expect(names == ["trigkey", "gmktec"])
        try await client.command(TmuxCommand.killWindow(created.0))
        try await recorder.waitFor { event in
            event == .windowClose(created.0) || event == .unlinkedWindowClose(created.0)
        }

        // send-keys round trip: typed bytes come back as %output.
        for c in TmuxCommand.sendKeys(pane: pane, bytes: Array("echo et-\u{e9}-$((6*7))\r".utf8), chunkSize: 5) {
            await client.post(c)
        }
        try await recorder.waitForOutput(pane: pane, containing: "et-\u{e9}-42")

        let history = try await client.command(TmuxCommand.captureHistory(pane: pane, lines: 100))
        #expect(history.textLines.contains { $0.contains("et-\u{e9}-42") })

        let state = try #require(PaneState(try await client.command(TmuxCommand.paneState(pane: pane))))
        #expect(state.alternateScreen == false)

        try await client.command(TmuxCommand.refreshClientSize(columns: 40, rows: 12))
        let resized = TmuxCommand.parseWindowList(try await client.command(TmuxCommand.listWindows()))
        #expect(resized.first.map { ($0.width, $0.height) } ?? (0, 0) == (40, 12))

        // Errors come back as thrown commandFailed, and the queue stays in sync.
        await #expect(throws: TmuxError.self) { try await client.command("no-such-command") }
        await #expect(throws: TmuxError.self) { try await client.command(TmuxCommand.captureAlternateScreen(pane: pane)) }
        #expect(try await client.command("display-message -p hello").textLines == ["hello"])

        await client.close()
        await #expect(throws: TmuxError.disconnected) { try await client.command("list-windows") }
    }

    @Test(.enabled(if: tmux != nil, "tmux not installed"), .timeLimit(.minutes(1)))
    func serverExitFailsPendingAndEndsEvents() async throws {
        let server = try TestServer()
        let client = TmuxClient(channel: try ProcessChannel(tmux: server.tmux, socket: server.socket, session: "et"))
        await client.start()
        _ = try await client.command("list-windows")
        server.kill()
        var sawExit = false
        for await event in client.events {
            if case .exit = event { sawExit = true }
        }
        #expect(sawExit)
        await #expect(throws: TmuxError.disconnected) { try await client.command("list-windows") }
    }
}

/// A tmux server on a private socket with one session "et", window "trigkey".
struct TestServer {
    let tmux: String
    let socket = "et-test-\(UUID().uuidString.prefix(8))"

    init() throws {
        tmux = try #require(TmuxClientIntegrationTests.tmux)
        try run(["-u", "-f", "/dev/null", "new-session", "-d", "-s", "et", "-n", "trigkey", "-x", "80", "-y", "24",
                 "-e", "LC_ALL=en_US.UTF-8", "/bin/sh"])
    }

    func kill() { try? run(["kill-server"]) }

    private func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-L", socket] + args
        try p.run()
        p.waitUntilExit()
    }
}

/// Runs `tmux -C attach` as a child process, like the SSH exec channel would.
final class ProcessChannel: ControlChannel, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(tmux: String, socket: String, session: String) throws {
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-L", socket, "-C", "attach-session", "-t", session]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func incoming() -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(Array(data))
                }
            }
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        try input.fileHandleForWriting.write(contentsOf: Data(bytes))
    }

    func close() async {
        try? input.fileHandleForWriting.close()
    }
}

/// Collects client events so tests can wait for one to arrive.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ControlEvent] = []

    init(_ stream: AsyncStream<ControlEvent>) {
        Task { for await e in stream { self.lock.withLock { self.events.append(e) } } }
    }

    func waitFor(_ expected: ControlEvent) async throws {
        try await waitFor { $0 == expected }
    }

    func waitFor(_ match: @escaping (ControlEvent) -> Bool) async throws {
        try await poll { $0.contains(where: match) }
    }

    func waitForOutput(pane: PaneID, containing text: String) async throws {
        try await poll { events in
            let bytes = events.flatMap { e -> [UInt8] in if case .output(pane, let d) = e { d } else { [] } }
            return String(decoding: bytes, as: UTF8.self).contains(text)
        }
    }

    private func poll(_ done: ([ControlEvent]) -> Bool) async throws {
        for _ in 0..<100 {
            if lock.withLock({ done(events) }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out; events: \(lock.withLock { events })")
    }
}
#endif
