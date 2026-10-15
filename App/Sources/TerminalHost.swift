@preconcurrency import SwiftTerm
import SwiftUI
import UIKit

enum Theme {
    // Catppuccin Mocha.
    static let background = UIColor(hex: 0x181825)
    static let foreground = UIColor(hex: 0xCDD6F4)
    static let accent = Color(UIColor(hex: 0x89B4FA))
    static let active = Color(UIColor(hex: 0xF38BA8))
    static let surface = Color(UIColor(hex: 0x1E1E2E))
    static let ansi: [UInt32] = [
        0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
        0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
    ]
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// SwiftTerm's view with two-finger gestures.
///
/// SwiftTerm uses one-finger drags for text selection and, when the program
/// in the pane turns on mouse reporting, for mouse drags. Two fingers:
/// - up/down scrolls (local scrollback, or wheel events in a full-screen
///   program such as vim) and closes the keyboard;
/// - left/right switches tmux windows.
final class ETTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var wheelPan: UIPanGestureRecognizer?
    private var wheelRemainder: CGFloat = 0
    private enum Axis { case horizontal, vertical }
    private var gestureAxis: Axis?
    private var lastTranslationY: CGFloat = 0
    /// Two-finger swipe left (true = next window) or right (false = previous).
    var onTwoFingerSwipe: ((Bool) -> Void)?
    /// Whether a selection exists changed (shows the Select button).
    var onSelectionChange: ((Bool) -> Void)?
    private var hadSelection = false
    /// A long-press happened (with the selected text, if SwiftTerm made a
    /// selection). Programs with mouse reporting get the press instead of
    /// SwiftTerm, so this is the reliable "user wants to select" signal.
    var onLongPress: ((String?) -> Void)?

    // Selection handles: a line with a knob at each end of the selection,
    // draggable to change it (SwiftTerm selects but draws no handles).
    private let startHandle = SelectionHandle(atStart: true)
    private let endHandle = SelectionHandle(atStart: false)
    private var handleLink: CADisplayLink?
    /// The selection end that stays put while a handle is dragged.
    private var dragAnchor: Position?
    /// Called when keyboard dictation starts (true) or stops (false) while
    /// this terminal has the keyboard.
    /// iOS finished a dictation; the text is the final result it inserted.
    var onDictationResult: ((String) -> Void)?
    /// Any tap in the terminal (used to dismiss the Edit prompt).
    var onTap: (() -> Void)?
    /// Diagnostics for text input; goes to the debug log.
    var onInputDebug: ((String) -> Void)?

