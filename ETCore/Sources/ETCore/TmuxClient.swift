/// A byte pipe to a `tmux -C` process: an SSH exec channel in the app, a
/// local `Process` in tests.
public protocol ControlChannel: Sendable {
    /// Bytes from tmux. Called once. Finishes when the channel closes.
    func incoming() -> AsyncThrowingStream<[UInt8], any Error>
    func write(_ bytes: [UInt8]) async throws
    func close() async
}

public enum TmuxError: Error, Equatable, Sendable {
    /// tmux answered with `%error`. `message` is the reply body.
    case commandFailed(command: String, message: [String])
    case disconnected
    /// Command lines must not contain newlines.
    case invalidCommand(String)
}

/// Sends commands to tmux, matches replies, and publishes notifications.
/// All tmux traffic goes through here (SPEC.md §4).
public actor TmuxClient {
    /// Notifications and pane output, in the order tmux sent them. Replies to
    /// commands are not included. Finishes on disconnect.
    public nonisolated let events: AsyncStream<ControlEvent>

    private let channel: any ControlChannel
    private let eventSink: AsyncStream<ControlEvent>.Continuation
    private let outbox: AsyncStream<[UInt8]>.Continuation
    private let outboxStream: AsyncStream<[UInt8]>
    private var parser = ControlParser()
    /// Commands waiting for a reply. tmux answers in order.
    private var pending: [(command: String, continuation: CheckedContinuation<ControlReply, any Error>?)] = []
    private var onError: (@Sendable (TmuxError) -> Void)?
    private var isClosed = false
    private var started = false

    public init(channel: any ControlChannel) {
        self.channel = channel
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (outboxStream, outbox) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts reading and writing. Call once.
    public func start() {
        guard !started else { return }
        started = true
        let channel = channel
        let outboxStream = outboxStream
        // One writer, fed in order, so command lines never interleave.
        Task {
            do {
                for await bytes in outboxStream { try await channel.write(bytes) }
            } catch {
                self.shutdown()
            }
        }
        Task {
            do {
                for try await chunk in channel.incoming() { self.receive(chunk) }
            } catch {}
            self.shutdown()
        }
    }

    /// Runs one tmux command and returns its reply. Throws
    /// `TmuxError.commandFailed` when tmux answers with `%error`.
    @discardableResult
    public func command(_ command: String) async throws -> ControlReply {
        guard !command.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw TmuxError.invalidCommand(command)
        }
        guard !isClosed else { throw TmuxError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((command, continuation))
            outbox.yield(Array((command + "\n").utf8))
        }
    }

    /// Queues a command without waiting for its reply. Order is kept with
    /// all other commands. Use for typing (`send-keys`), so keystrokes do
    /// not wait for round trips. A failure is reported through `onError`.
    public func post(_ command: String) {
        guard !isClosed, !command.contains(where: { $0 == "\n" || $0 == "\r" }) else { return }
        pending.append((command, nil))
        outbox.yield(Array((command + "\n").utf8))
    }

    /// Called when a posted command fails.
    public func setErrorHandler(_ handler: (@Sendable (TmuxError) -> Void)?) {
        onError = handler
    }

    /// Closes the control client. The tmux session keeps running.
    public func close() async {
        await channel.close()
        shutdown()
    }

    private func receive(_ chunk: [UInt8]) {
        for event in parser.feed(chunk) {
            switch event {
            case .reply(let reply):
                // flags 0: a command tmux ran itself (the initial attach).
                guard reply.isFromClient, !pending.isEmpty else { continue }
                let (command, continuation) = pending.removeFirst()
                if reply.isError {
                    let error = TmuxError.commandFailed(command: command, message: reply.textLines)
                    if let continuation { continuation.resume(throwing: error) } else { onError?(error) }
                } else {
                    continuation?.resume(returning: reply)
                }
            case .exit:
                eventSink.yield(event)
                shutdown()
            default:
                eventSink.yield(event)
            }
        }
    }

    private func shutdown() {
        guard !isClosed else { return }
        isClosed = true
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation?.resume(throwing: TmuxError.disconnected) }
        eventSink.finish()
        outbox.finish()
    }
}
