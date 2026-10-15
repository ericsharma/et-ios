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
@MainActor
final class SelectModeModel {
    weak var textView: SelectTextView?
    var screenStart = 0

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
    @State private var frozen: TerminalText?
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Select", systemImage: "text.cursor").font(.subheadline.weight(.semibold))
                Text("tap word · double-tap line · triple-tap block · long-press + drag")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
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
        .onAppear {
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

    func makeCoordinator() -> Coordinator { Coordinator(sendToEditor: sendToEditor, copyOneLine: copyOneLine) }

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
        let sendToEditor: () -> Void
        let copyOneLine: () -> Void
        init(sendToEditor: @escaping () -> Void, copyOneLine: @escaping () -> Void) {
            self.sendToEditor = sendToEditor
            self.copyOneLine = copyOneLine
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

    /// The logical line around `i`, without its newline.
    private func lineRange(at i: Int) -> NSRange {
        let ns = text as NSString
        var r = ns.lineRange(for: NSRange(location: min(max(i, 0), max(ns.length - 1, 0)), length: 0))
        if r.length > 0, ns.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        return r
    }
}

/// Floating button shown while text is selected in the live terminal:
/// opens select mode with that selection.
struct SelectButton: View {
    let session: SessionController
    let page: WindowPage

    var body: some View {
        Button {
            session.enterSelectMode(page, initial: page.terminal.view.getSelection())
        } label: {
            Label("Select", systemImage: "text.cursor")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
        .shadow(radius: 8)
    }
}
