@preconcurrency import Citadel
import ETCore
import Foundation
import NIOCore
@preconcurrency import NIOSSH

public enum SSHConnectionError: Error, Sendable, Equatable {
    /// TCP or SSH handshake failed before the host key was checked.
    case unreachable(String)
    /// The server did not accept the app's key.
    case authenticationFailed
    /// Connected, but the SSH handshake or login did not finish in time.
    case timedOut
    /// The user declined a new host key.
    case hostKeyRejected
    /// The server's key differs from the pinned one. Never connect.
    case hostKeyChanged(pinned: HostKey, presented: HostKey)
    /// `output` is what the discovery script printed, for the debug log.
    case tmuxNotFound(output: String)
    case commandFailed(command: String, exitCode: Int, output: String)
}

/// Asked once for a server without a pinned host key. Return true to trust it.
public typealias HostKeyTrustHandler = @Sendable (HostKey) async -> Bool

public struct TmuxInstall: Sendable, Equatable {
    public var path: String
    /// For example "tmux 3.6a".
    public var version: String
    /// The TMUX_TMPDIR to use, or nil for tmux's default (/tmp). Found by
    /// looking for a live server, because a non-login SSH command may not
    /// have the TMUX_TMPDIR that interactive shells set (home-manager's
    /// secureSocket puts the socket under /run/user/<uid>).
    public var tmpDir: String?
}

public struct SessionInfo: Sendable, Equatable, Identifiable {
    public var id: SessionID
    public var name: String
    public var windowCount: Int
    public var attachedClients: Int
}

