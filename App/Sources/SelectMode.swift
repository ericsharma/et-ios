import SwiftUI
import UIKit

/// Opens select mode for a window, optionally pre-selecting some text.
struct SelectModeRequest: Identifiable {
    let id = UUID()
    let page: WindowPage
    let initialSelection: String?
}

/// The frozen text of a terminal for select mode: history plus screen, with
/// soft-wrapped rows joined back into their logical lines.
struct TerminalText {
    var text: String
    /// UTF-16 offset where the visible screen begins.
    var screenStart: Int
}

extension TerminalHost {
    func frozenText() -> TerminalText {
        let t = terminal
        var rows: [(text: String, wrapped: Bool)] = []
        var row = t.buffer.totalLinesTrimmed
        while let line = t.getScrollInvariantLine(row: row) {
            rows.append((line.translateToString(trimRight: true), line.isWrapped))
            row += 1
        }
        var lines: [String] = []
        var current: String?
        var lineOfRow: [Int] = []  // logical line index of each physical row
        for (text, wrapped) in rows {
            if wrapped, current != nil {
                current! += text
            } else {
                if let current { lines.append(current) }
                current = text
            }
            lineOfRow.append(lines.count)
        }
        if let current { lines.append(current) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let screenTop = max(0, rows.count - t.rows)
        let screenLine = min(lineOfRow.indices.contains(screenTop) ? lineOfRow[screenTop] : 0, max(lines.count - 1, 0))
        let screenStart = lines.prefix(screenLine).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return TerminalText(text: lines.joined(separator: "\n"), screenStart: screenStart)
    }
}

/// Talks to the text view from the toolbar.
@MainActor @Observable
final class SelectModeModel {
    @ObservationIgnored weak var textView: SelectTextView?
    @ObservationIgnored var screenStart = 0
    /// Which end of the selection the volume buttons move.
    var movingStart = false
    /// Characters copied by copy-on-select, for the header.
    var autoCopied: Int?
    @ObservationIgnored private var copyTask: Task<Void, Never>?

    /// Copy-on-select: the selection goes to the clipboard once it stops
    /// changing for a moment (drags and held volume buttons change it a lot).
    func selectionChanged() {
        copyTask?.cancel()
        copyTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let text = selectedText
            guard !text.isEmpty else { return }
            UIPasteboard.general.string = text
            autoCopied = text.count
        }
    }

    @ObservationIgnored private var lastPress: (up: Bool, at: Date)?

