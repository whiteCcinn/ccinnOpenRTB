import CoreGraphics
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Screen layout")
struct ScreenLayoutTests {
    private func device(_ id: String) throws -> DeviceProfile {
        try #require(DeviceCatalog.device(id: id))
    }

    @Test func phonePortraitAndLandscape() throws {
        let phone = try device("iphone-15-pro")
        let portrait = ScreenLayout(device: phone, landscape: false, folded: false, spanned: false)
        #expect(portrait.canvasSize == CGSize(width: 393, height: 852))
        #expect(portrait.panes.count == 1)
        #expect(portrait.contentFrame == CGRect(x: 0, y: 0, width: 393, height: 852))
        #expect(portrait.safeArea == DeviceInsets(top: 59, bottom: 34))
        #expect(portrait.cutout == .dynamicIsland)
        #expect(!portrait.isLandscape)
        #expect(portrait.showsStatusBar)

        let landscape = ScreenLayout(device: phone, landscape: true, folded: false, spanned: false)
        #expect(landscape.canvasSize == CGSize(width: 852, height: 393))
        #expect(landscape.isLandscape)
        // The island moves to the leading edge; iOS insets both sides and hides the status bar.
        #expect(landscape.safeArea.leading == 59 && landscape.safeArea.trailing == 59 && landscape.safeArea.top == 0)
        #expect(landscape.safeArea.bottom == 21)
        #expect(!landscape.showsStatusBar)
    }

    @Test func homeButtonPhoneHasNoInsetsInLandscape() throws {
        let landscape = ScreenLayout(device: try device("iphone-se-3"), landscape: true, folded: false, spanned: false)
        #expect(landscape.safeArea == DeviceInsets())
        #expect(landscape.canvasSize == CGSize(width: 667, height: 375))
    }

    @Test func foldableFoldedUsesTheCoverScreen() throws {
        let fold = try device("galaxy-z-fold")
        let folded = ScreenLayout(device: fold, landscape: false, folded: true, spanned: false)
        #expect(folded.canvasSize == CGSize(width: 344, height: 882))
        #expect(folded.crease == nil)
        #expect(folded.cutout == .punchHole)

        let unfolded = ScreenLayout(device: fold, landscape: false, folded: false, spanned: false)
        #expect(unfolded.canvasSize == CGSize(width: 690, height: 829))
        // The crease runs down the middle along the hinge; no visible camera on the main screen.
        #expect(unfolded.crease == .vertical(x: 345))
        #expect(unfolded.cutout == .none)

        let rotated = ScreenLayout(device: fold, landscape: true, folded: false, spanned: false)
        #expect(rotated.canvasSize == CGSize(width: 829, height: 690))
        #expect(rotated.crease == .horizontal(y: 345))
    }

    @Test func dualScreenSingleAndSpanned() throws {
        let duo = try device("surface-duo")
        let single = ScreenLayout(device: duo, landscape: false, folded: false, spanned: false)
        #expect(single.canvasSize == CGSize(width: 1114, height: 720))
        #expect(single.panes.map(\.frame) == [CGRect(x: 0, y: 0, width: 540, height: 720), CGRect(x: 574, y: 0, width: 540, height: 720)])
        #expect(single.hinge == CGRect(x: 540, y: 0, width: 34, height: 720))
        #expect(single.contentFrame == CGRect(x: 0, y: 0, width: 540, height: 720))

        let spanned = ScreenLayout(device: duo, landscape: false, folded: false, spanned: true)
        #expect(spanned.contentFrame == CGRect(x: 0, y: 0, width: 1114, height: 720))

        let stacked = ScreenLayout(device: duo, landscape: true, folded: false, spanned: true)
        #expect(stacked.canvasSize == CGSize(width: 720, height: 1114))
        #expect(stacked.hinge == CGRect(x: 0, y: 540, width: 720, height: 34))
        #expect(stacked.panes.map(\.frame) == [CGRect(x: 0, y: 0, width: 720, height: 540), CGRect(x: 0, y: 574, width: 720, height: 540)])
    }

    @Test func connectedTVIsLandscapeOnly() throws {
        let tv = try device("apple-tv-4k")
        let layout = ScreenLayout(device: tv, landscape: false, folded: false, spanned: false)
        let rotated = ScreenLayout(device: tv, landscape: true, folded: false, spanned: false)
        #expect(layout == rotated)
        #expect(layout.canvasSize == CGSize(width: 1920, height: 1080))
        #expect(layout.isLandscape)
        #expect(!layout.showsStatusBar)
        #expect(layout.safeArea == DeviceInsets())
    }

    @Test func postureFlagsAreIgnoredOnDevicesWithoutThem() throws {
        let phone = try device("pixel-8")
        #expect(ScreenLayout(device: phone, landscape: false, folded: true, spanned: true)
            == ScreenLayout(device: phone, landscape: false, folded: false, spanned: false))
    }
}
