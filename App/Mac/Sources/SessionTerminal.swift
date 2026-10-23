import AppKit
import ETCore
import ETSSH
@preconcurrency import SwiftTerm
import SwiftUI

enum Theme {
    // Catppuccin Mocha, as on iOS.
    static let background = NSColor(hex: 0x181825)
    static let foreground = NSColor(hex: 0xCDD6F4)
    static let accent = Color(nsColor: NSColor(hex: 0x89B4FA))
    static let bell = Color(nsColor: NSColor(hex: 0xF38BA8))
    static let ansi: [UInt32] = [
        0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
        0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
    ]
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// SwiftTerm's view, with images on the clipboard (⌘V) and dropped files
/// pasted into the session: an image goes to the session's machine and its
/// path is typed, the way a terminal does for a local file.
final class ETTerminalView: TerminalView {
    var onPasteImage: ((Data) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    /// A horizontal swipe (two fingers on a trackpad, one on a Magic
    /// Mouse): +1 when the fingers move left (next tab), -1 when right.
    var onSwipe: ((Int) -> Void)?
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    /// Set once this gesture switched tabs, or turned out to be a scroll.
    private var swipeDecided = false
    private var swipeIsHorizontal = false

    override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        if board.string(forType: .string) == nil, let png = Self.png(from: board) {
            onPasteImage?(png)
            return
        }
        super.paste(sender)
    }