    /// A volume button press. Each press moves the chosen end one character
    /// right away, so holding a button keeps moving. Up and down pressed
    /// together (opposite directions within a third of a second) swaps
    /// Start/End instead; holding one button only ever repeats one
    /// direction, so it never swaps by accident.
    func volumePressed(up: Bool) {
        let now = Date()
        if let last = lastPress, last.up != up, now.timeIntervalSince(last.at) < 0.33 {
            // This press undoes the first one's move, then swap ends.
            nudge(forward: up)
            movingStart.toggle()
            lastPress = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        nudge(forward: up)
        lastPress = (up, now)
    }

    /// Move the chosen end one character forward/back.
    func nudge(forward: Bool) {
        textView?.moveEnd(start: movingStart, forward: forward)
    }

    var selectedText: String {
        guard let tv = textView, tv.selectedRange.length > 0 else { return "" }
        return (tv.text as NSString).substring(with: tv.selectedRange)
    }

    func selectScreen() {
        guard let tv = textView else { return }
        let length = (tv.text as NSString).length
        tv.select(NSRange(location: min(screenStart, length), length: max(0, length - screenStart)))
    }

    /// Wrapped and multi-line text as one line (for long commands).
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Select mode (frozen screen, selection gestures, copy toolbar). Shown over
/// the terminal area; live output keeps going to the hidden terminal.
struct SelectModeView: View {
    let session: SessionController
    let request: SelectModeRequest
    @State private var model = SelectModeModel()
    @State private var volume = VolumeButtons()
    @State private var frozen: TerminalText?
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Select", systemImage: "text.cursor").font(.subheadline.weight(.semibold))
                    Spacer()
                    // Which end the volume buttons move.
                    Picker("Volume buttons move", selection: $model.movingStart) {
                        Text("Start").tag(true)
                        Text("End").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    Image(systemName: "speaker.wave.2").font(.caption).foregroundStyle(.secondary)
                }
                if let n = model.autoCopied {
                    Label("Copied \(n) characters", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.green)
                }
                Text("tap word · double-tap line · triple-tap block · long-press + drag · volume ± moves the \(model.movingStart ? "start" : "end") by a letter · up+down together swaps")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.surface)
            if let frozen {
                SelectTextRepresentable(model: model, text: frozen, initialSelection: request.initialSelection,
                                        sendToEditor: sendToEditor, copyOneLine: copyOneLine)
            } else {
                Color(Theme.background)
            }
            toolbar
        }
        .overlay(alignment: .top) {
            if let copied {
                Label(copied, systemImage: "doc.on.doc").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 40)
            }
        }
        .background { HiddenVolumeView(buttons: volume).frame(width: 1, height: 1) }
        .onDisappear { volume.stop() }
        .onAppear {
            volume.onPress = { [model] up in model.volumePressed(up: up) }
            volume.start()
            _ = request.page.terminal.view.resignFirstResponder()
            let text = request.page.terminal.frozenText()
            model.screenStart = text.screenStart
            frozen = text
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            tool("Copy", "doc.on.doc") { finish(copy: model.selectedText) }
            tool("One line", "arrow.right.to.line") { copyOneLine() }
            tool("Editor", "square.and.pencil") { sendToEditor() }
            tool("Screen", "rectangle.dashed") { model.selectScreen() }
            tool("Done", "checkmark") { exit() }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.surface)
    }

    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func copyOneLine() { finish(copy: SelectModeModel.oneLine(model.selectedText)) }

    private func sendToEditor() {
        let text = model.selectedText
        exit()
        session.composeRequest = ComposeRequest(page: request.page, text: text)
    }

    /// Copying ends select mode.
    private func finish(copy text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = "Copied \(text.count) characters"
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            exit()
        }
    }

    private func exit() {
        request.page.terminal.view.clearSelection()
        session.selectMode = nil
    }
}

struct SelectTextRepresentable: UIViewRepresentable {
    let model: SelectModeModel
    let text: TerminalText
    let initialSelection: String?
    let sendToEditor: () -> Void
    let copyOneLine: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, sendToEditor: sendToEditor, copyOneLine: copyOneLine) }

    func makeUIView(context: Context) -> SelectTextView {
        let tv = SelectTextView()
        tv.delegate = context.coordinator
        tv.text = text.text
        model.textView = tv
        DispatchQueue.main.async {
            let ns = tv.text as NSString
            if let initial = initialSelection, !initial.isEmpty {
                let found = ns.range(of: initial, options: .backwards)
                if found.location != NSNotFound {
                    tv.select(found)
                    tv.scrollRangeToVisible(found)
                    return
                }
            }
            tv.scrollRangeToVisible(NSRange(location: ns.length, length: 0))
        }
        return tv
    }

    func updateUIView(_ uiView: SelectTextView, context: Context) {}

    final class Coordinator: NSObject, UITextViewDelegate {
        let model: SelectModeModel
        let sendToEditor: () -> Void
        let copyOneLine: () -> Void
        init(model: SelectModeModel, sendToEditor: @escaping () -> Void, copyOneLine: @escaping () -> Void) {
            self.model = model
            self.sendToEditor = sendToEditor
            self.copyOneLine = copyOneLine
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            MainActor.assumeIsolated { model.selectionChanged() }
        }

        /// The selection's own menu gets the select-mode actions too.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let extras = UIMenu(options: .displayInline, children: [
                UIAction(title: "Copy as one line", image: UIImage(systemName: "arrow.right.to.line")) { [copyOneLine] _ in copyOneLine() },
                UIAction(title: "Send to editor", image: UIImage(systemName: "square.and.pencil")) { [sendToEditor] _ in sendToEditor() },
            ])
            return UIMenu(children: [extras] + suggestedActions)
        }
    }
}

/// A read-only text view with terminal-friendly selection gestures on top of
/// iOS's own (handles with magnifier, long-press + drag):
/// tap = shell word (path, URL, flag), double-tap = line, triple-tap = block
/// of consecutive non-empty lines.
final class SelectTextView: UITextView {
    private var ownTaps: [UITapGestureRecognizer] = []

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        font = UIFont.monospacedSystemFont(ofSize: TerminalHost.fontSize, weight: .regular)
        textColor = Theme.foreground
        backgroundColor = Theme.background
        tintColor = UIColor(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 1)
        textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textContainer.lineFragmentPadding = 0
        alwaysBounceVertical = true
        dataDetectorTypes = []

