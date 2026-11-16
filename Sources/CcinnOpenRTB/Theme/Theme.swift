import AppKit
import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Visual language: one accent ("signal teal"), adaptive colours per request category and delivery, consistent metrics.
enum Theme {
    static let accent = Color(nsColor: .appAccent)

    enum Metrics {
        static let cornerRadius: CGFloat = 10
        static let smallCornerRadius: CGFloat = 6
        static let cardPadding: CGFloat = 14
    }

    static let monospaced = Font.system(size: 12, design: .monospaced)
    static let monospacedSmall = Font.system(size: 11, design: .monospaced)

    // MARK: Request categories

    static func color(for category: TrackerCategory) -> Color {
        let color: NSColor = switch category {
        case .win: .adaptive(light: .hex(0x15803D), dark: .hex(0x4ADE80))
        case .billing: .adaptive(light: .hex(0x0F766E), dark: .hex(0x2DD4BF))
        case .loss: .adaptive(light: .hex(0x6B7280), dark: .hex(0x9CA3AF))
        case .impression: .adaptive(light: .hex(0x2563EB), dark: .hex(0x60A5FA))
        case .viewability: .adaptive(light: .hex(0x0891B2), dark: .hex(0x22D3EE))
        case .event: .adaptive(light: .hex(0x4F46E5), dark: .hex(0xA5B4FC))
        case .click: .adaptive(light: .hex(0xC2410C), dark: .hex(0xFB923C))
        case .navigation: .adaptive(light: .hex(0xBE185D), dark: .hex(0xF472B6))
        case .error: .adaptive(light: .hex(0xDC2626), dark: .hex(0xF87171))
        case .verification: .adaptive(light: .hex(0x7E22CE), dark: .hex(0xC084FC))
        case .content: .adaptive(light: .hex(0x92400E), dark: .hex(0xFBBF24))
        case .creative: .adaptive(light: .hex(0x047857), dark: .hex(0x6EE7B7))
        }
        return Color(nsColor: color)
    }

    static func icon(for category: TrackerCategory) -> String {
        switch category {
        case .win: "trophy"
        case .billing: "dollarsign.circle"
        case .loss: "xmark.circle"
        case .impression: "eye"
        case .viewability: "eye.circle"
        case .event: "play.circle"
        case .click: "cursorarrow.click"
        case .navigation: "arrow.up.forward.app"
        case .error: "exclamationmark.triangle"
        case .verification: "checkmark.seal"
        case .content: "doc.richtext"
        case .creative: "paintbrush"
        }
    }

    static func label(for category: TrackerCategory) -> String {
        switch category {
        case .win: "Win"
        case .billing: "Billing"
        case .loss: "Loss"
        case .impression: "Impression"
        case .viewability: "Viewability"
        case .event: "Event"
        case .click: "Click"
        case .navigation: "Navigation"
        case .error: "Error"
        case .verification: "Verification"
        case .content: "Content"
        case .creative: "Creative"
        }
    }

    // MARK: Delivery (the "mode" column)

    static func color(for delivery: NetworkDelivery) -> Color {
        switch delivery {
        case .simulated: Color(nsColor: .adaptive(light: .hex(0x6D28D9), dark: .hex(0xC4B5FD)))
        case .network: Color(nsColor: .adaptive(light: .hex(0xB91C1C), dark: .hex(0xFCA5A5)))
        case .blocked: Color(nsColor: .adaptive(light: .hex(0x9A3412), dark: .hex(0xFDBA74)))
        case .local: Color(nsColor: .adaptive(light: .hex(0x0369A1), dark: .hex(0x7DD3FC)))
        case .renderer: Color(nsColor: .adaptive(light: .hex(0x0F766E), dark: .hex(0x5EEAD4)))
        case .browser: Color(nsColor: .adaptive(light: .hex(0xBE185D), dark: .hex(0xF9A8D4)))
        }
    }

    static func icon(for delivery: NetworkDelivery) -> String {
        switch delivery {
        case .simulated: "circle.dashed"
        case .network: "antenna.radiowaves.left.and.right"
        case .blocked: "nosign"
        case .local: "internaldrive"
        case .renderer: "play.rectangle"
        case .browser: "safari"
        }
    }

    // MARK: States

    static func color(for state: NetworkEntryState) -> Color {
        switch state {
        case .simulated: .secondary
        case .blocked: .orange
        case .pending: .blue
        case let .completed(status): status >= 400 ? .red : status >= 300 ? .orange : .green
        case .failed: .red
        }
    }

    static func statusText(for entry: NetworkEntry) -> String {
        switch entry.state {
        case .simulated: "—"
        case .blocked: "blocked"
        case .pending: "pending"
        case let .completed(status): status > 0 ? "\(status)" : "loaded"
        case .failed: "failed"
        }
    }
}

extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let appAccent = adaptive(light: .hex(0x0E7490), dark: .hex(0x22D3EE))
    static let macroReplaced = adaptive(light: .hex(0x15803D), dark: .hex(0x86EFAC))
    static let macroUnknown = adaptive(light: .hex(0xC2410C), dark: .hex(0xFDBA74))
}

enum Format {
    static func bytes(_ value: Int?) -> String {
        guard let value else { return "—" }
        guard value > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    static func duration(milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "—" }
        if milliseconds < 1 { return "<1 ms" }
        if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) ms" }
        if milliseconds < 60_000 { return String(format: "%.2f s", milliseconds / 1000) }
        let seconds = Int(min(milliseconds / 1000, Double(Int32.max)))
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func duration(seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return duration(milliseconds: seconds * 1000)
    }

    /// "+1,234 ms" relative to the session's first entry.
    static func offset(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let milliseconds = Int(min(max(seconds * 1000, -Double(Int32.max)), Double(Int32.max)).rounded())
        return "+" + milliseconds.formatted(.number)
    }
}

/// Small rounded label used for categories, modes and states.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

struct CategoryBadge: View {
    let category: TrackerCategory

    var body: some View {
        Badge(text: Theme.label(for: category), color: Theme.color(for: category), systemImage: Theme.icon(for: category))
    }
}

struct DeliveryBadge: View {
    let delivery: NetworkDelivery

    var body: some View {
        Badge(text: delivery.label, color: Theme.color(for: delivery), systemImage: Theme.icon(for: delivery))
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The app mark (a phone showing an ad, with network waves), drawn in SwiftUI to match the app icon.
struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.62, blue: 0.72), Color(red: 0.10, green: 0.16, blue: 0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(.white.opacity(0.95))
                .frame(width: size * 0.34, height: size * 0.6)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.03)
                        .fill(Color(red: 0.98, green: 0.72, blue: 0.16))
                        .frame(width: size * 0.24, height: size * 0.13)
                        .overlay(Text("AD").font(.system(size: size * 0.08, weight: .heavy)).foregroundStyle(Color(red: 0.1, green: 0.16, blue: 0.45)))
                }
                .offset(x: -size * 0.1)
            ForEach(0..<3) { ring in
                Circle()
                    .trim(from: 0.38, to: 0.62)
                    .stroke(.white.opacity(0.9 - Double(ring) * 0.22), style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round))
                    .frame(width: size * (0.22 + CGFloat(ring) * 0.16), height: size * (0.22 + CGFloat(ring) * 0.16))
                    .rotationEffect(.degrees(180))
                    .offset(x: size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: size * 0.08, y: size * 0.04)
    }
}

/// Settings ▸ General ▸ Appearance.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    static let key = "appearance"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the appearance setting and the accent; use on every window's root view.
struct AppAppearance: ViewModifier {
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
            .tint(Theme.accent)
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearance()) }
}
