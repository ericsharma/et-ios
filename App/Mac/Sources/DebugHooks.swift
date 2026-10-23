#if DEBUG
import AppKit

/// Launch flags for testing on a headless Mac (debug builds only):
///   --open <machine/session>  select a session in the first window
///   --snapshot <file.png>     every 3 s, draw the front window into a PNG
///   --spawn <machine:command>  start a session and show it
///   --type <text>             after 6 s, type into the selected session
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
        if let path = value("--snapshot") {
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(3))
                    snapshot(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
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
