import CoreGraphics
import RTBKit
import SwiftUI

/// Where and how large the simulator's own text is drawn inside an ad's area: an empty slot's label, a renderer's message
/// ("VAST error 901", "Ad closed"), the player's status. It never sits under a dual-screen hinge (the slot's part on one
/// screen), and it is sized for the 10-foot UI on a CTV. A creative's own content still spans the hinge, as on the device.
enum SimulatorTextLayout {
    /// The ad area's coordinate space (set by `AdSlotView`), in which `simulatorTextArea` is expressed.
    static let adSpace = "ccinn.ad"
    /// The device screen content's coordinate space (set by the simulated app), in which `AdSlotView` finds its slot.
    static let screenSpace = "ccinn.screen"

    /// The text area as seen from a view at `frame` (in the ad area's coordinates): its overlap with the view, in the view's
    /// coordinates; the view's own bounds without an area, or when none of it is in the view.
    static func localArea(_ area: CGRect?, viewFrameInAd frame: CGRect, size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: CGSize(width: max(0, clean(size.width)), height: max(0, clean(size.height))))
        guard let area, isFinite(area), isFinite(frame) else { return bounds }
        let local = area.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds)
        guard !local.isNull, local.width >= 1, local.height >= 1 else { return bounds }
        return local
    }

    /// Text scale: the 10-foot UI of a CTV reads like the empty slot's label (`AdSlotPlaceholder.textScale`); other devices 1.
    static func scale(device: DeviceProfile, slot: CGSize) -> CGFloat {
        device.family == .ctv ? AdSlotPlaceholder.textScale(for: slot) : 1
    }

    private static func clean(_ value: CGFloat) -> CGFloat { value.isFinite ? value : 0 }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}

extension EnvironmentValues {
    /// The part of the ad area (its coordinates) where the simulator's own text may sit; `nil`: the whole area.
    @Entry var simulatorTextArea: CGRect? = nil
    /// The simulator's own text size factor (the 10-foot UI on a CTV).
    @Entry var simulatorTextScale: CGFloat = 1
}

/// Centres a status view (a message, a label, a spinner) in the simulator's text area as seen from where it is drawn.
private struct SimulatorStatusPlacement: ViewModifier {
    @Environment(\.simulatorTextArea) private var area

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let local = SimulatorTextLayout.localArea(area, viewFrameInAd: proxy.frame(in: .named(SimulatorTextLayout.adSpace)), size: proxy.size)
            content
                .frame(width: local.width, height: local.height)
                .position(x: local.midX, y: local.midY)
        }
    }
}

extension View {
    /// Centres this status view in the simulator's text area (never under a hinge), instead of the middle of its frame.
    func simulatorStatusPlacement() -> some View {
        modifier(SimulatorStatusPlacement())
    }
}
