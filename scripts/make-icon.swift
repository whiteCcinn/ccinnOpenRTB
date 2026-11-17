// Renders the CcinnOpenRTB app icon (all macOS iconset sizes) with AppKit: a phone showing an ad, with network waves.
// Usage: swift scripts/make-icon.swift <output.iconset> [<preview.png>]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset> [<preview.png>]\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale

    // Drop shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    color(0x0B1D4A).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Signal-teal to deep-navy gradient.
    let gradient = NSGradient(colors: [color(0x22D3EE), color(0x0E7490), color(0x0B1D4A)], atLocations: [0, 0.48, 1], colorSpace: .sRGB)
    gradient?.draw(in: shape, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    // Network waves radiating from the phone's right edge.
    let waveCenter = NSPoint(x: body.minX + body.width * 0.50, y: body.minY + body.height * 0.52)
    for (index, waveRadius) in [CGFloat(150), 235, 320].enumerated() {
        let wave = NSBezierPath()
        wave.appendArc(withCenter: waveCenter, radius: waveRadius * scale, startAngle: -38, endAngle: 38)
        wave.lineWidth = 34 * scale
        wave.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.92 - CGFloat(index) * 0.24).setStroke()
        wave.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // The phone.
    let phone = NSRect(x: body.minX + body.width * 0.17, y: body.minY + body.height * 0.15, width: body.width * 0.34, height: body.height * 0.70)
    let phoneShadow = NSShadow()
    phoneShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    phoneShadow.shadowBlurRadius = 24 * scale
    phoneShadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    NSGraphicsContext.saveGraphicsState()
    phoneShadow.set()
    color(0xF8FAFC).setFill()
    NSBezierPath(roundedRect: phone, xRadius: 52 * scale, yRadius: 52 * scale).fill()
    NSGraphicsContext.restoreGraphicsState()

    let screen = phone.insetBy(dx: 22 * scale, dy: 30 * scale)
    color(0x0F172A).setFill()
    NSBezierPath(roundedRect: screen, xRadius: 30 * scale, yRadius: 30 * scale).fill()
    // Dynamic-island pill.
    color(0xF8FAFC).setFill()
    let island = NSRect(x: screen.midX - 36 * scale, y: screen.maxY - 30 * scale, width: 72 * scale, height: 16 * scale)
    NSBezierPath(roundedRect: island, xRadius: 8 * scale, yRadius: 8 * scale).fill()
    // Feed lines above and below the ad card.
    for (y, width) in [(0.80, 0.70), (0.72, 0.50), (0.22, 0.66), (0.14, 0.44)] as [(CGFloat, CGFloat)] {
        let line = NSRect(x: screen.minX + screen.width * 0.12, y: screen.minY + screen.height * y, width: screen.width * width, height: 14 * scale)
        color(0x334155).setFill()
        NSBezierPath(roundedRect: line, xRadius: 7 * scale, yRadius: 7 * scale).fill()
    }
    // The ad card.
    let card = NSRect(x: screen.minX + screen.width * 0.10, y: screen.minY + screen.height * 0.34, width: screen.width * 0.80, height: screen.height * 0.30)
    color(0xFBBF24).setFill()
    NSBezierPath(roundedRect: card, xRadius: 18 * scale, yRadius: 18 * scale).fill()
    let label = "AD" as NSString
    let font = NSFont.systemFont(ofSize: 92 * scale, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(0x0B1D4A)]
    let size = label.size(withAttributes: attributes)
    label.draw(at: NSPoint(x: card.midX - size.width / 2, y: card.midY - size.height / 2), withAttributes: attributes)

    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
if arguments.count == 3, let preview = renderIcon(pixels: 512) {
    try preview.write(to: URL(fileURLWithPath: arguments[2]))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
