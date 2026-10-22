import ETCore
import Foundation

public enum ControlTarget: Sendable {
    /// Attach to an existing session by exact name.
    case attach(String)
    /// Attach, or create the session if it does not exist.
    case attachOrCreate(String)
}

/// A `tmux -C` byte pipe plus tmux's stderr, for the debug log.
public struct OpenedControl: Sendable {
    public var channel: any ControlChannel
    public var stderr: AsyncStream<String>

    public init(channel: any ControlChannel, stderr: AsyncStream<String>) {
        self.channel = channel
        self.stderr = stderr
    }
}

/// Errors from transports other than SSH, mapped so `SessionController`
/// does not depend on their types.
public enum HostError: Error, Sendable, Equatable {
    /// This device is not paired with the machine, or it was revoked.
    case notPaired
    case unreachable(String)
    case closed(String)
    case other(String)
}

/// What `SessionController` needs from a connected machine: SSH
/// (`SSHConnection`) or etd over iroh (`IrohHost`).
public protocol HostConnection: AnyObject, Sendable {
    func findTmux() async throws -> TmuxInstall
    /// Sessions on the server. Empty when no tmux server is running.
    func listSessions(tmux: TmuxInstall) async throws -> [SessionInfo]
    func openControlChannel(tmux: TmuxInstall, target: ControlTarget) async throws -> OpenedControl
    /// Runs a shell script; stdout and stderr together, plus the exit code.
    func run(_ command: String) async throws -> (output: String, exitCode: Int)
    func upload(_ data: Data, to path: String) async throws
    func close() async
}
