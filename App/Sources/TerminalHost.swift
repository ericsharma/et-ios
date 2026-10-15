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
    /// iOS finished a keyboard dictation; the text is the final result it
    /// inserted (used to offer the Edit button).
    var onDictationResult: ((String) -> Void)?
    /// Any tap in the terminal (used to dismiss the Edit prompt).
    var onTap: (() -> Void)?

    override init(frame: CGRect, font: UIFont?) {
        _ = Self.installDictationHook
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @objc private func tapped() { onTap?() }

    // MARK: - Keyboard dictation result

    fileprivate func dictationInserted(_ text: String) {
        onDictationResult?(text)
    }

    /// SwiftTerm's UITextInput methods aren't `open`, so the one call that
    /// carries the final dictation text, insertDictationResult:, is wrapped at
    /// runtime on this subclass: it calls SwiftTerm's implementation, then
    /// reports the text.
    private static let installDictationHook: Void = {
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let sel = NSSelectorFromString("insertDictationResult:")
        guard let method = class_getInstanceMethod(TerminalView.self, sel) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { obj, phrases in
            original(obj, sel, phrases)
            let text = (phrases as? [UIDictationPhrase])?.map(\.text).joined() ?? ""
            // UIKit calls this on the main thread.
            nonisolated(unsafe) let view = obj as? ETTerminalView
            MainActor.assumeIsolated { view?.dictationInserted(text) }
        }
        class_addMethod(ETTerminalView.self, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
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
        (g === wheelPan && other === panGestureRecognizer) || g is UITapGestureRecognizer
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
        view.onTap = { [weak self] in self?.dismissDictationPrompt() }
        view.onTwoFingerSwipe = { [weak self] next in self?.onSwipe?(next) }
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
