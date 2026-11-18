import CcinnOpenRTBKit
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
        #expect(summary.notes.contains { $0.contains("the creative's own scripts") }, "scripts may make requests no list can know")
    }

    /// Safety review: an unquoted `<script src=…>` in a jstracker gave no host and no note. Script markup is tokenised
    /// as HTML (quoted, unquoted and entity-encoded attribute values; any resource element), and whatever scripts may
    /// load at run time is said explicitly.
    @Test func trackerMarkupIsTokenisedAsHTML() {
        let markup = """
        <SCRIPT src=https://unquoted.example/t.js async></SCRIPT>
        <img data-src="https://not-a-src.example/x" src='https://single.example/p.gif?a=1&amp;b=2'>
        <iframe src="https:&#x2F;&#x2F;entity.example&#47;f.html"></iframe>
        <script>var u = "src=https://in-script.example/never-parsed";</script>
        <link rel=preload href=//protocol.example/s.css>
        """
        let sources = TrackerHosts.scriptSources(markup)
        #expect(sources == ["https://unquoted.example/t.js", "https://single.example/p.gif?a=1&b=2", "https://entity.example/f.html",
                            "//protocol.example/s.css"], "\(sources)")
        #expect(TrackerHosts.scriptSources("https://bare.example/t.js") == ["https://bare.example/t.js"])
        #expect(TrackerHosts.scriptSources("<script src=\"unterminated") == [])
        #expect(TrackerHosts.scriptSources("<img src=>").isEmpty)
    }

    /// Safety review: a Native video asset's VAST trackers were missing from the sheet. Inline vasttag XML is listed
    /// from the document; a tag URL from its resolution, or with an explicit note while it is not resolved.
    @Test func nativeVideoVASTTrackersAreListed() {
        let candidate = Fixtures.candidate(.native("{}"), format: .native)
        let xml = "<VAST version=\"3.0\"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://imp.video.example/i</Impression>"
            + "<Creatives></Creatives></InLine></Ad></VAST>"
        let inline = NativeAd(assets: [NativeAsset(id: 4, content: .video(vastTag: xml))], link: AdLink(url: "https://l.example"))
        #expect(TrackerHosts.summary(candidate: candidate, native: inline, vastDocuments: [], resolved: nil).hosts.map(\.name)
            .contains("imp.video.example"))

        let byURL = NativeAd(assets: [NativeAsset(id: 4, content: .video(vastTag: "https://tags.video.example/vast"))], link: AdLink(url: "https://l.example"))
        let unresolved = TrackerHosts.summary(candidate: candidate, native: byURL, vastDocuments: [], resolved: nil)
        #expect(unresolved.notes.contains { $0.contains("tags.video.example") }, "\(unresolved.notes)")
        let resolved = TrackerHosts.summary(candidate: candidate, native: byURL, vastDocuments: [], resolved: nil,
                                            nativeVideo: Fixtures.vast(ads: 1))
        #expect(resolved.hosts.map(\.name).contains("imp.vast.example"))
        #expect(!resolved.notes.contains { $0.contains("tags.video.example") })
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

/// Safety review: Real mode is not the only one that reaches servers — the ad's content (VAST, images, media) loads in
/// Simulated mode too. The confirmation and the Inspector list the content hosts the render contacted.
@Suite("Content hosts")
struct ContentHostsTests {
    private func entry(_ url: String, _ category: TrackerCategory, trigger: String, delivery: NetworkDelivery, sequence: Int) -> NetworkEntry {
        var entry = NetworkEntry(sequence: sequence, category: category, trigger: trigger, source: "bid 0.0", template: url, url: url, state: .completed(status: 200))
        entry.delivery = delivery
        return entry
    }