/// One SSH connection to a server. Runs short commands (tmux discovery,
/// session list) and opens the long-running control-mode channel.
public actor SSHConnection {
    public let config: ServerConfig
    /// The host key the user trusted during `connect`, if it was new. The
    /// caller saves it into `ServerConfig.hostKey`.
    public nonisolated let newlyTrustedHostKey: HostKey?
    private let client: SSHClient

    private init(config: ServerConfig, client: SSHClient, newlyTrustedHostKey: HostKey?) {
        self.config = config
        self.client = client
        self.newlyTrustedHostKey = newlyTrustedHostKey
    }

    public static func connect(
        _ config: ServerConfig,
        identity: SSHIdentity,
        trustNewHostKey: @escaping HostKeyTrustHandler,
        onAuthBanner: (@Sendable (String) -> Void)? = nil,
        timeout: Duration = .seconds(10)
    ) async throws -> SSHConnection {
        var config = config
        var newlyTrusted: HostKey?
        if config.hostKey == nil {
            // Citadel gives the whole login a fixed 10 s, which includes host
            // key validation. Fetch the key in a separate short connection and
            // ask the user with no clock running, then log in with it pinned.
            let presented = try await fetchHostKey(config, timeout: timeout)
            guard await trustNewHostKey(presented) else { throw SSHConnectionError.hostKeyRejected }
            config.hostKey = presented
            newlyTrusted = presented
        }

        let validator = PinningHostKeyValidator(pinned: config.hostKey!)
        let auth = PublicKeyAuthentication(user: config.user, key: identity.privateKey)
        var settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: { .custom(auth) },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(timeout.components.seconds)
        settings.loginTimeout = .seconds(timeout.components.seconds)
        // Servers like Tailscale SSH ("check" mode) hold the login and send an
        // approval URL as a banner; the timeout then grows to 5 minutes.
        settings.onUserAuthBanner = onAuthBanner
        do {
            let client = try await SSHClient.connect(to: settings)
            return SSHConnection(config: config, client: client, newlyTrustedHostKey: newlyTrusted)
        } catch {
            if let presented = validator.mismatch {
                throw SSHConnectionError.hostKeyChanged(pinned: config.hostKey!, presented: presented)
            }
            if auth.wasRejected { throw SSHConnectionError.authenticationFailed }
            if validator.matched { throw SSHConnectionError.timedOut }
            throw SSHConnectionError.unreachable(String(describing: error))
        }
    }

    /// Opens a connection only to read the server's host key, then drops it.
    static func fetchHostKey(_ config: ServerConfig, timeout: Duration) async throws -> HostKey {
        let recorder = HostKeyRecorder()
        do {
            let client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: .custom(PublicKeyAuthentication(user: config.user, key: SSHIdentity.software().privateKey)),
                hostKeyValidator: .custom(recorder),
                reconnect: .never,
                connectTimeout: .seconds(timeout.components.seconds)
            )
            try? await client.close()
        } catch {}
        guard let key = recorder.key else {
            throw SSHConnectionError.unreachable("no host key from \(config.host):\(config.port)")
        }
        return key
    }

    public func close() async {
        try? await client.close()
    }

    // MARK: - Commands

    private static let exitMarker = "__ET_EXIT__"

    /// Runs `command` with `sh` and returns stdout and stderr together, plus
    /// the exit code. Wrapped in `sh -c` so it works whatever the login shell is.
    public func run(_ command: String) async throws -> (output: String, exitCode: Int) {
        // Subshell, so an `exit` inside `command` still reaches the marker.
        let script = "( \(command) ) 2>&1; echo \"\(Self.exitMarker)$?\""
        // Absolute path: some servers (Tailscale SSH) run commands with a
        // minimal PATH.
        let buffer = try await client.executeCommand("/bin/sh -c \(shQuote(script))")
        var output = String(buffer: buffer)
        guard let range = output.range(of: Self.exitMarker, options: .backwards) else {
            return (output, -1)
        }
        let code = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        output.removeSubrange(range.lowerBound...)
        return (output, code)
    }

    /// Writes `data` to the absolute `path` on the server. Uses SFTP, and
    /// falls back to base64 chunks over plain commands if the server has no
    /// SFTP subsystem.
    public func upload(_ data: Data, to path: String) async throws {
        do {
            let sftp = try await client.openSFTP()
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                try await file.write(ByteBuffer(bytes: data))
            }
            try? await sftp.close()
        } catch {
            let encoded = data.base64EncodedString()
            let chunk = 48_000
            var start = encoded.startIndex
            var first = true
            while start < encoded.endIndex {
                let end = encoded.index(start, offsetBy: chunk, limitedBy: encoded.endIndex) ?? encoded.endIndex
                let redirect = first ? ">" : ">>"
                let (output, code) = try await run("printf '%s' '\(encoded[start..<end])' \(redirect) \(shQuote(path + ".b64"))")
                guard code == 0 else { throw SSHConnectionError.commandFailed(command: "upload", exitCode: code, output: output) }
                start = end
                first = false
            }
            let decode = "base64 -d \(shQuote(path + ".b64")) > \(shQuote(path)) && rm -f \(shQuote(path + ".b64"))"
            let (output, code) = try await run(decode)
            guard code == 0 else { throw SSHConnectionError.commandFailed(command: "upload", exitCode: code, output: output) }
        }
    }

    /// Common tmux locations, tried after `command -v` in a plain and a login
    /// shell. Non-interactive SSH often has a short PATH (macOS: no Homebrew).
    static let tmuxCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
        "/run/current-system/sw/bin/tmux",
        "/etc/profiles/per-user/$USER/bin/tmux",
        "$HOME/.nix-profile/bin/tmux",
        "/snap/bin/tmux",
    ]

    /// Finds tmux and its socket directory (SPEC.md §2.1). Uses
    /// `config.tmuxPath` if set.
    public func findTmux() async throws -> TmuxInstall {
        let candidates = config.tmuxPath.map { [shQuote($0)] } ?? (
            ["\"$(command -v tmux 2>/dev/null)\"",
             "\"$(\"${SHELL:-sh}\" -lc 'command -v tmux' 2>/dev/null | tail -n 1)\""]
            + Self.tmuxCandidates.map { "\"\($0)\"" })
        let socket = config.socketName.map { shQuote($0) } ?? "default"
        // Prints: path, version, then "tmpdir:<dir>". <dir> is where a server
        // answers; failing that, the login shell's TMUX_TMPDIR (where a new
        // server should go); failing that, empty (tmux's default).
        let script = """
            for p in \(candidates.joined(separator: " ")); do \
            if [ -n "$p" ] && [ -x "$p" ]; then \
            echo "$p"; "$p" -V; \
            uid=$(id -u); \
            lt=$("${SHELL:-sh}" -lc 'printf "%s" "$TMUX_TMPDIR"' 2>/dev/null | tail -n 1); \
            for d in "$TMUX_TMPDIR" "$lt" "$XDG_RUNTIME_DIR" "/run/user/$uid" /tmp; do \
            if [ -n "$d" ] && [ -S "$d/tmux-$uid/\(socket)" ] && \
            TMUX_TMPDIR="$d" "$p" -L \(socket) list-sessions >/dev/null 2>&1; then \
            echo "tmpdir:$d"; exit 0; fi; done; \
            echo "tmpdir:$lt"; exit 0; fi; done; exit 127
            """
        let (output, code) = try await run(script)
        let lines = output.split(separator: "\n").map(String.init)
        guard code == 0, let tmpLine = lines.last(where: { $0.hasPrefix("tmpdir:") }),
              let index = lines.lastIndex(of: tmpLine), index >= 2 else {
            throw SSHConnectionError.tmuxNotFound(output: "exit \(code): \(output)")
        }
        let dir = String(tmpLine.dropFirst("tmpdir:".count))
        return TmuxInstall(path: lines[index - 2], version: lines[index - 1], tmpDir: dir.isEmpty ? nil : dir)
    }

    /// Sessions on the server. Empty when no tmux server is running.
    public func listSessions(tmux: TmuxInstall) async throws -> [SessionInfo] {
        let format = "#{session_id} #{session_windows} #{session_attached} #{session_name}"
        let command = tmuxCommand(tmux) + " list-sessions -F \(shQuote(format))"
        let (output, code) = try await run(command)
        if code != 0 {
            if output.contains("no server running") || output.contains("error connecting to")
                || output.contains("No such file or directory") {
                return []
            }
            throw SSHConnectionError.commandFailed(command: command, exitCode: code, output: output)
        }
        return output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let id = SessionID(token: f[0]),
                  let windows = Int(f[1]), let attached = Int(f[2]) else { return nil }
            return SessionInfo(id: id, name: String(f[3]), windowCount: windows, attachedClients: attached)
        }
    }

    public enum ControlTarget: Sendable {
        /// Attach to an existing session by exact name.
        case attach(String)
        /// Attach, or create the session if it does not exist.
        case attachOrCreate(String)
    }

    /// Opens `tmux -C` on an exec channel without a PTY (SPEC.md §2.1).
    public func openControlChannel(tmux: TmuxInstall, target: ControlTarget) async throws -> SSHControlChannel {
        let args = switch target {
        case .attach(let name): "-C attach-session -t \(shQuote("=" + name))"
        case .attachOrCreate(let name): "-C new-session -A -s \(shQuote(name))"
        }
        return try await SSHControlChannel.open(client: client, command: "exec " + tmuxCommand(tmux) + " " + args)
    }

    /// `env` works the same in sh, bash and fish, and composes with `exec`.
    private func tmuxCommand(_ tmux: TmuxInstall) -> String {
        var command = shQuote(tmux.path)
        if let dir = tmux.tmpDir { command = "env TMUX_TMPDIR=\(shQuote(dir)) " + command }
        if let socket = config.socketName { command += " -L \(shQuote(socket))" }
        return command
    }
}

