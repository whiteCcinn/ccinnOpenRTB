import Foundation
import Testing
@testable import RTBKit

@Suite("VAST resolver")
struct VASTResolverTests {
    private typealias F = VASTFixture

    // MARK: Inline

    @Test func inlineMarkupIsOneHopCarryingTheDeliveringRequest() async throws {
        let delivering = UUID()
        let result = await resolved(VASTSamples.inline30Skippable, parentRequestID: delivering)
        #expect(result.failure == nil)
        #expect(result.chain.count == 1)
        #expect(result.chain[0].url == nil)
        #expect(result.chain[0].requestID == delivering)
        #expect(result.chain[0].parent == nil)
        let ad = try #require(result.ads.first)
        #expect(ad.origin == [VASTAdOrigin(hop: 0, ad: 0)])
        #expect(ad.impressions == ["https://tracker.example/vast30/impression?cb=[CACHEBUSTING]"])
        #expect(ad.clickTrackings == ["https://tracker.example/vast30/click?cb=[CACHEBUSTING]"])
        #expect(ad.trackingEvents.count == 16)
        #expect(ad.sequence == nil)
    }

    // MARK: Wrapper chains

    /// Spec scenario "Wrapper chain": two fetches forming a chain, and every Impression of all three documents.
    @Test func wrapperChainMergesOutermostFirst() async throws {
        let fetcher = FakeVASTFetcher()
        let root = UUID()
        let result = await resolved(VASTSamples.wrapperChain30, fetcher: fetcher, parentRequestID: root)
        #expect(result.failure == nil)
        #expect(result.issues.codes(.error).isEmpty)
        #expect(result.chain.count == 3)

        let calls = await fetcher.calls
        #expect(calls.count == 2)
        #expect(calls[0].parentRequestID == root)
        #expect(calls[1].parentRequestID == calls[0].requestID)
        #expect(result.chain.map(\.requestID) == [root, calls[0].requestID, calls[1].requestID])
        #expect(result.chain.map(\.parent) == [nil, VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 0)])
        #expect(result.chain.dropFirst().allSatisfy { $0.url?.hasPrefix("data:application/xml;base64,") == true })

        let ad = try #require(result.ads.first)
        #expect(ad.origin == [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 0), VASTAdOrigin(hop: 2, ad: 0)])
        #expect(ad.impressions == [
            "https://tracker.example/chain/wrapper1/impression?cb=[CACHEBUSTING]",
            "https://tracker.example/chain/wrapper2/impression?cb=[CACHEBUSTING]",
            "https://tracker.example/chain/inline/impression?cb=[CACHEBUSTING]",
        ])
        #expect(ad.errors == [
            "https://tracker.example/chain/wrapper1/error?code=[ERRORCODE]",
            "https://tracker.example/chain/wrapper2/error?code=[ERRORCODE]",
            "https://tracker.example/chain/inline/error?code=[ERRORCODE]",
        ])
        #expect(ad.clickTrackings == [
            "https://tracker.example/chain/wrapper1/click", "https://tracker.example/chain/wrapper2/click", "https://tracker.example/chain/inline/click",
        ])
        #expect(ad.trackingEvents.filter { $0.event == .firstQuartile }.map(\.url) == [
            "https://tracker.example/chain/wrapper1/firstQuartile", "https://tracker.example/chain/wrapper2/firstQuartile",
            "https://tracker.example/chain/inline/firstQuartile",
        ])
        #expect(ad.inline.adTitle == "VAST 3.0 Inline (end of the wrapper chain)")
        #expect(ad.inline.playedLinear?.clickThrough == "https://advertiser.example/landing?src=chain")
    }

    @Test func viewableImpressionsAndVerificationsMergeOutermostFirst() async throws {
        let inner = F.inline(version: "4.1", extraInline: """
        <ViewableImpression><Viewable>https://tracker.example/inline/viewable</Viewable></ViewableImpression>
        <AdVerifications><Verification vendor="inline-vendor"><JavaScriptResource>https://tracker.example/inline.js</JavaScriptResource></Verification></AdVerifications>
        """)
        let outer = """
        <VAST version="4.1"><Ad><Wrapper>
          <AdSystem>w</AdSystem><VASTAdTagURI>\(F.dataURL(inner))</VASTAdTagURI><Impression>https://tracker.example/w/impression</Impression>
          <ViewableImpression><Viewable>https://tracker.example/w/viewable</Viewable><NotViewable>https://tracker.example/w/not</NotViewable></ViewableImpression>
          <AdVerifications><Verification vendor="wrapper-vendor"><JavaScriptResource>https://tracker.example/w.js</JavaScriptResource></Verification></AdVerifications>
        </Wrapper></Ad></VAST>
        """
        let ad = try #require(await resolved(outer).ads.first)
        #expect(ad.viewableImpression.viewable == ["https://tracker.example/w/viewable", "https://tracker.example/inline/viewable"])
        #expect(ad.viewableImpression.notViewable == ["https://tracker.example/w/not"])
        #expect(ad.verifications.map(\.vendor) == ["wrapper-vendor", "inline-vendor"])
    }

    @Test func fiveWrappersAreFollowed() async throws {
        let fetcher = FakeVASTFetcher()
        let result = await resolved(F.chain(depth: 5), fetcher: fetcher)
        #expect(result.failure == nil)
        #expect(await fetcher.calls.count == 5)
        #expect(result.ads.first?.impressions.count == 6)
    }

    @Test func theSixthWrapperHitsTheLimit() async throws {
        let fetcher = FakeVASTFetcher()
        let result = await resolved(F.chain(depth: 6), fetcher: fetcher)
        #expect(result.failure == .wrapperLimit)
        #expect(result.ads.isEmpty)
        #expect(await fetcher.calls.count == 5)
        #expect(result.failureErrorURLs == (1...6).map { F.url("w\($0)", "error?code=[ERRORCODE]") })
        let issue = try #require(result.issues.issue("vast.wrapper.depth"))
        #expect(issue.severity == .error)
        #expect(issue.path == "hop 5 › VAST/Ad[1]/Wrapper")
    }

    @Test func aSelfReferencingWrapperStopsAtTheLimit() async {
        let loop = "https://ads.example/loop"
        let fetcher = FakeVASTFetcher([loop: .body(F.wrapper(name: "loop", adTagURI: loop))])
        let result = await VASTResolver(fetcher: fetcher).resolve(.url(loop))
        #expect(result.failure == .wrapperLimit)
        #expect(await fetcher.calls.count == 6)
    }

    @Test func maxDepthIsConfigurable() async {
        #expect(await resolved(F.chain(depth: 2), maxDepth: 1).failure == .wrapperLimit)
        #expect(await resolved(F.chain(depth: 1), maxDepth: 0).failure == .wrapperLimit)
        #expect(await resolved(F.chain(depth: 1), maxDepth: -3).failure == .wrapperLimit)
    }

    // MARK: Wrapper errors

    @Test func fetchFailureIs301WithTheChainsErrorURLs() async throws {
        let result = await resolved(F.wrapper(name: "w", adTagURI: "https://ads.example/down"))
        #expect(result.failure == .wrapperTimeout)
        #expect(result.failureErrorURLs == [F.url("w", "error?code=[ERRORCODE]")])
        #expect(result.chain.count == 2)
        #expect(result.chain[1].error == .wrapperTimeout)
        #expect(result.chain[1].document == nil)
        #expect(result.chain[1].parent == VASTAdOrigin(hop: 0, ad: 0))
        let issue = try #require(result.issues.issue("vast.wrapper.fetch.failed"))
        #expect(issue.message.contains("timed out"))
        #expect(issue.path == "VAST/Ad[1]/Wrapper/VASTAdTagURI")
    }

    @Test func failureInADeeperWrapperFiresEveryWrapperOfTheChain() async {
        let inner = F.wrapper(name: "w2", adTagURI: "https://ads.example/down")
        let result = await resolved(F.wrapper(name: "w1", adTagURI: F.dataURL(inner)))
        #expect(result.failure == .wrapperTimeout)
        #expect(result.failureErrorURLs == [F.url("w1", "error?code=[ERRORCODE]"), F.url("w2", "error?code=[ERRORCODE]")])
    }

    @Test func emptyResponseIs303() async {
        let url = "https://ads.example/empty"
        let result = await VASTResolver(fetcher: FakeVASTFetcher([url: .body("  \n")])).resolve(.xml(F.wrapper(name: "w", adTagURI: url)))
        #expect(result.failure == .noAdsAfterWrapper)
        #expect(result.chain.last?.error == .noAdsAfterWrapper)
        #expect(result.issues.codes(.error).contains("vast.response.empty"))
    }

    @Test func noAdResponseIs303AndAddsItsRootErrors() async throws {
        let result = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL(VASTSamples.noAd)))
        #expect(result.failure == .noAdsAfterWrapper)
        #expect(result.failureErrorURLs == [F.url("w", "error?code=[ERRORCODE]"), "https://tracker.example/no-ad/error?code=[ERRORCODE]&cb=[CACHEBUSTING]"])
        #expect(result.chain[1].document?.ads.isEmpty == true)
        #expect(result.chain[1].error == .noAdsAfterWrapper)
        #expect(result.issues.issue("vast.wrapper.noAd")?.path == "hop 1 › VAST")
    }

    @Test func topLevelNoAdIs303WithRootErrors() async {
        let result = await resolved(VASTSamples.noAd)
        #expect(result.failure == .noAdsAfterWrapper)
        #expect(result.failureErrorURLs == ["https://tracker.example/no-ad/error?code=[ERRORCODE]&cb=[CACHEBUSTING]"])
        #expect(result.ads.isEmpty && result.adFailures.isEmpty)
    }

    @Test func malformedResponseIs100AndNonVASTIs101() async {
        let malformed = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL("<VAST version=\"3.0\"><Ad>")))
        #expect(malformed.failure == .xmlParsing)
        #expect(malformed.issues.issue("vast.xml.malformed")?.path == "hop 1 › VAST")
        let html = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL("<html><body>Not found</body></html>")))
        #expect(html.failure == .schemaValidation)
        #expect(html.chain[1].error == .schemaValidation)
    }

    @Test func wrapperWithoutAdTagURIIs300WithoutFetching() async {
        let fetcher = FakeVASTFetcher()
        let result = await resolved(F.wrapper(name: "w", adTagURI: nil), fetcher: fetcher)
        #expect(result.failure == .wrapperError)
        #expect(result.failureErrorURLs == [F.url("w", "error?code=[ERRORCODE]")])
        #expect(await fetcher.calls.isEmpty)
        #expect(await resolved(F.wrapper(name: "w", adTagURI: "not a url"), fetcher: fetcher).failure == .wrapperError)
    }

    @Test func malformedTopLevelMarkupIs100() async {
        let result = await resolved("<VAST")
        #expect(result.failure == .xmlParsing)
        #expect(result.chain.count == 1)
        #expect(result.chain[0].error == .xmlParsing)
        #expect(result.failureErrorURLs.isEmpty)
    }

    // MARK: Wrapper attributes

    @Test func followAdditionalWrappersFalseIgnoresWrappersInTheResponse() async throws {
        let fetcher = FakeVASTFetcher()
        let nested = F.wrapper(name: "w2", adTagURI: F.dataURL(F.inline()))
        let result = await resolved(F.wrapper(name: "w1", adTagURI: F.dataURL(nested), attributes: #"followAdditionalWrappers="false""#),
                                    fetcher: fetcher)
        #expect(result.failure == .noAdsAfterWrapper)
        #expect(await fetcher.calls.count == 1)
        #expect(result.issues.issue("vast.wrapper.notFollowed")?.path == "hop 1 › VAST/Ad[1]/Wrapper")
        #expect(result.failureErrorURLs == [F.url("w1", "error?code=[ERRORCODE]")])
    }

    @Test func followAdditionalWrappersFalseStillTakesAnInlineAd() async throws {
        let response = F.document(ads: [F.wrapperAd(id: "x", name: "w2", adTagURI: "https://ads.example/x"), F.inlineAd(id: "y", name: "y")])
        let result = await resolved(F.wrapper(name: "w1", adTagURI: F.dataURL(response), attributes: #"followAdditionalWrappers="false""#))
        #expect(result.ads.map(\.inline.adTitle) == ["y"])
    }

    @Test func allowMultipleAdsFalseTakesTheFirstStandAloneAd() async throws {
        let response = F.document(ads: [F.inlineAd(id: "p1", sequence: 1, name: "p1"), F.inlineAd(id: "s1", name: "s1"),
                                        F.inlineAd(id: "s2", name: "s2")])
        let result = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL(response)))
        #expect(result.ads.map(\.inline.adTitle) == ["s1"])
        #expect(result.ads.first?.origin == [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 1)])
        #expect(result.issues.issue("vast.wrapper.allowMultipleAds")?.severity == .info)
    }

    @Test func allowMultipleAdsFalseWithAPodResponseUsesItsFirstAd() async throws {
        let response = F.document(ads: [F.inlineAd(id: "p2", sequence: 2, name: "p2"), F.inlineAd(id: "p1", sequence: 1, name: "p1")])
        let result = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL(response)))
        #expect(result.ads.map(\.inline.adTitle) == ["p1"])
        #expect(result.issues.issue("vast.wrapper.allowMultipleAds")?.severity == .warning)
    }

    @Test func allowMultipleAdsTrueExpandsAPodWithTheWrappersTrackersInEachAd() async throws {
        let response = F.document(ads: [F.inlineAd(id: "p2", sequence: 2, name: "p2"), F.inlineAd(id: "p1", sequence: 1, name: "p1")])
        let result = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL(response), attributes: #"allowMultipleAds="true""#))
        #expect(result.ads.map(\.inline.adTitle) == ["p1", "p2"])
        #expect(result.ads.map(\.impressions) == [
            [F.url("w", "impression"), F.url("p1", "impression")],
            [F.url("w", "impression"), F.url("p2", "impression")],
        ])
        #expect(result.ads.map(\.sequence) == [1, 2])
    }

    // MARK: Pods

    @Test func podPlaysInSequenceOrderAndIgnoresTheBuffet() async throws {
        let xml = F.document(ads: [F.inlineAd(id: "b", sequence: 2, name: "two"), F.inlineAd(id: "x", name: "buffet"),
                                   F.inlineAd(id: "a", sequence: 1, name: "one"), F.inlineAd(id: "c", sequence: 3, name: "three")])
        let result = await resolved(xml)
        #expect(result.ads.map(\.inline.adTitle) == ["one", "two", "three"])
        #expect(result.ads.map(\.sequence) == [1, 2, 3])
        #expect(result.ads.map(\.origin) == [[VASTAdOrigin(hop: 0, ad: 2)], [VASTAdOrigin(hop: 0, ad: 0)], [VASTAdOrigin(hop: 0, ad: 3)]])
    }

    @Test func pod41SampleResolvesTwoAds() async throws {
        let result = await resolved(VASTSamples.pod41)
        #expect(result.ads.map(\.inline.adTitle) == ["VAST 4.1 Pod Ad 1 of 2", "VAST 4.1 Pod Ad 2 of 2"])
        #expect(result.adFailures.isEmpty)
    }

    @Test func aFailedPodSlotIsAnAdFailureAndTheRestPlays() async throws {
        let xml = F.document(ads: [F.inlineAd(id: "a", sequence: 1, name: "one"),
                                   F.wrapperAd(id: "w", sequence: 2, name: "w", adTagURI: "https://ads.example/down"),
                                   F.inlineAd(id: "c", sequence: 3, name: "three"), F.inlineAd(id: "x", name: "buffet")])
        let result = await resolved(xml)
        #expect(result.failure == nil)
        #expect(result.ads.map(\.inline.adTitle) == ["one", "three"])
        #expect(result.adFailures == [VASTAdFailure(code: .wrapperTimeout, errorURLs: [F.url("w", "error?code=[ERRORCODE]")],
                                                    origin: [VASTAdOrigin(hop: 0, ad: 1)])])
    }

    @Test func fallbackOnNoAdReplacesTheSlotWithABuffetAd() async throws {
        let xml = F.document(ads: [F.inlineAd(id: "a", sequence: 1, name: "one"),
                                   F.wrapperAd(id: "w", sequence: 2, name: "w", adTagURI: F.dataURL(VASTSamples.noAd), attributes: #"fallbackOnNoAd="true""#),
                                   F.inlineAd(id: "c", sequence: 3, name: "three"), F.inlineAd(id: "x", name: "buffet")])
        let result = await resolved(xml)
        #expect(result.ads.map(\.inline.adTitle) == ["one", "buffet", "three"])
        #expect(result.adFailures.map(\.code) == [.noAdsAfterWrapper])
        #expect(result.adFailures.first?.errorURLs == [F.url("w", "error?code=[ERRORCODE]"),
                                                       "https://tracker.example/no-ad/error?code=[ERRORCODE]&cb=[CACHEBUSTING]"])
        #expect(result.issues.codes(.info).contains("vast.pod.fallbackOnNoAd"))
    }

    @Test func fallbackOnNoAdDoesNotApplyToOtherErrors() async throws {
        let xml = F.document(ads: [F.wrapperAd(id: "w", sequence: 1, name: "w", adTagURI: "https://ads.example/down", attributes: #"fallbackOnNoAd="true""#),
                                   F.inlineAd(id: "c", sequence: 2, name: "two"), F.inlineAd(id: "x", name: "buffet")])
        let result = await resolved(xml)
        #expect(result.ads.map(\.inline.adTitle) == ["two"])
    }

    @Test func theBuffetIsUsedWhenTheWholePodFails() async throws {
        let xml = F.document(ads: [F.wrapperAd(id: "w1", sequence: 1, name: "w1", adTagURI: "https://ads.example/1"),
                                   F.wrapperAd(id: "w2", sequence: 2, name: "w2", adTagURI: "https://ads.example/2"),
                                   F.wrapperAd(id: "b1", name: "b1", adTagURI: "https://ads.example/3"), F.inlineAd(id: "b2", name: "buffet")])
        let result = await resolved(xml)
        #expect(result.failure == nil)
        #expect(result.ads.map(\.inline.adTitle) == ["buffet"])
        #expect(result.adFailures.map(\.origin) == [[VASTAdOrigin(hop: 0, ad: 0)], [VASTAdOrigin(hop: 0, ad: 1)], [VASTAdOrigin(hop: 0, ad: 2)]])
        #expect(result.issues.codes(.info).contains("vast.pod.buffetUsed"))
    }

    @Test func whenEverythingFailsTheFirstFailureIsTheFailureAndTheRestAreAdFailures() async throws {
        let xml = F.document(ads: [F.wrapperAd(id: "w1", sequence: 1, name: "w1", adTagURI: "https://ads.example/1"),
                                   F.wrapperAd(id: "w2", sequence: 2, name: "w2", adTagURI: nil)])
        let result = await resolved(xml)
        #expect(result.failure == .wrapperTimeout)
        #expect(result.failureErrorURLs == [F.url("w1", "error?code=[ERRORCODE]")])
        #expect(result.adFailures == [VASTAdFailure(code: .wrapperError, errorURLs: [F.url("w2", "error?code=[ERRORCODE]")],
                                                    origin: [VASTAdOrigin(hop: 0, ad: 1)])])
    }

    @Test func standAloneAdsAreTriedInOrder() async throws {
        let fetcher = FakeVASTFetcher()
        let xml = F.document(ads: [F.wrapperAd(id: "w", name: "w", adTagURI: "https://ads.example/down"), F.inlineAd(id: "a", name: "a"),
                                   F.wrapperAd(id: "never", name: "never", adTagURI: "https://ads.example/never")])
        let result = await resolved(xml, fetcher: fetcher)
        #expect(result.ads.map(\.inline.adTitle) == ["a"])
        #expect(result.adFailures.map(\.code) == [.wrapperTimeout])
        #expect(await fetcher.calls.map(\.url) == ["https://ads.example/down"])
    }

    @Test func nestedPodFailuresKeepTheirFullChain() async throws {
        let response = F.document(ads: [F.inlineAd(id: "p1", sequence: 1, name: "p1"),
                                        F.wrapperAd(id: "p2", sequence: 2, name: "p2", adTagURI: "https://ads.example/down")])
        let result = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL(response), attributes: #"allowMultipleAds="true""#))
        #expect(result.ads.map(\.inline.adTitle) == ["p1"])
        #expect(result.adFailures == [VASTAdFailure(code: .wrapperTimeout,
                                                    errorURLs: [F.url("w", "error?code=[ERRORCODE]"), F.url("p2", "error?code=[ERRORCODE]")],
                                                    origin: [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 1)])])
    }

    // MARK: Sources and requests

    @Test func tagURLIsFetchedWithTheParentRequest() async throws {
        let url = "https://ads.example/tag"
        let fetcher = FakeVASTFetcher([url: .body(VASTSamples.inline40)])
        let parent = UUID()
        let result = await VASTResolver(fetcher: fetcher).resolve(.url(url), parentRequestID: parent)
        let calls = await fetcher.calls
        #expect(calls.map(\.parentRequestID) == [parent])
        #expect(result.chain.map(\.url) == [url])
        #expect(result.chain.first?.requestID == calls.first?.requestID)
        #expect(result.ads.count == 1)
    }

    @Test func unreachableTagURLIs301() async {
        let result = await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.url("https://ads.example/tag"))
        #expect(result.failure == .wrapperTimeout)
        #expect(result.chain.first?.error == .wrapperTimeout)
        #expect(result.issues.codes(.error) == ["vast.tag.fetch.failed"])
    }

    @Test func issuesOfFetchedDocumentsNameTheirHop() async {
        let inner = """
        <VAST version="3.0"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Creatives><Creative><Linear><Duration>00:00:10</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1" height="1">https://cdn.example/a.mp4</MediaFile></MediaFiles>
        </Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let result = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL(inner)))
        #expect(result.issues.issue("vast.inline.impression.missing")?.path == "hop 1 › VAST/Ad[1]/InLine/Impression")
    }

    @Test func requireSecureAppliesToEveryHop() async {
        let inner = F.inline(extraInline: "<Impression>http://tracker.example/plain</Impression>")
        let resolver = VASTResolver(fetcher: FakeVASTFetcher(), requireSecure: true)
        let result = await resolver.resolve(.xml(F.wrapper(name: "w", adTagURI: F.dataURL(inner))))
        #expect(result.issues.issue("vast.url.insecure")?.severity == .warning)
        #expect(result.issues.issue("vast.url.insecure")?.path.hasPrefix("hop 1 › ") == true)
    }

    @Test func fetchBudgetCapsPodsOfWrappers() async {
        let ads = (1...10).map { (index: Int) in
            F.wrapperAd(id: "w\(index)", sequence: index, name: "w\(index)", adTagURI: F.dataURL(F.inline(name: "i\(index)")))
        }
        let fetcher = FakeVASTFetcher()
        let result = await VASTResolver(fetcher: fetcher, maxFetches: 4).resolve(.xml(F.document(ads: ads)))
        #expect(result.ads.count == 4)
        #expect(result.adFailures.count == 6)
        #expect(result.adFailures.allSatisfy { $0.code == .wrapperLimit })
        #expect(await fetcher.calls.count == 4)
    }

    @Test(.enabled(if: MacroSupport.isImplemented, "needs kit-openrtb's MacroExpander"))
    func macrosInHTTPTagURIsAreExpandedButDataURIsAreNot() async {
        let tag = "https://ads.example/tag?cb=[CACHEBUSTING]"
        let fetcher = FakeVASTFetcher(["https://ads.example/tag?cb=12345678": .body(VASTSamples.inline40)])
        let resolver = VASTResolver(fetcher: fetcher, macroContext: MacroContext(cacheBuster: "12345678"))
        let result = await resolver.resolve(.xml(F.wrapper(name: "w", adTagURI: tag)))
        #expect(result.ads.count == 1)
        let inner = F.inline().replacingOccurrences(of: "?code=[ERRORCODE]", with: "?code=[ERRORCODE]&cb=[CACHEBUSTING]")
        let dataTag = "data:application/xml," + (inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let dataResult = await resolver.resolve(.xml(F.wrapper(name: "w", adTagURI: dataTag)))
        #expect(dataResult.ads.first?.inline.errors.first?.contains("[CACHEBUSTING]") == true)
    }

    // MARK: Pods of wrappers

    @Test func podWrapperSlotsAreFetchedInPlayOrderAndLinkedToTheirSlot() async throws {
        let fetcher = FakeVASTFetcher()
        let root = UUID()
        let xml = F.document(ads: [F.wrapperAd(id: "w2", sequence: 2, name: "w2", adTagURI: F.dataURL(F.inline(name: "i2"))),
                                   F.wrapperAd(id: "w1", sequence: 1, name: "w1", adTagURI: F.dataURL(F.inline(name: "i1")))])
        let result = await resolved(xml, fetcher: fetcher, parentRequestID: root)
        #expect(result.failure == nil)
        #expect(result.ads.map(\.inline.adTitle) == ["i1", "i2"])
        #expect(result.ads.map(\.sequence) == [1, 2])
        #expect(result.chain.map(\.parent) == [nil, VASTAdOrigin(hop: 0, ad: 1), VASTAdOrigin(hop: 0, ad: 0)])
        let calls = await fetcher.calls
        #expect(calls.map(\.parentRequestID) == [root, root])
        #expect(result.chain.map(\.requestID) == [root] + calls.map(\.requestID))
        #expect(result.ads.map(\.origin) == [[VASTAdOrigin(hop: 0, ad: 1), VASTAdOrigin(hop: 1, ad: 0)],
                                             [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 2, ad: 0)]])
        #expect(result.ads.map(\.impressions) == [[F.url("w1", "impression"), F.url("i1", "impression")],
                                                  [F.url("w2", "impression"), F.url("i2", "impression")]])
    }

    @Test func aWrapperResponseWithAPodAndABuffetPlaysThePodOnly() async throws {
        let response = F.document(ads: [F.inlineAd(id: "b", name: "buffet"), F.inlineAd(id: "p1", sequence: 1, name: "p1")])
        let result = await resolved(F.wrapper(name: "w", adTagURI: F.dataURL(response), attributes: #"allowMultipleAds="true""#))
        #expect(result.ads.map(\.inline.adTitle) == ["p1"])
        #expect(result.adFailures.isEmpty)
    }

    // MARK: Versions

    /// VAST 2.0 has wrappers but no wrapper attributes, pods or root errors: a 2.0 chain resolves without version notes.
    @Test func vast20WrapperChainMergesWithoutVersionNoise() async throws {
        let wrapper = """
        <VAST version="2.0"><Ad id="w20"><Wrapper><AdSystem>w</AdSystem>
        <VASTAdTagURI><![CDATA[\(F.dataURL(VASTSamples.inline20))]]></VASTAdTagURI>
        <Error><![CDATA[https://tracker.example/w20/error]]></Error>
        <Impression><![CDATA[https://tracker.example/w20/impression]]></Impression>
        <Creatives><Creative><Linear><TrackingEvents><Tracking event="start"><![CDATA[https://tracker.example/w20/start]]></Tracking></TrackingEvents>
        <VideoClicks><ClickTracking><![CDATA[https://tracker.example/w20/click]]></ClickTracking></VideoClicks></Linear></Creative></Creatives>
        </Wrapper></Ad></VAST>
        """
        let result = await resolved(wrapper)
        #expect(result.failure == nil)
        #expect(result.issues.codes(.error).isEmpty && result.issues.codes(.warning).isEmpty, "\(result.issues)")
        #expect(!result.issues.codes().contains("vast.element.newerVersion"))
        let ad = try #require(result.ads.first)
        #expect(ad.impressions == ["https://tracker.example/w20/impression", "https://tracker.example/vast20/impression",
                                   "https://tracker.example/vast20/impression-3p"])
        #expect(ad.errors == ["https://tracker.example/w20/error", "https://tracker.example/vast20/error"])
        #expect(ad.trackingEvents.filter { $0.event == .start }.map(\.url) == ["https://tracker.example/w20/start",
                                                                              "https://tracker.example/vast20/start"])
        #expect(ad.clickTrackings == ["https://tracker.example/w20/click", "https://tracker.example/vast20/click"])
    }

    @Test(arguments: [("2.0", VASTSamples.inline20), ("3.0", VASTSamples.inline30Skippable), ("4.0", VASTSamples.inline40),
                      ("4.1", VASTSamples.pod41), ("4.2", VASTSamples.inline42Verification), ("4.0", VASTSamples.audio40)])
    func everyVersionResolvesToPlayableAds(_ version: String, _ xml: String) async throws {
        let result = await resolved(xml)
        #expect(result.chain.first?.document?.version == version)
        #expect(result.failure == nil)
        #expect(!result.ads.isEmpty)
        #expect(result.ads.allSatisfy { $0.inline.playedLinear?.duration == 15 })
        #expect(result.ads.allSatisfy { !$0.impressions.isEmpty && !$0.errors.isEmpty })
    }

    // MARK: Regression: the chain survives resolution

    /// Regression: `finish(await resolveDocument(…))` loaded `self` before the call, so every fetched hop was dropped from
    /// `chain` and the ads' origins pointed at hops that did not exist. A 3-hop chain (wrapper → wrapper → pod) must keep
    /// every hop with its URL, document, request and parent, and every ad its full origin.
    @Test func threeHopChainKeepsEveryHopRequestParentAndOrigin() async throws {
        let fetcher = FakeVASTFetcher()
        let root = UUID()
        let pod = F.document(ads: [F.inlineAd(id: "p2", sequence: 2, name: "p2"), F.inlineAd(id: "p1", sequence: 1, name: "p1")])
        let middle = F.wrapper(name: "m", adTagURI: F.dataURL(pod), attributes: #"allowMultipleAds="true""#)
        let outer = F.wrapper(name: "o", adTagURI: F.dataURL(middle), attributes: #"allowMultipleAds="true""#)
        let result = await resolved(outer, fetcher: fetcher, parentRequestID: root)

        let calls = await fetcher.calls
        try #require(calls.count == 2)
        #expect(calls.map(\.url) == [F.dataURL(middle), F.dataURL(pod)])
        #expect(calls.map(\.parentRequestID) == [root, calls[0].requestID])
        #expect(result.chain == [
            VASTHop(url: nil, document: VASTParser.parse(outer).document, requestID: root, parent: nil),
            VASTHop(url: F.dataURL(middle), document: VASTParser.parse(middle).document, requestID: calls[0].requestID,
                    parent: VASTAdOrigin(hop: 0, ad: 0)),
            VASTHop(url: F.dataURL(pod), document: VASTParser.parse(pod).document, requestID: calls[1].requestID,
                    parent: VASTAdOrigin(hop: 1, ad: 0)),
        ])
        #expect(result.failure == nil && result.adFailures.isEmpty)
        #expect(result.ads.map(\.inline.adTitle) == ["p1", "p2"])
        #expect(result.ads.map(\.origin) == [
            [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 0), VASTAdOrigin(hop: 2, ad: 1)],
            [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 0), VASTAdOrigin(hop: 2, ad: 0)],
        ])
        // Each impression's parent is the request that delivered its document.
        for adIndex in 0..<2 {
            let impressions = VASTTrackingPlan.requests(for: .video(.creativeView, adIndex: adIndex), vast: result, candidate: nil,
                                                        context: MacroContext(), source: "bid").filter { $0.category == .impression }
            #expect(impressions.map(\.parentID) == [root, calls[0].requestID, calls[1].requestID])
        }
    }

    /// The same regression through a tag URL: the tag fetch is hop 0, linked to the delivering request.
    @Test func tagURLChainKeepsEveryHop() async throws {
        let tag = "https://ads.example/tag"
        let inline = F.inline(name: "end")
        let fetcher = FakeVASTFetcher([tag: .body(F.wrapper(name: "w", adTagURI: F.dataURL(inline)))])
        let delivering = UUID()
        let result = await VASTResolver(fetcher: fetcher).resolve(.url(tag), parentRequestID: delivering)
        let calls = await fetcher.calls
        try #require(calls.count == 2)
        #expect(calls.map(\.parentRequestID) == [delivering, calls[0].requestID])
        #expect(result.chain.map(\.url) == [tag, F.dataURL(inline)])
        #expect(result.chain.map(\.requestID) == calls.map(\.requestID))
        #expect(result.chain.map(\.parent) == [nil, VASTAdOrigin(hop: 0, ad: 0)])
        #expect(result.chain.map(\.error) == [nil, nil])
        #expect(result.ads.map(\.origin) == [[VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 0)]])
    }
}
