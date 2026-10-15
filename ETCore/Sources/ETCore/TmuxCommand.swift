/// Builds the tmux command lines the app sends (SPEC.md §2.3), and parses
/// their replies. Pure functions, no I/O.
public enum TmuxCommand {
    /// Quotes `text` as one tmux argument. tmux single quotes are literal; a
    /// quote inside is written as `'\''`, as in sh.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Quotes a window name. `new-window -n` and `rename-window` expand
    /// formats, so `#` is doubled to keep it literal.
    public static func quoteName(_ name: String) -> String {
        quote(name.replacingOccurrences(of: "#", with: "##"))
    }

    /// `send-keys -H` commands that type `bytes` into `pane`, split so no
    /// single command line gets too long.
    public static func sendKeys(pane: PaneID, bytes: [UInt8], chunkSize: Int = 256) -> [String] {
        stride(from: 0, to: bytes.count, by: chunkSize).map { start in
            let chunk = bytes[start..<min(start + chunkSize, bytes.count)]
            let hex = chunk.map { byteHex($0) }.joined(separator: " ")
            return "send-keys -t \(pane) -H \(hex)"
        }
    }

    // Fixed fields first, the window name last so it may contain spaces.
    // tmux turns tabs in -F output into "_", so a tab separator is not usable.
    static let windowFormat =
        "#{window_id} #{window_index} #{window_active} #{pane_id} #{window_panes} " +
        "#{window_width} #{window_height} #{s/ /_/:pane_current_command} #{window_name}"

    public static func listWindows(session: String? = nil) -> String {
        var command = "list-windows"
        if let session { command += " -t \(quote(session + ":"))" }
        return command + " -F \(quote(windowFormat))"
    }

    public static func parseWindowList(_ reply: ControlReply) -> [WindowInfo] {
        reply.textLines.compactMap(WindowInfo.init(line:))
    }

    /// History plus visible screen, with colors, wrapped lines joined.
    public static func captureHistory(pane: PaneID, lines: Int) -> String {
        "capture-pane -p -e -J -t \(pane) -S -\(lines)"
    }

    /// The alternate screen (vim, htop, claude). Fails if the pane has none.
    public static func captureAlternateScreen(pane: PaneID) -> String {
        "capture-pane -p -e -a -t \(pane)"
    }

    public static func paneState(pane: PaneID) -> String {
        "display-message -p -t \(pane) " +
            quote("#{cursor_x} #{cursor_y} #{alternate_on} #{pane_width} #{pane_height} " +
                  "#{cursor_flag} #{keypad_cursor_flag} #{keypad_flag} #{mouse_standard_flag} " +
                  "#{mouse_button_flag} #{mouse_any_flag} #{mouse_sgr_flag}")
    }

    public static func refreshClientSize(columns: Int, rows: Int) -> String {
        "refresh-client -C \(columns)x\(rows)"
    }

    /// Gives a window a fixed size (window-size becomes manual for it).
    public static func claimWindowSize(_ window: WindowID, columns: Int, rows: Int) -> String {
        "resize-window -t \(window) -x \(columns) -y \(rows)"
    }

    /// Returns a window to the global window-size (automatic sizing).
    public static func releaseWindowSize(_ window: WindowID) -> String {
        "set-option -uw -t \(window) window-size"
    }

    /// Creates a window without making it the server's current window.
    /// The reply is one line: `@<window> %<pane>`.
    public static func newWindow(name: String) -> String {
        "new-window -d -n \(quoteName(name)) -P -F \(quote("#{window_id} #{pane_id}"))"
    }

    public static func parseNewWindow(_ reply: ControlReply) -> (WindowID, PaneID)? {
        guard let line = reply.textLines.first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 2, let w = WindowID(token: parts[0]), let p = PaneID(token: parts[1]) else { return nil }
        return (w, p)
    }

    public static func renameWindow(_ window: WindowID, to name: String) -> String {
        "rename-window -t \(window) \(quoteName(name))"
    }

    public static func killWindow(_ window: WindowID) -> String {
        "kill-window -t \(window)"
    }

    public static func selectWindow(_ window: WindowID) -> String {
        "select-window -t \(window)"
    }

    private static func byteHex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
    }
}

/// One row of `TmuxCommand.listWindows`.
public struct WindowInfo: Sendable, Equatable {
    public var id: WindowID
    public var index: Int
    public var isActive: Bool
    public var activePane: PaneID
    public var paneCount: Int
    public var width: Int
    public var height: Int
    public var currentCommand: String
    public var name: String

    public init(id: WindowID, index: Int, isActive: Bool, activePane: PaneID, paneCount: Int,
                width: Int, height: Int, currentCommand: String, name: String) {
        self.id = id
        self.index = index
        self.isActive = isActive
        self.activePane = activePane
        self.paneCount = paneCount
        self.width = width
        self.height = height
        self.currentCommand = currentCommand
        self.name = name
    }

    init?(line: String) {
        let f = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard f.count == 9,
              let id = WindowID(token: f[0]), let index = Int(f[1]),
              let pane = PaneID(token: f[3]), let panes = Int(f[4]),
              let width = Int(f[5]), let height = Int(f[6])
        else { return nil }
        self.init(id: id, index: index, isActive: f[2] == "1", activePane: pane, paneCount: panes,
                  width: width, height: height, currentCommand: String(f[7]), name: String(f[8]))
    }
}

/// Reply of `TmuxCommand.paneState`.
public struct PaneState: Sendable, Equatable {
    public var cursorX: Int
    public var cursorY: Int
    public var alternateScreen: Bool
    public var width: Int
    public var height: Int
    /// Terminal modes the program set; replayed after a repaint, which
    /// starts from a reset terminal.
    public var cursorVisible = true
    public var applicationCursor = false
    public var applicationKeypad = false
    public var mouseStandard = false
    public var mouseButton = false
    public var mouseAny = false
    public var mouseSGR = false

    public init(cursorX: Int, cursorY: Int, alternateScreen: Bool, width: Int, height: Int) {
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.alternateScreen = alternateScreen
        self.width = width
        self.height = height
    }

    public init?(_ reply: ControlReply) {
        guard let line = reply.textLines.first else { return nil }
        let f = line.split(separator: " ").compactMap { Int($0) }
        guard f.count >= 5 else { return nil }
        self.init(cursorX: f[0], cursorY: f[1], alternateScreen: f[2] == 1, width: f[3], height: f[4])
        if f.count >= 12 {
            cursorVisible = f[5] == 1
            applicationCursor = f[6] == 1
            applicationKeypad = f[7] == 1
            mouseStandard = f[8] == 1
            mouseButton = f[9] == 1
            mouseAny = f[10] == 1
            mouseSGR = f[11] == 1
        }
    }

    /// Escape sequences that put a freshly reset terminal into these modes.
    public var modeSequences: String {
        var s = ""
        func set(_ on: Bool, _ mode: Int) { if on { s += "\u{1b}[?\(mode)h" } }
        set(applicationCursor, 1)
        set(mouseStandard, 1000)
        set(mouseButton, 1002)
        set(mouseAny, 1003)
        set(mouseSGR, 1006)
        if applicationKeypad { s += "\u{1b}=" }
        if !cursorVisible { s += "\u{1b}[?25l" }
        return s
    }
}
