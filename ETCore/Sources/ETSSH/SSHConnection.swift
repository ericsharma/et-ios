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
    /// The user declined a new host key.
    case hostKeyRejected
    /// The server's key differs from the pinned one. Never connect.
    case hostKeyChanged(pinned: HostKey, presented: HostKey)
    case tmuxNotFound
    case commandFailed(command: String, exitCode: Int, output: String)
}

/// Asked once for a server without a pinned host key. Return true to trust it.
public typealias HostKeyTrustHandler = @Sendable (HostKey) async -> Bool

public struct TmuxInstall: Sendable, Equatable {
    public var path: String
    /// For example "tmux 3.6a".
    public var version: String
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
        timeout: Duration = .seconds(10)
    ) async throws -> SSHConnection {
        let validator = PinningHostKeyValidator(pinned: config.hostKey, trust: trustNewHostKey)
        let auth = PublicKeyAuthentication(user: config.user, key: identity.privateKey)
        do {
            let client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: .custom(auth),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(timeout.components.seconds)
            )
            return SSHConnection(config: config, client: client, newlyTrustedHostKey: validator.outcome?.trustedKey)
        } catch {
            switch validator.outcome {
            case .changed(let presented): throw SSHConnectionError.hostKeyChanged(pinned: config.hostKey!, presented: presented)
            case .rejected: throw SSHConnectionError.hostKeyRejected
            case .matched, .trusted: throw SSHConnectionError.authenticationFailed
            case nil: throw SSHConnectionError.unreachable(String(describing: error))
            }
        }
    }

    public func close() async {
        try? await client.close()
    }

    // MARK: - Commands

    private static let exitMarker = "__ET_EXIT__"

    /// Runs `command` with `sh` and returns stdout and stderr together, plus
    /// the exit code. Wrapped in `sh -c` so it works whatever the login shell is.
    public func run(_ command: String) async throws -> (output: String, exitCode: Int) {
        let script = "\(command) 2>&1; echo \"\(Self.exitMarker)$?\""
        let buffer = try await client.executeCommand("sh -c \(shQuote(script))")
        var output = String(buffer: buffer)
        guard let range = output.range(of: Self.exitMarker, options: .backwards) else {
            return (output, -1)
        }
        let code = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        output.removeSubrange(range.lowerBound...)
        return (output, code)
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

    /// Finds tmux (SPEC.md §2.1). Uses `config.tmuxPath` if set.
    public func findTmux() async throws -> TmuxInstall {
        let candidates = config.tmuxPath.map { [shQuote($0)] } ?? (
            ["\"$(command -v tmux 2>/dev/null)\"",
             "\"$(\"${SHELL:-sh}\" -lc 'command -v tmux' 2>/dev/null | tail -n 1)\""]
            + Self.tmuxCandidates.map { "\"\($0)\"" })
        let script = "for p in \(candidates.joined(separator: " ")); do " +
            "if [ -n \"$p\" ] && [ -x \"$p\" ]; then echo \"$p\"; \"$p\" -V; exit 0; fi; done; exit 127"
        let (output, code) = try await run(script)
        let lines = output.split(separator: "\n").map(String.init)
        guard code == 0, lines.count >= 2 else { throw SSHConnectionError.tmuxNotFound }
        return TmuxInstall(path: lines[lines.count - 2], version: lines[lines.count - 1])
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

    private func tmuxCommand(_ tmux: TmuxInstall) -> String {
        var command = shQuote(tmux.path)
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

    init(user: String, key: NIOSSHPrivateKey) {
        self.user = user
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let first = lock.withLock { () -> Bool in
            defer { offered = true }
            return !offered
        }
        guard first, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// Trust on first use, then pin (SPEC.md §9).
final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    enum Outcome {
        case matched
        case trusted(HostKey)
        case rejected
        case changed(HostKey)

        var trustedKey: HostKey? {
            if case .trusted(let key) = self { key } else { nil }
        }
    }

    private let pinned: HostKey?
    private let trust: HostKeyTrustHandler
    private let lock = NSLock()
    private var _outcome: Outcome?

    var outcome: Outcome? { lock.withLock { _outcome } }

    init(pinned: HostKey?, trust: @escaping HostKeyTrustHandler) {
        self.pinned = pinned
        self.trust = trust
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKey(hostKey)
        if let pinned {
            if pinned == presented {
                record(.matched)
                validationCompletePromise.succeed(())
            } else {
                record(.changed(presented))
                validationCompletePromise.fail(SSHConnectionError.hostKeyChanged(pinned: pinned, presented: presented))
            }
            return
        }
        let trust = trust
        Task {
            if await trust(presented) {
                self.record(.trusted(presented))
                validationCompletePromise.succeed(())
            } else {
                self.record(.rejected)
                validationCompletePromise.fail(SSHConnectionError.hostKeyRejected)
            }
        }
    }

    private func record(_ outcome: Outcome) {
        lock.withLock { _outcome = outcome }
    }
}
