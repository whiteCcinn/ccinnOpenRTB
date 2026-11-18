import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Placement rules")
struct PlacementRulesTests {
    private let phone = DeviceCatalog.defaultDevice

    @Test func connectedTVOnlyPlaysInstream() throws {
        let tv = try #require(DeviceCatalog.device(id: "roku-express"))
        #expect(Placement.available(on: tv) == [.ctvInstream])
        #expect(Placement.suggested(for: .banner, size: nil, on: tv) == .ctvInstream)
        #expect(Placement.inFeed.compatible(with: tv, format: .video, size: nil) == .ctvInstream)
        #expect(!Placement.available(on: phone).contains(.ctvInstream))
        #expect(Placement.ctvInstream.compatible(with: phone, format: .video, size: nil) == .interstitial)
        #expect(Placement.inFeed.compatible(with: phone, format: .video, size: nil) == .inFeed)
    }

    @Test func suggestionsFollowTheFormatAndSize() {
        #expect(Placement.suggested(for: .native, size: nil, on: phone) == .inFeed)
        #expect(Placement.suggested(for: .video, size: AdSize(width: 640, height: 360), on: phone) == .interstitial)
        #expect(Placement.suggested(for: .banner, size: AdSize(width: 320, height: 50), on: phone) == .inlineBanner)
        #expect(Placement.suggested(for: .banner, size: AdSize(width: 300, height: 250), on: phone) == .inlineBanner)
        #expect(Placement.suggested(for: .banner, size: AdSize(width: 320, height: 480), on: phone) == .interstitial)
        #expect(Placement.suggested(for: .banner, size: AdSize(width: 1024, height: 768), on: phone) == .interstitial)
        #expect(Placement.suggested(for: nil, size: nil, on: phone) == .inlineBanner)
    }

    /// AdCOM device type is reporting only: 3 (a TV set) and 7 (a box or stick) behave the same, and a non-TV device that
    /// reports 3 is not treated as a TV. Every CTV behaviour keys off `family == .ctv`.
    @Test func ctvBehaviourKeysOffTheFamilyNeverTheDeviceType() {
        func device(_ family: DeviceProfile.Family, deviceType: Int) -> DeviceProfile {
            DeviceProfile(id: "x", name: "X", family: family, screenWidth: 1920, screenHeight: 1080, scale: 1, os: "OS", osVersion: "1",
                          make: "M", model: "X", userAgent: "UA", openRTBDeviceType: deviceType)
        }
        for deviceType in [3, 7] {
            let tv = device(.ctv, deviceType: deviceType)
            #expect(Placement.available(on: tv) == [.ctvInstream])
            #expect(Placement.suggested(for: .video, size: nil, on: tv) == .ctvInstream)
            let layout = ScreenLayout(device: tv, landscape: false, folded: false, spanned: false)
            #expect(layout.chrome == .television && layout.isLandscape && layout.safeArea == DeviceInsets())
        }
        let notATV = device(.tablet, deviceType: 3)
        #expect(!Placement.available(on: notATV).contains(.ctvInstream))
        #expect(ScreenLayout(device: notATV, landscape: false, folded: false, spanned: false).chrome != .television)
    }

    /// The request's ad unit comes before the format and size (bid-client B6): rewarded, then interstitial. CTV still only
    /// plays instream.
    @Test func theRequestedPresentationComesFirst() throws {
        let rewarded = BidRequestSummary.Impression(id: "1", formats: [.video], isInterstitial: true, isRewarded: true)
        let interstitial = BidRequestSummary.Impression(id: "1", formats: [.banner], isInterstitial: true)
        let plain = BidRequestSummary.Impression(id: "1", formats: [.banner])
        let banner = AdSize(width: 320, height: 50)
        #expect(Placement.suggested(for: .video, size: nil, on: phone, impression: rewarded) == .rewarded)
        #expect(Placement.suggested(for: .native, size: nil, on: phone, impression: rewarded) == .rewarded)
        #expect(Placement.suggested(for: .banner, size: banner, on: phone, impression: interstitial) == .interstitial)
        #expect(Placement.suggested(for: .banner, size: banner, on: phone, impression: plain) == .inlineBanner)
        #expect(Placement.suggested(for: .banner, size: banner, on: phone, impression: nil) == .inlineBanner)
        let tv = try #require(DeviceCatalog.device(id: "apple-tv-4k"))
        #expect(Placement.suggested(for: .video, size: nil, on: tv, impression: rewarded) == .ctvInstream)
        #expect(Placement.inlineBanner.compatible(with: tv, format: .video, size: nil, impression: rewarded) == .ctvInstream)
        #expect(Placement.ctvInstream.compatible(with: phone, format: .video, size: nil, impression: rewarded) == .rewarded)
    }

    @Test func fullScreenPlacements() {
        #expect(Placement.allCases.filter(\.isFullScreen) == [.interstitial, .rewarded, .ctvInstream])
    }
}