/// Quotes for POSIX sh (and fish): single quotes, `'` written as `'\''`.
func shQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

// MARK: - Authentication delegates

/// Offers the app's key once. No passwords, no keyboard-interactive (SPEC.md §9).
final class PublicKeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private let key: NIOSSHPrivateKey
    private let lock = NSLock()
    private var offered = false
    private var rejected = false

    init(user: String, key: NIOSSHPrivateKey) {
        self.user = user
        self.key = key
    }

    /// True when the server was offered the key and asked for another method.
    var wasRejected: Bool { lock.withLock { rejected } }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let first = lock.withLock { () -> Bool in
            if offered { rejected = true }
            defer { offered = true }
            return !offered
        }
        guard first, availableMethods.contains(.publicKey) else {
            lock.withLock { rejected = true }
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Accepts only the pinned host key (SPEC.md §9).
final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let pinned: HostKey
    private let lock = NSLock()
    private var _matched = false
    private var _mismatch: HostKey?

    init(pinned: HostKey) {
        self.pinned = pinned
    }

    var matched: Bool { lock.withLock { _matched } }
    /// The key the server presented, if it differs from the pinned one.
    var mismatch: HostKey? { lock.withLock { _mismatch } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKey(hostKey)
        if presented == pinned {
            lock.withLock { _matched = true }
            validationCompletePromise.succeed(())
        } else {
            lock.withLock { _mismatch = presented }
            validationCompletePromise.fail(SSHConnectionError.hostKeyChanged(pinned: pinned, presented: presented))
        }
    }
}

/// Records the host key and stops the handshake. Used for trust on first use.
final class HostKeyRecorder: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _key: HostKey?
    var key: HostKey? { lock.withLock { _key } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        lock.withLock { _key = HostKey(hostKey) }
        validationCompletePromise.fail(SSHConnectionError.hostKeyRejected)
    }
}
