import AppKit

// Renders the disk image window background: background.png (1x) and background@2x.png.
// Layout matches tools/dmg_settings.py — a 660×400 window with icons centred at x 165 and 495, y 205.

let outputDir = CommandLine.arguments[1]
let size = NSSize(width: 660, height: 400)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Mid-blue so Finder's icon labels read in both light (black text) and dark (white text) mode.
    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.52, blue: 0.93, alpha: 1),
                        NSColor(srgbRed: 0.40, green: 0.66, blue: 0.98, alpha: 1)])!
        .draw(in: bounds, angle: 90)

    // A soft glow behind each icon slot.
    for x in [165.0, 495.0] {
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        glow.draw(fromCenter: NSPoint(x: x, y: 195), radius: 0, toCenter: NSPoint(x: x, y: 195), radius: 105, options: [])
    }

    // Scattered snowflakes, faint and fixed so every build looks the same.
    let flakes: [(CGFloat, CGFloat, CGFloat)] = [(40, 350, 22), (120, 60, 14), (300, 330, 12), (340, 70, 18),
                                                 (610, 345, 16), (585, 50, 24), (250, 120, 10), (420, 300, 9), (30, 150, 12)]
    for (x, y, pointSize) in flakes {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.28)]))
        if let flake = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            flake.draw(at: NSPoint(x: x - flake.size.width / 2, y: y - flake.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    // Title.
    let title = NSAttributedString(string: "Drag Icicle into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor.white,
        .shadow: { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.2); s.shadowBlurRadius = 4; s.shadowOffset = NSSize(width: 0, height: -1); return s }(),
    ])
    title.draw(at: NSPoint(x: (size.width - title.size().width) / 2, y: 330))

    // Arrow from the app to Applications (y is flipped: icon centre y 205 from the top = 195 from the bottom).
    let arrow = NSBezierPath()
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 262, y: 195))
    arrow.line(to: NSPoint(x: 392, y: 195))
    arrow.move(to: NSPoint(x: 372, y: 213))
    arrow.line(to: NSPoint(x: 394, y: 195))
    arrow.line(to: NSPoint(x: 372, y: 177))
    NSColor.white.withAlphaComponent(0.85).setStroke()
    arrow.stroke()

    // Footer hint.
    let hint = NSAttributedString(string: "Then open Icicle from Applications. It lives in your menu bar.", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
    ])
    hint.draw(at: NSPoint(x: (size.width - hint.size().width) / 2, y: 34))

    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: "\(outputDir)/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(outputDir)/background@2x.png"))