    override init(frame: CGRect, font: UIFont?) {
        _ = Self.installInputHooks
        super.init(frame: frame, font: font)
        // UIScrollView's own pan scrolls the scrollback, with momentum.
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.maximumNumberOfTouches = 2
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPanned(_:)))
        wheel.minimumNumberOfTouches = 2
        wheel.maximumNumberOfTouches = 2
        wheel.delegate = self
        wheelPan = wheel
        addGestureRecognizer(wheel)
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            handle.tintColor = UIColor(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 1)
            handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:))))
            addSubview(handle)
        }
        selectionHandleColor = startHandle.tintColor

        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.45
        press.cancelsTouchesInView = false
        press.delegate = self
        addGestureRecognizer(press)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @objc private func tapped() { onTap?() }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        // Let SwiftTerm's own long-press make its selection first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let text = self.hasActiveSelection ? self.getSelection() : nil
            self.onInputDebug?("long-press: selection=\(text != nil) mouseMode=\(self.getTerminal().mouseMode)")
            self.onLongPress?(text)
        }
    }

    // MARK: - Selection handles

    /// The display link holds its target, so it only runs while on screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, handleLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(updateHandles))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            handleLink = link
        } else if window == nil {
            handleLink?.invalidate()
            handleLink = nil
        }
    }

    /// One character cell, in points (SwiftTerm keeps its own internal).
    private var cell: CGSize? {
        guard let px = cellSizeInPixels(source: getTerminal()), px.width > 0, px.height > 0 else { return nil }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        return CGSize(width: CGFloat(px.width) / scale, height: CGFloat(px.height) / scale)
    }

    private static func ordered(_ a: Position, _ b: Position) -> (Position, Position) {
        (a.row, a.col) <= (b.row, b.col) ? (a, b) : (b, a)
    }

    /// Keeps the handles on the selection's ends (selection changes have no
    /// callback, so this runs on a display link; it is cheap when idle).
    @objc private func updateHandles() {
        let active = selection?.active == true
        if active != hadSelection {
            hadSelection = active
            onSelectionChange?(active)
        }
        guard let selection, selection.active, let cell else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let (start, end) = Self.ordered(selection.start, selection.end)
        // Selection rows are buffer rows; in this scroll view's content
        // coordinates a buffer row sits at row * cell height.
        startHandle.place(at: CGPoint(x: CGFloat(start.col) * cell.width, y: CGFloat(start.row) * cell.height), lineHeight: cell.height)
        endHandle.place(at: CGPoint(x: CGFloat(end.col) * cell.width, y: CGFloat(end.row) * cell.height), lineHeight: cell.height)
        startHandle.isHidden = false
        endHandle.isHidden = false
    }

    @objc private func handleDragged(_ gesture: UIPanGestureRecognizer) {
        guard let selection, let cell, let handle = gesture.view as? SelectionHandle else { return }
        let terminal = getTerminal()
        let (start, end) = Self.ordered(selection.start, selection.end)
        switch gesture.state {
        case .began:
            dragAnchor = handle.atStart ? end : start
            isScrollEnabled = false
        case .changed:
            guard let anchor = dragAnchor else { return }
            // Aim at the line's middle, above the finger.
            let point = gesture.location(in: self)
            let y = handle.atStart ? point.y + cell.height / 2 : point.y - cell.height / 2
            let lastRow = max(0, Int(contentSize.height / cell.height) - 1)
            let moved = Position(col: max(0, min(terminal.cols, Int((point.x / cell.width).rounded()))),
                                 row: max(0, min(lastRow, Int(y / cell.height))))
            let (a, b) = Self.ordered(anchor, moved)
            setSelectionRange(start: a, end: b)
            UISelectionFeedbackGenerator().selectionChanged()
        case .ended, .cancelled:
            dragAnchor = nil
            isScrollEnabled = true
            showStandardContextMenu(at: handle.center)
        default:
            break
        }
    }

    /// Touches on a handle belong to the handle, not SwiftTerm's own
    /// selection and mouse drags.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer.view === self {
            let point = gestureRecognizer.location(in: self)
            for handle in [startHandle, endHandle] where !handle.isHidden && handle.frame.contains(point) {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }



    // Diagnostics: which UITextInput calls does iOS 26 dictation make?
    // Only insertText is open in SwiftTerm, so the rest are hooked at runtime
    // on this subclass (see installInputHooks).

    override func insertText(_ text: String) {
        if text.count > 1 { onInputDebug?("insertText len=\(text.count)") }
        super.insertText(text)
    }

    fileprivate func inputHook(_ name: String) {
        onInputDebug?(name)
    }

    fileprivate func dictationInserted(_ text: String) {
        onDictationResult?(text)
    }

    /// Adds logging overrides to ETTerminalView for SwiftTerm's non-open
    /// UITextInput methods. Each calls TerminalView's implementation.
    private static let installInputHooks: Void = {
        func hook<F>(_ name: String, _ type: F.Type, _ make: (F, Selector) -> Any) {
            let sel = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(TerminalView.self, sel) else { return }
            let original = unsafeBitCast(method_getImplementation(method), to: F.self)
            class_addMethod(ETTerminalView.self, sel, imp_implementationWithBlock(make(original, sel)),
                            method_getTypeEncoding(method))
        }
        func note(_ obj: AnyObject, _ name: String) {
            // UIKit calls these on the main thread.
            nonisolated(unsafe) let view = obj as? ETTerminalView
            MainActor.assumeIsolated { view?.inputHook(name) }
        }
        typealias Void0 = @convention(c) (AnyObject, Selector) -> Void
        typealias Obj0 = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Void1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        typealias Marked = @convention(c) (AnyObject, Selector, AnyObject?, NSRange) -> Void
        typealias Remove = @convention(c) (AnyObject, Selector, AnyObject?, Bool) -> Void
        typealias Replace = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void

        for name in ["unmarkText", "dictationRecordingDidEnd", "dictationRecognitionFailed"] {
            hook(name, Void0.self) { f, sel in
                { (obj: AnyObject) in note(obj, name); f(obj, sel) } as @convention(block) (AnyObject) -> Void
            }
        }
        hook("insertDictationResultPlaceholder", Obj0.self) { f, sel in
            { (obj: AnyObject) -> AnyObject? in note(obj, "insertDictationResultPlaceholder"); return f(obj, sel) }
                as @convention(block) (AnyObject) -> AnyObject?
        }
        hook("insertDictationResult:", Void1.self) { f, sel in
            { (obj: AnyObject, a: AnyObject?) in
                note(obj, "insertDictationResult:")
                f(obj, sel, a)
                let text = (a as? [UIDictationPhrase])?.map(\.text).joined() ?? ""
                nonisolated(unsafe) let view = obj as? ETTerminalView
                MainActor.assumeIsolated { view?.dictationInserted(text) }
            }
                as @convention(block) (AnyObject, AnyObject?) -> Void
        }
        hook("setMarkedText:selectedRange:", Marked.self) { f, sel in
            { (obj: AnyObject, a: AnyObject?, r: NSRange) in
                note(obj, "setMarkedText len=\((a as? String)?.count ?? -1)"); f(obj, sel, a, r)
            } as @convention(block) (AnyObject, AnyObject?, NSRange) -> Void
        }
        hook("removeDictationResultPlaceholder:willInsertResult:", Remove.self) { f, sel in
            { (obj: AnyObject, a: AnyObject?, b: Bool) in
                note(obj, "removeDictationResultPlaceholder willInsert=\(b)"); f(obj, sel, a, b)
            } as @convention(block) (AnyObject, AnyObject?, Bool) -> Void
        }
        hook("replaceRange:withText:", Replace.self) { f, sel in
            { (obj: AnyObject, a: AnyObject?, t: AnyObject?) in
                note(obj, "replaceRange len=\((t as? String)?.count ?? -1)"); f(obj, sel, a, t)
            } as @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void
        }
    }()

    required init?(coder: NSCoder) { fatalError("not used") }

    /// SwiftTerm adds its selection and mouse pans lazily; keep them to one finger.
    override func addGestureRecognizer(_ gesture: UIGestureRecognizer) {
        if let pan = gesture as? UIPanGestureRecognizer, pan !== wheelPan, pan !== panGestureRecognizer {
            pan.maximumNumberOfTouches = 1
        }
        super.addGestureRecognizer(gesture)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === wheelPan && other === panGestureRecognizer) || g is UITapGestureRecognizer || g is UILongPressGestureRecognizer
    }

    @objc private func twoFingerPanned(_ gesture: UIPanGestureRecognizer) {
        let t = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            gestureAxis = nil
            lastTranslationY = 0
            wheelRemainder = 0
        case .changed:
            if gestureAxis == nil, hypot(t.x, t.y) > 12 {
                if abs(t.x) > abs(t.y) {
                    gestureAxis = .horizontal
                    // Cancel the scroll view's vertical scrolling for this swipe.
                    panGestureRecognizer.isEnabled = false
                    panGestureRecognizer.isEnabled = true
                } else {
                    gestureAxis = .vertical
                    if isFirstResponder { _ = resignFirstResponder() }
                }
            }
            if gestureAxis == .vertical {
                wheel(by: t.y - lastTranslationY, at: gesture.location(in: self))
                lastTranslationY = t.y
            }
        case .ended:
            if gestureAxis == .horizontal, abs(t.x) > 50 {
                onTwoFingerSwipe?(t.x < 0)
            }
        default:
            break
        }
    }

    /// In the alternate screen (no scrollback), vertical movement becomes
    /// mouse-wheel events. Elsewhere the scroll view itself scrolls.
    private func wheel(by dy: CGFloat, at location: CGPoint) {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate else { return }
        let lineHeight = max(font.lineHeight, 1)
        wheelRemainder += dy
        let lines = Int(wheelRemainder / lineHeight)
        guard lines != 0 else { return }
        wheelRemainder -= CGFloat(lines) * lineHeight
        let col = max(0, min(terminal.cols - 1, Int(location.x / max(bounds.width / CGFloat(terminal.cols), 1))))
        let row = max(0, min(terminal.rows - 1, Int(location.y / lineHeight)))
        // Fingers down = content down = scroll up (wheel button 4).
        let button = lines > 0 ? 4 : 5
        for _ in 0..<abs(lines) {
            if terminal.mouseMode != .off {
                let flags = terminal.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
                terminal.sendEvent(buttonFlags: flags, x: col, y: row)
            } else {
                // No mouse support: arrow keys, as most terminals do.
                send(Array((button == 4 ? "\u{1b}OA" : "\u{1b}OB").utf8))
            }
        }
    }
}

