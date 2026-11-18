import Foundation
import Testing
@testable import RTBKit

/// What a tracker request says, without its random `id` (and with its parent reduced to "has one").
struct PlannedRequest: Equatable, CustomStringConvertible {
    var category: TrackerCategory
    var trigger: String
    var source: String
    var url: String
    var isScript: Bool = false
    var hasParent: Bool = false

    init(_ category: TrackerCategory, _ trigger: String, _ source: String, _ url: String, isScript: Bool = false, hasParent: Bool = false) {
        self.category = category
        self.trigger = trigger
        self.source = source
        self.url = url
        self.isScript = isScript
        self.hasParent = hasParent
    }

    init(_ request: TrackerRequest) {
        self.init(request.category, request.trigger, request.source, request.url, isScript: request.isScript, hasParent: request.parentID != nil)
    }

    var description: String { "\(category.rawValue) | \(trigger) | \(source) | \(url)\(isScript ? " | script" : "")\(hasParent ? " | child" : "")" }
}

enum TrackingFixtures {
    static let phone = DeviceProfile(id: "phone", name: "Phone", family: .iPhone, screenWidth: 393, screenHeight: 852, scale: 3, os: "iOS",
                                     osVersion: "18", make: "Apple", model: "iPhone", userAgent: "Phone UA", openRTBDeviceType: 4)
    static let tv = DeviceProfile(id: "tv", name: "TV", family: .ctv, screenWidth: 1920, screenHeight: 1080, scale: 1, os: "tvOS",
                                  osVersion: "18", make: "Apple", model: "Apple TV", userAgent: "TV UA", openRTBDeviceType: 3, input: .remote,
                                  supportsClickThrough: false)

    static let context = MacroContext(auctionID: "auc-1", bidID: "resp-bid", impID: "1", seatID: "dsp", adID: "ad-9", price: 1.23,
                                      currency: "USD", minimumToWin: 1.5, device: phone)

    /// OpenRTB 2.6 banner with the three auction notices.
    static let banner = AdCandidate(id: "0.0", bidID: "b1", impID: "1", seat: "dsp", price: 2.5, format: .banner, markup: .html("<div>ad</div>"),
                                    winURL: "https://t.example/win?p=${AUCTION_PRICE}&a=${AUCTION_ID}",
                                    billingURL: "https://t.example/bill?p=${AUCTION_PRICE}&b=${AUCTION_BID_ID}",
                                    lossURL: "https://t.example/loss?r=${AUCTION_LOSS}&m=${AUCTION_MIN_TO_WIN}&p=${AUCTION_PRICE}")

    static func plan(_ event: AdLifecycleEvent, _ candidate: AdCandidate, native: NativeAd? = nil, vast: ResolvedVAST? = nil,
                     context: MacroContext = context, options: TrackingPlan.Options = TrackingPlan.Options()) -> [PlannedRequest] {
        TrackingPlan.requests(for: event, candidate: candidate, native: native, vast: vast, context: context, options: options).map(PlannedRequest.init)
    }
}

