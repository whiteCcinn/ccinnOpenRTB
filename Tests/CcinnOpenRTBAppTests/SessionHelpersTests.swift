import CoreGraphics
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Tracker hosts")
struct TrackerHostsTests {
    @Test func auctionNativeAndScriptHostsAreGroupedAndSorted() {
        var candidate = Fixtures.candidate(.native("{}"), format: .native)
        candidate.adcomEvents = [AdcomEvent(type: 2, method: 1, url: "//view.adcom.example/v"),
                                 AdcomEvent(type: 1, method: 2, script: "<script src='https://js.adcom.example/t.js'></script>")]
        let native = NativeAd(assets: [NativeAsset(id: 2, content: .title(text: "x"),
                                                   link: AdLink(url: "https://l.example", clickTrackers: ["https://Click.Example/a"]))],
                              link: AdLink(url: "https://landing.example", clickTrackers: ["https://click.example/b?x=${AUCTION_PRICE}"]),
                              impressionTrackers: ["https://imp.native.example/i", "data:image/gif;base64,R0lGOD"],
                              jsTracker: "<script src=\"https://js.native.example/m.js\"></script>",
                              eventTrackers: [NativeEventTracker(event: 2, method: 1, url: "https://view.native.example/v")])
        let summary = TrackerHosts.summary(candidate: candidate, native: native, vastDocuments: [], resolved: nil)
        #expect(summary.hosts.map(\.name) == ["bill.dsp.example", "click.example", "imp.native.example", "js.adcom.example",
                                              "js.native.example", "loss.dsp.example", "view.adcom.example", "view.native.example",
                                              "win.dsp.example"])
        #expect(summary.hosts.first { $0.name == "click.example" }?.count == 2)
        #expect(summary.hosts.first { $0.name == "view.adcom.example" }?.kinds == ["impression"])
        #expect(summary.notes.isEmpty)
    }

    @Test func unresolvedVASTTagsAndWinNoticeMarkupAreNoted() {
        let tag = Fixtures.candidate(.vast(.url("https://tags.example/vast?x=1")), format: .video)
        #expect(TrackerHosts.summary(candidate: tag, native: nil, vastDocuments: [], resolved: nil).notes.first?.contains("tags.example") == true)
        let byWin = Fixtures.candidate(.none, format: .video)
        #expect(TrackerHosts.summary(candidate: byWin, native: nil, vastDocuments: [], resolved: nil).notes.first?.contains("win notice") == true)
        #expect(TrackerHosts.summary(candidate: nil, native: nil, vastDocuments: [], resolved: nil).hosts.isEmpty)
    }

    @Test func vastDocumentsAndResolvedChainsContributeTheirTrackers() {
        let linear = VASTLinear(trackingEvents: [VASTTracking(event: .start, url: "https://events.vast.example/start")],
                                clickTrackings: ["https://clicks.vast.example/c"])
        let wrapper = VASTWrapper(adTagURI: "https://next.example/vast", impressions: ["https://imp.wrapper.example/i"],
                                  creatives: [VASTCreative(linear: linear)])
        let document = VASTDocument(ads: [VASTAd(body: .wrapper(wrapper))], errors: ["https://err.root.example/e?c=[ERRORCODE]"])
        let candidate = Fixtures.candidate(.vast(.xml("<VAST/>")), format: .video, winURL: nil)
        let summary = TrackerHosts.summary(candidate: candidate, native: nil, vastDocuments: [document], resolved: nil)
        #expect(summary.hosts.map(\.name) == ["bill.dsp.example", "clicks.vast.example", "err.root.example", "events.vast.example",
                                              "imp.wrapper.example", "loss.dsp.example"])
        #expect(summary.notes.count == 1)

        let resolved = ResolvedVAST(ads: [ResolvedVASTAd(inline: VASTInline(), impressions: ["https://imp.inline.example/i"],
                                                         viewableImpression: VASTViewableImpression(viewable: ["https://mrc.example/v"]))],
                                    adFailures: [VASTAdFailure(code: .noAdsAfterWrapper, errorURLs: ["https://pod.example/e"])])
        let afterRender = TrackerHosts.summary(candidate: candidate, native: nil, vastDocuments: [document], resolved: resolved)
        #expect(afterRender.hosts.map(\.name) == ["bill.dsp.example", "imp.inline.example", "loss.dsp.example", "mrc.example", "pod.example"])
        #expect(afterRender.notes.isEmpty)
    }

    @Test func adcomAndNativeEventNumberingsAreNotConfused() {
        var candidate = Fixtures.candidate(.native("{}"), format: .native, winURL: nil)
        candidate.billingURL = nil
        candidate.lossURL = nil
        // AdCOM 1.0: 1 loaded, 2 impression, 3–5 viewable. Native 1.2: 1 impression, 2–4 viewable.
        candidate.adcomEvents = [AdcomEvent(type: 1, method: 1, url: "https://loaded.adcom.example/"),
                                 AdcomEvent(type: 2, method: 1, url: "https://imp.adcom.example/"),
                                 AdcomEvent(type: 5, method: 1, url: "https://v50.adcom.example/"),
                                 AdcomEvent(type: 501, method: 1, url: "https://vendor.adcom.example/")]
        let native = NativeAd(link: AdLink(url: "https://landing.example"),
                              eventTrackers: [NativeEventTracker(event: 1, method: 1, url: "https://imp.native.example/"),
                                              NativeEventTracker(event: 4, method: 1, url: "https://v50.native.example/")])
        let kinds = Dictionary(uniqueKeysWithValues: TrackerHosts.summary(candidate: candidate, native: native, vastDocuments: [], resolved: nil)
            .hosts.map { ($0.name, $0.kinds) })
        #expect(kinds["loaded.adcom.example"] == ["impression"])
        #expect(kinds["imp.adcom.example"] == ["impression"])
        #expect(kinds["v50.adcom.example"] == ["viewability"])
        #expect(kinds["vendor.adcom.example"] == ["event"])
        #expect(kinds["imp.native.example"] == ["impression"])
        #expect(kinds["v50.native.example"] == ["viewability"])
    }

    @Test func hostsOfTemplates() {
        #expect(TrackerHosts.host(of: " https://User@Ads.Example:8443/p?x=${AUCTION_PRICE}") == "ads.example")
        #expect(TrackerHosts.host(of: "//cdn.example/x") == "cdn.example")
        #expect(TrackerHosts.host(of: "https://[::1]:80/x") == "::1")
        #expect(TrackerHosts.host(of: "ccinn-sample://media/x.mp4") == nil)
        #expect(TrackerHosts.host(of: "/relative") == nil)
        #expect(TrackerHosts.host(of: "") == nil)
    }

    @Test func scriptSourcesAreExtractedFromMarkup() {
        #expect(TrackerHosts.scriptSources("<script src = \"https://a.example/x.js\"></script><img SRC='https://b.example/p'>")
            == ["https://a.example/x.js", "https://b.example/p"])
        #expect(TrackerHosts.scriptSources("https://c.example/tag.js") == ["https://c.example/tag.js"])
        #expect(TrackerHosts.scriptSources("<script>var src = 1;</script><script src=\"unterminated") == [])
    }
}