/// A selection end marker: a vertical line one text line tall, with a round
/// knob above it (start) or below it (end), like iOS text selection. The
/// view is larger than it looks, so it is easy to grab.
final class SelectionHandle: UIView {
    let atStart: Bool
    private let line = UIView()
    private let knob = UIView()
    private static let touchSize: CGFloat = 44

    init(atStart: Bool) {
        self.atStart = atStart
        super.init(frame: .zero)
        backgroundColor = .clear
        knob.layer.cornerRadius = 6
        addSubview(line)
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func tintColorDidChange() {
        line.backgroundColor = tintColor
        knob.backgroundColor = tintColor
    }

    /// `origin` is the top-left of the selection edge, in the terminal's
    /// content coordinates.
    func place(at origin: CGPoint, lineHeight: CGFloat) {
        let height = lineHeight + 12 + Self.touchSize / 2
        let y = atStart ? origin.y - 12 - Self.touchSize / 4 : origin.y
        frame = CGRect(x: origin.x - Self.touchSize / 2, y: y, width: Self.touchSize, height: height)
        let lineTop: CGFloat = atStart ? 12 + Self.touchSize / 4 : 0
        line.frame = CGRect(x: Self.touchSize / 2 - 1, y: lineTop, width: 2, height: lineHeight)
        let knobY = atStart ? lineTop - 12 : lineTop + lineHeight
        knob.frame = CGRect(x: Self.touchSize / 2 - 6, y: knobY, width: 12, height: 12)
    }
}

/// Owns one SwiftTerm `TerminalView` for the life of a window, so output is
/// never lost and pages switch instantly (SPEC §4).
@MainActor
final class TerminalHost: NSObject {
    let view: ETTerminalView
    var onInput: (([UInt8]) -> Void)?
    var onSizeChange: ((Int, Int) -> Void)?
    /// Show (text) or hide (nil) the "Edit" prompt after dictation.
    var onDictationPrompt: ((String?) -> Void)?
    /// Two-finger swipe: true = next window, false = previous.
    var onSwipe: ((Bool) -> Void)?
    var onSelectionChange: ((Bool) -> Void)?
    var onLongPress: ((String?) -> Void)?
    /// A plain tap in the terminal (hides transient offers).
    var onTapped: (() -> Void)?
    /// A real BEL, as parsed by SwiftTerm (not the 0x07 that ends a title
    /// escape sequence).
    var onBell: (() -> Void)?
    /// The user tapped Edit: open the editor with this text.
    var onEditDictation: ((String) -> Void)?
    private let log: DebugLog