@Suite("TrackingPlan – auction notices")
struct TrackingPlanAuctionTests {
    @Test func winNoticeWithTheClearingPrice() {
        #expect(TrackingFixtures.plan(.won, TrackingFixtures.banner)
            == [PlannedRequest(.win, "win", "bid 0.0 › win notice", "https://t.example/win?p=1.23&a=auc-1")])
    }

    @Test func noWinNoticeWhenTheExchangeDoesNotSendIt() {
        #expect(TrackingFixtures.plan(.won, TrackingFixtures.banner, options: TrackingPlan.Options(exchangeSendsWinNotice: false)).isEmpty)
    }

    @Test func encryptedPriceIsSubstitutedVerbatim() {
        var context = TrackingFixtures.context
        context.encryptedPrice = "AAABBBCCC_-x"
        #expect(TrackingFixtures.plan(.won, TrackingFixtures.banner, context: context).first?.url
            == "https://t.example/win?p=AAABBBCCC_-x&a=auc-1")
    }

    @Test func billingNoticeOnRender() {
        // `${AUCTION_BID_ID}` is the response-level `bidid` the context carries, not `bid.id`.
        #expect(TrackingFixtures.plan(.rendered, TrackingFixtures.banner)
            == [PlannedRequest(.billing, "billing", "bid 0.0 › burl", "https://t.example/bill?p=1.23&b=resp-bid")])
    }

    @Test func lossNoticeCarriesTheLossReason() {
        #expect(TrackingFixtures.plan(.loss(reason: 102), TrackingFixtures.banner)
            == [PlannedRequest(.loss, "loss (102)", "bid 0.0 › lurl", "https://t.example/loss?r=102&m=1.5&p=1.23")])
    }

    @Test func absentNoticesProduceNothing() {
        let bare = AdCandidate(id: "0.0", bidID: "b", price: 1, format: .banner, markup: .html("<p/>"))
        for event: AdLifecycleEvent in [.won, .rendered, .loss(reason: 2), .closed, .click(assetID: nil), .viewable(.mrc50)] {
            #expect(TrackingFixtures.plan(event, bare).isEmpty, "\(event)")
        }
    }

    @Test func unknownMacrosAreReportedAndLeftInPlace() throws {
        var candidate = TrackingFixtures.banner
        candidate.billingURL = "https://t.example/bill?ts=[TIMESTAMP]&x=${NOT_A_MACRO}"
        let request = try #require(TrackingPlan.requests(for: .rendered, candidate: candidate, native: nil, vast: nil,
                                                         context: TrackingFixtures.context).first)
        #expect(request.template == "https://t.example/bill?ts=[TIMESTAMP]&x=${NOT_A_MACRO}")
        #expect(request.url == request.template)
        #expect(request.unknownMacros == ["[TIMESTAMP]", "${NOT_A_MACRO}"])
    }

    @Test func requestsAreDeterministic() {
        let first = TrackingFixtures.plan(.rendered, TrackingFixtures.banner)
        #expect(first == TrackingFixtures.plan(.rendered, TrackingFixtures.banner))
    }
}

@Suite("TrackingPlan – AdCOM display events")
struct TrackingPlanAdcomTests {
    /// OpenRTB 3.0 banner whose events are listed out of order, with a JavaScript viewability tracker.
    static let candidate: AdCandidate = {
        var candidate = AdCandidate(id: "0.0", bidID: "yaddayadda", impID: "1", price: 1.5, format: .banner,
                                    markup: .image(ImageBanner(imageURL: "https://cdn.example/creative.jpg",
                                                               link: AdLink(url: "https://adv.example/click?tok=${CUSTOM_CLICKTOKEN}",
                                                                            clickTrackers: ["https://t.example/c?p=${OPENRTB_PRICE}"],
                                                                            fallback: "https://adv.example/fb"))),
                                    billingURL: "https://t.example/bill?p=${OPENRTB_PRICE}")
        candidate.adcomEvents = [AdcomEvent(type: 2, method: 1, url: "https://t.example/imp?id=${OPENRTB_ID}"),
                                 AdcomEvent(type: 1, method: 1, url: "https://t.example/loaded"),
                                 AdcomEvent(type: 3, method: 2, url: "https://t.example/view.js"),
                                 AdcomEvent(type: 4, method: 1, url: "https://t.example/view100"),
                                 AdcomEvent(type: 5, method: 1, url: "https://t.example/video50"),
                                 AdcomEvent(type: 2, method: 2, script: "<script>imp()</script>"),
                                 AdcomEvent(type: 501, method: 1, url: "https://t.example/vendor")]
        candidate.customMacros = ["CLICKTOKEN": "A7D800F2716DB"]
        return candidate
    }()