@Suite("Macro settings")
struct MacroSettingsTests {
    @Test func keysAreNormalised() {
        #expect(MacroSettings.plainKey("${KEY}") == "KEY")
        #expect(MacroSettings.plainKey("KEY") == "KEY")
        #expect(MacroSettings.plainKey("${}") == "${}")
        #expect(MacroSettings.bracketedKey("DOMAIN") == "[DOMAIN]")
        #expect(MacroSettings.bracketedKey("[DOMAIN]") == "[DOMAIN]")
    }

    @Test func pricesAreParsedStrictly() {
        #expect(MacroSettings.price(" 1.5 ") == 1.5)
        #expect(MacroSettings.price("0,75") == 0.75)
        #expect(MacroSettings.price("") == nil)
        #expect(MacroSettings.price("-1") == nil)
        #expect(MacroSettings.price("inf") == nil)
        #expect(MacroSettings.price("abc") == nil)
    }

    @Test func panelOverridesBidMacrosAndDefaultsFillTheRest() {
        var candidate = Fixtures.candidate(.html(""))
        candidate.customMacros = ["CAMPAIGN": "bid", "CREATIVE": "c1"]
        var settings = MacroSettings()
        settings.customMacros = [MacroEntry(key: "CAMPAIGN", value: "panel"), MacroEntry(key: " ", value: "ignored")]
        settings.encryptedPrice = " WFX0aS3n "
        settings.auctionID = "override"
        settings.seatID = "seat-x"
        let input = ParsedInput(kind: .bidResponse(.v2("2.5")), responseID: "resp",
                                request: BidRequestSummary(id: "request-id", impressions: []))
        let context = settings.context(candidate: candidate, input: input, device: DeviceCatalog.defaultDevice,
                                       playerSize: CGSize(width: 0, height: CGFloat.infinity), transactionID: "tx", playhead: 3.5)
        #expect(context.custom["CAMPAIGN"] == "panel")
        #expect(context.custom["CREATIVE"] == "c1")
        #expect(context.custom[" "] == nil)
        #expect(context.custom["[TRANSACTIONID]"] == "tx")
        #expect(context.encryptedPrice == "WFX0aS3n")
        #expect(context.price == 2.5)
        #expect(context.marketBidRatio == nil)
        #expect(context.auctionID == "override")
        #expect(context.seatID == "seat-x")
        // A zero / infinite player size is not passed on: the kit's default for a missing size applies.
        let kitDefault = MacroContext.simulatorDefaults(candidate: candidate, request: input.request, device: DeviceCatalog.defaultDevice)
        #expect(context.playerWidth == kitDefault.playerWidth && context.playerHeight == kitDefault.playerHeight)
        #expect(context.adPlayhead == 3.5)
        #expect(context.timestamp == nil && context.cacheBuster == nil)

        settings.auctionID = ""
        #expect(settings.context(candidate: candidate, input: input, device: DeviceCatalog.defaultDevice, playerSize: .zero,
                                 transactionID: "tx").auctionID == "request-id")
    }

    @Test func thePastedRequestBeatsThePanelFallbacksAndExplicitMacrosBeatEverything() {
        let candidate = Fixtures.candidate(.html(""))
        var settings = MacroSettings()
        settings.requestValues = [MacroEntry(key: "[DOMAIN]", value: "fallback.example"), MacroEntry(key: "PAGEURL", value: "https://fallback/")]
        let request = BidRequestSummary(id: "req", impressions: [], domain: "real.example", ifa: "IFA-1", transactionID: "tid-9")
        let input = ParsedInput(kind: .bidResponse(.v2("2.6")), responseID: "resp", bidResponseID: "bidid-1", request: request)
        let context = settings.context(candidate: candidate, input: input, device: DeviceCatalog.defaultDevice, playerSize: .zero,
                                       transactionID: "per-render")
        #expect(context.custom["[DOMAIN]"] == "real.example")
        #expect(context.custom["[PAGEURL]"] == "https://fallback/")
        #expect(context.custom["[IFA]"] == "IFA-1")
        #expect(context.custom["[TRANSACTIONID]"] == "tid-9")
        #expect(context.bidID == "bidid-1")
        #expect(context.auctionID == "req")

        // Without a request: the panel's fallbacks and the per-render transaction id; the response id is the auction id.
        let bare = ParsedInput(kind: .bidResponse(.v2("2.6")), responseID: "resp")
        let fallback = settings.context(candidate: candidate, input: bare, device: DeviceCatalog.defaultDevice, playerSize: .zero,
                                        transactionID: "per-render")
        #expect(fallback.custom["[DOMAIN]"] == "fallback.example")
        #expect(fallback.custom["[TRANSACTIONID]"] == "per-render")
        #expect(fallback.auctionID == "resp")
        #expect(fallback.bidID == candidate.bidID)
    }

    @Test func lossReasonsAreKnownOrExchangeSpecific() {
        #expect(LossReason.reason(code: 102) == .lostToHigherBid)
        #expect(LossReason.reason(code: 1001).title == "Exchange-specific")
        #expect(Set(LossReason.all.map(\.code)).count == LossReason.all.count)
    }
}

