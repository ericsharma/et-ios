#if os(macOS)
import ETCore
@testable import ETSSH
import Foundation
import Testing

/// Runs against a private `sshd` on 127.0.0.1, started as the current user
/// with its own host key and authorized_keys in a temp directory. Never
/// touches ~/.ssh or the system sshd.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SSHConnectionTests {
    static let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/run/current-system/sw/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test func trustOnFirstUseThenPin() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }

        let offered = Recorded<HostKey>()
        let connection = try await SSHConnection.connect(sshd.config, identity: sshd.identity) { key in
            offered.set(key)
            return true
        }
        let trusted = try #require(connection.newlyTrustedHostKey)
        #expect(offered.value == trusted)
        #expect(trusted.algorithm == "ssh-ed25519")
        #expect(trusted.fingerprint == sshd.hostKeyFingerprint)
        await connection.close()

        // Pinned: connects without asking.
        var pinned = sshd.config
        pinned.hostKey = trusted
        let again = try await SSHConnection.connect(pinned, identity: sshd.identity) { _ in
            Issue.record("asked to trust a pinned key")
            return false
        }
        #expect(again.newlyTrustedHostKey == nil)
        await again.close()
    }

    @Test func changedHostKeyStops() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        var config = sshd.config
        config.hostKey = HostKey(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        await #expect {
            try await SSHConnection.connect(config, identity: sshd.identity) { _ in true }
        } throws: { error in
            guard case SSHConnectionError.hostKeyChanged(let pinned, let presented) = error else { return false }
            return pinned == config.hostKey && presented.fingerprint == sshd.hostKeyFingerprint
        }
    }

    @Test func declinedHostKey() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        await #expect(throws: SSHConnectionError.hostKeyRejected) {
            try await SSHConnection.connect(sshd.config, identity: sshd.identity) { _ in false }
        }
    }

    @Test func unknownClientKey() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        await #expect(throws: SSHConnectionError.authenticationFailed) {
            try await SSHConnection.connect(sshd.config, identity: .software()) { _ in true }
        }
    }

    @Test func unreachable() async throws {
        let config = ServerConfig(host: "127.0.0.1", port: 1, user: NSUserName())
        await #expect {
            try await SSHConnection.connect(config, identity: .software()) { _ in true }
        } throws: { error in
            if case SSHConnectionError.unreachable = error { true } else { false }
        }
    }

    @Test func runReturnsOutputAndExitCode() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connection = try await SSHConnection.connect(sshd.config, identity: sshd.identity) { _ in true }
        let ok = try await connection.run("printf '%s\\n' \(shQuote("it's \"quoted\" $HOME"))")
        #expect(ok.output == "it's \"quoted\" $HOME\n")
        #expect(ok.exitCode == 0)
        let failed = try await connection.run("echo to-stderr >&2; exit 3")
        #expect(failed.output == "to-stderr\n")
        #expect(failed.exitCode == 3)
        await connection.close()
    }

    @Test(.enabled(if: tmux != nil)) func findsTmuxOutsideNonInteractivePath() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        let connection = try await SSHConnection.connect(sshd.config, identity: sshd.identity) { _ in true }
        let install = try await connection.findTmux()
        #expect(install.path == Self.tmux)
        #expect(install.version.hasPrefix("tmux "))
        await connection.close()

        var wrong = sshd.config
        wrong.tmuxPath = "/nonexistent/tmux"
        let c2 = try await SSHConnection.connect(wrong, identity: sshd.identity) { _ in true }
        await #expect(throws: SSHConnectionError.tmuxNotFound) { try await c2.findTmux() }
        await c2.close()
    }

    @Test(.enabled(if: tmux != nil)) func sessionsAndControlModeOverSSH() async throws {
        let sshd = try LocalSSHD()
        defer { sshd.stop() }
        var config = sshd.config
        config.socketName = "et-ssh-test-\(UUID().uuidString.prefix(8))"
        defer { runTmux(socket: config.socketName!, ["kill-server"]) }

        let connection = try await SSHConnection.connect(config, identity: sshd.identity) { _ in true }
        let install = try await connection.findTmux()
        #expect(try await connection.listSessions(tmux: install).isEmpty)

        // Create a session through control mode, then see it listed.
        let channel = try await connection.openControlChannel(tmux: install, target: .attachOrCreate("et main"))
        let client = TmuxClient(channel: channel)
        await client.start()
        let windows = TmuxCommand.parseWindowList(try await client.command(TmuxCommand.listWindows()))
        #expect(windows.count == 1)
        let sessions = try await connection.listSessions(tmux: install)
        #expect(sessions.map(\.name) == ["et main"])
        #expect(sessions.first?.attachedClients == 1)

        // Typing round trip over SSH.
        let pane = try #require(windows.first?.activePane)
        let output = OutputCollector(client.events, pane: pane)
        for c in TmuxCommand.sendKeys(pane: pane, bytes: Array("echo over-ssh-$((6*7))\r".utf8)) {
            await client.post(c)
        }
        try await output.waitFor("over-ssh-42")

        // Closing the channel detaches; the session keeps running.
        await client.close()
        try await Task.sleep(for: .milliseconds(300))
        let after = try await connection.listSessions(tmux: install)
        #expect(after.map(\.name) == ["et main"])
        #expect(after.first?.attachedClients == 0)

        // Attaching to a session that does not exist ends the channel.
        let missing = try await connection.openControlChannel(tmux: install, target: .attach("nope"))
        let missingClient = TmuxClient(channel: missing)
        await missingClient.start()
        await #expect(throws: TmuxError.self) { try await missingClient.command("list-windows") }
        await connection.close()
    }
}

