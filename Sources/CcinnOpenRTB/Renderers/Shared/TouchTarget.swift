import RTBKit
import SwiftUI

/// The minimum touch target on the simulated device: 44 × 44 pt on Apple platforms (HIG), 50 × 50 on Android (the size
/// of the MRAID close region). The renderer owns every container control (close, skip, custom close, player controls);
/// their hit area — not only the drawn glyph — must be at least this large. CTV has no touch: it uses the remote.
enum TouchTarget {
    static let apple: CGFloat = 44
    static let android: CGFloat = 50

    static func minimumSide(for device: DeviceProfile) -> CGFloat {
        isAndroid(device) ? android : apple
    }

    /// The OS decides (an iOS foldable is Apple); the device family only when the OS is unknown.
    static func isAndroid(_ device: DeviceProfile) -> Bool {
        let os = device.os.lowercased()
        if os.contains("android") { return true }
        if os.contains("ios") || os.contains("ipados") || os.contains("tvos") || os.contains("visionos") { return false }
        switch device.family {
        case .androidPhone, .foldable, .dualScreen: return true
        case .iPhone, .tablet, .ctv: return false
        }
    }
}

private struct MinimumTouchTargetKey: EnvironmentKey {
    static let defaultValue = TouchTarget.apple
}

extension EnvironmentValues {
    /// Set by `RendererRoot` from the device.
    var minimumTouchTarget: CGFloat {
        get { self[MinimumTouchTargetKey.self] }
        set { self[MinimumTouchTargetKey.self] = newValue }
    }
}

private struct TouchTargetModifier: ViewModifier {
    @Environment(\.minimumTouchTarget) private var side

    func body(content: Content) -> some View {
        content
            .frame(minWidth: side, minHeight: side)
            .contentShape(Rectangle())
    }
}

extension View {
    /// Grows the hit area (not the drawing) to the device's minimum touch target. Apply it INSIDE a button's label, so the
    /// padding is part of the button.
    func touchTarget() -> some View {
        modifier(TouchTargetModifier())
    }
}

/// The container's close control: a 30-pt glyph whose centre sits `glyphCenterInset` from the top and trailing edges, with
/// a hit area of the minimum touch target around it.
struct CloseControl: View {
    static let glyphSide: CGFloat = 30
    static let glyphCenterInset: CGFloat = 25

    let label: String
    let action: () -> Void

    @Environment(\.minimumTouchTarget) private var side

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
                .background(Circle().fill(.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .frame(width: max(side, Self.glyphSide), height: max(side, Self.glyphSide))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(max(0, Self.glyphCenterInset - max(side, Self.glyphSide) / 2))
        .accessibilityLabel(label)
    }
}

/// MRAID custom close: the creative draws its own control, the container keeps an invisible region (MRAID: 50 × 50, at
/// least the minimum touch target) in the top-right corner.
struct CustomCloseRegion: View {
    static let mraidSide: CGFloat = 50

    let label: String
    let action: () -> Void

    @Environment(\.minimumTouchTarget) private var side

    var body: some View {
        Color.clear
            .frame(width: max(side, Self.mraidSide), height: max(side, Self.mraidSide))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}