@Suite("Viewability controller")
struct ViewabilityControllerTests {
    @Test func audioAdsAreUndeterminedWhenTheyEnd() {
        var controller = ViewabilityController(kind: .audio)
        _ = controller.videoEvent(.creativeView, adIndex: 0, at: 0)
        _ = controller.playback(adIndex: 0, isPlaying: true, at: 0)
        #expect(controller.advance(to: 30).isEmpty)
        #expect(controller.videoEvent(.complete, adIndex: 0, at: 30) == [.videoViewability(.undetermined, adIndex: 0)])
        #expect(controller.videoEvent(.close, adIndex: 0, at: 31).isEmpty)
    }

    @Test func playbackReportedBeforeTheFirstFrameStillCounts() {
        var controller = ViewabilityController(kind: .video)
        _ = controller.visibility(1, at: 0)
        _ = controller.playback(adIndex: 0, isPlaying: true, at: 0)
        _ = controller.videoEvent(.creativeView, adIndex: 0, at: 0.5)
        #expect(controller.nextDeadline == 2.5)
        #expect(controller.advance(to: 2.5) == [.videoViewability(.viewable, adIndex: 0)])
        #expect(controller.videoEvent(.complete, adIndex: 0, at: 15).isEmpty)
    }

    @Test func closingDecidesEveryStartedAd() {
        var controller = ViewabilityController(kind: .video)
        _ = controller.videoEvent(.creativeView, adIndex: 0, at: 0)
        #expect(controller.closed(at: 1) == [.videoViewability(.notViewable, adIndex: 0)])
        #expect(controller.closed(at: 2).isEmpty)
    }