    @Test func renderedFiresBillingThenLoadedThenImpression() {
        #expect(TrackingFixtures.plan(.rendered, Self.candidate) == [
            PlannedRequest(.billing, "billing", "bid 0.0 › burl", "https://t.example/bill?p=1.23"),
            PlannedRequest(.event, "loaded (AdCOM 1)", "bid 0.0 › display › event[1]", "https://t.example/loaded"),
            PlannedRequest(.impression, "impression (AdCOM 2)", "bid 0.0 › display › event[0]", "https://t.example/imp?id=auc-1"),
            PlannedRequest(.impression, "impression (AdCOM 2)", "bid 0.0 › display › event[5]", "<script>imp()</script>", isScript: true),
        ])
    }

    @Test func viewabilityLevelsMapToAdcomThreeFourFive() {
        #expect(TrackingFixtures.plan(.viewable(.mrc50), Self.candidate)
            == [PlannedRequest(.viewability, "viewable MRC 50% (AdCOM 3)", "bid 0.0 › display › event[2]", "https://t.example/view.js", isScript: true)])
        #expect(TrackingFixtures.plan(.viewable(.mrc100), Self.candidate)
            == [PlannedRequest(.viewability, "viewable MRC 100% (AdCOM 4)", "bid 0.0 › display › event[3]", "https://t.example/view100")])
        #expect(TrackingFixtures.plan(.viewable(.video50), Self.candidate)
            == [PlannedRequest(.viewability, "viewable video 50% (AdCOM 5)", "bid 0.0 › display › event[4]", "https://t.example/video50")])
    }

    @Test func imageBannerClickFiresTrackersThenNavigates() {
        // `${CUSTOM_CLICKTOKEN}` is OpenRTB 3.0 `bid.macro` CLICKTOKEN, which `simulatorDefaults` puts in `custom`.
        let context = MacroContext.simulatorDefaults(candidate: Self.candidate, request: nil, device: TrackingFixtures.phone)
        #expect(TrackingFixtures.plan(.click(assetID: nil), Self.candidate, context: context) == [
            PlannedRequest(.click, "click", "bid 0.0 › display › banner › link › trkr[0]", "https://t.example/c?p=1.5"),
            PlannedRequest(.navigation, "click", "bid 0.0 › display › banner › link (fallback: https://adv.example/fb)",
                           "https://adv.example/click?tok=A7D800F2716DB"),
        ])
    }

    @Test func noNavigationOnDevicesWithoutClickThrough() {
        var context = TrackingFixtures.context
        context.device = TrackingFixtures.tv
        #expect(TrackingFixtures.plan(.click(assetID: nil), Self.candidate, context: context).map(\.category) == [.click])
    }

    /// The trackers and the navigation of one click are siblings: same trigger, none the parent of another (the click
    /// causes them all; no tracker causes the navigation).
    @Test func aClickIsOneGroupOfSiblings() throws {
        let requests = TrackingPlan.requests(for: .click(assetID: nil), candidate: Self.candidate, native: nil, vast: nil,
                                             context: TrackingFixtures.context)
        #expect(requests.map(\.category) == [.click, .navigation])
        #expect(Set(requests.map(\.trigger)) == ["click"])
        #expect(requests.allSatisfy { $0.parentID == nil })
    }

    @Test func vendorEventsAreNeverFiredByTheLifecycle() {
        let all: [AdLifecycleEvent] = [.won, .rendered, .viewable(.mrc50), .viewable(.mrc100), .viewable(.video50), .click(assetID: nil), .closed,
                                       .loss(reason: 1)]
        #expect(!all.flatMap { TrackingFixtures.plan($0, Self.candidate) }.contains { $0.url.contains("vendor") })
    }
}

@Suite("TrackingPlan – Native")
struct TrackingPlanNativeTests {
    static let candidate = AdCandidate(id: "1.2", bidID: "n", impID: "3", price: 1, format: .native, markup: .native(NativeFixtures.response12),
                                       billingURL: "https://t.example/bill")

    static var native12: NativeAd {
        NativeParser.parse(NativeFixtures.response12).ad ?? NativeAd()
    }

