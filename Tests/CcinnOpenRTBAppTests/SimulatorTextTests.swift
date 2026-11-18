import CoreGraphics
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// The simulator's own text — an empty slot's label, a renderer's message ("VAST error 901", "Ad closed"), the player's
/// status — stays out of a dual-screen hinge (it goes to the slot's part on one screen) and is sized for the 10-foot UI
/// on a CTV. A creative's own content may still span the hinge, as on the real device.
@Suite("Simulator text placement")
struct SimulatorTextTests {
    private func layout(_ id: String, spanned: Bool = false) throws -> ScreenLayout {
        ScreenLayout(device: try #require(DeviceCatalog.device(id: id)), landscape: false, folded: false, spanned: spanned)
    }

    /// An inline slot centred on a spanned Surface Duo (a 320×50 banner or a 300×250 slot in the article) crosses the hinge;
    /// its text area is its part on the first screen.
    @Test func anInlineSlotAcrossTheHingeKeepsItsTextOnTheFirstScreen() throws {
        let spanned = try layout("surface-duo", spanned: true)
        let width = spanned.contentFrame.width
        let banner = CGRect(x: (width - 320) / 2, y: 500, width: 320, height: 50)
        let area = AdSizing.placeholderLabelRect(slot: banner, layout: spanned)
        let hinge = try #require(spanned.hinge)
        // Back on the canvas, the area ends before the hinge starts.
        let onCanvas = area.offsetBy(dx: banner.minX + spanned.contentFrame.minX, dy: banner.minY + spanned.contentFrame.minY)
        #expect(onCanvas.maxX <= hinge.minX + 0.5, "\(onCanvas) vs hinge \(hinge)")
        #expect(area.width > 0 && area.width < banner.width && area.height == banner.height)
        // No hinge: the whole slot.
        let phone = try layout("iphone-17-pro")
        let phoneBanner = CGRect(x: (phone.contentFrame.width - 320) / 2, y: 700, width: 320, height: 50)
        #expect(AdSizing.placeholderLabelRect(slot: phoneBanner, layout: phone) == CGRect(origin: .zero, size: phoneBanner.size))
    }

    /// A status view placed inside a part of the ad area (the player under which a companion sits) is centred in the
    /// text area's overlap with it, in its own coordinates; without an area, or with none of it in the view, the view's
    /// own bounds.
    @Test func statusTextIsCentredInTheTextAreaSeenFromTheView() {
        let size = CGSize(width: 1114, height: 627)
        #expect(SimulatorTextLayout.localArea(nil, viewFrameInAd: CGRect(origin: .zero, size: size), size: size)
            == CGRect(origin: .zero, size: size))
        let firstScreen = CGRect(x: 0, y: 0, width: 540, height: 672)
        #expect(SimulatorTextLayout.localArea(firstScreen, viewFrameInAd: CGRect(origin: .zero, size: size), size: size)
            == CGRect(x: 0, y: 0, width: 540, height: 627))
        // A view lower in the ad area (a player at y 100): the same horizontal span, its own vertical extent.
        #expect(SimulatorTextLayout.localArea(firstScreen, viewFrameInAd: CGRect(x: 0, y: 100, width: 1114, height: 300),
                                              size: CGSize(width: 1114, height: 300))
            == CGRect(x: 0, y: 0, width: 540, height: 300))
        // A view entirely on the second screen keeps its own bounds.
        #expect(SimulatorTextLayout.localArea(firstScreen, viewFrameInAd: CGRect(x: 600, y: 0, width: 300, height: 100),
                                              size: CGSize(width: 300, height: 100))
            == CGRect(x: 0, y: 0, width: 300, height: 100))
        #expect(SimulatorTextLayout.localArea(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), viewFrameInAd: .zero, size: CGSize(width: 50, height: 50))
            == CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    /// The renderers' messages are read from ten feet on a TV: scaled like the empty slot's label (up to 3× on a 1080 pt
    /// TV). Phones, foldables and tablets keep their size.
    @Test func ctvTextIsScaledForTheTenFootUI() throws {
        let tv = try #require(DeviceCatalog.device(id: "apple-tv-4k"))
        #expect(SimulatorTextLayout.scale(device: tv, slot: CGSize(width: 1920, height: 1080)) == 3)
        let phone = try #require(DeviceCatalog.device(id: "iphone-17-pro"))
        #expect(SimulatorTextLayout.scale(device: phone, slot: CGSize(width: 402, height: 778)) == 1)
        let tablet = try #require(DeviceCatalog.device(id: "ipad-pro-11-m5"))
        #expect(SimulatorTextLayout.scale(device: tablet, slot: CGSize(width: 834, height: 1166)) == 1)
    }
}
