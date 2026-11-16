import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws the sample creatives with CoreGraphics: same input, same pixels, same PNG bytes.
enum SampleImageRenderer {
    struct Palette {
        var top: CGColor
        var bottom: CGColor
        var accent: CGColor
    }

    static func png(_ spec: SampleImageSpec) -> Data? {
        guard let image = render(spec) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func render(_ spec: SampleImageSpec) -> CGImage? {
        let width = spec.width, height = spec.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let palette = palette(for: spec.name)
        drawBackground(context, bounds: bounds, palette: palette)

        let short = CGFloat(min(width, height))
        switch spec.name {
        case "icon":
            drawMark(context, center: CGPoint(x: bounds.midX, y: bounds.midY), radius: short * 0.30, palette: palette)
        case "logo":
            drawMark(context, center: CGPoint(x: bounds.midX, y: bounds.midY + short * 0.08), radius: short * 0.24, palette: palette)
            drawText(context, "CcinnOpenRTB", in: bounds, size: short * 0.09, weight: .bold, centerY: bounds.minY + short * 0.2)
        case "banner":
            drawMark(context, center: CGPoint(x: CGFloat(height) * 0.55, y: bounds.midY), radius: CGFloat(height) * 0.32, palette: palette)
            drawText(context, "CcinnOpenRTB sample · \(width)×\(height)", in: bounds.insetBy(dx: CGFloat(height) * 0.6, dy: 0),
                     size: CGFloat(height) * 0.3, weight: .semibold, centerY: bounds.midY)
        default:
            drawDecoration(context, bounds: bounds, palette: palette)
            let title = titles[spec.name] ?? "CcinnOpenRTB sample"
            drawText(context, title, in: bounds, size: max(10, short * 0.11), weight: .bold, centerY: bounds.midY + short * 0.07)
            drawText(context, "\(width)×\(height)", in: bounds, size: max(8, short * 0.065), weight: .regular, centerY: bounds.midY - short * 0.08,
                     alpha: 0.85)
            if height >= 200 {
                drawButton(context, "Learn more", center: CGPoint(x: bounds.midX, y: bounds.minY + short * 0.16), height: short * 0.11,
                           palette: palette)
            }
        }
        return context.makeImage()
    }

    private static let titles: [String: String] = [
        "main": "CcinnOpenRTB sample",
        "companion": "Companion ad",
        "interstitial": "Interstitial ad",
    ]

    private static func palette(for name: String) -> Palette {
        // A stable hash of the name picks one of a few palettes, so every size looks distinct but never random.
        let palettes: [Palette] = [
            Palette(top: rgb(0x4F46E5), bottom: rgb(0x0EA5E9), accent: rgb(0xF59E0B)),
            Palette(top: rgb(0x7C3AED), bottom: rgb(0xDB2777), accent: rgb(0x22D3EE)),
            Palette(top: rgb(0x0F766E), bottom: rgb(0x2563EB), accent: rgb(0xFACC15)),
            Palette(top: rgb(0xB45309), bottom: rgb(0xBE123C), accent: rgb(0x93C5FD)),
        ]
        let hash = name.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return palettes[Int(hash % UInt32(palettes.count))]
    }

    private static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    private static func drawBackground(_ context: CGContext, bounds: CGRect, palette: Palette) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: [palette.top, palette.bottom] as CFArray, locations: [0, 1]) else {
            context.setFillColor(palette.top)
            context.fill(bounds)
            return
        }
        context.drawLinearGradient(gradient, start: CGPoint(x: bounds.minX, y: bounds.maxY), end: CGPoint(x: bounds.maxX, y: bounds.minY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawDecoration(_ context: CGContext, bounds: CGRect, palette: Palette) {
        let short = min(bounds.width, bounds.height)
        context.setFillColor(CGColor(gray: 1, alpha: 0.10))
        context.fillEllipse(in: CGRect(x: bounds.maxX - short * 0.55, y: bounds.maxY - short * 0.45, width: short * 0.8, height: short * 0.8))
        context.fillEllipse(in: CGRect(x: bounds.minX - short * 0.25, y: bounds.minY - short * 0.3, width: short * 0.7, height: short * 0.7))
        context.setStrokeColor(palette.accent)
        context.setLineWidth(max(1, short * 0.012))
        context.stroke(bounds.insetBy(dx: short * 0.03, dy: short * 0.03))
    }

    /// The app's mark: a phone with an ad card, used as icon and logo.
    private static func drawMark(_ context: CGContext, center: CGPoint, radius: CGFloat, palette: Palette) {
        let phone = CGRect(x: center.x - radius * 0.62, y: center.y - radius, width: radius * 1.24, height: radius * 2)
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.addPath(CGPath(roundedRect: phone, cornerWidth: radius * 0.22, cornerHeight: radius * 0.22, transform: nil))
        context.fillPath()
        let screen = phone.insetBy(dx: radius * 0.1, dy: radius * 0.16)
        context.setFillColor(palette.top)
        context.addPath(CGPath(roundedRect: screen, cornerWidth: radius * 0.1, cornerHeight: radius * 0.1, transform: nil))
        context.fillPath()
        let card = CGRect(x: screen.minX + screen.width * 0.12, y: screen.midY - screen.height * 0.12, width: screen.width * 0.76,
                          height: screen.height * 0.34)
        context.setFillColor(palette.accent)
        context.addPath(CGPath(roundedRect: card, cornerWidth: radius * 0.06, cornerHeight: radius * 0.06, transform: nil))
        context.fillPath()
        drawText(context, "AD", in: card, size: card.height * 0.5, weight: .heavy, centerY: card.midY, color: palette.top)
    }

    private static func drawButton(_ context: CGContext, _ title: String, center: CGPoint, height: CGFloat, palette: Palette) {
        let width = height * 4.2
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        context.setFillColor(palette.accent)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
        drawText(context, title, in: rect, size: height * 0.45, weight: .semibold, centerY: rect.midY, color: CGColor(gray: 0.1, alpha: 1))
    }

    enum Weight {
        case regular, semibold, bold, heavy

        var value: CGFloat {
            switch self {
            case .regular: 0
            case .semibold: 0.3
            case .bold: 0.4
            case .heavy: 0.56
            }
        }
    }

    /// Draws one line of text centred horizontally in `rect`, shrunk to fit its width.
    static func drawText(_ context: CGContext, _ text: String, in rect: CGRect, size: CGFloat, weight: Weight, centerY: CGFloat,
                         alpha: CGFloat = 1, color: CGColor? = nil) {
        guard size > 0, !text.isEmpty else { return }
        var fontSize = size
        var line = makeLine(text, size: fontSize, weight: weight, color: color ?? CGColor(gray: 1, alpha: alpha))
        var bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let available = rect.width * 0.92
        if bounds.width > available, bounds.width > 0 {
            fontSize = max(4, fontSize * available / bounds.width)
            line = makeLine(text, size: fontSize, weight: weight, color: color ?? CGColor(gray: 1, alpha: alpha))
            bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX, y: centerY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func makeLine(_ text: String, size: CGFloat, weight: Weight, color: CGColor) -> CTLine {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: weight.value] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}