    @Test func renderedFiresBillingAndEventOneTrackers() {
        // Native 1.2 eventtrackers: event 1 method 1 (impression pixel); event 2 is viewability; 555 is vendor-specific.
        #expect(TrackingFixtures.plan(.rendered, Self.candidate, native: Self.native12) == [
            PlannedRequest(.billing, "billing", "bid 1.2 › burl", "https://t.example/bill"),
            PlannedRequest(.impression, "impression", "bid 1.2 › native › eventtrackers[0]", "https://t.example/imp"),
        ])
    }

    @Test func viewableMRC50FiresEventTwoAsAScript() {
        // Native spec scenario: event 2 fires when the ad has been at least 50% visible for one second.
        #expect(TrackingFixtures.plan(.viewable(.mrc50), Self.candidate, native: Self.native12)
            == [PlannedRequest(.viewability, "viewable MRC 50%", "bid 1.2 › native › eventtrackers[1]", "https://t.example/viewable.js",
                               isScript: true)])
        #expect(TrackingFixtures.plan(.viewable(.mrc100), Self.candidate, native: Self.native12).isEmpty)
    }

    @Test func eventTrackersOneToFour() {
        let native = NativeAd(assets: [NativeAsset(id: 1, content: .title(text: "T"))], link: AdLink(url: "https://l.example"),
                              eventTrackers: (1...4).map { NativeEventTracker(event: $0, method: 1, url: "https://t.example/e\($0)") })
        let events: [AdLifecycleEvent] = [.rendered, .viewable(.mrc50), .viewable(.mrc100), .viewable(.video50)]
        let urls = events.map { event in TrackingFixtures.plan(event, Self.candidate, native: native).filter { $0.source.contains("native") }.map(\.url) }
        #expect(urls == [["https://t.example/e1"], ["https://t.example/e2"], ["https://t.example/e3"], ["https://t.example/e4"]])
    }

    @Test func native10ImpTrackersAndJSTracker() throws {
        let json = #"{"native":{"ver":"1.1","assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l.example"},"imptrackers":["https://t.example/i1?p=${AUCTION_PRICE}","https://t.example/i2"],"jstracker":"<script src=\"https://t.example/j.js?p=${AUCTION_PRICE}\"></script>"}}"#
        let native = try #require(NativeParser.parse(json).ad)
        let candidate = AdCandidate(id: "0.0", bidID: "n", price: 1, format: .native, markup: .native(json))
        #expect(TrackingFixtures.plan(.rendered, candidate, native: native) == [
            PlannedRequest(.impression, "impression", "bid 0.0 › native › imptrackers[0]", "https://t.example/i1?p=1.23"),
            PlannedRequest(.impression, "impression", "bid 0.0 › native › imptrackers[1]", "https://t.example/i2"),
            PlannedRequest(.impression, "impression (jstracker)", "bid 0.0 › native › jstracker",
                           #"<script src="https://t.example/j.js?p=1.23"></script>"#, isScript: true),
        ])
    }

    @Test func clickOnAnAssetWithItsOwnLink() {
        // Asset link clicktrackers, then the ad link's, then one navigation to the asset's url.
        #expect(TrackingFixtures.plan(.click(assetID: 7), Self.candidate, native: Self.native12) == [
            PlannedRequest(.click, "click", "bid 1.2 › native › asset 7 › link › clicktrackers[0]", "https://t.example/asset-click"),
            PlannedRequest(.click, "click", "bid 1.2 › native › link › clicktrackers[0]", "https://t.example/click"),
            PlannedRequest(.navigation, "click", "bid 1.2 › native › asset 7 › link", "https://landing.example/asset"),
        ])
    }

    @Test func clickOnTheAdOrAnAssetWithoutALink() {
        let expected = [
            PlannedRequest(.click, "click", "bid 1.2 › native › link › clicktrackers[0]", "https://t.example/click"),
            PlannedRequest(.navigation, "click", "bid 1.2 › native › link", "https://landing.example/"),
        ]
        #expect(TrackingFixtures.plan(.click(assetID: nil), Self.candidate, native: Self.native12) == expected)
        #expect(TrackingFixtures.plan(.click(assetID: 1), Self.candidate, native: Self.native12) == expected)
        #expect(TrackingFixtures.plan(.click(assetID: 99), Self.candidate, native: Self.native12) == expected)
    }

    @Test func deepLinkFallbackIsNoted() throws {
        let native = try #require(NativeParser.parse(NativeFixtures.response10).ad)
        let candidate = AdCandidate(id: "0.0", bidID: "n", price: 1, format: .native, markup: .native(NativeFixtures.response10))
        let navigation = try #require(TrackingFixtures.plan(.click(assetID: nil), candidate, native: native).last)
        #expect(navigation == PlannedRequest(.navigation, "click", "bid 0.0 › native › link (fallback: http://i.am.a/URL)",
                                             "deeplink://deeplink/url/into/app"))
    }

    @Test func noNativeTrackersWithoutTheParsedAd() {
        #expect(TrackingFixtures.plan(.rendered, Self.candidate, native: nil).map(\.category) == [.billing])
    }
}

@Suite("TrackingPlan – VAST delegation")
struct TrackingPlanVASTTests {
    static let vastCandidate = AdCandidate(id: "0.0", bidID: "v", price: 4, format: .video, markup: .vast(.xml("<VAST version=\"4.0\"/>")),
                                           winURL: "https://t.example/win", billingURL: "https://t.example/bill", lossURL: "https://t.example/loss")