        let triple = UITapGestureRecognizer(target: self, action: #selector(tripleTapped(_:)))
        triple.numberOfTapsRequired = 3
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        double.require(toFail: triple)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped(_:)))
        single.require(toFail: double)
        ownTaps = [single, double, triple]
        ownTaps.forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Our taps replace the text view's own tap handling; its long-press,
    /// handle drags and magnifier stay.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let tap = gestureRecognizer as? UITapGestureRecognizer, !ownTaps.contains(tap), tap.view === self {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func select(_ range: NSRange) {
        _ = becomeFirstResponder()
        selectedRange = range
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func index(at gesture: UIGestureRecognizer) -> Int? {
        let point = gesture.location(in: self)
        guard let position = closestPosition(to: point) else { return nil }
        return offset(from: beginningOfDocument, to: position)
    }

    @objc private func singleTapped(_ g: UITapGestureRecognizer) {
        guard let i = index(at: g) else { return }
        let ns = text as NSString
        guard ns.length > 0 else { return }
        var start = min(i, ns.length - 1), end = start
        let space = CharacterSet.whitespacesAndNewlines
        func isWord(_ at: Int) -> Bool {
            guard let scalar = UnicodeScalar(ns.character(at: at)) else { return true }
            return !space.contains(scalar)
        }
        guard isWord(start) else { return }
        while start > 0, isWord(start - 1) { start -= 1 }
        while end < ns.length - 1, isWord(end + 1) { end += 1 }
        select(NSRange(location: start, length: end - start + 1))
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let i = index(at: g) else { return }
        select(lineRange(at: i))
    }

    @objc private func tripleTapped(_ g: UITapGestureRecognizer) {
        guard let i = index(at: g) else { return }
        let ns = text as NSString
        var range = lineRange(at: i)
        func isBlank(_ r: NSRange) -> Bool { ns.substring(with: r).trimmingCharacters(in: .whitespaces).isEmpty }
        guard !isBlank(range) else { select(range); return }
        // Grow over neighbouring non-empty lines.
        while range.location > 0 {
            let above = lineRange(at: range.location - 1)
            if isBlank(above) { break }
            range = NSRange(location: above.location, length: NSMaxRange(range) - above.location)
        }
        while NSMaxRange(range) < ns.length - 1 {
            let below = lineRange(at: NSMaxRange(range) + 1)
            if isBlank(below) { break }
            range = NSRange(location: range.location, length: NSMaxRange(below) - range.location)
        }
        select(range)
    }

    // MARK: - Moving an end by characters (volume buttons)

    /// Moves the start or end of the selection one character forward or
    /// back, for precise ends. With no selection, selects the first
    /// character in view.
    func moveEnd(start movingStart: Bool, forward: Bool) {
        let ns = text as NSString
        guard ns.length > 0 else { return }
        let range = selectedRange
        if range.length == 0 {
            let top = closestPosition(to: CGPoint(x: textContainerInset.left + 2, y: contentOffset.y + textContainerInset.top + 4))
            let i = min(top.map { offset(from: beginningOfDocument, to: $0) } ?? 0, ns.length - 1)
            select(NSRange(location: i, length: 1))
            return
        }
        var lo = range.location, hi = NSMaxRange(range)  // hi is exclusive
        if movingStart {
            lo = forward ? min(lo + 1, hi - 1) : max(lo - 1, 0)
        } else {
            hi = forward ? min(hi + 1, ns.length) : max(hi - 1, lo + 1)
        }
        // Keep composed characters (emoji, accents) whole.
        let fixed = ns.rangeOfComposedCharacterSequences(for: NSRange(location: lo, length: hi - lo))
        select(fixed)
        scrollRangeToVisible(NSRange(location: movingStart ? fixed.location : max(fixed.location, NSMaxRange(fixed) - 1), length: 1))
    }

    /// The logical line around `i`, without its newline.
    private func lineRange(at i: Int) -> NSRange {
        let ns = text as NSString
        var r = ns.lineRange(for: NSRange(location: min(max(i, 0), max(ns.length - 1, 0)), length: 0))
        if r.length > 0, ns.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return r
    }
}