// MARK: - Helpers

final class Recorded<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? { lock.withLock { _value } }
    func set(_ v: T) { lock.withLock { _value = v } }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    init(_ events: AsyncStream<ControlEvent>, pane: PaneID) {
        Task {
            for await e in events {
                if case .output(pane, let data) = e { self.lock.withLock { self.bytes += data } }
            }
        }
    }

    func waitFor(_ text: String) async throws {
        for _ in 0..<100 {
            if lock.withLock({ String(decoding: bytes, as: UTF8.self).contains(text) }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("no output containing \(text)")
    }
}

@discardableResult
func runProcess(_ path: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func runTmux(socket: String, _ args: [String]) {
    guard let tmux = SSHConnectionTests.tmux else { return }
    _ = try? runProcess(tmux, ["-L", socket] + args)
}

/// A private sshd for one test.
final class LocalSSHD: @unchecked Sendable {
    let directory: URL
    let port: Int
    let identity = SSHIdentity.software()
    let hostKeyFingerprint: String
    private let process = Process()

    var config: ServerConfig {
        ServerConfig(name: "test", host: "127.0.0.1", port: port, user: NSUserName())
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("et-sshd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostKey = directory.appendingPathComponent("host_key").path
        try runProcess("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        hostKeyFingerprint = String(try runProcess("/usr/bin/ssh-keygen", ["-l", "-f", hostKey + ".pub"])
            .split(separator: " ")[1])
        try (identity.openSSHPublicKey() + "\n")
            .write(to: directory.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)

        port = Int.random(in: 20000..<40000)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        AuthorizedKeysFile \(directory.appendingPathComponent("authorized_keys").path)
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(directory.appendingPathComponent("sshd.pid").path)
        """
        let configPath = directory.appendingPathComponent("sshd_config")
        try config.write(to: configPath, atomically: true, encoding: .utf8)

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", configPath.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        try waitForPort()
    }

    private func waitForPort() throws {
        for _ in 0..<50 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if ok { return }
            usleep(100_000)
        }
        throw CocoaError(.fileReadUnknown)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
