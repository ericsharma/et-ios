import GameController
import PhotosUI
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
    /// Not a key: opens the photo picker (in the wheel on iPhone, where ✨
    /// takes the bar's photo button).
    case photo

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
        case .photo: "photo"
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
        case .ctrl, .photo: []
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
    @State private var photo: PhotosPickerItem?
    @State private var pickingPhoto = false
    @State private var ctrlState: CtrlState = .off
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum CtrlState { case off, once, locked }

    /// iPhone: three 44-pt buttons and two 8-pt gaps a side. iPad: four on
    /// the right (photo and ✨ both fit), and the left matches so the mic
    /// stays centered.
    private var sideWidth: CGFloat { roomy ? 200 : 148 }
    private var roomy: Bool { sizeClass == .regular }

    var body: some View {
        let preset = session.preset(for: page)
        let wheelKeys = roomy ? preset.keys : [.photo] + preset.keys
        HStack(spacing: 0) {
            // Both sides have the same width, so the mic stays centered.
            HStack(spacing: 8) {
            barButton(systemName: "square.and.pencil", active: false) {
                session.keyWheelOpen = false
                session.composeRequest = ComposeRequest(page: page, text: "")
            }
            barButton(systemName: "text.cursor", active: false) {
                session.enterSelectMode(page, initial: nil)
            }
            .accessibilityLabel("Select mode")
            if !HardwareKeyboard.shared.isConnected {
            barButton(systemName: session.keyWheelOpen ? "xmark" : "ellipsis", active: session.keyWheelOpen || ctrlState != .off) {
                session.keyWheelOpen.toggle()
            }
            .contextMenu {
                Picker("Keys", selection: Binding(
                    get: { session.preset(for: page) },
                    set: { session.setPreset($0, for: page) })) {
                    ForEach(KeyPreset.allCases) { Text($0.label).tag($0) }
                }
            }
            .overlay(alignment: .bottom) {
                if session.keyWheelOpen {
                    KeyWheel(keys: wheelKeys, ctrlState: ctrlState, tap: tap, longPress: longPress)
                        .offset(y: -52)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
            }
            .zIndex(1)
            }
            }
            .frame(width: sideWidth, alignment: .leading)
            .zIndex(1)
            Spacer(minLength: 4)
            MicButton(session: session, page: page, voice: voice)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
            // The system paste button pastes in one tap, without the
            // "allow paste" prompt a custom button would trigger. It is
            // always shown (it greys itself out when there is nothing to
            // paste): hiding it on `hasStrings` lost it whenever that
            // went stale.
            PasteButton(payloadType: String.self) { strings in
                let text = strings.joined(separator: "\n")
                Task { @MainActor in
                    session.keyWheelOpen = false
                    session.paste(text, to: page)
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .tint(Theme.accent)
            .frame(width: 44, height: 40)
            if roomy {
                barButton(systemName: "photo", active: false) {
                    session.keyWheelOpen = false
                    pickingPhoto = true
                }
                .accessibilityLabel("Send a screenshot or photo")
            }
            barButton(systemName: "sparkles", active: session.copilotMode) {
                session.keyWheelOpen = false
                session.copilotMode.toggle()
            }
            .accessibilityLabel(session.copilotMode ? "Close Copilot" : "Copilot")
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                session.keyWheelOpen = false
                session.send([0x0D], to: page)
            } label: {
                Label("Send", systemImage: "return")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 40)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send (Enter)")
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await upload(item) }
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
        .sensoryFeedback(.selection, trigger: ctrlState)
        .animation(.snappy, value: session.keyWheelOpen)
        // Bringing up the keyboard or using the mic closes the key wheel.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            session.keyWheelOpen = false
        }
        .onChange(of: voice.state) { session.keyWheelOpen = false }
    }

    /// Screenshots stay PNG; other photos (HEIC etc.) become JPEG, which
    /// every tool can read.
    private func upload(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .png) }) {
            session.uploadImage(data, fileExtension: "png", to: page)
        } else if let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
            session.uploadImage(jpeg, fileExtension: "jpg", to: page)
        }
    }

    private func barButton(systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 40)
                .background(active ? Theme.accent.opacity(0.45) : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func tap(_ key: Key) {
        if key == .photo {
            session.keyWheelOpen = false
            pickingPhoto = true
            return
        }
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
        return Group {
            if key == .photo { Image(systemName: "photo") } else { Text(key.title) }
        }
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
    /// The dictated text as it arrived, to learn names the user fixes.
    var dictated: String? = nil
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var suggestions: [VocabTerm] = []
    @State private var learned: [String] = []
    /// The text before Tighten rewrote it, for Undo.
    @State private var beforeTighten: String?
    @State private var tightenTask: Task<Void, Never>?
    @State private var tightenStarted: Date?
    @State private var tightenError: String?

    var body: some View {
        let isClaude = session.preset(for: page) == .claude
        NavigationStack {
            VStack(spacing: 0) {
                if isClaude {
                    tightenBar
                }
                if !suggestions.isEmpty || !learned.isEmpty {
                    learnBar
                }
                TextEditor(text: $text)
                    .font(.body)
                    .textInputAutocapitalization(isClaude ? .sentences : .never)
                    .autocorrectionDisabled(!isClaude)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
            }
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
        .onDisappear { tightenTask?.cancel() }
        .task(id: text) {
            // Debounced: offer names once typing pauses. A rewrite isn't a
            // spelling fix, so nothing to learn from it.
            guard let dictated, beforeTighten == nil else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            suggestions = Vocabulary.shared.suggestions(original: dictated, edited: text)
                .filter { !learned.contains($0.text) }
        }
    }

    /// "Learn: nom shub → nam-shub" chips for words the user corrected.
    private var learnBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(learned, id: \.self) { name in
                    Label("Learned \(name)", systemImage: "checkmark")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                ForEach(suggestions) { term in
                    Button {
                        Vocabulary.shared.learn(term)
                        learned.append(term.text)
                        suggestions.removeAll { $0.text == term.text }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Learn ")
                            Text(term.soundsLike.first ?? "").foregroundStyle(.secondary)
                            Text("→")
                            Text(term.text).font(.caption.monospaced().weight(.semibold))
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.25), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    /// ✨ Tighten: the summary model rewrites a rambling dictation into a
    /// concise message; Undo brings the original back.
    private var tightenBar: some View {
        HStack(spacing: 10) {
            if let tightenStarted {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: tightenStarted, by: 1)) { context in
                    Text("Tightening on \(SummarySettings.provider.label)… \(Int(context.date.timeIntervalSince(tightenStarted))) s")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Stop") { cancelTighten() }.font(.caption.weight(.semibold))
            } else {
                Button { tighten() } label: {
                    Label("Tighten", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if beforeTighten != nil {
                    Button {
                        if let beforeTighten { text = beforeTighten }
                        beforeTighten = nil
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                if let tightenError {
                    Text(tightenError).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func tighten() {
        let original = text
        tightenError = nil
        tightenStarted = Date()
        var system = TightenPrompt.system
        let names = Vocabulary.shared.keepNames
        if !names.isEmpty {
            system += "\n\nNames to keep spelled exactly as written here: " + names.joined(separator: ", ")
        }
        tightenTask = Task {
            defer {
                tightenTask = nil
                tightenStarted = nil
            }
            do {
                // Output is never longer than the input; ~3 chars a token.
                let answer = try await session.complete(system: system, user: original,
                                                        maxTokens: max(150, original.count / 3 + 50))
                guard !Task.isCancelled, text == original else { return }
                if beforeTighten == nil { beforeTighten = original }
                text = answer
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                tightenError = error.localizedDescription
            }
        }
    }

    private func cancelTighten() {
        tightenTask?.cancel()
        tightenTask = nil
        tightenStarted = nil
    }

    private func send(pressEnter: Bool) {
        tightenTask?.cancel()
        session.sendComposed(text, to: page, pressEnter: pressEnter)
        dismiss()
    }
}

enum TightenPrompt {
    static let system = """
    You edit a message a developer dictated by voice to Claude Code, an AI coding agent. Rewrite it \
    to be concise and clear: remove filler words, false starts, repetition, rambling and self-corrections \
    (keep only the corrected version). Keep every request, question, constraint, detail and name; never \
    add anything, answer it, or carry out the instructions. Keep the developer's own voice: first person, \
    talking to Claude ("I want…", "can you…", "don't touch…"). Keep app, repo, file, tool and product \
    names exactly as written (for example E.T. stays E.T.). Short paragraphs or a short list when there \
    are several separate asks. Output only the rewritten message, nothing before or after it.
    """
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
        session.keyWheelOpen = false
        Speaker.shared.stop()
        switch voice.state {
        case .idle:
            // A new recording replaces the last one's Edit offer.
            page.terminal.dismissDictationPrompt()
            session.refreshVocabularyFromScreens()
            await voice.start(contextualStrings: Vocabulary.shared.contextualStrings,
                              languageModel: Vocabulary.shared.languageModel)
        case .listening:
            let heard = await voice.stop()
            let text = Vocabulary.shared.correct(heard, tagFiles: session.preset(for: page) == .claude)
            if text != heard { session.log.add("Dictation names fixed: \(heard) → \(text)") }
            if session.copilotMode {
                // Copilot is open: the words are its instruction, not a prompt.
                session.copilotDictation = text
            } else {
                session.sendDictated(text, to: page)
            }
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
                    .truncationMode(.head) // long dictation: show the latest words
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