    static let resolved = ResolvedVAST(ads: [ResolvedVASTAd(inline: VASTInline(adTitle: "Ad", impressions: ["https://t.example/vast-imp"]),
                                                            impressions: ["https://t.example/vast-imp"],
                                                            trackingEvents: [VASTTracking(event: .start, url: "https://t.example/start"),
                                                                             VASTTracking(event: .creativeView, url: "https://t.example/cv")],
                                                            clickTrackings: ["https://t.example/vast-click"])])

    static let vastEvents: [AdLifecycleEvent] = [.video(.creativeView, adIndex: 0), .video(.start, adIndex: 0), .videoClick(adIndex: 0),
                                                 .videoViewability(.viewable, adIndex: 0), .companionView(adIndex: 0, companionIndex: 0),
                                                 .companionClick(adIndex: 0, companionIndex: 0), .error(.noSupportedMedia, adIndex: 0),
                                                 .error(.wrapperLimit, adIndex: nil)]

    @Test func vastEventsAreExactlyWhatVASTTrackingPlanSays() {
        for event in Self.vastEvents {
            let expected = VASTTrackingPlan.requests(for: event, vast: Self.resolved, candidate: Self.vastCandidate, context: TrackingFixtures.context,
                                                     source: "bid 0.0").map(PlannedRequest.init)
            #expect(TrackingFixtures.plan(event, Self.vastCandidate, vast: Self.resolved) == expected, "\(event)")
        }
    }

    @Test func renderedIsBillingOnlyForVAST() {
        // VAST impressions fire per pod ad on `.video(.creativeView, adIndex:)`, never on `.rendered`.
        #expect(TrackingFixtures.plan(.rendered, Self.vastCandidate, vast: Self.resolved)
            == [PlannedRequest(.billing, "billing", "bid 0.0 › burl", "https://t.example/bill")])
    }

    @Test func vastEventsWithoutAResolutionProduceNothing() {
        for event in Self.vastEvents {
            #expect(TrackingFixtures.plan(event, Self.vastCandidate, vast: nil).isEmpty, "\(event)")
        }
    }

    @Test func videoEventsNeverFireAuctionNotices() {
        let auction = Set(["https://t.example/win", "https://t.example/bill", "https://t.example/loss"])
        for event in Self.vastEvents {
            #expect(!TrackingFixtures.plan(event, Self.vastCandidate, vast: Self.resolved).contains { auction.contains($0.url) }, "\(event)")
        }
    }

    @Test func clickOnAVASTAdIsNotADisplayClick() {
        #expect(TrackingFixtures.plan(.click(assetID: nil), Self.vastCandidate, vast: Self.resolved).isEmpty)
    }

    @Test func nativeVideoAssetVASTIsAttributedToTheAsset() {
        let native = NativeParser.parse(NativeFixtures.response12).ad
        let candidate = TrackingPlanNativeTests.candidate
        let event = AdLifecycleEvent.video(.start, adIndex: 0)
        let expected = VASTTrackingPlan.requests(for: event, vast: Self.resolved, candidate: candidate, context: TrackingFixtures.context,
                                                 source: "bid 1.2 › native › asset 6 › video").map(PlannedRequest.init)
        #expect(TrackingFixtures.plan(event, candidate, native: native, vast: Self.resolved) == expected)
    }
}

/// decisions.md "Network relationships": a request's parent is the request that delivered the document containing its
/// URL. The bid response is pasted, so its own URLs have none: nurl/purl, burl, lurl, AdCOM `display.event` and the
/// AdCOM banner link. URLs inside markup that a request delivered (the win notice, or `display.curl`, whose entry the
/// shell passes as `markupRequestID`) are its children: Native trackers, clicktrackers and the Native navigation. A
/// tracker never parents a navigation; one click's requests are siblings sharing the trigger "click".
@Suite("TrackingPlan – parents")
struct TrackingPlanParentTests {
    static let winNoticeRequest = UUID()
    static let curlRequest = UUID()

    static let events: [AdLifecycleEvent] = [.won, .rendered, .viewable(.mrc50), .viewable(.mrc100), .viewable(.video50), .click(assetID: nil),
                                             .click(assetID: 7), .loss(reason: 102), .closed]

    static func plan(_ event: AdLifecycleEvent, _ candidate: AdCandidate, native: NativeAd?, options: TrackingPlan.Options) -> [TrackerRequest] {
        TrackingPlan.requests(for: event, candidate: candidate, native: native, vast: nil, context: TrackingFixtures.context, options: options)
    }