    @Test func onlyContentThatWentOutCounts() {
        let entries = [
            entry("https://ads.example/tag.xml", .content, trigger: "VAST tag", delivery: .network, sequence: 1),
            entry("https://cdn.example/v.mp4", .content, trigger: "media file", delivery: .network, sequence: 2),
            entry("https://cdn.example/v.mp4", .content, trigger: "media file", delivery: .network, sequence: 3),
            entry("https://t.example/imp", .impression, trigger: "impression", delivery: .simulated, sequence: 4),
            entry("ccinn-sample://media/sample-15s.mp4", .content, trigger: "media file", delivery: .local, sequence: 5),
            entry("https://off.example/i.png", .content, trigger: "image", delivery: .offline, sequence: 6),
        ]
        let hosts = TrackerHosts.contentHosts(entries)
        #expect(hosts.map(\.name) == ["ads.example", "cdn.example"])
        #expect(hosts.first { $0.name == "cdn.example" }?.count == 2)
        #expect(hosts.first { $0.name == "cdn.example" }?.kinds == ["media file"])
        #expect(hosts.first { $0.name == "ads.example" }?.kinds == ["VAST tag"])
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

    // MARK: Panel over the kit's defaults

    private static let candidate = Fixtures.candidate(.html(""))

    /// What `MacroContext.simulatorDefaults` would give, written out so the panel's rules are tested whatever the kit's
    /// version sets: the bid's MBR of 1 and the player's `[VASTVERSIONS]`.
    private static let simulatorOwn = MacroContext(price: 2.5, marketBidRatio: 1, custom: ["[APPBUNDLE]": "com.advertised.app"],
                                                   customLists: ["[VASTVERSIONS]": ["2", "3", "7"]])

    @Test func anEmptyClearingPriceKeepsTheDefaultMarketBidRatio() {
        var settings = MacroSettings()
        let untyped = settings.overlay(on: Self.simulatorOwn, withoutRequest: Self.simulatorOwn, candidate: Self.candidate, transactionID: "tx")
        #expect(untyped.marketBidRatio == 1)
        #expect(untyped.price == 2.5)
        settings.clearingPrice = "1.25"
        let typed = settings.overlay(on: Self.simulatorOwn, withoutRequest: Self.simulatorOwn, candidate: Self.candidate, transactionID: "tx")
        #expect(typed.marketBidRatio == 0.5)
        #expect(typed.price == 1.25)

        // Through `context`: whatever the kit's default is.
        let kit = MacroContext.simulatorDefaults(candidate: Self.candidate, request: nil, device: DeviceCatalog.defaultDevice)
        #expect(MacroSettings().context(candidate: Self.candidate, input: Fixtures.input([]), device: DeviceCatalog.defaultDevice,
                                        playerSize: .zero, transactionID: "tx").marketBidRatio == kit.marketBidRatio)
    }

    @Test func emptyPanelFieldsKeepTheDefaults() {
        let base = MacroContext(encryptedPrice: "ENC", minimumToWin: 1.5, adPlayhead: 4, timestamp: Date(timeIntervalSince1970: 7),
                                cacheBuster: "42")
        let context = MacroSettings().overlay(on: base, withoutRequest: base, candidate: Self.candidate, transactionID: "tx")
        #expect(context.encryptedPrice == "ENC" && context.minimumToWin == 1.5 && context.adPlayhead == 4)
        #expect(context.timestamp == Date(timeIntervalSince1970: 7) && context.cacheBuster == "42")
    }

    /// VAST `Array<T>` macros (VAST 4.1/4.2 §6.1) typed in the panel are lists: `customLists`, one item per comma, so the
    /// expander encodes each item and keeps the commas literal.
    @Test func listMacrosFromThePanelAreLists() {
        var settings = MacroSettings()
        settings.requestValues = [MacroEntry(key: "BLOCKEDADCATEGORIES", value: " IAB25 , IAB26,, "),
                                  MacroEntry(key: "[REGULATIONS]", value: "gdpr,coppa"),
                                  MacroEntry(key: "[LATLONG]", value: "51.004703,3.754806"),
                                  MacroEntry(key: "[DOMAIN]", value: "a,b.example")]
        let context = settings.overlay(on: MacroContext(), withoutRequest: MacroContext(), candidate: Self.candidate, transactionID: "tx")
        #expect(context.customLists["[BLOCKEDADCATEGORIES]"] == ["IAB25", "IAB26"])
        #expect(context.customLists["[REGULATIONS]"] == ["gdpr", "coppa"])
        #expect(context.customLists["[LATLONG]"] == ["51.004703", "3.754806"])
        #expect(context.custom["[BLOCKEDADCATEGORIES]"] == nil && context.custom["[REGULATIONS]"] == nil)
        // A scalar stays one value, commas and all.
        #expect(context.custom["[DOMAIN]"] == "a,b.example" && context.customLists["[DOMAIN]"] == nil)
        #expect(MacroSettings.listMacroKeys.isSuperset(of: ["[BLOCKEDADCATEGORIES]", "[VASTVERSIONS]", "[REGULATIONS]", "[ADCATEGORIES]",
                                                            "[UNIVERSALADID]"]))
    }

    /// The pasted request beats the panel; the panel beats the simulator's own defaults (the player's `[VASTVERSIONS]`, a
    /// value the kit derives from the bid), which a list in `customLists` used to shadow.
    @Test func thePanelOverridesTheSimulatorsDefaultsButNotTheRequest() {
        var fromRequest = Self.simulatorOwn
        fromRequest.customLists["[BLOCKEDADCATEGORIES]"] = ["IAB7"]
        fromRequest.custom["[DOMAIN]"] = "request.example"
        var settings = MacroSettings()
        settings.requestValues = [MacroEntry(key: "[VASTVERSIONS]", value: "7,8"), MacroEntry(key: "[BLOCKEDADCATEGORIES]", value: "IAB25"),
                                  MacroEntry(key: "[DOMAIN]", value: "panel.example"), MacroEntry(key: "[APPBUNDLE]", value: "com.publisher")]
        let context = settings.overlay(on: fromRequest, withoutRequest: Self.simulatorOwn, candidate: Self.candidate, transactionID: "tx")
        #expect(context.customLists["[VASTVERSIONS]"] == ["7", "8"])
        #expect(context.customLists["[BLOCKEDADCATEGORIES]"] == ["IAB7"])
        #expect(context.custom["[DOMAIN]"] == "request.example")
        #expect(context.custom["[APPBUNDLE]"] == "com.publisher")
    }

    /// `[REGULATIONS]` is `Array<string>` (`gdpr`, `coppa`, … VAST 4.1 §6.2): never a made-up default such as "gdpr:0". With
    /// nothing from the request or the user it stays unknown.
    @Test func regulationsHaveNoMadeUpDefault() {
        #expect(!MacroSettings.defaultRequestValues.contains { $0.key == "[REGULATIONS]" })
        let context = MacroSettings().context(candidate: Self.candidate, input: Fixtures.input([]), device: DeviceCatalog.defaultDevice,
                                              playerSize: .zero, transactionID: "tx")
        #expect(context.custom["[REGULATIONS]"] == nil && context.customLists["[REGULATIONS]"] == nil)
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
