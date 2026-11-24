import RTBKit
import SwiftUI

/// The system UI drawn over a simulated screen: status bar, home indicator / gesture bar, camera cutout.
struct SystemChrome: View {
    let layout: ScreenLayout
    /// The pane this chrome belongs to (screen coordinates inside the canvas).
    let pane: CGRect
    let showsStatusBar: Bool
    let isFirstPane: Bool
    /// Light content (white glyphs) over dark backgrounds such as full-screen video.
    var lightContent = false
    /// iOS's "◀ App" stands where the time is (`BackBreadcrumbSlot`).
    var hidesTime = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsStatusBar && layout.showsStatusBar {
                StatusBar(layout: layout, width: pane.width, lightContent: lightContent, hidesTime: hidesTime)
                    .frame(width: pane.width, height: statusBarHeight)
            }
            if let indicator = homeIndicatorSize {
                Capsule()
                    .fill(lightContent ? Color.white.opacity(0.85) : Color.primary.opacity(0.75))
                    .frame(width: indicator.width, height: indicator.height)
                    .position(x: pane.width / 2, y: pane.height - homeIndicatorBottom)
            }
            if isFirstPane { cutout }
        }
        .frame(width: pane.width, height: pane.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var statusBarHeight: CGFloat { Self.statusBarHeight(for: layout) }

    static func statusBarHeight(for layout: ScreenLayout) -> CGFloat {
        let top = CGFloat(layout.safeArea.top)
        return top > 0 ? top : 24
    }

    private var homeIndicatorSize: CGSize? {
        switch layout.chrome {
        case .iPhone: CGSize(width: layout.isLandscape ? 210 : 136, height: 5)
        case .iPad: CGSize(width: min(320, pane.width * 0.3), height: 5)
        case .android: CGSize(width: 108, height: 4)
        case .iPhoneHomeButton, .television: nil
        }
    }

    private var homeIndicatorBottom: CGFloat {
        layout.chrome == .iPhone ? 8 : 10
    }

    @ViewBuilder private var cutout: some View {
        let isLandscape = layout.isLandscape
        switch layout.cutout {
        case .dynamicIsland:
            let size = CutoutGeometry.islandSize(for: layout.device)
            Capsule()
                .fill(.black)
                .frame(width: isLandscape ? size.height : size.width, height: isLandscape ? size.width : size.height)
                .position(isLandscape ? CGPoint(x: 11 + size.height / 2, y: pane.height / 2) : CGPoint(x: pane.width / 2, y: 11 + size.height / 2))
        case .notch:
            let size = CGSize(width: 162, height: 32)
            NotchShape()
                .fill(.black)
                .frame(width: size.width, height: size.height)
                .rotationEffect(isLandscape ? .degrees(-90) : .zero)
                .position(isLandscape ? CGPoint(x: size.height / 2, y: pane.height / 2) : CGPoint(x: pane.width / 2, y: size.height / 2))
        case .punchHole:
            Circle()
                .fill(.black)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .frame(width: 12, height: 12)
                .position(isLandscape ? CGPoint(x: 14, y: pane.height / 2) : CGPoint(x: pane.width / 2, y: 14))
        case .none:
            EmptyView()
        }
    }
}

/// An iPhone notch: square top corners flaring into the screen edge, rounded bottom corners.
struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let flare: CGFloat = 6
        let radius: CGFloat = min(20, rect.height * 0.62)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + flare, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + flare), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.minX - flare, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// iOS / iPadOS / Android status bar with the classic 9:41.
struct StatusBar: View {
    let layout: ScreenLayout
    let width: CGFloat
    var lightContent = false
    var hidesTime = false

    var body: some View {
        let phone = layout.chrome == .iPhone || layout.chrome == .iPhoneHomeButton
        let ears = layout.chrome == .iPhone
        HStack(spacing: 6) {
            Text(timeText)
                .font(.system(size: phone ? 16 : 13, weight: phone ? .semibold : .medium))
                .monospacedDigit()
                .opacity(hidesTime ? 0 : 1)
                .frame(width: ears ? earWidth : nil, alignment: ears ? .center : .leading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                BatteryGlyph()
            }
            .font(.system(size: phone ? 13 : 11, weight: .semibold))
            .frame(width: ears ? earWidth : nil, alignment: ears ? .center : .trailing)
        }
        .foregroundStyle(lightContent ? Color.white : Color.primary)
        .padding(.horizontal, ears ? 0 : 16)
        .padding(.top, ears ? 4 : 0)
        .frame(maxHeight: .infinity)
    }

    /// Each side of the island / notch.
    private var earWidth: CGFloat { Self.earWidth(for: width) }

    static func earWidth(for width: CGFloat) -> CGFloat { max(60, (width - 130) / 2) }

    private var timeText: String {
        layout.chrome == .iPad ? "9:41  Tue Nov 17" : "9:41"
    }
}

private struct BatteryGlyph: View {
    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(lineWidth: 1)
                .opacity(0.45)
                .frame(width: 22, height: 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.6, style: .continuous).frame(width: 16, height: 7).padding(.leading, 2)
                }
            RoundedRectangle(cornerRadius: 1).frame(width: 1.5, height: 4).opacity(0.45)
        }
    }
}

/// Cutout sizes in points (approx.: measured from Apple's device frames).
enum CutoutGeometry {
    /// The Dynamic Island pill: 125×36.7 pt on iPhone 14 Pro – 17 Pro; about 30% narrower on the iPhone 18 Pro models,
    /// whose Face ID sits under the display.
    static func islandSize(for device: DeviceProfile) -> CGSize {
        switch device.id {
        case "iphone-18-pro", "iphone-18-pro-max": CGSize(width: 88, height: 36.7)
        default: CGSize(width: 125, height: 36.7)
        }
    }
}