    /// A URL from the delivered Native document (its source runs through "native").
    static func fromNativeMarkup(_ request: TrackerRequest) -> Bool {
        request.source.contains(" › native › ") || request.source.hasSuffix(" › native")
    }

    /// OpenRTB 2.x Native without `adm`: the win notice's response is the Native JSON (shown here as the shell
    /// substitutes it). The win notice itself is that markup request, so the plan does not send it again.
    static let nativeByWinNotice = AdCandidate(id: "1.2", bidID: "n", impID: "3", price: 1, format: .native, markup: .native(NativeFixtures.response12),
                                               winURL: "https://t.example/win", billingURL: "https://t.example/bill", lossURL: "https://t.example/loss")

    /// OpenRTB 3.0 bid whose markup came from `display.curl` (Native JSON here), with purl, burl, lurl and AdCOM events in
    /// the response.
    static let displayByCurl: AdCandidate = {
        var candidate = nativeByWinNotice
        candidate.markupURL = "https://cdn.example/markup"
        candidate.winURL = "https://t.example/purl"
        candidate.adcomEvents = [AdcomEvent(type: 1, method: 1, url: "https://t.example/loaded"), AdcomEvent(type: 2, method: 1, url: "https://t.example/imp"),
                                 AdcomEvent(type: 3, method: 2, url: "https://t.example/view.js")]
        return candidate
    }()

    @Test func inlineMarkupHasNoParents() throws {
        let native11JSON = #"{"native":{"ver":"1.1","assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l.example","clicktrackers":["https://t.example/c"]},"imptrackers":["https://t.example/i"],"jstracker":"<script>j()</script>"}}"#
        let native11 = try #require(NativeParser.parse(native11JSON).ad)
        let native11Candidate = AdCandidate(id: "0.1", bidID: "n", price: 1, format: .native, markup: .native(native11JSON),
                                            winURL: "https://t.example/win", lossURL: "https://t.example/loss")
        let ads: [(AdCandidate, NativeAd?)] = [(TrackingFixtures.banner, nil), (TrackingPlanAdcomTests.candidate, nil),
                                               (TrackingPlanNativeTests.candidate, TrackingPlanNativeTests.native12), (native11Candidate, native11),
                                               (Self.displayByCurl, TrackingPlanNativeTests.native12)]
        let requests = ads.flatMap { candidate, native in Self.events.flatMap { Self.plan($0, candidate, native: native, options: TrackingPlan.Options()) } }
        #expect(Set(requests.map(\.category)) == [.win, .billing, .loss, .event, .impression, .viewability, .click, .navigation])
        #expect(requests.contains { $0.isScript && $0.source.hasSuffix("jstracker") })
        #expect(requests.allSatisfy { $0.parentID == nil })
    }

    @Test func nativeDeliveredByTheWinNoticeIsItsChild() {
        let options = TrackingPlan.Options(exchangeSendsWinNotice: false, markupRequestID: Self.winNoticeRequest)
        let native = TrackingPlanNativeTests.native12
        #expect(Self.plan(.won, Self.nativeByWinNotice, native: native, options: options).isEmpty)
        let rendered = Self.plan(.rendered, Self.nativeByWinNotice, native: native, options: options)
        #expect(rendered.map(\.category) == [.billing, .impression])
        #expect(rendered.map(\.parentID) == [nil, Self.winNoticeRequest])
        #expect(Self.plan(.viewable(.mrc50), Self.nativeByWinNotice, native: native, options: options).map(\.parentID) == [Self.winNoticeRequest])
        let click = Self.plan(.click(assetID: 7), Self.nativeByWinNotice, native: native, options: options)
        #expect(click.map(\.category) == [.click, .click, .navigation])
        #expect(click.allSatisfy { $0.parentID == Self.winNoticeRequest })
        let loss = Self.plan(.loss(reason: 102), Self.nativeByWinNotice, native: native, options: options)
        #expect(loss.map(\.category) == [.loss])
        #expect(loss.map(\.parentID) == [nil])
        for event in Self.events {
            for request in Self.plan(event, Self.nativeByWinNotice, native: native, options: options) {
                #expect(request.parentID == (Self.fromNativeMarkup(request) ? Self.winNoticeRequest : nil), "\(event): \(request.source)")
            }
        }
    }

