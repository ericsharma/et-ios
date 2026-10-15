import GameController
import SwiftUI

/// Key-row presets (SPEC §5.4).
enum KeyPreset: String, CaseIterable, Identifiable {
    case shell
    case claude

    var id: String { rawValue }
    var label: String { self == .shell ? "Shell" : "Claude" }

    var keys: [Key] {
        switch self {
        case .shell:
            [.esc, .tab, .ctrl, .up, .down, .left, .right,
             .text("|"), .text("~"), .text("/"), .text("-"), .ctrlC, .ctrlD]
        case .claude:
            [.esc, .shiftTab, .text("1"), .text("2"), .text("3"), .up, .down, .enter, .ctrlC]
        }
    }
}

enum Key: Hashable {
    case esc, tab, shiftTab, ctrl, up, down, left, right, enter, ctrlC, ctrlD
    case text(String)

    var title: String {
        switch self {
        case .esc: "esc"
        case .tab: "tab"
        case .shiftTab: "⇧tab"
        case .ctrl: "ctrl"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .enter: "enter"
        case .ctrlC: "^C"
        case .ctrlD: "^D"
        case .text(let t): t
        }
    }

    /// Bytes to send. Arrows follow the terminal's cursor-key mode (vim and
    /// friends switch to application mode).
    func bytes(applicationCursor: Bool) -> [UInt8] {
        let csi = applicationCursor ? "\u{1b}O" : "\u{1b}["
        return switch self {
        case .esc: [0x1B]
        case .tab: [0x09]
        case .shiftTab: Array("\u{1b}[Z".utf8)
        case .ctrl: []
        case .up: Array((csi + "A").utf8)
        case .down: Array((csi + "B").utf8)
        case .right: Array((csi + "C").utf8)
        case .left: Array((csi + "D").utf8)
        case .enter: [0x0D]
        case .ctrlC: [0x03]
        case .ctrlD: [0x04]
        case .text(let t): Array(t.utf8)
        }
    }
}

/// One row of keys above the compose bar. Scrolls if it doesn't fit.
/// Long-press to switch presets.
struct KeyRow: View {
    @Bindable var session: SessionController
    let page: WindowPage
    @State private var ctrlState: CtrlState = .off

    enum CtrlState { case off, once, locked }

    var body: some View {
        let preset = session.preset(for: page)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(preset.keys, id: \.self) { key in
                    keyButton(key)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 38)
        .contextMenu {
            Picker("Keys", selection: Binding(
                get: { session.preset(for: page) },
                set: { session.setPreset($0, for: page) })) {
                ForEach(KeyPreset.allCases) { Text($0.label).tag($0) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) { note in
            // SwiftTerm clears its sticky Ctrl after one key; mirror that,
            // unless Ctrl is locked.
            guard (note.object as AnyObject?) === page.terminal.view else { return }
            if ctrlState == .locked {
                page.terminal.view.controlModifier = true
            } else {
                ctrlState = .off
            }
        }
    }

    @ViewBuilder private func keyButton(_ key: Key) -> some View {
        let isCtrl = key == .ctrl
        let active = isCtrl && ctrlState != .off
        Text(key.title)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .padding(.horizontal, 12)
            .frame(minWidth: 40, minHeight: 32)
            .background(active ? Theme.accent.opacity(ctrlState == .locked ? 0.7 : 0.35) : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottom) {
                if ctrlState == .locked && isCtrl {
                    Capsule().fill(Theme.accent).frame(width: 14, height: 2).padding(.bottom, 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { tap(key) }
            .onLongPressGesture(minimumDuration: 0.4) {
                if isCtrl { setCtrl(.locked) }
            }
            .sensoryFeedback(.selection, trigger: ctrlState)
    }

    private func tap(_ key: Key) {
        if key == .ctrl {
            setCtrl(ctrlState == .off ? .once : .off)
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        let terminal = page.terminal
        var bytes = key.bytes(applicationCursor: terminal.terminal.applicationCursor)
        if ctrlState != .off, case .text(let t) = key, let c = t.unicodeScalars.first, c.isASCII {
            // Ctrl + a key-row character.
            bytes = [UInt8(c.value) & 0x1F]
            if ctrlState == .once { setCtrl(.off) }
        }
        session.send(bytes, to: page)
    }

    private func setCtrl(_ state: CtrlState) {
        ctrlState = state
        // Keyboard keys pick up Ctrl through SwiftTerm's sticky modifier.
        page.terminal.view.controlModifier = state != .off
    }
}

/// True when a hardware keyboard is attached; the key row is hidden then.
@MainActor @Observable
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()
    private(set) var isConnected = GCKeyboard.coalesced != nil

    private init() {
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HardwareKeyboard.shared.isConnected = true }
        }
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HardwareKeyboard.shared.isConnected = GCKeyboard.coalesced != nil }
        }
    }
}

/// Write or dictate a whole message, edit it, then send it (SPEC §6.2).
/// Uses the keyboard's own dictation; E.T. has no mic of its own.
struct ComposeBar: View {
    @Bindable var session: SessionController
    let page: WindowPage
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let isClaude = session.preset(for: page) == .claude
        HStack(alignment: .bottom, spacing: 8) {
            TextField(isClaude ? "Message Claude…" : "Type or dictate a command…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textInputAutocapitalization(isClaude ? .sentences : .never)
                .autocorrectionDisabled(!isClaude)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(text.isEmpty)
            .contextMenu {
                Button("Send without Enter") { send(pressEnter: false) }
            }
        }
        .padding(.horizontal, 10)
    }

    private func send() { send(pressEnter: true) }

    private func send(pressEnter: Bool) {
        guard !text.isEmpty else { return }
        session.sendComposed(text, to: page, pressEnter: pressEnter)
        text = ""
    }
}
