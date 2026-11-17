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

    @Test func fullScreenPlacements() {
        #expect(Placement.allCases.filter(\.isFullScreen) == [.interstitial, .rewarded, .ctvInstream])
    }
}
