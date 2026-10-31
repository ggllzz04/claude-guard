import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: make-icon.swift <iconset-dir>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255.0
    let g = CGFloat((hex >> 8) & 0xff) / 255.0
    let b = CGFloat(hex & 0xff) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func shieldPath(inset: CGFloat = 0) -> NSBezierPath {
    let p = NSBezierPath()
    let cx: CGFloat = 512
    let top: CGFloat = 790 - inset
    let bottom: CGFloat = 300 + inset
    let half: CGFloat = 210 - inset

    p.move(to: NSPoint(x: cx, y: top))
    p.curve(to: NSPoint(x: cx + half, y: top - 82),
            controlPoint1: NSPoint(x: cx + half * 0.52, y: top - 8),
            controlPoint2: NSPoint(x: cx + half * 0.88, y: top - 44))
    p.line(to: NSPoint(x: cx + half, y: 520))
    p.curve(to: NSPoint(x: cx, y: bottom),
            controlPoint1: NSPoint(x: cx + half, y: 420),
            controlPoint2: NSPoint(x: cx + half * 0.62, y: bottom + 52))
    p.curve(to: NSPoint(x: cx - half, y: 520),
            controlPoint1: NSPoint(x: cx - half * 0.62, y: bottom + 52),
            controlPoint2: NSPoint(x: cx - half, y: 420))
    p.line(to: NSPoint(x: cx - half, y: top - 82))
    p.curve(to: NSPoint(x: cx, y: top),
            controlPoint1: NSPoint(x: cx - half * 0.88, y: top - 44),
            controlPoint2: NSPoint(x: cx - half * 0.52, y: top - 8))
    p.close()
    return p
}

func sparkle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let inner = radius * 0.26
    p.move(to: NSPoint(x: center.x, y: center.y + radius))
    p.line(to: NSPoint(x: center.x + inner, y: center.y + inner))
    p.line(to: NSPoint(x: center.x + radius, y: center.y))
    p.line(to: NSPoint(x: center.x + inner, y: center.y - inner))
    p.line(to: NSPoint(x: center.x, y: center.y - radius))
    p.line(to: NSPoint(x: center.x - inner, y: center.y - inner))
    p.line(to: NSPoint(x: center.x - radius, y: center.y))
    p.line(to: NSPoint(x: center.x - inner, y: center.y + inner))
    p.close()
    return p
}

// 折光护盾：两道交错的折面形成 G，暖色核心代表正在被保护的连接。
func makeBase() -> NSImage {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let tile = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 218, yRadius: 218)
    NSGradient(colors: [color(0x263A50), color(0x0B1326), color(0x060D1B)])!.draw(in: tile, angle: -65)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let glow = NSBezierPath(ovalIn: NSRect(x: 75, y: 300, width: 800, height: 800))
    NSGradient(colors: [color(0x48E0C9, 0.20), color(0x48E0C9, 0)])!.draw(in: glow, relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()
    tile.lineWidth = 2
    color(0xFFFFFF, 0.17).setStroke(); tile.stroke()

    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 832))
    shield.line(to: NSPoint(x: 785, y: 718))
    shield.line(to: NSPoint(x: 760, y: 440))
    shield.curve(to: NSPoint(x: 512, y: 204), controlPoint1: NSPoint(x: 744, y: 330), controlPoint2: NSPoint(x: 604, y: 245))
    shield.curve(to: NSPoint(x: 264, y: 440), controlPoint1: NSPoint(x: 420, y: 245), controlPoint2: NSPoint(x: 280, y: 330))
    shield.line(to: NSPoint(x: 239, y: 718)); shield.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0x000000, 0.6); shadow.shadowBlurRadius = 38; shadow.shadowOffset = NSSize(width: 0, height: -20); shadow.set()
    NSGradient(colors: [color(0xC6FFF0), color(0x45DCCC), color(0x1684A0)])!.draw(in: shield, angle: -58)
    NSGraphicsContext.restoreGraphicsState()

    // A negative-space G, deliberately open on the upper right.
    let g = NSBezierPath()
    g.move(to: NSPoint(x: 644, y: 655))
    g.curve(to: NSPoint(x: 382, y: 590), controlPoint1: NSPoint(x: 525, y: 755), controlPoint2: NSPoint(x: 382, y: 701))
    g.curve(to: NSPoint(x: 512, y: 354), controlPoint1: NSPoint(x: 371, y: 485), controlPoint2: NSPoint(x: 428, y: 408))
    g.curve(to: NSPoint(x: 650, y: 533), controlPoint1: NSPoint(x: 596, y: 408), controlPoint2: NSPoint(x: 649, y: 469))
    g.line(to: NSPoint(x: 534, y: 533))
    g.lineWidth = 66; g.lineJoinStyle = .round; g.lineCapStyle = .round
    color(0x0C2235).setStroke(); g.stroke()

    let facet = NSBezierPath()
    facet.move(to: NSPoint(x: 512, y: 832)); facet.line(to: NSPoint(x: 785, y: 718)); facet.line(to: NSPoint(x: 703, y: 659)); facet.close()
    NSGradient(colors: [color(0xF3FFF8), color(0x90F8D8)])!.draw(in: facet, angle: -90)
    let core = NSBezierPath(roundedRect: NSRect(x: 685, y: 614, width: 102, height: 102), xRadius: 30, yRadius: 30)
    NSGraphicsContext.saveGraphicsState()
    let light = NSShadow(); light.shadowColor = color(0xFFAB67, 0.45); light.shadowBlurRadius = 25; light.shadowOffset = .zero; light.set()
    NSGradient(colors: [color(0xFFE7B9), color(0xFF9A67)])!.draw(in: core, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    image.unlockFocus()
    return image
}

let base = makeBase()

func writePNG(_ image: NSImage, size: Int, name: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
               from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
               operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: output.appendingPathComponent(name))
}

let entries: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for (size, name) in entries {
    writePNG(base, size: size, name: name)
}
print("icon written to \(output.path)")
