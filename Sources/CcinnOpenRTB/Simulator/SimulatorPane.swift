import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// The left half of the main window: device header, zoomable device canvas, and the lifecycle controls.
struct SimulatorPane: View {
    @Bindable var session: AdSession

    var body: some View {
        VStack(spacing: 0) {
            SimulatorHeader(session: session, magnification: session.canvasMagnification)
            Divider()
            ZStack(alignment: .top) {
                let style = DeviceFrameStyle(layout: session.layout)
                ZoomableCanvas(contentSize: style.outerSize, zoom: $session.zoom, onMagnification: { session.canvasMagnification = $0 }) {
                    DeviceView(session: session)
                }
                if session.mode == .real { RealModeRibbon() }
            }
            Divider()
            SimulatorControls(session: session)
        }
    }
}

/// A red strip across the top of the canvas while trackers are really sent.
struct RealModeRibbon: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("REAL MODE — trackers are sent to their servers").fontWeight(.semibold)
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.red, in: Capsule())
        .padding(.top, 8)
        .shadow(color: .red.opacity(0.35), radius: 6, y: 2)
        .accessibilityLabel("Real mode: trackers are sent")
    }
}

// MARK: - Header

private struct SimulatorHeader: View {
    @Bindable var session: AdSession
    let magnification: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceSymbols.symbol(for: session.device))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.device.name).font(.headline).lineLimit(1)
                Text(specification)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.device.userAgent)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            postureControls
            orientationControl
            zoomMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var specification: String {
        let device = session.device
        let layout = session.layout
        let scale = device.scale.formatted(.number.precision(.fractionLength(0...3)))
        return "\(Int(layout.contentFrame.width))×\(Int(layout.contentFrame.height)) pt @\(scale)x · \(device.os) \(device.osVersion) · "
            + "devicetype \(device.openRTBDeviceType)"
    }

    @ViewBuilder private var postureControls: some View {
        switch session.device.family {
        case .foldable:
            Picker("Posture", selection: $session.folded) {
                Text("Unfolded").tag(false)
                Text("Folded").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Foldable posture: the main screen (unfolded) or the cover screen (folded)")
        case .dualScreen:
            Picker("Screens", selection: $session.spanned) {
                Text("One screen").tag(false)
                Text("Spanned").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Dual-screen: the app uses one screen, or spans both across the hinge")
        default:
            EmptyView()
        }
        if session.placement == .inlineBanner {
            Picker("Banner", selection: $session.bannerPosition) {
                Image(systemName: "rectangle.tophalf.inset.filled").help("Banner anchored at the top").tag(BannerPosition.top)
                Image(systemName: "rectangle.bottomhalf.inset.filled").help("Banner anchored at the bottom").tag(BannerPosition.bottom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Inline banner position")
        }
    }

    private var orientationControl: some View {
        Picker("Orientation", selection: $session.landscape) {
            Image(systemName: "rectangle.portrait").help("Portrait").tag(false)
            Image(systemName: "rectangle").help("Landscape").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(session.device.family == .ctv)
        .help(session.device.family == .ctv ? "Connected TVs are landscape only" : "Orientation (⌘→ rotates)")
    }

    private var zoomMenu: some View {
        Menu {
            Button("Zoom to Fit") { session.zoom = .fit }
            Divider()
            ForEach(ZoomSetting.levels, id: \.self) { level in
                Button("\(Int((level * 100).rounded()))%") { session.zoom = .scale(level) }
            }
        } label: {
            Text(session.zoom == .fit ? "Fit · \(Int((magnification * 100).rounded()))%" : ZoomSetting.scale(magnification).label)
                .monospacedDigit()
                .frame(minWidth: 64)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Zoom (⌘+ / ⌘− / ⌘0 fits)")
    }
}

/// SF Symbols for device families.
enum DeviceSymbols {
    static func symbol(for device: DeviceProfile) -> String {
        symbol(for: device.family, homeButton: device.family == .iPhone && device.cutout == .none)
    }

    static func symbol(for family: DeviceProfile.Family, homeButton: Bool = false) -> String {
        switch family {
        case .iPhone: homeButton ? "iphone.gen1" : "iphone"
        case .androidPhone: "smartphone"
        case .foldable: "rectangle.portrait.split.2x1"
        case .dualScreen: "rectangle.split.2x1"
        case .tablet: "ipad"
        case .ctv: "tv"
        }
    }

    static func title(for family: DeviceProfile.Family) -> String {
        switch family {
        case .iPhone: "iPhone"
        case .androidPhone: "Android"
        case .foldable: "Foldables"
        case .dualScreen: "Dual-screen"
        case .tablet: "Tablets"
        case .ctv: "Connected TV"
        }
    }
}
