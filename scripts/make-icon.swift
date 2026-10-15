// Renders the 1024×1024 app icon: a terminal prompt with a glowing cursor
// (a nod to E.T.'s glowing fingertip), in the app's Catppuccin Mocha colors.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: deep mantle → base gradient (iOS adds the rounded mask).
let bg = NSGradient(colors: [color(0x11111B), color(0x1E1E2E)])!
bg.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 90)

// Soft glow behind the cursor.
let cursorRect = NSRect(x: 590, y: 330, width: 170, height: 300)
let glowCenter = CGPoint(x: cursorRect.midX, y: cursorRect.midY)
let glow = NSGradient(colors: [color(0xF38BA8, 0.55), color(0xF38BA8, 0.0)])!
glow.draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 380, options: [])

// Prompt chevron ">" in the accent blue.
ctx.setStrokeColor(color(0x89B4FA).cgColor)
ctx.setLineWidth(78)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 250, y: 650))
ctx.addLine(to: CGPoint(x: 470, y: 480))
ctx.addLine(to: CGPoint(x: 250, y: 310))
ctx.strokePath()

// Cursor block, glowing pink-red.
ctx.setShadow(offset: .zero, blur: 60, color: color(0xF38BA8, 0.9).cgColor)
let cursor = NSBezierPath(roundedRect: cursorRect, xRadius: 26, yRadius: 26)
color(0xF38BA8).setFill()
cursor.fill()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// Hot core of the glow.
let core = NSGradient(colors: [color(0xFFFFFF, 0.55), color(0xF5C2E7, 0.0)])!
core.draw(in: NSBezierPath(roundedRect: cursorRect.insetBy(dx: 30, dy: 60), xRadius: 20, yRadius: 20), angle: 90)

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
