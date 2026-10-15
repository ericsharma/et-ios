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

/// SwiftTerm's view with touch scrolling moved to two fingers.
///
/// SwiftTerm uses one-finger drags for text selection and, when the program
/// in the pane turns on mouse reporting, for mouse drags. Neither scrolls.
/// Here a two-finger drag always scrolls: the local scrollback normally, or
/// mouse-wheel events in a full-screen program (vim, htop), which has no
/// scrollback of its own.
final class ETTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var wheelPan: UIPanGestureRecognizer?
    private var wheelRemainder: CGFloat = 0
    /// Called when keyboard dictation starts (true) or stops (false) while
    /// this terminal has the keyboard.
    var onDictationChange: ((Bool) -> Void)?
    /// Diagnostics for text input; goes to the debug log.
    var onInputDebug: ((String) -> Void)?
    private var isDictating = false

    override init(frame: CGRect, font: UIFont?) {
        _ = Self.installInputHooks
        super.init(frame: frame, font: font)
        // UIScrollView's own pan scrolls the scrollback, with momentum.
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.maximumNumberOfTouches = 2
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheelPanned(_:)))
        wheel.minimumNumberOfTouches = 2
        wheel.maximumNumberOfTouches = 2
        wheel.delegate = self
        wheelPan = wheel
        addGestureRecognizer(wheel)
        // iOS has no public "dictation started" event. While dictation runs,
        // the keyboard's input mode reports the language "dictation".
        NotificationCenter.default.addObserver(
            self, selector: #selector(inputModeChanged),
            name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
    }

    @objc private func inputModeChanged() {
        let language = textInputMode?.primaryLanguage ?? "nil"
        onInputDebug?("inputMode → \(language) (firstResponder: \(isFirstResponder))")
        setDictating(isFirstResponder && language == "dictation")
    }

    private func setDictating(_ dictating: Bool) {
        guard dictating != isDictating else { return }
        isDictating = dictating
        onDictationChange?(dictating)
    }

    // Diagnostics: which UITextInput calls does iOS 26 dictation make?
    // Only insertText is open in SwiftTerm, so the rest are hooked at runtime
    // on this subclass (see installInputHooks).

    override func insertText(_ text: String) {
        onInputDebug?("insertText len=\(text.count) lang=\(textInputMode?.primaryLanguage ?? "nil")")
        super.insertText(text)
    }

    fileprivate func inputHook(_ name: String) {
        onInputDebug?(name)
        switch name {
        case "insertDictationResultPlaceholder", "insertDictationResult:":
            setDictating(true)
        case "dictationRecordingDidEnd", "dictationRecognitionFailed":
            setDictating(false)
        default:
            break
        }
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
            { (obj: AnyObject, a: AnyObject?) in note(obj, "insertDictationResult:"); f(obj, sel, a) }
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
        g === wheelPan && other === panGestureRecognizer
    }

    /// In the alternate screen, turn two-finger drags into wheel events.
    @objc private func wheelPanned(_ gesture: UIPanGestureRecognizer) {
        let terminal = getTerminal()
        guard terminal.isCurrentBufferAlternate else { return }
        switch gesture.state {
        case .began:
            wheelRemainder = 0
        case .changed:
            let lineHeight = max(font.lineHeight, 1)
            wheelRemainder += gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            let lines = Int(wheelRemainder / lineHeight)
            guard lines != 0 else { return }
            wheelRemainder -= CGFloat(lines) * lineHeight
            let location = gesture.location(in: self)
            let col = max(0, min(terminal.cols - 1, Int(location.x / max(bounds.width / CGFloat(terminal.cols), 1))))
            let row = max(0, min(terminal.rows - 1, Int(location.y / lineHeight)))
            // Finger down = content down = scroll up (wheel button 4).
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
        default:
            break
        }
    }
}

/// Owns one SwiftTerm `TerminalView` for the life of a window, so output is
/// never lost and pages switch instantly (SPEC §4).
@MainActor
final class TerminalHost: NSObject {
    let view: ETTerminalView
    var onInput: (([UInt8]) -> Void)?
    var onSizeChange: ((Int, Int) -> Void)?
    /// Dictation started: ask "edit first or into terminal?" (true), or the
    /// question is no longer needed (false).
    var onDictationPrompt: ((Bool) -> Void)?
    /// Dictation finished in "edit first" mode: open the editor with this text.
    var onEditDictation: ((String) -> Void)?
    private let log: DebugLog

    /// While dictation runs and the user hasn't chosen, or chose to edit,
    /// typed bytes are held here instead of going to tmux.
    private enum Dictation {
        case idle
        case undecided(buffer: [UInt8], ended: Bool)
        case editing(buffer: [UInt8])
        case passthrough
    }
    private var dictation: Dictation = .idle

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
        view.onDictationChange = { [weak self] active in self?.dictationChanged(active) }
        view.onInputDebug = { [weak self] line in self?.log.add("input: \(line)") }
    }

    // MARK: - Dictation choice

    private func dictationChanged(_ active: Bool) {
        log.add("Keyboard dictation \(active ? "started" : "ended")")
        switch (active, dictation) {
        case (true, _):
            dictation = .undecided(buffer: [], ended: false)
            onDictationPrompt?(true)
        case (false, .undecided(let buffer, _)):
            dictation = .undecided(buffer: buffer, ended: true)
        case (false, .editing(let buffer)):
            dictation = .idle
            onEditDictation?(Self.text(from: buffer))
        case (false, _):
            dictation = .idle
        }
    }

    /// The user's answer to "edit first or into terminal?".
    func chooseDictation(edit: Bool) {
        onDictationPrompt?(false)
        guard case .undecided(let buffer, let ended) = dictation else { return }
        if edit {
            if ended {
                dictation = .idle
                onEditDictation?(Self.text(from: buffer))
            } else {
                dictation = .editing(buffer: buffer)
                // Leave dictation running; the editor opens when it stops.
            }
        } else {
            dictation = ended ? .idle : .passthrough
            if !buffer.isEmpty { onInput?(buffer) }
        }
    }

    /// Turns held keystrokes into text, applying the backspaces dictation
    /// sends when it revises a word.
    static func text(from bytes: [UInt8]) -> String {
        var text = ""
        var pending: [UInt8] = []
        func flush() { text += String(decoding: pending, as: UTF8.self); pending = [] }
        for b in bytes {
            if b == 0x7F || b == 0x08 {
                flush()
                if !text.isEmpty { text.removeLast() }
            } else {
                pending.append(b)
            }
        }
        flush()
        return text
    }

    var terminal: Terminal { view.getTerminal() }

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
        switch dictation {
        case .undecided(var buffer, let ended):
            buffer += data
            dictation = .undecided(buffer: buffer, ended: ended)
        case .editing(var buffer):
            buffer += data
            dictation = .editing(buffer: buffer)
        case .idle, .passthrough:
            onInput?(Array(data))
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onSizeChange?(newCols, newRows)
    }

    func bell(source: TerminalView) {}
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