    /// The dictated text the Edit prompt offers, while it's showing.
    private var promptText: String?

    static var fontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 14 : 13

    init(log: DebugLog) {
        self.log = log
        view = ETTerminalView(frame: UIScreen.main.bounds,
                              font: UIFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular))
        super.init()
        view.terminalDelegate = self
        view.nativeBackgroundColor = Theme.background
        view.nativeForegroundColor = Theme.foreground
        view.caretColor = UIColor(hex: 0xF5E0DC)
        view.installColors(Theme.ansi.map {
            SwiftTerm.Color(red8: UInt16(($0 >> 16) & 0xFF), green8: UInt16(($0 >> 8) & 0xFF), blue8: UInt16($0 & 0xFF))
        })
        view.keyboardAppearance = .dark
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        // E.T. draws its own key row (KeyRow) instead of SwiftTerm's.
        view.inputAccessoryView = nil
        view.onDictationResult = { [weak self] text in self?.dictationFinished(text) }
        view.onTap = { [weak self] in
            self?.dismissDictationPrompt()
            self?.onTapped?()
        }
        view.onTwoFingerSwipe = { [weak self] next in self?.onSwipe?(next) }
        view.onSelectionChange = { [weak self] active in self?.onSelectionChange?(active) }
        view.onLongPress = { [weak self] text in self?.onLongPress?(text) }
        view.onInputDebug = { [weak self] line in self?.log.add("input: \(line)") }
    }

