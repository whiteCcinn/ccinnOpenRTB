import Foundation
import Testing
@testable import RTBKit

@Suite("VAST tracking plan")
struct VASTTrackingPlanTests {
    private typealias F = VASTFixture
    private static let context = MacroContext(timestamp: Date(timeIntervalSince1970: 1_700_000_000), cacheBuster: "12345678")

    private func plan(_ event: AdLifecycleEvent, _ vast: ResolvedVAST, context: MacroContext = Self.context) -> [TrackerRequest] {
        VASTTrackingPlan.requests(for: event, vast: vast, candidate: nil, context: context, source: "bid 0.0")
    }

    private func ctv() throws -> DeviceProfile {
        DeviceProfile(id: "tv", name: "TV", family: .ctv, screenWidth: 1920, screenHeight: 1080, scale: 1, os: "tvOS", osVersion: "18",
                      make: "Apple", model: "AppleTV", userAgent: "AppleTV", openRTBDeviceType: 3, input: .remote, supportsClickThrough: false)
    }

    // MARK: creativeView

    @Test func creativeViewFiresImpressionsThenCreativeViewThenVerificationNotExecuted() async throws {
        let vast = await resolved(VASTSamples.inline42Verification)
        let requests = plan(.video(.creativeView, adIndex: 0), vast)
        #expect(requests.map(\.template) == [
            "https://tracker.example/vast42/impression?cb=[CACHEBUSTING]&ts=[TIMESTAMP]",
            "https://tracker.example/vast42/creativeView",
            "https://tracker.example/vast42/verification/not-executed?reason=[REASON]",
        ])
        #expect(requests.map(\.category) == [.impression, .event, .verification])
        #expect(requests.map(\.trigger) == ["VAST impression", "VAST creativeView", "VAST verificationNotExecuted (2)"])
        #expect(requests[2].source == "bid 0.0 › VAST › InLine Ad[1] 'VAST 4.2 Inline with AdVerifications and Companions' › "
            + "AdVerifications/Verification 'tracker.example-omid'/verificationNotExecuted")
        #expect(requests.allSatisfy { $0.parentID == nil })
    }

    @Test func everyPodAdFiresItsOwnImpressionsOnItsCreativeView() async throws {
        let vast = await resolved(VASTSamples.pod41)
        for index in 0..<2 {
            let requests = plan(.video(.creativeView, adIndex: index), vast)
            #expect(requests.map(\.template) == [
                "https://tracker.example/vast41/pod/\(index + 1)/impression?cb=[CACHEBUSTING]&pod=[PODSEQUENCE]",
                "https://tracker.example/vast41/pod/\(index + 1)/creativeView",
            ])
            #expect(requests.first?.trigger == "VAST impression (ad \(index + 1) of 2)")
        }
        #expect(plan(.video(.creativeView, adIndex: 2), vast).isEmpty)
        #expect(plan(.video(.creativeView, adIndex: -1), vast).isEmpty)
    }

    @Test func renderedAndDisplayEventsProduceNoVASTRequests() async {
        let vast = await resolved(VASTSamples.inline42Verification)
        for event: AdLifecycleEvent in [.won, .rendered, .viewable(.mrc50), .viewable(.video50), .click(assetID: nil), .click(assetID: 1), .closed,
                                        .loss(reason: 102)] {
            #expect(plan(event, vast).isEmpty, "\(event)")
        }
    }

    // MARK: Wrapper chain attribution

    @Test func chainRequestsNameTheirDocumentAndHop() async throws {
        let root = UUID()
        let vast = await resolved(VASTSamples.wrapperChain30, parentRequestID: root)
        let requests = plan(.video(.creativeView, adIndex: 0), vast)
        #expect(requests.map(\.template) == [
            "https://tracker.example/chain/wrapper1/impression?cb=[CACHEBUSTING]",
            "https://tracker.example/chain/wrapper2/impression?cb=[CACHEBUSTING]",
            "https://tracker.example/chain/inline/impression?cb=[CACHEBUSTING]",
            "https://tracker.example/chain/wrapper1/creativeView",
            "https://tracker.example/chain/wrapper2/creativeView",
            "https://tracker.example/chain/inline/creativeView",
        ])
        #expect(requests.map(\.parentID) == [root, vast.chain[1].requestID, vast.chain[2].requestID,
                                             root, vast.chain[1].requestID, vast.chain[2].requestID])
        #expect(requests.map(\.source) == [
            "bid 0.0 › VAST › Wrapper Ad[1] id=\"ccinn-chain-wrapper-1\" › Impression",
            "bid 0.0 › VAST hop 1 › Wrapper Ad[1] id=\"ccinn-chain-wrapper-2\" › Impression",
            "bid 0.0 › VAST hop 2 › InLine Ad[1] 'VAST 3.0 Inline (end of the wrapper chain)' › Impression",
            "bid 0.0 › VAST › Wrapper Ad[1] id=\"ccinn-chain-wrapper-1\" › TrackingEvents/creativeView",
            "bid 0.0 › VAST hop 1 › Wrapper Ad[1] id=\"ccinn-chain-wrapper-2\" › TrackingEvents/creativeView",
            "bid 0.0 › VAST hop 2 › InLine Ad[1] 'VAST 3.0 Inline (end of the wrapper chain)' › TrackingEvents/creativeView",
        ])
        #expect(vast.chain[1].requestID != nil)
    }

    @Test func quartilesAndClicksMergeTheChain() async throws {
        let vast = await resolved(VASTSamples.wrapperChain30)
        #expect(plan(.video(.midpoint, adIndex: 0), vast).map(\.template) == [
            "https://tracker.example/chain/wrapper1/midpoint", "https://tracker.example/chain/wrapper2/midpoint",
            "https://tracker.example/chain/inline/midpoint",
        ])
        let clicks = plan(.videoClick(adIndex: 0), vast)
        #expect(clicks.map(\.template) == [
            "https://tracker.example/chain/wrapper1/click", "https://tracker.example/chain/wrapper2/click",
            "https://tracker.example/chain/inline/click", "https://advertiser.example/landing?src=chain",
        ])
        #expect(clicks.map(\.category) == [.click, .click, .click, .navigation])
        #expect(clicks.last?.parentID == vast.chain[2].requestID)
        #expect(clicks.last?.trigger == "VAST click-through")
    }

    @Test func handBuiltAdsArePlannedWithoutParents() {
        let inline = VASTInline(adTitle: "manual", impressions: ["https://tracker.example/manual/i"],
                                creatives: [VASTCreative(linear: VASTLinear(duration: 10, clickThrough: "https://advertiser.example/m"))])
        let vast = ResolvedVAST(ads: [ResolvedVASTAd(inline: inline, impressions: ["https://tracker.example/manual/i"],
                                                     trackingEvents: [VASTTracking(event: .start, url: "https://tracker.example/manual/start")],
                                                     clickTrackings: ["https://tracker.example/manual/c"])])
        let impressions = plan(.video(.creativeView, adIndex: 0), vast)
        #expect(impressions.map(\.source) == ["bid 0.0 › VAST ad 1 › Impression"])
        #expect(impressions.first?.parentID == nil)
        #expect(plan(.video(.start, adIndex: 0), vast).map(\.template) == ["https://tracker.example/manual/start"])
        #expect(plan(.videoClick(adIndex: 0), vast).map(\.category) == [.click, .navigation])
    }

    // MARK: Events

    @Test func progressFiresItsExactOffsetOnly() async throws {
        let vast = await resolved(VASTSamples.inline30Skippable)
        #expect(plan(.video(.progress(.seconds(10)), adIndex: 0), vast).map(\.template) == ["https://tracker.example/vast30/progress-10s"])
        #expect(plan(.video(.progress(.percent(25)), adIndex: 0), vast).map(\.template) == ["https://tracker.example/vast30/progress-25pct"])
        #expect(plan(.video(.progress(.seconds(3.75)), adIndex: 0), vast).isEmpty)
        #expect(plan(.video(.progress(.percent(25)), adIndex: 0), vast).first?.trigger == "VAST progress 25%")
    }

    /// Spec scenario "Skippable ad": skip fires `skip`, never `complete`.
    @Test func skipFiresSkipOnly() async throws {
        let vast = await resolved(VASTSamples.inline30Skippable)
        let requests = plan(.video(.skip, adIndex: 0), vast)
        #expect(requests.map(\.template) == ["https://tracker.example/vast30/skip"])
        #expect(requests.first?.category == .event)
        #expect(plan(.video(.start, adIndex: 0), vast).map(\.template) == ["https://tracker.example/vast30/start"])
        #expect(plan(.video(.firstQuartile, adIndex: 0), vast).map(\.template) == ["https://tracker.example/vast30/firstQuartile"])
    }

    @Test func renamedPlayerActionsFireEverySpelling() async throws {
        let vast20 = await resolved(VASTSamples.inline20)
        #expect(plan(.video(.playerExpand, adIndex: 0), vast20).map(\.template) == ["https://tracker.example/vast20/fullscreen"])
        #expect(plan(.video(.closeLinear, adIndex: 0), vast20).map(\.template) == ["https://tracker.example/vast20/close"])
        let vast40 = await resolved(VASTSamples.inline40)
        #expect(plan(.video(.fullscreen, adIndex: 0), vast40).map(\.template) == ["https://tracker.example/vast40/playerExpand"])
        #expect(plan(.video(.exitFullscreen, adIndex: 0), vast40).map(\.template) == ["https://tracker.example/vast40/playerCollapse"])
        #expect(plan(.video(.notUsed, adIndex: 0), vast40).isEmpty)
    }

    // MARK: Clicks

    @Test func ctvFiresClickTrackingWithoutNavigation() async throws {
        let vast = await resolved(VASTSamples.inline30Skippable)
        var tvContext = Self.context
        tvContext.device = try ctv()
        #expect(plan(.videoClick(adIndex: 0), vast, context: tvContext).map(\.category) == [.click])
        #expect(plan(.videoClick(adIndex: 0), vast).map(\.category) == [.click, .navigation])
        #expect(plan(.videoClick(adIndex: 0), vast).last?.template == "https://advertiser.example/landing?src=vast30")
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 0), vast, context: tvContext).map(\.category) == [.click])
    }

    // MARK: Companions

    @Test func companions() async throws {
        let vast = await resolved(VASTSamples.inline42Verification)
        #expect(plan(.companionView(adIndex: 0, companionIndex: 1), vast).map(\.template) == [
            "https://tracker.example/vast42/companion/html/creativeView",
        ])
        let click = plan(.companionClick(adIndex: 0, companionIndex: 0), vast)
        #expect(click.map(\.template) == ["https://tracker.example/vast42/companion/static/click",
                                          "https://advertiser.example/landing?src=vast42-companion-static"])
        #expect(click.map(\.category) == [.click, .navigation])
        #expect(click.first?.source.hasSuffix("Companion 1 id=\"ccinn-companion-static\"/CompanionClickTracking") == true)
        #expect(plan(.companionView(adIndex: 0, companionIndex: 2), vast).isEmpty)
        #expect(plan(.companionView(adIndex: 1, companionIndex: 0), vast).isEmpty)
    }

    // MARK: Viewability

    @Test func viewableImpressionOutcomes() async throws {
        let vast = await resolved(VASTSamples.inline42Verification)
        let expectations: [(VideoViewability, String, String)] = [
            (.viewable, "https://tracker.example/vast42/viewable", "VAST Viewable"),
            (.notViewable, "https://tracker.example/vast42/not-viewable", "VAST NotViewable"),
            (.undetermined, "https://tracker.example/vast42/view-undetermined", "VAST ViewUndetermined"),
        ]
        for (outcome, url, trigger) in expectations {
            let requests = plan(.videoViewability(outcome, adIndex: 0), vast)
            #expect(requests.map(\.template) == [url])
            #expect(requests.map(\.category) == [.viewability])
            #expect(requests.map(\.trigger) == [trigger])
        }
    }

    // MARK: Errors

    /// Spec scenario "Unsupported media": VPAID only → the Error URLs with `[ERRORCODE]` = 901.
    @Test func vpaidOnlyFiresErrorURLsWith901() async throws {
        let vast = await resolved(VASTSamples.vpaidOnly)
        let ad = try #require(vast.ads.first)
        guard case let .unsupported(code) = VASTMediaSelector.choose(ad.inline.playedLinear?.mediaFiles ?? [], playerWidth: 1280, playerHeight: 720)
        else {
            Issue.record("VPAID must not play")
            return
        }
        let requests = plan(.error(code, adIndex: 0), vast)
        #expect(requests.map(\.template) == ["https://tracker.example/vpaid/error?code=[ERRORCODE]&cb=[CACHEBUSTING]"])
        #expect(requests.map(\.category) == [.error])
        #expect(requests.map(\.trigger) == ["VAST error 901"])
    }

    @Test func chainFailureFiresEveryKnownErrorURL() async throws {
        let inner = F.wrapper(name: "w2", adTagURI: "https://ads.example/down")
        let vast = await resolved(F.wrapper(name: "w1", adTagURI: F.dataURL(inner)))
        let failure = try #require(vast.failure)
        let requests = plan(.error(failure, adIndex: nil), vast)
        #expect(requests.map(\.template) == [F.url("w1", "error?code=[ERRORCODE]"), F.url("w2", "error?code=[ERRORCODE]")])
        #expect(requests.map(\.trigger) == ["VAST error 301", "VAST error 301"])
        #expect(requests.map(\.parentID) == [nil, vast.chain[1].requestID])
        #expect(requests.map(\.source) == ["bid 0.0 › VAST › Wrapper Ad[1] id=\"wrapper\" › Error",
                                           "bid 0.0 › VAST hop 1 › Wrapper Ad[1] id=\"wrapper\" › Error"])
    }

    @Test func noAdErrorIsAttributedToTheRootError() async throws {
        let vast = await resolved(VASTSamples.noAd)
        let requests = plan(.error(.noAdsAfterWrapper, adIndex: nil), vast)
        #expect(requests.map(\.source) == ["bid 0.0 › VAST › VAST/Error"])
        #expect(requests.map(\.trigger) == ["VAST error 303"])
    }

    @Test func wholeChainErrorWithAdsFiresEveryAd() async {
        let vast = await resolved(VASTSamples.pod41)
        #expect(plan(.error(.undefinedError, adIndex: nil), vast).map(\.template) == [
            "https://tracker.example/vast41/pod/1/error?code=[ERRORCODE]", "https://tracker.example/vast41/pod/2/error?code=[ERRORCODE]",
        ])
        #expect(plan(.error(.mediaTimeout, adIndex: 1), vast).map(\.template) == ["https://tracker.example/vast41/pod/2/error?code=[ERRORCODE]"])
    }

    @Test func resolutionRequestsFireEachAdFailureOnceWithItsCode() async throws {
        let xml = F.document(ads: [F.inlineAd(id: "a", sequence: 1, name: "one"),
                                   F.wrapperAd(id: "w", sequence: 2, name: "w", adTagURI: F.dataURL(VASTSamples.noAd), attributes: #"fallbackOnNoAd="true""#),
                                   F.wrapperAd(id: "d", sequence: 3, name: "d", adTagURI: "https://ads.example/down"), F.inlineAd(id: "x", name: "buffet")])
        let vast = await resolved(xml)
        let requests = VASTTrackingPlan.resolutionRequests(vast: vast, context: Self.context, source: "bid 0.0")
        #expect(requests.map(\.template) == [F.url("w", "error?code=[ERRORCODE]"), "https://tracker.example/no-ad/error?code=[ERRORCODE]&cb=[CACHEBUSTING]",
                                             F.url("d", "error?code=[ERRORCODE]")])
        #expect(requests.map(\.trigger) == ["VAST error 303", "VAST error 303", "VAST error 301"])
        let noAdHop = try #require(vast.chain.firstIndex { $0.parent == VASTAdOrigin(hop: 0, ad: 1) })
        #expect(requests[1].source == "bid 0.0 › VAST hop \(noAdHop) › VAST/Error")
        #expect(requests[1].parentID == vast.chain[noAdHop].requestID)
        #expect(requests.allSatisfy { $0.category == .error })
        #expect(VASTTrackingPlan.resolutionRequests(vast: await resolved(VASTSamples.pod41), context: Self.context, source: "bid 0.0").isEmpty)
    }

    // MARK: Macros (enabled once kit-openrtb's MacroExpander is merged)

    @Test(.enabled(if: MacroSupport.isImplemented, "needs kit-openrtb's MacroExpander"))
    func errorCodeReasonAndCacheBusterAreExpanded() async throws {
        let vast = await resolved(VASTSamples.inline42Verification)
        let error = try #require(plan(.error(.noSupportedMedia, adIndex: 0), vast).first)
        #expect(error.url == "https://tracker.example/vast42/error?code=403&cb=12345678")
        #expect(error.replacedMacros == ["[ERRORCODE]", "[CACHEBUSTING]"])
        let verification = try #require(plan(.video(.creativeView, adIndex: 0), vast).last)
        #expect(verification.url == "https://tracker.example/vast42/verification/not-executed?reason=2")
        let impression = try #require(plan(.video(.creativeView, adIndex: 0), vast).first)
        #expect(impression.url.hasPrefix("https://tracker.example/vast42/impression?cb=12345678&ts="))
        #expect(!impression.url.contains("[TIMESTAMP]"))
    }

    @Test func templatesPassThroughTheExpanderUnchangedForPlainURLs() async throws {
        let vast = await resolved(VASTSamples.inline20)
        let requests = plan(.video(.creativeView, adIndex: 0), vast)
        #expect(requests.map(\.url) == requests.map(\.template))
        #expect(requests.allSatisfy { $0.unknownMacros.isEmpty })
    }

    // MARK: Pods and chains (more)

    @Test func podEventsUseTheirOwnAdsTrackers() async throws {
        func ad(_ number: Int) -> String {
            F.inlineAd(id: "a\(number)", sequence: number, name: "ad\(number)",
                       extraInline: "<ViewableImpression><Viewable>https://tracker.example/ad\(number)/viewable</Viewable></ViewableImpression>",
                       universalAdId: true)
        }
        let vast = await resolved(F.document(version: "4.0", ads: [ad(2), ad(1)]))
        #expect(plan(.video(.start, adIndex: 0), vast).map(\.template) == [F.url("ad1", "start")])
        #expect(plan(.videoViewability(.viewable, adIndex: 1), vast).map(\.template) == ["https://tracker.example/ad2/viewable"])
        #expect(plan(.videoViewability(.notViewable, adIndex: 1), vast).isEmpty)
        #expect(plan(.videoClick(adIndex: 1), vast).map(\.template) == [F.url("ad2", "click"), "https://advertiser.example/ad2"])
        #expect(plan(.error(.fileNotFound, adIndex: 1), vast).map(\.template) == [F.url("ad2", "error?code=[ERRORCODE]")])
        #expect(plan(.videoViewability(.viewable, adIndex: 2), vast).isEmpty)
        #expect(plan(.videoClick(adIndex: 2), vast).isEmpty)
        #expect(plan(.error(.fileNotFound, adIndex: 2), vast).isEmpty)
    }

    @Test func verificationNotExecutedFiresForEveryVerificationOfTheChain() async throws {
        let inner = F.inline(version: "4.1", extraInline: """
        <AdServingId>s</AdServingId>
        <AdVerifications><Verification vendor="inline-vendor"><JavaScriptResource apiFramework="omid">https://tracker.example/inline.js</JavaScriptResource>
        <TrackingEvents><Tracking event="verificationNotExecuted">https://tracker.example/inline/vne?r=[REASON]</Tracking></TrackingEvents></Verification></AdVerifications>
        """)
        let outer = """
        <VAST version="4.1"><Ad><Wrapper><AdSystem>w</AdSystem><VASTAdTagURI>\(F.dataURL(inner))</VASTAdTagURI>
        <Impression>https://tracker.example/w/impression</Impression>
        <AdVerifications><Verification vendor="wrapper-vendor"><JavaScriptResource apiFramework="omid">https://tracker.example/w.js</JavaScriptResource>
        <TrackingEvents><Tracking event="verificationNotExecuted">https://tracker.example/w/vne?r=[REASON]</Tracking></TrackingEvents></Verification></AdVerifications>
        </Wrapper></Ad></VAST>
        """
        let root = UUID()
        let vast = await resolved(outer, parentRequestID: root)
        let requests = plan(.video(.creativeView, adIndex: 0), vast)
        #expect(requests.map(\.category) == [.impression, .impression, .verification, .verification])
        let verifications = requests.filter { $0.category == .verification }
        #expect(verifications.map(\.template) == ["https://tracker.example/w/vne?r=[REASON]", "https://tracker.example/inline/vne?r=[REASON]"])
        #expect(verifications.map(\.parentID) == [root, vast.chain[1].requestID])
        #expect(verifications.map(\.source) == [
            "bid 0.0 › VAST › Wrapper Ad[1] › AdVerifications/Verification 'wrapper-vendor'/verificationNotExecuted",
            "bid 0.0 › VAST hop 1 › InLine Ad[1] 'inline' › AdVerifications/Verification 'inline-vendor'/verificationNotExecuted",
        ])
        // Only creativeView reports verificationNotExecuted.
        #expect(plan(.video(.start, adIndex: 0), vast).allSatisfy { $0.category != .verification })
    }

    @Test func extremeHandBuiltOffsetsAreLabelledWithoutTrapping() {
        let inline = VASTInline(creatives: [VASTCreative(linear: VASTLinear(duration: 10))])
        let events: [VASTEvent] = [.progress(.seconds(1e300)), .progress(.percent(1e300)), .progress(.seconds(-.infinity)), .progress(.percent(.nan))]
        let vast = ResolvedVAST(ads: [ResolvedVASTAd(inline: inline, trackingEvents: events.map { VASTTracking(event: $0, url: "https://tracker.example/p") })])
        // NaN never equals itself, so a NaN offset matches no report; the others fire their tracker once.
        #expect(events.map { plan(.video($0, adIndex: 0), vast).count } == [1, 1, 1, 0])
        #expect(plan(.video(events[0], adIndex: 0), vast).first?.trigger == "VAST progress 277777777:46:40")
    }

    // MARK: Macros (more; enabled once kit-openrtb's MacroExpander is merged)

    @Test(.enabled(if: MacroSupport.isImplemented, "needs kit-openrtb's MacroExpander"))
    func podSequenceIsTheSlotOfEachAd() async throws {
        let vast = await resolved(VASTSamples.pod41)
        for index in 0..<2 {
            let impression = try #require(plan(.video(.creativeView, adIndex: index), vast).first)
            #expect(impression.url == "https://tracker.example/vast41/pod/\(index + 1)/impression?cb=12345678&pod=\(index + 1)")
            #expect(impression.unknownMacros.isEmpty)
        }
        // A stand-alone ad has no pod sequence: VAST's "unknown" value.
        let single = await resolved(F.inline(extraInline: "<Impression>https://tracker.example/s?pod=[PODSEQUENCE]</Impression>"))
        #expect(plan(.video(.creativeView, adIndex: 0), single).last?.url == "https://tracker.example/s?pod=-1")
    }

    @Test(.enabled(if: MacroSupport.isImplemented, "needs kit-openrtb's MacroExpander"))
    func resolutionRequestsExpandEachFailuresOwnErrorCode() async throws {
        let xml = F.document(ads: [F.inlineAd(id: "a", sequence: 1, name: "one"),
                                   F.wrapperAd(id: "w", sequence: 2, name: "w", adTagURI: F.dataURL(VASTSamples.noAd), attributes: #"fallbackOnNoAd="true""#),
                                   F.wrapperAd(id: "d", sequence: 3, name: "d", adTagURI: "https://ads.example/down"), F.inlineAd(id: "x", name: "buffet")])
        let vast = await resolved(xml)
        let requests = VASTTrackingPlan.resolutionRequests(vast: vast, context: Self.context, source: "bid 0.0")
        #expect(requests.map(\.url) == [F.url("w", "error?code=303"), "https://tracker.example/no-ad/error?code=303&cb=12345678",
                                        F.url("d", "error?code=301")])
        #expect(requests.allSatisfy { $0.replacedMacros.contains("[ERRORCODE]") && $0.unknownMacros.isEmpty })
    }

    @Test(.enabled(if: MacroSupport.isImplemented, "needs kit-openrtb's MacroExpander"))
    func chainFailureAndMediaErrorsExpandTheirCode() async throws {
        let inner = F.wrapper(name: "w2", adTagURI: "https://ads.example/down")
        let chain = await resolved(F.wrapper(name: "w1", adTagURI: F.dataURL(inner)))
        #expect(plan(.error(.wrapperTimeout, adIndex: nil), chain).map(\.url) == [F.url("w1", "error?code=301"), F.url("w2", "error?code=301")])
        let vpaid = await resolved(VASTSamples.vpaidOnly)
        #expect(plan(.error(.vpaidError, adIndex: 0), vpaid).map(\.url) == ["https://tracker.example/vpaid/error?code=901&cb=12345678"])
        let noAd = await resolved(VASTSamples.noAd)
        #expect(plan(.error(.noAdsAfterWrapper, adIndex: nil), noAd).map(\.url) == ["https://tracker.example/no-ad/error?code=303&cb=12345678"])
    }

    @Test(.enabled(if: MacroSupport.isImplemented, "needs kit-openrtb's MacroExpander"))
    func playheadComesFromTheHostsContext() async throws {
        let vast = await resolved(VASTSamples.inline42Verification)
        var context = Self.context
        context.adPlayhead = 7.5
        let progress = try #require(plan(.video(.progress(.percent(50)), adIndex: 0), vast, context: context).first)
        #expect(progress.url == "https://tracker.example/vast42/progress-50pct?playhead=00%3A00%3A07.500")
        // The plan never sets `[ERRORCODE]` or `[REASON]` outside errors and verifications.
        #expect(progress.replacedMacros == ["[ADPLAYHEAD]"])
    }

    // MARK: Companion clicks: exactly one navigation per click (decisions "Renderer contract rulings")

    /// One inline ad with a linear creative and the given companions (`c1`, `c2`, …), each with a click-through and a
    /// click tracker.
    private static func companionVAST(_ resources: [String]) -> String {
        let companions = resources.enumerated().map { index, resource in
            """
            <Companion id="c\(index + 1)" width="300" height="250">\(resource)
              <CompanionClickThrough>https://advertiser.example/c\(index + 1)</CompanionClickThrough>
              <CompanionClickTracking>https://tracker.example/c\(index + 1)/click</CompanionClickTracking>
            </Companion>
            """
        }.joined()
        return """
        <VAST version="3.0"><Ad id="c"><InLine><AdSystem>s</AdSystem><AdTitle>companions</AdTitle><Impression>https://tracker.example/i</Impression>
        <Creatives><Creative><Linear><Duration>00:00:15</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1280" height="720">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative><Creative><CompanionAds>\(companions)</CompanionAds></Creative></Creatives></InLine></Ad></VAST>
        """
    }

    @Test func staticImageCompanionClickFiresTrackingThenNavigates() async throws {
        let vast = await resolved(Self.companionVAST([
            #"<StaticResource creativeType="image/png">https://cdn.example/c.png</StaticResource>"#,
            "<StaticResource>https://cdn.example/banner.JPG?size=300x250</StaticResource>",
            #"<HTMLResource><![CDATA[<b>x</b>]]></HTMLResource><StaticResource creativeType="image/gif">https://cdn.example/c.gif</StaticResource>"#,
        ]))
        for index in 0..<3 {
            let requests = plan(.companionClick(adIndex: 0, companionIndex: index), vast)
            #expect(requests.map(\.template) == ["https://tracker.example/c\(index + 1)/click", "https://advertiser.example/c\(index + 1)"])
            #expect(requests.map(\.category) == [.click, .navigation])
            #expect(requests.last?.trigger == "VAST companion click-through")
        }
        // The sample's static companion behaves the same.
        let sample = await resolved(VASTSamples.inline30Skippable)
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 0), sample).map(\.category) == [.click, .navigation])
    }

    @Test func htmlAndIFrameCompanionClicksFireTrackingWithoutNavigation() async throws {
        let vast = await resolved(Self.companionVAST([
            "<HTMLResource><![CDATA[<a href=\"https://advertiser.example/own\">Go</a>]]></HTMLResource>",
            "<IFrameResource>https://cdn.example/companion.html</IFrameResource>",
        ]))
        for index in 0..<2 {
            let requests = plan(.companionClick(adIndex: 0, companionIndex: index), vast)
            #expect(requests.map(\.template) == ["https://tracker.example/c\(index + 1)/click"])
            #expect(requests.map(\.category) == [.click])
        }
        // The 4.2 sample's HTML companion.
        let sample = await resolved(VASTSamples.inline42Verification)
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 1), sample).map(\.template) == [
            "https://tracker.example/vast42/companion/html/click",
        ])
    }

    @Test func scriptAndUnrecognisedStaticResourcesDoNotNavigate() async throws {
        let vast = await resolved(Self.companionVAST([
            #"<StaticResource creativeType="application/x-javascript">https://cdn.example/companion.js</StaticResource>"#,
            "<StaticResource>https://cdn.example/companion</StaticResource>",
        ]))
        for index in 0..<2 {
            #expect(plan(.companionClick(adIndex: 0, companionIndex: index), vast).map(\.category) == [.click])
        }
    }

    @Test func mixedCompanionsFollowTheDisplayPreference() async throws {
        let vast = await resolved(Self.companionVAST([
            // HTML first in the document, but an image StaticResource is preferred: navigates.
            #"<HTMLResource><![CDATA[<b>x</b>]]></HTMLResource><StaticResource creativeType="image/png">https://cdn.example/c.png</StaticResource>"#,
            // Iframe before HTML: HTML is preferred, no navigation.
            #"<IFrameResource>https://cdn.example/f.html</IFrameResource><HTMLResource><![CDATA[<b>x</b>]]></HTMLResource>"#,
            // A script StaticResource does not render; the iframe does: no navigation.
            #"<StaticResource creativeType="application/x-javascript">https://cdn.example/c.js</StaticResource><IFrameResource>https://cdn.example/f.html</IFrameResource>"#,
        ]))
        let companions = try #require(vast.ads.first).inline.creatives.flatMap(\.companions)
        #expect(companions.map(\.displayResource) == [
            .staticResource(url: "https://cdn.example/c.png", creativeType: "image/png"),
            .html("<b>x</b>"),
            .iframe(url: "https://cdn.example/f.html"),
        ])
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 0), vast).map(\.category) == [.click, .navigation])
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 1), vast).map(\.category) == [.click])
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 2), vast).map(\.category) == [.click])
    }

    @Test func ctvNeverNavigatesFromACompanion() async throws {
        var tvContext = Self.context
        tvContext.device = try ctv()
        let vast = await resolved(Self.companionVAST([
            #"<StaticResource creativeType="image/png">https://cdn.example/c.png</StaticResource>"#,
            "<HTMLResource><![CDATA[<b>x</b>]]></HTMLResource>",
            "<IFrameResource>https://cdn.example/f.html</IFrameResource>",
        ]))
        for index in 0..<3 {
            #expect(plan(.companionClick(adIndex: 0, companionIndex: index), vast, context: tvContext).map(\.template)
                == ["https://tracker.example/c\(index + 1)/click"])
        }
    }

    @Test func displayResourcePreference() {
        typealias R = VASTCompanion.Resource
        func display(_ resources: [R]) -> R? { VASTCompanion(resources: resources).displayResource }
        let png = R.staticResource(url: "https://cdn.example/a.png", creativeType: "image/png")
        let html = R.html("<b/>")
        let iframe = R.iframe(url: "https://cdn.example/f")
        let script = R.staticResource(url: "https://cdn.example/a.js", creativeType: "application/x-javascript")
        #expect(display([png]) == png)
        #expect(display([html, iframe, png]) == png)
        #expect(display([iframe, html]) == html)
        #expect(display([iframe]) == iframe)
        #expect(display([script, iframe]) == iframe)
        #expect(display([script]) == nil)
        #expect(display([]) == nil)
        // Image detection: the type wins; without one, the extension decides.
        let typed = R.staticResource(url: "https://cdn.example/a", creativeType: " IMAGE/JPEG ")
        #expect(display([typed]) == typed)
        let untyped = R.staticResource(url: "https://cdn.example/a.webp?x=1#y", creativeType: nil)
        #expect(display([untyped]) == untyped)
        #expect(display([.staticResource(url: "https://cdn.example/a.png", creativeType: "text/html")]) == nil)
        #expect(display([.staticResource(url: "https://cdn.example/a.", creativeType: nil)]) == nil)
        #expect(display([.staticResource(url: "https://cdn.example/a", creativeType: nil)]) == nil)
        // Blank resources never render.
        #expect(display([.staticResource(url: "  ", creativeType: "image/png"), .html(" \n"), .iframe(url: "")]) == nil)
        #expect(display([.html(" "), html]) == html)
    }

    // MARK: Untrusted indices

    /// Every event that names an ad, with every case of its payload.
    private static func perAdEvents(adIndex: Int, companionIndex: Int) -> [AdLifecycleEvent] {
        let videoEvents: [VASTEvent] = [
            .creativeView, .start, .firstQuartile, .midpoint, .thirdQuartile, .complete, .mute, .unmute, .pause, .resume, .rewind, .skip,
            .playerExpand, .playerCollapse, .fullscreen, .exitFullscreen, .closeLinear, .close, .acceptInvitation, .acceptInvitationLinear,
            .loaded, .notUsed, .otherAdInteraction, .interactiveStart, .timeSpentViewing, .progress(.seconds(5)), .progress(.percent(50)),
            .other("verificationNotExecuted"),
        ]
        let viewability: [VideoViewability] = [.viewable, .notViewable, .undetermined]
        return videoEvents.map { .video($0, adIndex: adIndex) }
            + [.videoClick(adIndex: adIndex)]
            + viewability.map { .videoViewability($0, adIndex: adIndex) }
            + [.companionView(adIndex: adIndex, companionIndex: companionIndex), .companionClick(adIndex: adIndex, companionIndex: companionIndex)]
            + VASTErrorCode.allCases.map { .error($0, adIndex: adIndex) }
    }

    /// Renderers send indices the plan does not control: an `adIndex` or `companionIndex` of -1, `count`, `Int.max` or
    /// `Int.min` plans nothing for every per-ad event, and never traps.
    @Test func outOfRangeIndicesPlanNothing() async throws {
        let single = await resolved(VASTSamples.inline42Verification)
        let pod = await resolved(VASTSamples.pod41)
        // The valid indices do plan requests, so the empty results below come from the indices alone.
        for event: AdLifecycleEvent in [.video(.creativeView, adIndex: 0), .videoClick(adIndex: 0), .videoViewability(.viewable, adIndex: 0),
                                        .companionView(adIndex: 0, companionIndex: 1), .companionClick(adIndex: 0, companionIndex: 1),
                                        .error(.fileNotFound, adIndex: 0)] {
            #expect(!plan(event, single).isEmpty, "\(event)")
        }

        let companionCount = try #require(single.ads.first).inline.creatives.flatMap(\.companions).count
        #expect(companionCount == 2)
        for resolution in [single, pod, ResolvedVAST()] {
            for adIndex in [-1, resolution.ads.count, Int.max, Int.min] {
                for companionIndex in [0, -1, companionCount, Int.max, Int.min] {
                    for event in Self.perAdEvents(adIndex: adIndex, companionIndex: companionIndex) {
                        #expect(plan(event, resolution).isEmpty, "\(event)")
                    }
                }
            }
        }
        for companionIndex in [-1, companionCount, Int.max, Int.min] {
            #expect(plan(.companionView(adIndex: 0, companionIndex: companionIndex), single).isEmpty)
            #expect(plan(.companionClick(adIndex: 0, companionIndex: companionIndex), single).isEmpty)
        }
        #expect(plan(.error(.undefinedError, adIndex: nil), ResolvedVAST()).isEmpty)
    }

    /// Hand-built resolutions whose origins and parents point outside the chain are planned without parents, never trap.
    @Test func inconsistentHandBuiltResolutionsAreTotal() {
        let inline = VASTInline(adTitle: "x", impressions: ["https://tracker.example/i"], errors: ["https://tracker.example/e"],
                                creatives: [VASTCreative(linear: VASTLinear(duration: 5))])
        let bogus = [VASTAdOrigin(hop: -1, ad: 0), VASTAdOrigin(hop: Int.max, ad: Int.max), VASTAdOrigin(hop: 0, ad: Int.min)]
        let chain = [VASTHop(document: VASTDocument(ads: [VASTAd(body: .inline(inline))]), requestID: UUID(),
                             parent: VASTAdOrigin(hop: Int.max, ad: -1))]
        let vast = ResolvedVAST(chain: chain,
                                ads: [ResolvedVASTAd(inline: inline, sequence: Int.max, impressions: inline.impressions, errors: inline.errors,
                                                     origin: bogus)],
                                adFailures: [VASTAdFailure(code: .wrapperTimeout, errorURLs: ["https://tracker.example/e"], origin: bogus)])
        let impressions = plan(.video(.creativeView, adIndex: 0), vast)
        #expect(impressions.map(\.template) == ["https://tracker.example/i"])
        #expect(impressions.map(\.parentID) == [nil])
        #expect(impressions.map(\.source) == ["bid 0.0 › VAST ad 1 › Impression"])
        #expect(plan(.error(.fileNotFound, adIndex: 0), vast).map(\.template) == ["https://tracker.example/e"])
        let failures = VASTTrackingPlan.resolutionRequests(vast: vast, context: Self.context, source: "bid 0.0")
        #expect(failures.map(\.template) == ["https://tracker.example/e"])
        #expect(failures.map(\.parentID) == [nil])
        #expect(VASTLabel.ordinal(Int.max) == String(Int.max))
        #expect(VASTLabel.ordinal(-1) == "0")
    }
}
