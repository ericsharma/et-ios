#if DEBUG
import AppKit
import ETCore
import SwiftUI

/// Launch flags for testing on a headless Mac (debug builds only):
///   --open <machine/session>  select a session in the first window
///   --snapshot <file.png>     every 3 s, draw the front window into a PNG
///   --spawn <machine:command>  start a session and show it
///   --type <text>             after 6 s, type into the selected session
///   --drop <file>             once the shown session is live, send the file
///                             as a drop on its terminal does
///   --logbook <id|place>      with --offscreen, build the Logbook window, and
///                             show a transcript (machine/session id, a
///                             session id on mac-mini, or machine/* for its
///                             newest), a place (now, findings, unsorted,
///                             archive, project:<n> = the n-th project),
///                             "report" (Refresh the report) or "last" (the
///                             last report, no Refresh)
///   --inspector               with --logbook <id>: open the inspector
///   --evidence                with --logbook findings: open the first
///                             finding's first evidence link
///   --logbook-grouping        with --logbook last: rename
///                             project 1, move a session of the last project
///                             to none; then log the report
///   --logbook-send <m/s>      after 8 s, send the shown transcript's last
///                             turn (or report project 1) to machine/session
///   --logbook-earlier         with --logbook <id>: load the transcript, then
///                             Load earlier twice, logging each step
///   --agents                  show the Agents page
///   --size <W>x<H>            the offscreen window's size (default 1100x700)
///   --offscreen               build the main window off screen (no display)
///   --hittest                 after 10 s, log the view under the top 160 pt
@MainActor
enum DebugHooks {
    static func run(_ fleet: Fleet) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        if let target = value("--open") {
            let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                Task {
                    while fleet.phase != .ready { try? await Task.sleep(for: .milliseconds(300)) }
                    fleet.requestedRef = SessionRef(machine: parts[0], name: parts[1])
                }
            }
        }
        if args.contains("--agents") {
            Task {
                while fleet.phase != .ready { try? await Task.sleep(for: .milliseconds(300)) }
                fleet.requestedLogbook = .agents
            }
        }
        if let page = value("--logbook") {
            Task {
                while fleet.phase != .ready { try? await Task.sleep(for: .milliseconds(300)) }
                try? await Task.sleep(for: .seconds(1))
                var key = LogbookKey(id: page) ?? LogbookKey(machine: "mac-mini", sessionId: page)
                if key.sessionId == "*", let logbook {
                    while !logbook.loaded { try? await Task.sleep(for: .milliseconds(300)) }
                    key = logbook.sessions.filter { $0.key.machine == key.machine }.max { $0.last < $1.last }?.key ?? key
                    fleet.log.add("Debug: Logbook \(key.id)")
                }
                let places: [String: LogbookPlace] = ["now": .now, "findings": .findings, "unsorted": .unsorted, "archive": .archive]
                if let place = places[page] {
                    logbook?.place = place
                    // --evidence: open the first finding's first evidence link.
                    guard place == .findings, args.contains("--evidence"), let logbook else { return }
                    while logbook.findings.shown.first?.evidence.first == nil { try? await Task.sleep(for: .milliseconds(300)) }
                    let item = logbook.findings.shown[0].evidence[0]
                    fleet.log.add("Debug: evidence \(item.key) turn \(item.turn)")
                    if let key = LogbookKey(id: item.key) {
                        logbook.pendingTurn = LogbookTurnRef(key: key, turn: item.turn)
                        logbook.selected = key
                    }
                    return
                }
                if page.hasPrefix("project:"), let logbook {
                    while logbook.report == nil { try? await Task.sleep(for: .milliseconds(300)) }
                    let n = Int(page.dropFirst(8)) ?? 1
                    if let project = logbook.report?.projects.dropFirst(n - 1).first { logbook.place = .project(project.id) }
                    return
                }
                if page != "report", page != "last", let logbook {
                    while !logbook.loaded { try? await Task.sleep(for: .milliseconds(300)) }
                    logbook.open(key)
                    logbook.inspector = args.contains("--inspector")
                }
                if let logbook, page != "report", page != "last" {
                    while !logbook.loaded { try? await Task.sleep(for: .milliseconds(300)) }
                    let session = logbook.session(key)
                    fleet.log.add("Debug: \(key.id): \(session.map { "\($0.bytes) bytes, previous \($0.previous ?? "none")" } ?? "not listed")")
                }
                if page == "report" { logbook?.refreshReport() }
                guard page == "last", let logbook else { return }
                while logbook.report == nil { try? await Task.sleep(for: .milliseconds(300)) }
                @MainActor func dump(_ when: String) {
                    let r = logbook.report!
                    fleet.log.add("Debug: report \(r.id) \(when): projects " + r.projects.map { "\($0.name) [\($0.sessions.map(\.key).joined(separator: ", "))]" }.joined(separator: "; ")
                                  + "; unassigned [\(r.unassigned.joined(separator: ", "))]; \(r.proposals.count) proposals")
                }
                dump("loaded")
                guard args.contains("--logbook-grouping") else { return }
                let r = logbook.report!
                if let first = r.projects.first { logbook.rename(project: first.id, to: first.name + " (renamed)") }
                if let last = r.projects.last, let key = last.sessions.first?.key { logbook.move(session: key, to: nil) }
                try? await Task.sleep(for: .seconds(5))
                dump("after grouping")
            }
        }
        if let target = value("--logbook-send"), let page = value("--logbook") {
            let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
            Task {
                try? await Task.sleep(for: .seconds(8))
                guard parts.count == 2, let logbook else { return }
                let key = (LogbookKey(id: page) ?? LogbookKey(machine: "mac-mini", sessionId: page))
                let transcript = logbook.transcript(key)
                if page == "report" || page == "last", let report = logbook.report, let project = report.projects.first {
                    logbook.send(.reportSection(reportId: report.id, projectId: project.id), to: parts[0], session: parts[1])
                    return
                }
                transcript.start(size: logbook.session(key)?.bytes ?? 0)
                while transcript.turns.last(where: { $0.id != Transcript.leadingTurnID }) == nil {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                let last = transcript.turns.last { $0.id != Transcript.leadingTurnID }!
                logbook.send(.turns(key, [last.id]), to: parts[0], session: parts[1])
                transcript.stop()
            }
        }
        if args.contains("--logbook-earlier"), let page = value("--logbook") {
            Task {
                while fleet.phase != .ready { try? await Task.sleep(for: .milliseconds(300)) }
                guard let logbook else { return }
                let key = (LogbookKey(id: page) ?? LogbookKey(machine: "mac-mini", sessionId: page))
                while logbook.session(key) == nil { try? await Task.sleep(for: .milliseconds(300)) }
                let transcript = logbook.transcript(key)
                transcript.start(size: logbook.session(key)?.bytes ?? 0)
                for _ in 0..<2 {
                    while transcript.loading || transcript.loadingEarlier { try? await Task.sleep(for: .milliseconds(300)) }
                    try? await Task.sleep(for: .seconds(1))
                    fleet.log.add("Debug: \(transcript.turns.count) turns from \(transcript.startOffset); Load earlier")
                    transcript.loadEarlier()
                }
                while transcript.loading || transcript.loadingEarlier { try? await Task.sleep(for: .milliseconds(300)) }
                fleet.log.add("Debug: \(transcript.turns.count) turns from \(transcript.startOffset)")
                transcript.stop()
            }
        }
        if let spec = value("--spawn") {
            // machine:command, e.g. mac-mini:claude
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            Task {
                while fleet.phase != .ready { try? await Task.sleep(for: .milliseconds(300)) }
                if let ref = await fleet.spawn(machine: parts[0], name: nil, command: parts.count > 1 ? [parts[1]] : [],
                                               cols: 120, rows: 40) {
                    fleet.requestedRef = ref
                }
            }
        }
        if let text = value("--type") {
            Task {
                try? await Task.sleep(for: .seconds(6))
                for terminal in fleet.terminals.values where terminal.isVisible {
                    terminal.send(Array(text.replacingOccurrences(of: "\\n", with: "\r").utf8))
                }
            }
        }
        if let path = value("--drop") {
            Task {
                while true {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let terminal = fleet.terminals.values.first(where: { $0.isVisible && $0.status == .live }) {
                        fleet.log.add("Debug drop of \(path) on \(terminal.ref.id)")
                        terminal.sendFiles([URL(fileURLWithPath: path)])
                        return
                    }
                }
            }
        }
        if let spec = value("--fetch") {
            // machine:path, a shared file fetched into Caches (Files > Quick Look)
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            Task {
                while fleet.phase != .ready { try? await Task.sleep(for: .milliseconds(300)) }
                guard parts.count == 2, let host = fleet.directHosts()[parts[0]] else {
                    fleet.log.add("Debug fetch: no machine \(parts.first ?? "")"); return
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("et-fetch").path
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                do {
                    let local = try await host.fetchFile(parts[1], into: folder) { _, _ in }
                    fleet.log.add("Debug fetch of \(parts[1]) from \(parts[0]) to \(local)")
                } catch {
                    fleet.log.add("Debug fetch of \(parts[1]) failed: \(error)")
                }
            }
        }
        if args.contains("--describe") {
            Task {
                try? await Task.sleep(for: .seconds(8))
                for t in fleet.terminals.values {
                    let v = t.view
                    @MainActor func describe(_ view: NSView, _ depth: Int) {
                        fleet.log.add(String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(view.frame) layerBG=\(String(describing: view.layer?.backgroundColor)) opaque=\(view.isOpaque)")
                        for sub in view.subviews { describe(sub, depth + 1) }
                    }
                    describe(v, 0)
                    fleet.log.add("appearance=\(v.effectiveAppearance.name.rawValue) nativeBG=\(v.nativeBackgroundColor)")
                }
            }
        }
        if args.contains("--hittest") {
            Task {
                try? await Task.sleep(for: .seconds(10))
                guard let window = offscreenWindow ?? NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 300 }),
                      let root = window.contentView?.superview else { return }
                let h = root.bounds.height
                for y in stride(from: 0, through: 160, by: 10) {
                    var row: [String] = []
                    for x in stride(from: 0, through: root.bounds.width, by: 100) {
                        let p = CGPoint(x: x, y: root.isFlipped ? CGFloat(y) : h - CGFloat(y))
                        row.append("\(Int(x)):\(root.hitTest(p).map { "\(type(of: $0))" } ?? "nil")")
                    }
                    fleet.log.add("hit y=\(y) " + row.joined(separator: " "))
                }
            }
        }
        if let path = value("--snapshot") {
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(3))
                    snapshot(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    static var offscreenWindow: NSWindow?
    static var logbook: Logbook?

    /// A window that never goes on screen (the Mac mini is headless), so
    /// hit tests and snapshots run against the real views.
    static func offscreen(_ root: some View, fleet: Fleet, setup: Setup) {
        let args = CommandLine.arguments
        let size = args.firstIndex(of: "--size").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            .map { $0.split(separator: "x").compactMap { Double($0) } }
        let frame = CGRect(x: 0, y: 0, width: size?.first ?? 1100, height: size?.last ?? 700)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .resizable, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar()
        window.contentViewController = args.contains("--logbook") && logbook != nil
            ? NSHostingController(rootView: AnyView(LogbookScene().environment(fleet).environment(logbook!)))
            : NSHostingController(rootView: AnyView(root))
        window.setFrame(frame, display: true)
        offscreenWindow = window
        setup.start()
        run(fleet)
    }

    static func snapshot(to url: URL) {
        guard let window = offscreenWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        layer.render(in: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