    @Test func displayIgnoresPlayback() {
        var controller = ViewabilityController(kind: .display)
        #expect(controller.playback(adIndex: 0, isPlaying: true, at: 0).isEmpty)
        #expect(controller.videoEvent(.complete, adIndex: 0, at: 0).isEmpty)
        _ = controller.rendered(at: 0)
        #expect(controller.advance(to: 1) == [.viewable(.mrc50), .viewable(.mrc100)])
    }
}

@Suite("Feed geometry")
struct FeedGeometryTests {
    private func geometry(_ id: String = "iphone-15-pro", ad: CGSize = CGSize(width: 300, height: 250), landscape: Bool = false) throws -> FeedGeometry {
        let device = try #require(DeviceCatalog.device(id: id))
        return FeedGeometry(layout: ScreenLayout(device: device, landscape: landscape, folded: false, spanned: false), adSize: ad, captioned: true)
    }

    @Test func theFeedLeavesRoomToScrollTheAdOut() throws {
        let feed = try geometry()
        #expect(feed.viewport.minY == 59 + FeedGeometry.appBarHeight)
        #expect(feed.viewport.height == 852 - 59 - 34 - FeedGeometry.appBarHeight - FeedGeometry.tabBarHeight)
        #expect(feed.columnWidth == 369)
        #expect(feed.adFrame.width == 300)
        #expect(feed.adFrame.minX == 34.5)
        #expect(feed.adSlot.height == 250 + FeedGeometry.adCaptionHeight)
        #expect(feed.maxOffset >= feed.adFrame.maxY)
        #expect(feed.items.filter { $0.kind == .ad }.count == 1)
    }

    @Test func visibleFractionFollowsTheScrollPosition() throws {
        let feed = try geometry()
        let atTop = feed.adFrame.minY
        #expect(feed.visibleFraction(offset: atTop) == 1)
        #expect(abs(feed.visibleFraction(offset: atTop + 125) - 0.5) < 1e-9)
        #expect(feed.visibleFraction(offset: atTop + 250) == 0)
        #expect(feed.visibleFraction(offset: CGFloat.infinity) == feed.visibleFraction(offset: 0))
        #expect(feed.visibleFraction(offset: -500) == feed.visibleFraction(offset: 0))
    }

    @Test func theSliderMapsFractionsToOffsetsAndBack() throws {
        for id in ["iphone-se-3", "iphone-16-pro-max", "ipad-pro-11", "galaxy-z-fold"] {
            let feed = try geometry(id)
            for fraction in [0.0, 0.25, 0.5, 0.75, 0.99, 1] {
                let offset = feed.offset(forVisibleFraction: fraction)
                #expect(abs(feed.visibleFraction(offset: offset) - fraction) < 0.01, "\(id) \(fraction)")
            }
        }
    }

    @Test func anAdTallerThanTheViewportNeverReachesFullVisibility() throws {
        let feed = try geometry("iphone-se-3", ad: CGSize(width: 300, height: 600), landscape: true)
        #expect(feed.visibleFraction(offset: feed.offset(forVisibleFraction: 1)) < 1)
    }
}

@Suite("Zoom")
struct ZoomSettingTests {
    @Test func fitScalesDownButNeverUp() {
        #expect(ZoomSetting.fitScale(content: CGSize(width: 1000, height: 500), available: CGSize(width: 540, height: 1000), margin: 20) == 0.5)
        #expect(ZoomSetting.fitScale(content: CGSize(width: 100, height: 100), available: CGSize(width: 2000, height: 2000), margin: 0) == 1)
        #expect(ZoomSetting.fitScale(content: .zero, available: CGSize(width: 10, height: 10), margin: 0) == 1)
        #expect(ZoomSetting.fitScale(content: CGSize(width: 10_000, height: 10_000), available: CGSize(width: 1, height: 1), margin: 50)
            == ZoomSetting.minimum)
    }

    @Test func stepsFollowThePresets() {
        #expect(ZoomSetting.zoomedIn(from: 0.5) == .scale(0.67))
        #expect(ZoomSetting.zoomedIn(from: 0.42) == .scale(0.5))
        #expect(ZoomSetting.zoomedOut(from: 0.5) == .scale(0.33))
        #expect(ZoomSetting.zoomedIn(from: 2) == .scale(2.5))
        #expect(ZoomSetting.zoomedOut(from: 0.25) == .scale(0.2))
        #expect(ZoomSetting.scale(.nan).magnification(fitting: 0.4) == 1)
        #expect(ZoomSetting.fit.magnification(fitting: 0.4) == 0.4)
        #expect(ZoomSetting.scale(9).label == "300%")
    }
}
