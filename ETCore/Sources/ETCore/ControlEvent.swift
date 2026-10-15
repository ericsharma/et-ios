/// The reply to one command, framed by `%begin` and `%end` / `%error`.
public struct ControlReply: Sendable, Equatable {
    public var time: Int
    public var number: Int
    /// 1 when the command came from this control client, 0 for commands tmux
    /// ran on its own (for example the initial `attach-session`).
    public var flags: Int
    public var isError: Bool
    /// Body lines as raw bytes, without the trailing newline. Not escaped.
    public var lines: [[UInt8]]

    public init(time: Int, number: Int, flags: Int, isError: Bool, lines: [[UInt8]]) {
        self.time = time
        self.number = number
        self.flags = flags
        self.isError = isError
        self.lines = lines
    }

    public var isFromClient: Bool { flags & 1 == 1 }
    public var textLines: [String] { lines.map { String(decoding: $0, as: UTF8.self) } }
}

/// One line (or one reply block) of tmux control-mode output.
public enum ControlEvent: Sendable, Equatable {
    case reply(ControlReply)

    case output(pane: PaneID, data: [UInt8])
    case extendedOutput(pane: PaneID, ageMilliseconds: Int, data: [UInt8])
    case pause(pane: PaneID)
    case `continue`(pane: PaneID)
    case paneModeChanged(pane: PaneID)

    case windowAdd(WindowID)
    case windowClose(WindowID)
    case windowRenamed(WindowID, name: String)
    case unlinkedWindowAdd(WindowID)
    case unlinkedWindowClose(WindowID)
    case unlinkedWindowRenamed(WindowID, name: String)
    case windowPaneChanged(WindowID, pane: PaneID)
    case layoutChange(WindowID, layout: String, visibleLayout: String?, flags: String?)

    case sessionChanged(SessionID, name: String)
    case sessionRenamed(SessionID?, name: String)
    case sessionWindowChanged(SessionID, WindowID)
    case sessionsChanged
    case clientSessionChanged(client: String, SessionID, name: String)
    case clientDetached(client: String)

    case subscriptionChanged(name: String, value: String)
    case message(String)
    case configError(String)
    case exit(reason: String?)

    /// A `%` line this parser does not know, or a stray non-`%` line.
    case unknown(String)
}
