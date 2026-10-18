// Genera AppIcon.iconset (poi: iconutil -c icns AppIcon.iconset): squircle con sfumatura, monitor bianco e sole della luminosità.
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Sfondo: squircle in stile macOS (area 824/1024 con margine)
    let inset = s * 100 / 1024
    let bg = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: bg, xRadius: bg.width * 0.225, yRadius: bg.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowBlurRadius = s * 0.02
    shadow.set()
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.62, blue: 1.00, alpha: 1)])!
        .draw(in: shape, angle: 90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Monitor
    let w = bg.width
    let screen = NSRect(x: bg.minX + w * 0.16, y: bg.minY + w * 0.34, width: w * 0.68, height: w * 0.46)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: screen, xRadius: w * 0.05, yRadius: w * 0.05).fill()
    let inner = screen.insetBy(dx: w * 0.035, dy: w * 0.035)
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.12, blue: 0.30, alpha: 1),
                        NSColor(srgbRed: 0.20, green: 0.25, blue: 0.55, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: inner, xRadius: w * 0.025, yRadius: w * 0.025), angle: 90)
    // Piede
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: bg.midX - w * 0.04, y: screen.minY - w * 0.09, width: w * 0.08, height: w * 0.09)).fill()
    NSBezierPath(roundedRect: NSRect(x: bg.midX - w * 0.17, y: screen.minY - w * 0.13, width: w * 0.34, height: w * 0.05),
                 xRadius: w * 0.025, yRadius: w * 0.025).fill()

    // Sole (luminosità) al centro dello schermo
    let c = NSPoint(x: inner.midX, y: inner.midY)
    let r = inner.height * 0.17
    NSColor(srgbRed: 1.0, green: 0.80, blue: 0.25, alpha: 1).set()
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4
        let ray = NSBezierPath()
        ray.lineWidth = r * 0.32
        ray.lineCapStyle = .round
        ray.move(to: NSPoint(x: c.x + cos(a) * r * 1.5, y: c.y + sin(a) * r * 1.5))
        ray.line(to: NSPoint(x: c.x + cos(a) * r * 2.1, y: c.y + sin(a) * r * 2.1))
        ray.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)" + (sc == 2 ? "@2x" : "") + ".png"
        try! render(pt * sc).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }
}