    /// Horizontal gestures switch tabs; everything else scrolls as usual.
    /// SwiftTerm's `scrollWheel` can't be overridden, so a local event
    /// monitor sees the events first and swallows a swipe's.
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, self.onSwipe != nil, event.hasPreciseScrollingDeltas,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            return self.swipe(event) ? nil : event
        }
    }

    /// True when the event is part of a tab swipe (then it doesn't scroll).
    private func swipe(_ event: NSEvent) -> Bool {
        if event.phase.contains(.began) {
            swipeX = 0
            swipeY = 0
            swipeDecided = false
            swipeIsHorizontal = false
        }
        // The momentum after a swipe belongs to it.
        if event.phase.isEmpty, !event.momentumPhase.isEmpty { return swipeIsHorizontal }
        if !swipeDecided {
            swipeX += event.scrollingDeltaX
            swipeY += event.scrollingDeltaY
            if abs(swipeY) > 12, abs(swipeY) > abs(swipeX) {
                swipeDecided = true
            } else if abs(swipeX) > 50, abs(swipeX) > 2 * abs(swipeY) {
                swipeDecided = true
                swipeIsHorizontal = true
                // With natural scrolling the deltas follow the fingers.
                let fingers = event.isDirectionInvertedFromDevice ? swipeX : -swipeX
                onSwipe?(fingers < 0 ? 1 : -1)
            }
        }
        return swipeIsHorizontal || (!swipeDecided && abs(swipeX) > abs(swipeY))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }
        if let png = Self.png(from: board) {
            onPasteImage?(png)
            return true
        }
        return false
    }

    static func png(from board: NSPasteboard) -> Data? {
        if let png = board.data(forType: .png) { return png }
        guard let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// One manymux session shown in a window: SwiftTerm's view plus the
/// attachment that feeds it. Detaching keeps the view and its contents;
/// attaching again repaints.
@MainActor @Observable
final class SessionTerminal: NSObject {
    enum Status: Equatable {
        case attaching
        case live
        case detached
        case failed(String)
        case ended(Int)
    }

    private(set) var ref: SessionRef
    private(set) var status: Status = .detached
    /// The session's size when it isn't the view's (another client is smaller).
    private(set) var sessionSize: (cols: Int, rows: Int)?
    /// Set by the view hosting it; bells in a visible session don't notify.
    var isVisible = false
    @ObservationIgnored let view: ETTerminalView
    @ObservationIgnored private weak var fleet: Fleet?
    @ObservationIgnored private var handle: MmAttachHandle?
    @ObservationIgnored private var input: AsyncStream<[UInt8]>.Continuation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var awaitingOutput = false
    @ObservationIgnored private var sentSize: (cols: Int, rows: Int)?
    /// The size the view has room for (the terminal may show the session's instead).
    @ObservationIgnored private var viewSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var retries = 0

    var isAttached: Bool { status == .attaching || status == .live }

    init(ref: SessionRef, fleet: Fleet) {
        self.ref = ref
        self.fleet = fleet
        view = ETTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500),
                              font: NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular))
        super.init()
        view.terminalDelegate = self
        view.nativeBackgroundColor = Theme.background
        view.nativeForegroundColor = Theme.foreground
        view.caretColor = Theme.foreground
        view.installColors(Theme.ansi.map {
            SwiftTerm.Color(red: UInt16(($0 >> 16) & 0xFF) * 257, green: UInt16(($0 >> 8) & 0xFF) * 257, blue: UInt16($0 & 0xFF) * 257)
        })
        view.optionAsMetaKey = true
        view.onPasteImage = { [weak self] png in self?.pasteImage(png) }
        view.onDropFiles = { [weak self] urls in self?.upload(urls) }
    }

    // MARK: - Font size (View → Bigger / Smaller)

    static var fontSize: CGFloat {
        get { UserDefaults.standard.object(forKey: "fontSize") as? CGFloat ?? 13 }
        set { UserDefaults.standard.set(newValue, forKey: "fontSize") }
    }

    func applyFontSize() {
        view.font = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
    }

    // MARK: - Attach

    func attach(host: IrohHost, machine: String?) {
        detach()
        let generation = UUID()
        self.generation = generation
        status = .attaching
        awaitingOutput = true
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        input = continuation
        let terminal = view.getTerminal()
        let size = viewSize ?? (cols: terminal.cols, rows: terminal.rows)
        let name = ref.name
        fleet?.log.add("Attaching \(ref.id) \(size.cols)x\(size.rows)")
        task = Task {
            do {
                let handle = try await host.mmAttach(machine: machine, name: name, cols: size.cols, rows: size.rows,
                                                     history: 5000, readOnly: false)
                guard self.generation == generation else {
                    await handle.detach()
                    return
                }
                self.handle = handle
                sentSize = size
                setSessionSize(cols: handle.cols, rows: handle.rows)
                status = .live
                retries = 0
                // The window changed size while attaching.
                if let viewSize, viewSize != size { viewResized(cols: viewSize.cols, rows: viewSize.rows) }
                // One writer, so keystrokes stay in order.
                Task {
                    for await bytes in stream {
                        do { try await handle.write(bytes) } catch { break }
                    }
                }
                while true {
                    let output = try await handle.next()
                    guard self.generation == generation else { return }
                    if !self.handle(output) { return }
                }
            } catch {
                guard self.generation == generation else { return }
                attachEnded(error, host: host, machine: machine)
            }
        }
    }

    /// Leaves the session running.
    func detach() {
        generation = UUID()
        task?.cancel()
        task = nil
        input?.finish()
        input = nil
        if let handle {
            Task { await handle.detach() }
        }
        handle = nil
        if isAttached { status = .detached }
    }

    func failed(_ message: String) {
        status = .failed(message)
    }

    /// One output of the session; false after `exit`.
    private func handle(_ output: MmOut) -> Bool {
        switch output {
        case .history(let bytes), .data(let bytes):
            if awaitingOutput {
                // Attaching again: the session repaints from scratch.
                awaitingOutput = false
                view.getTerminal().resetToInitialState()
            }
            view.feed(byteArray: bytes[...])
        case .resync(let bytes):
            awaitingOutput = false
            view.getTerminal().resetToInitialState()
            view.feed(byteArray: bytes[...])
        case .size(let cols, let rows):
            setSessionSize(cols: cols, rows: rows)
        case .event:
            fleet?.scheduleRefresh(ref.machine)
        case .renamed(let name, let refused):
            if let name {
                fleet?.log.add("Renamed \(ref.id) → \(name)")
                let old = ref
                ref.name = name
                fleet?.renamed(old, to: name)
            } else {
                fleet?.flash("Rename refused: \(refused ?? "?")")
            }
        case .exit(let code):
            fleet?.log.add("\(ref.id) exited (\(code))")
            handle = nil
            input?.finish()
            status = .ended(code)
            fleet?.ended(ref)
            return false
        }
        return true
    }

    /// A closed stream on a live connection attaches again, up to three times.
    private func attachEnded(_ error: any Error, host: IrohHost, machine: String?) {
        fleet?.log.add("Attach \(ref.id) ended: \(error)")
        handle = nil
        input?.finish()
        if case HostError.closed = error, retries < 3 {
            retries += 1
            status = .attaching
            Task {
                try? await Task.sleep(for: .seconds(1))
                if self.status == .attaching, self.handle == nil { self.fleet?.reattach(self) }
            }
            return
        }
        status = .failed(Fleet.describe(error))
    }

    /// The session took a size: show it, even if the view is another size.
    private func setSessionSize(cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        let room = viewSize ?? (cols: terminal.cols, rows: terminal.rows)
        sessionSize = (cols, rows) == room ? nil : (cols, rows)
        guard cols > 1, rows > 1, cols != terminal.cols || rows != terminal.rows else { return }
        terminal.resize(cols: cols, rows: rows)
        view.needsDisplay = true
    }

    /// The window changed size: ask the session for the view's size.
    private func viewResized(cols: Int, rows: Int) {
        guard let handle, status == .live else { return }
        if let sentSize, sentSize == (cols, rows) { return }
        sentSize = (cols, rows)
        Task {
            do { try await handle.resize(cols: cols, rows: rows) } catch { fleet?.log.add("Resize failed: \(error)") }
        }
    }

    /// Takes the session to the window's size again (after a smaller client left).
    func fitToWindow() {
        sentSize = nil
        let terminal = view.getTerminal()
        let room = viewSize ?? (cols: terminal.cols, rows: terminal.rows)
        viewResized(cols: room.cols, rows: room.rows)
    }

    func rename(to name: String) {
        guard let handle else { return }
        Task {
            do { try await handle.rename(to: name) } catch { fleet?.flash("Rename failed: \(Fleet.describe(error))") }
        }
    }

    func send(_ bytes: [UInt8]) {
        input?.yield(bytes)
    }

    /// Gives the keyboard back to the terminal (after a toolbar button).
    func focus() {
        view.window?.makeFirstResponder(view)
    }

    // MARK: - Images and files

    private func pasteImage(_ png: Data) {
        guard let handle else { return }
        fleet?.log.add("Pasting image (\(png.count) bytes) into \(ref.id)")
        Task {
            do { try await handle.paste(kind: "png", bytes: png) } catch { fleet?.flash("Paste failed: \(Fleet.describe(error))") }
        }
    }

    /// Dropped or picked files: images are pasted (uploaded, path typed);
    /// other files are uploaded to ~/.cache/et-uploads on the session's
    /// machine and their paths typed.
    func upload(_ urls: [URL]) {
        guard let fleet else { return }
        guard let handle else {
            fleet.flash("\(ref.name) isn't attached")
            return
        }
        let images = ["png", "jpg", "jpeg", "gif", "webp"]
        Task {
            var paths: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    fleet.flash("Couldn't read \(url.lastPathComponent)")
                    continue
                }
                let ext = url.pathExtension.lowercased()
                do {
                    if images.contains(ext) {
                        try await handle.paste(kind: ext == "jpeg" ? "jpg" : ext, bytes: data)
                    } else {
                        let path = try await fleet.upload(data, name: url.lastPathComponent, to: ref.machine)
                        paths.append(path)
                    }
                } catch {
                    fleet.flash("Upload failed: \(Fleet.describe(error))")
                }
            }
            if !paths.isEmpty {
                send(Array(paths.map(Self.shellQuoted).joined(separator: " ").utf8))
            }
        }
    }

    private static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SessionTerminal: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        send(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        viewSize = (newCols, newRows)
        viewResized(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
    }

    func bell(source: TerminalView) {
        if !NSApp.isActive || !isVisible { NSApp.requestUserAttention(.informationalRequest) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// Hosts a session's terminal view in SwiftUI.
struct TerminalPane: NSViewRepresentable {
    let terminal: SessionTerminal

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        place(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if terminal.view.superview !== container { place(in: container) }
    }

    private func place(in container: NSView) {
        let view = terminal.view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
