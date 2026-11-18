import CcinnOpenRTBKit
import CoreGraphics
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// Full-screen placements (interstitial, rewarded, CTV instream) and how a bid picks its placement.
@MainActor
@Suite("Full-screen placements")
struct FullScreenPlacementTests {
    private static let interstitialBanner: AdCandidate = {
        var candidate = Fixtures.candidate(.html("<div>interstitial</div>"), id: "0.0")
        candidate.size = AdSize(width: 320, height: 480)
        return candidate
    }()

    private static let inlineBanner = Fixtures.candidate(.html("<div>banner</div>"), id: "0.0")

    /// A session whose parser answers each pasted text with its own input.
    private static func session(answering inputs: [String: ParsedInput]) -> AdSession {
        var services = Fixtures.services(Fixtures.input([]), recorder: KitRecorder())
        services.parseInput = { text, _ in inputs[text] ?? ParsedInput(kind: .empty) }
        return AdSession(services: services, monitor: NetworkMonitor(transport: CountingTransport(), publishInterval: .zero),
                         clock: ManualSessionClock(), browser: RecordingBrowser(), opensClickThroughs: { false }, parseDebounce: .zero)
    }

    private static func paste(_ text: String, into session: AdSession) async {
        session.responseText = text
        await session.parseNow()
    }

    // MARK: Slot geometry

    /// On every catalog device, orientation and posture, a full-screen slot is the safe-area rect of the screen in use:
    /// the size the session reports (`adSize`, `RenderRequest.adSize`), the frame the simulator draws and the placeholder's
    /// label all come from that one rect.
    @Test func theFullScreenSlotIsTheSafeAreaRectOnEveryDeviceOrientationAndPosture() async {
        let session = Self.session(answering: ["ad": Fixtures.input([Self.interstitialBanner])])
        await Self.paste("ad", into: session)
        for device in DeviceCatalog.all {
            session.device = device
            for landscape in [false, true] {
                for (folded, spanned) in [(false, false), (true, false), (false, true)] {
                    session.landscape = landscape
                    session.folded = folded
                    session.spanned = spanned
                    let layout = session.layout
                    let insets = layout.safeArea
                    let content = layout.contentFrame.size
                    let safeRect = CGRect(x: insets.leading, y: insets.top, width: content.width - insets.leading - insets.trailing,
                                          height: content.height - insets.top - insets.bottom)
                    for placement in Placement.available(on: device) where placement.isFullScreen {
                        session.placement = placement
                        let context = "\(device.id) \(placement.rawValue) landscape \(landscape) folded \(folded) spanned \(spanned)"
                        #expect(session.adSize == safeRect.size, "\(context)")
                        let frame = AdSizing.slotFrame(placement: session.placement, adSize: session.adSize, layout: layout)
                        #expect(frame == safeRect, "\(context)")
                        #expect(AdSlotPlaceholder.sizeText(frame.size) == "\(Int(safeRect.width)) × \(Int(safeRect.height))", "\(context)")
                    }
                }
            }
        }
    }

    @Test func aRenderedFullScreenAdReportsTheSafeAreaRect() async throws {
        let session = Self.session(answering: ["ad": Fixtures.input([Self.interstitialBanner])])
        await Self.paste("ad", into: session)
        session.device = try #require(DeviceCatalog.device(id: "surface-duo"))
        session.spanned = true
        session.render()
        for _ in 0..<500 where session.phase != .ready { try await Task.sleep(for: .milliseconds(1)) }
        let request = try #require(session.renderRequest)
        #expect(request.placement == .interstitial)
        #expect(request.adSize == AdSizing.fullScreenSlot(in: session.layout).size)
        #expect(request.adSize == CGSize(width: 1114, height: 720 - 24 - 24))
    }

    @Test func thePlaceholderLabelIsTheSizeItIsDrawnAt() {
        #expect(AdSlotPlaceholder.sizeText(CGSize(width: 402, height: 874 - 62 - 34)) == "402 × 778")
        #expect(AdSlotPlaceholder.sizeText(CGSize(width: 320.4, height: 49.6)) == "320 × 50")
    }

    // MARK: The bid picks the placement

    @Test func anInterstitialSizedBidSelectsTheInterstitialPlacement() async {
        let session = Self.session(answering: ["interstitial": Fixtures.input([Self.interstitialBanner])])
        #expect(session.placement == .inlineBanner)
        await Self.paste("interstitial", into: session)
        #expect(session.placement == .interstitial)
    }

    /// The user's placement stands while they edit the same kind of bid; a bid of another kind brings its own placement.
    @Test func thePlacementFollowsTheKindOfBidAndTheUsersChoiceStandsWithinIt() async {
        var edited = Self.interstitialBanner
        edited.price = 9
        let session = Self.session(answering: ["interstitial": Fixtures.input([Self.interstitialBanner]),
                                               "interstitial, edited": Fixtures.input([edited]),
                                               "banner": Fixtures.input([Self.inlineBanner]),
                                               "video": Fixtures.input([Fixtures.candidate(.vast(.url("https://v.example/tag")), format: .video)])])
        await Self.paste("interstitial", into: session)
        #expect(session.placement == .interstitial)

        session.placement = .rewarded
        await Self.paste("interstitial, edited", into: session)
        #expect(session.placement == .rewarded)

        await Self.paste("banner", into: session)
        #expect(session.placement == .inlineBanner)

        await Self.paste("video", into: session)
        #expect(session.placement == .interstitial)
    }

    @Test func aPlacementThatCannotShowTheFormatGivesWayEvenForTheSameKindOfBid() async {
        let video = Fixtures.candidate(.vast(.url("https://v.example/tag")), format: .video)
        let session = Self.session(answering: ["video": Fixtures.input([video]), "video, again": Fixtures.input([video])])
        await Self.paste("video", into: session)
        session.placement = .inlineBanner
        await Self.paste("video, again", into: session)
        #expect(session.placement == .interstitial)
    }

    @Test func theLaunchPlacementWinsOverTheSamplesOwn() async {
        let sample = Sample(id: "interstitial", title: "Interstitial", group: "Display", response: "interstitial")
        let session = Self.session(answering: ["interstitial": Fixtures.input([Self.interstitialBanner])])
        await LaunchOptions(arguments: ["app", "--sample", "interstitial", "--no-render"]).apply(to: session, samples: [sample])
        #expect(session.placement == .interstitial)

        let other = Self.session(answering: ["interstitial": Fixtures.input([Self.interstitialBanner])])
        await LaunchOptions(arguments: ["app", "--sample", "interstitial", "--placement", "rewarded", "--no-render"])
            .apply(to: other, samples: [sample])
        #expect(other.placement == .rewarded)
    }
}