    @Test func displayDeliveredByCurl() {
        let options = TrackingPlan.Options(exchangeSendsWinNotice: true, markupRequestID: Self.curlRequest)
        let native = TrackingPlanNativeTests.native12
        let won = Self.plan(.won, Self.displayByCurl, native: native, options: options)
        #expect(won.map(\.url) == ["https://t.example/purl"])
        #expect(won.map(\.parentID) == [nil])
        let rendered = Self.plan(.rendered, Self.displayByCurl, native: native, options: options)
        #expect(rendered.map(\.source) == ["bid 1.2 › burl", "bid 1.2 › display › event[0]", "bid 1.2 › display › event[1]",
                                            "bid 1.2 › native › eventtrackers[0]"])
        #expect(rendered.map(\.parentID) == [nil, nil, nil, Self.curlRequest])
        #expect(Self.plan(.viewable(.mrc50), Self.displayByCurl, native: native, options: options).map(\.parentID) == [nil, Self.curlRequest])
        #expect(Self.plan(.click(assetID: nil), Self.displayByCurl, native: native, options: options).allSatisfy { $0.parentID == Self.curlRequest })
        #expect(Self.plan(.loss(reason: 102), Self.displayByCurl, native: native, options: options).map(\.parentID) == [nil])
        for event in Self.events {
            for request in Self.plan(event, Self.displayByCurl, native: native, options: options) {
                #expect(request.parentID == (Self.fromNativeMarkup(request) ? Self.curlRequest : nil), "\(event): \(request.source)")
            }
        }
        // HTML from curl: the plan has no markup URLs to parent (the creative navigates itself); response URLs stay roots.
        var html = Self.displayByCurl
        html.markup = .html("<a href=https://adv.example>ad</a>")
        #expect(Self.plan(.click(assetID: nil), html, native: nil, options: options).isEmpty)
        #expect(Self.plan(.rendered, html, native: nil, options: options).allSatisfy { $0.parentID == nil })
    }

    /// The click causes its trackers and its navigation alike: no request of one click is the parent of another, and the
    /// navigation's parent is the trackers' (the markup request, or none).
    @Test(arguments: [nil, 7])
    func aNavigationIsNeverParentedToATracker(assetID: Int?) {
        let byWinNotice = TrackingPlan.Options(exchangeSendsWinNotice: false, markupRequestID: Self.winNoticeRequest)
        let clicks: [(AdCandidate, NativeAd?, TrackingPlan.Options, UUID?)] = [
            (Self.nativeByWinNotice, TrackingPlanNativeTests.native12, byWinNotice, Self.winNoticeRequest),
            (TrackingPlanNativeTests.candidate, TrackingPlanNativeTests.native12, TrackingPlan.Options(), nil),
            (TrackingPlanAdcomTests.candidate, nil, TrackingPlan.Options(markupRequestID: Self.curlRequest), nil),
        ]
        for (candidate, native, options, parent) in clicks {
            let click = Self.plan(.click(assetID: assetID), candidate, native: native, options: options)
            #expect(click.count >= 2 && click.dropLast().allSatisfy { $0.category == .click } && click.last?.category == .navigation)
            #expect(Set(click.map(\.trigger)) == ["click"])
            let ids = Set(click.map(\.id))
            #expect(!click.contains { $0.parentID.map(ids.contains) == true })
            #expect(click.allSatisfy { $0.parentID == parent })
        }
    }

    /// VAST requests are parented by `VASTTrackingPlan` to the hop that delivered their document; the plan passes them
    /// through untouched. The same bid's burl is in the response: no parent.
    @Test func vastRequestsKeepTheirHopParents() {
        let candidate = TrackingPlanVASTTests.vastCandidate
        let resolved = TrackingPlanVASTTests.resolved
        let options = TrackingPlan.Options(markupRequestID: Self.winNoticeRequest)
        for event in TrackingPlanVASTTests.vastEvents {
            let planned = TrackingPlan.requests(for: event, candidate: candidate, native: nil, vast: resolved, context: TrackingFixtures.context,
                                                options: options)
            let vast = VASTTrackingPlan.requests(for: event, vast: resolved, candidate: candidate, context: TrackingFixtures.context, source: "bid 0.0")
            #expect(planned.map(\.parentID) == vast.map(\.parentID), "\(event)")
        }
        let billing = TrackingPlan.requests(for: .rendered, candidate: candidate, native: nil, vast: resolved, context: TrackingFixtures.context,
                                            options: options)
        #expect(billing.map(\.category) == [.billing])
        #expect(billing.map(\.parentID) == [nil])
    }
}
