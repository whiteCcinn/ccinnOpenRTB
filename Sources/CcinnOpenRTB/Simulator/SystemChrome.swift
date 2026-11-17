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

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsStatusBar && layout.showsStatusBar {
                StatusBar(layout: layout, width: pane.width, lightContent: lightContent)
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

    private var statusBarHeight: CGFloat {
        let top = CGFloat(layout.safeArea.top)
        return top > 0 ? top : 24
    }

    private var homeIndicatorSize: CGSize? {
        switch layout.device.family {
        case .iPhone where layout.device.cutout != .none: CGSize(width: layout.isLandscape ? 210 : 136, height: 5)
        case .tablet: CGSize(width: 320, height: 5)
        case .androidPhone, .foldable, .dualScreen: CGSize(width: 108, height: 4)
        default: nil
        }
    }

    private var homeIndicatorBottom: CGFloat {
        layout.device.family == .iPhone ? 8 : 10
    }

    @ViewBuilder private var cutout: some View {
        let isLandscape = layout.isLandscape
        switch layout.cutout {
        case .dynamicIsland:
            let size = CGSize(width: 125, height: 36.7)
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

    var body: some View {
        let family = layout.device.family
        HStack(spacing: 6) {
            Text(timeText)
                .font(.system(size: family == .iPhone ? 16 : 13, weight: family == .iPhone ? .semibold : .medium))
                .monospacedDigit()
                .frame(width: family == .iPhone && layout.cutout != .none ? earWidth : nil, alignment: family == .iPhone ? .center : .leading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                BatteryGlyph()
            }
            .font(.system(size: family == .iPhone ? 13 : 11, weight: .semibold))
            .frame(width: family == .iPhone && layout.cutout != .none ? earWidth : nil, alignment: family == .iPhone ? .center : .trailing)
        }
        .foregroundStyle(lightContent ? Color.white : Color.primary)
        .padding(.horizontal, family == .iPhone && layout.cutout != .none ? 0 : 16)
        .padding(.top, verticalOffset)
        .frame(maxHeight: .infinity, alignment: family == .iPhone ? .center : .center)
    }

    /// Each side of the island / notch.
    private var earWidth: CGFloat { max(60, (width - 130) / 2) }

    private var verticalOffset: CGFloat {
        layout.device.family == .iPhone && layout.cutout != .none ? 4 : 0
    }

    private var timeText: String {
        switch layout.device.family {
        case .tablet: "9:41  Mon Nov 17"
        default: "9:41"
        }
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
