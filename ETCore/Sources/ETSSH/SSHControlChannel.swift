@preconcurrency import Citadel
import ETCore
import Foundation
import NIOCore

/// `tmux -C` running on an SSH exec channel. Implements `ControlChannel`
/// for `TmuxClient`.
public final class SSHControlChannel: ControlChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private let stream: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    /// tmux's stderr, for the debug log. tmux -C writes errors there before
    /// control mode starts (for example "can't find session").
    public let stderr: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    private init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
        (stderr, stderrContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(200))
    }

    /// Starts `command` and returns once the channel can be written to.
    static func open(client: SSHClient, command: String) async throws -> SSHControlChannel {
        let channel = SSHControlChannel()
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            channel.start(client: client, command: command, ready: ready)
        }
        return channel
    }

    private func start(client: SSHClient, command: String, ready: CheckedContinuation<Void, any Error>) {
        let readyOnce = Once(ready)
        let task = Task { [continuation, stderrContinuation] in
            do {
                try await client.withExec(command) { inbound, outbound in
                    self.lock.withLock { self.writer = outbound }
                    readyOnce.resume()
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer):
                            continuation.yield(Array(buffer.readableBytesView))
                        case .stderr(let buffer):
                            stderrContinuation.yield(String(buffer: buffer))
                        }
                    }
                }
                continuation.finish()
            } catch {
                readyOnce.resume(throwing: error)
                continuation.finish(throwing: error)
            }
            stderrContinuation.finish()
            self.lock.withLock { self.writer = nil }
        }
        lock.withLock { self.task = task }
    }

    public func incoming() -> AsyncThrowingStream<[UInt8], any Error> {
        stream
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let writer = lock.withLock({ writer }) else { throw TmuxError.disconnected }
        try await writer.write(ByteBuffer(bytes: bytes))
    }

    /// Closes the channel. tmux sees EOF and detaches; the session keeps running.
    public func close() async {
        let task = lock.withLock { self.task }
        task?.cancel()
        await task?.value
    }
}

/// Resumes a continuation at most once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(throwing error: (any Error)? = nil) {
        let c = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }
}