    // MARK: - Dictation choice

    /// Dictation went into the terminal untouched; offer to move it to the
    /// editor.
    private func dictationFinished(_ text: String) {
        offerEdit(text)
    }

    /// Shows the Edit button for text that was just typed into the terminal
    /// (keyboard dictation or E.T.'s own mic).
    func offerEdit(_ text: String) {
        guard !text.isEmpty else { return }
        promptText = text
        onDictationPrompt?(text)
    }

    /// Edit tapped: erase the live copy from the input line, then edit.
    func editDictation() {
        guard let text = promptText else { return }
        dismissDictationPrompt()
        onInput?(Array(repeating: 0x7F, count: text.count))
        onEditDictation?(text)
    }

    /// Ignored (typed, tapped, dictated again, switched window): the text
    /// simply stays in the terminal.
    func dismissDictationPrompt() {
        guard promptText != nil else { return }
        promptText = nil
        onDictationPrompt?(nil)
    }

    var terminal: Terminal { view.getTerminal() }

    /// The bottom of the visible screen as plain text, for overview tiles.
    func snapshot(lines count: Int) -> [String] {
        let t = terminal
        var rows = (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return Array(rows.suffix(count))
    }

    /// Sends bytes as if typed, honoring SwiftTerm's sticky Ctrl.
    func type(_ bytes: [UInt8]) {
        view.send(bytes)
    }

    func feed(_ bytes: [UInt8]) {
        view.feed(byteArray: bytes[...])
    }

    /// Clears the terminal and replays restored content.
    func reset(with bytes: [UInt8]) {
        view.getTerminal().resetToInitialState()
        view.feed(byteArray: bytes[...])
    }
}

extension TerminalHost: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        dismissDictationPrompt()
        onInput?(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onSizeChange?(newCols, newRows)
    }

    func bell(source: TerminalView) { onBell?() }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
}

/// Puts a `TerminalHost`'s view into SwiftUI. The view is reused, so it is
/// moved into each new container rather than recreated.
struct TerminalPane: UIViewRepresentable {
    let host: TerminalHost

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.background
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if host.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        host.view.removeFromSuperview()
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
