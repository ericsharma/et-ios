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

/// The bottom bar: editor and ⋯ (key wheel) on the left, a big mic in the
/// middle (the main action), Send (Enter) on the right. The key wheel floats
/// vertically over the terminal above ⋯. Long-press ⋯ to switch between the
/// Shell and Claude key sets.
struct KeyRow: View {
    @Bindable var session: SessionController
    let page: WindowPage
    let voice: VoiceInput
    @State private var showKeys = false
    @State private var ctrlState: CtrlState = .off

    enum CtrlState { case off, once, locked }

    var body: some View {
        let preset = session.preset(for: page)
        HStack(spacing: 10) {
            barButton(systemName: "square.and.pencil", active: false) {
                session.composeRequest = ComposeRequest(page: page, text: "")
            }
            barButton(systemName: showKeys ? "xmark" : "ellipsis", active: showKeys || ctrlState != .off) {
                withAnimation(.snappy) { showKeys.toggle() }
            }
            .contextMenu {
                Picker("Keys", selection: Binding(
                    get: { session.preset(for: page) },
                    set: { session.setPreset($0, for: page) })) {
                    ForEach(KeyPreset.allCases) { Text($0.label).tag($0) }
                }
            }
            .overlay(alignment: .bottom) {
                if showKeys {
                    KeyWheel(keys: preset.keys, ctrlState: ctrlState, tap: tap, longPress: longPress)
                        .offset(y: -52)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
            }
            .zIndex(1)
            Spacer()
            MicButton(session: session, page: page, voice: voice)
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                session.send([0x0D], to: page)
            } label: {
                Label("Send", systemImage: "return")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 106, height: 40)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send (Enter)")
        }
        .padding(.horizontal, 20)
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
        .sensoryFeedback(.selection, trigger: ctrlState)
    }

    private func barButton(systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: 40)
                .background(active ? Theme.accent.opacity(0.45) : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func tap(_ key: Key) {
        if key == .ctrl {
            setCtrl(ctrlState == .off ? .once : .off)
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        var bytes = key.bytes(applicationCursor: page.terminal.terminal.applicationCursor)
        if ctrlState != .off, case .text(let t) = key, let c = t.unicodeScalars.first, c.isASCII {
            // Ctrl + a wheel character.
            bytes = [UInt8(c.value) & 0x1F]
            if ctrlState == .once { setCtrl(.off) }
        }
        session.send(bytes, to: page)
    }

    private func longPress(_ key: Key) {
        if key == .ctrl { setCtrl(.locked) }
    }

    private func setCtrl(_ state: CtrlState) {
        ctrlState = state
        // Keyboard keys pick up Ctrl through SwiftTerm's sticky modifier.
        page.terminal.view.controlModifier = state != .off
    }
}

/// A vertical wheel of keys floating over the terminal. It snaps to each
/// key, and the one in the middle is enlarged like a picker wheel. Tap any
/// key to send it; the wheel stays open for repeated taps.
struct KeyWheel: View {
    let keys: [Key]
    let ctrlState: KeyRow.CtrlState
    let tap: (Key) -> Void
    let longPress: (Key) -> Void

    private let rowHeight: CGFloat = 46
    private let visibleRows: CGFloat = 5

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    keyCap(key)
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1.08 : 0.86)
                                .opacity(phase.isIdentity ? 1 : 0.5)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.vertical, (rowHeight * visibleRows) / 2 - rowHeight / 2, for: .scrollContent)
        .defaultScrollAnchor(.bottom)
        .frame(width: 76, height: rowHeight * visibleRows)
        .mask(LinearGradient(colors: [.clear, .black, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 10)
    }

    private func keyCap(_ key: Key) -> some View {
        let isCtrl = key == .ctrl
        let active = isCtrl && ctrlState != .off
        return Text(key.title)
            .font(.system(size: 16, weight: .semibold, design: .monospaced))
            .frame(width: 62, height: 40)
            .background(active ? Theme.accent.opacity(ctrlState == .locked ? 0.75 : 0.4) : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onTapGesture { tap(key) }
            .onLongPressGesture(minimumDuration: 0.4) { longPress(key) }
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

/// A roomy editor for writing or dictating a whole message, then sending
/// it in one go (SPEC §6.2). Opened from the key row's compose button, or
/// with dictated text when the user picks "Edit first".
struct ComposeSheet: View {
    @Bindable var session: SessionController
    let page: WindowPage
    @State var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        let isClaude = session.preset(for: page) == .claude
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .textInputAutocapitalization(isClaude ? .sentences : .never)
                .autocorrectionDisabled(!isClaude)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .background(Theme.surface)
                .navigationTitle(isClaude ? "Message to \(page.name)" : "Command for \(page.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Menu {
                            Button("Send without Enter") { send(pressEnter: false) }
                        } label: {
                            Text("Send").bold()
                        } primaryAction: {
                            send(pressEnter: true)
                        }
                        .disabled(text.isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private func send(pressEnter: Bool) {
        session.sendComposed(text, to: page, pressEnter: pressEnter)
        dismiss()
    }
}

/// Shown after keyboard dictation: tap Edit to move the dictated text into
/// the editor. Ignoring it leaves the text in the terminal.
struct DictationEditButton: View {
    let page: WindowPage

    var body: some View {
        Button { page.terminal.editDictation() } label: {
            Label("Edit", systemImage: "square.and.pencil")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
        .shadow(radius: 8)
    }
}

/// One-tap dictation with E.T.'s own recognizer. Tap to start, tap to stop;
/// the text goes into the current window and the Edit button appears.
struct MicButton: View {
    let session: SessionController
    let page: WindowPage
    let voice: VoiceInput

    var body: some View {
        let listening = voice.state == .listening
        Button {
            Task { await toggle() }
        } label: {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(listening ? .white : Color(Theme.background))
                .frame(width: 60, height: 60)
                .background(listening ? Color.red : Theme.accent, in: Circle())
                .symbolEffect(.pulse, isActive: listening)
                .shadow(color: (listening ? Color.red : Theme.accent).opacity(0.4), radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(voice.state == .stopping)
        .sensoryFeedback(.impact(weight: .light), trigger: listening)
    }

    private func toggle() async {
        await MicButton.toggle(session: session, page: page, voice: voice)
    }

    static func toggle(session: SessionController, page: WindowPage, voice: VoiceInput) async {
        switch voice.state {
        case .idle:
            await voice.start(contextualStrings: session.dictationVocabulary)
        case .listening:
            let text = await voice.stop()
            session.sendDictated(text, to: page)
        case .stopping:
            break
        }
    }
}

/// Live transcription while E.T.'s mic is listening. Tap to stop.
struct ListeningBubble: View {
    let session: SessionController
    let page: WindowPage
    let voice: VoiceInput

    var body: some View {
        Button {
            Task { await MicButton.toggle(session: session, page: page, voice: voice) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(.red).symbolEffect(.variableColor, isActive: true)
                Text(voice.text.isEmpty ? "Listening…" : voice.text)
                    .font(.callout)
                    .foregroundStyle(voice.text.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Tap to stop").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }
}
