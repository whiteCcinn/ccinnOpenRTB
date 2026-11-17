import CoreGraphics
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Ad sizing")
struct AdSizingTests {
    private func layout(_ id: String, landscape: Bool = false, folded: Bool = false, spanned: Bool = false) throws -> ScreenLayout {
        ScreenLayout(device: try #require(DeviceCatalog.device(id: id)), landscape: landscape, folded: folded, spanned: spanned)
    }

    @Test func bannerThatFitsKeepsItsSize() throws {
        let size = AdSizing.adSize(bidSize: AdSize(width: 320, height: 50), format: .banner, placement: .inlineBanner,
                                   layout: try layout("iphone-15-pro"))
        #expect(size == CGSize(width: 320, height: 50))
    }

    @Test func bannerWiderThanTheScreenIsScaledDownProportionally() throws {
        let size = AdSizing.adSize(bidSize: AdSize(width: 728, height: 90), format: .banner, placement: .inlineBanner,
                                   layout: try layout("iphone-se-3"))
        #expect(size.width == 375)
        #expect(size.height == 46) // 90 × 375 / 728 = 46.4
    }

    @Test func leaderboardFitsOnATabletAndASpannedDualScreen() throws {
        let leaderboard = AdSize(width: 728, height: 90)
        #expect(AdSizing.adSize(bidSize: leaderboard, format: .banner, placement: .inlineBanner, layout: try layout("ipad-10"))
            == CGSize(width: 728, height: 90))
        #expect(AdSizing.adSize(bidSize: leaderboard, format: .banner, placement: .inlineBanner, layout: try layout("surface-duo", spanned: true))
            == CGSize(width: 728, height: 90))
        #expect(AdSizing.adSize(bidSize: leaderboard, format: .banner, placement: .inlineBanner, layout: try layout("surface-duo")).width == 540)
    }

    @Test func landscapeSafeAreaReducesTheAvailableWidth() throws {
        // 852 − 2 × 59 = 734 ≥ 728: fits.
        let size = AdSizing.adSize(bidSize: AdSize(width: 728, height: 90), format: .banner, placement: .inlineBanner,
                                   layout: try layout("iphone-15-pro", landscape: true))
        #expect(size == CGSize(width: 728, height: 90))
    }

    @Test func missingBidSizeUsesFormatDefaults() throws {
        let phone = try layout("iphone-15-pro")
        #expect(AdSizing.adSize(bidSize: nil, format: .banner, placement: .inlineBanner, layout: phone) == CGSize(width: 320, height: 50))
        let video = AdSizing.adSize(bidSize: nil, format: .video, placement: .inFeed, layout: phone)
        #expect(video.width == 369) // 393 − 2 × 12 feed padding
        #expect(video.height == 208) // 16:9
    }

    @Test func zeroOrNegativeBidSizeFallsBackToDefaults() throws {
        let phone = try layout("iphone-15-pro")
        #expect(AdSizing.adSize(bidSize: AdSize(width: 0, height: 250), format: .banner, placement: .inlineBanner, layout: phone)
            == CGSize(width: 320, height: 50))
        #expect(AdSizing.adSize(bidSize: AdSize(width: -1, height: -1), format: .banner, placement: .inlineBanner, layout: phone)
            == CGSize(width: 320, height: 50))
    }

    @Test func fullScreenPlacementsCoverTheScreen() throws {
        let phone = try layout("iphone-15-pro")
        for placement in [Placement.interstitial, .rewarded] {
            #expect(AdSizing.adSize(bidSize: AdSize(width: 320, height: 480), format: .banner, placement: placement, layout: phone)
                == CGSize(width: 393, height: 852))
        }
        let tv = try layout("google-tv")
        #expect(AdSizing.adSize(bidSize: AdSize(width: 640, height: 360), format: .video, placement: .ctvInstream, layout: tv)
            == CGSize(width: 1920, height: 1080))
    }

    @Test func spannedInterstitialCoversBothScreensAndTheHinge() throws {
        let size = AdSizing.adSize(bidSize: nil, format: .banner, placement: .interstitial, layout: try layout("surface-duo", spanned: true))
        #expect(size == CGSize(width: 1114, height: 720))
        let single = AdSizing.adSize(bidSize: nil, format: .banner, placement: .interstitial, layout: try layout("surface-duo"))
        #expect(single == CGSize(width: 540, height: 720))
    }

    @Test func inFeedNativeCardFillsTheColumn() throws {
        let size = AdSizing.adSize(bidSize: nil, format: .native, placement: .inFeed, layout: try layout("iphone-15-pro"))
        #expect(size.width == 369)
        #expect(size.height == (369 / 1.91).rounded() + AdSizing.nativeCardChromeHeight)
        // Wide screens cap the feed column.
        let tablet = AdSizing.adSize(bidSize: nil, format: .native, placement: .inFeed, layout: try layout("ipad-pro-11"))
        #expect(tablet.width == AdSizing.maximumFeedColumnWidth)
    }

    @Test func tallBannerIsScaledToFitTheHeightInLandscape() throws {
        // 300×600 half-page on an SE in landscape: 375 pt tall screen.
        let size = AdSizing.adSize(bidSize: AdSize(width: 300, height: 600), format: .banner, placement: .inlineBanner,
                                   layout: try layout("iphone-se-3", landscape: true))
        #expect(size.height <= 375)
        #expect(abs(size.width / size.height - 0.5) < 0.01)
    }
}
