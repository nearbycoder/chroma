// Renders the installer window background: Resources/dmg/background.tiff (1x + 2x).
// Usage: swift Scripts/make-dmg-background.swift
// The arrow sits between icon_locations in Resources/dmg/settings.py: (160, 186) and (480, 186).
import AppKit

let size = NSSize(width: 640, height: 400)
let appCenter = NSPoint(x: 160, y: size.height - 186)
let applicationsCenter = NSPoint(x: 480, y: size.height - 186)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw() {
    color(0x1A1925).setFill()
    NSRect(origin: .zero, size: size).fill()

    // A row of dots fading through the icon's three colors, ending in an arrowhead.
    let y = appCenter.y
    let from = appCenter.x + 92, to = applicationsCenter.x - 96
    let stops: [UInt32] = [0xFF4D6D, 0xFF8A5C, 0x2BD9A8, 0x3FB8D6, 0x4C6FFF]
    let count = 7
    for i in 0..<count {
        let t = CGFloat(i) / CGFloat(count - 1)
        let x = from + (to - from - 14) * t
        let stop = min(Int(t * CGFloat(stops.count - 1) + 0.5), stops.count - 1)
        color(stops[stop]).setFill()
        let r: CGFloat = 4
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }
    color(0x4C6FFF).setStroke()
    let head = NSBezierPath()
    head.lineWidth = 2.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: to - 6, y: y + 8)); head.line(to: NSPoint(x: to + 3, y: y)); head.line(to: NSPoint(x: to - 6, y: y - 8))
    head.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    NSAttributedString(string: "Drag Chroma into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        .paragraphStyle: paragraph,
    ]).draw(in: NSRect(x: 0, y: 64, width: size.width, height: 24))
    NSAttributedString(string: "Then press ⌃⌥⌘P anywhere to pick a color", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        .paragraphStyle: paragraph,
    ]).draw(in: NSRect(x: 0, y: 44, width: size.width, height: 20))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
let output = URL(fileURLWithPath: "Resources/dmg/background.tiff")
try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try! image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: output)
print("Wrote \(output.path)")
