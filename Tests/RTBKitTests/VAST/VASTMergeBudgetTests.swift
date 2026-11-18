import Foundation
import Testing
@testable import RTBKit

/// Wrapper trackers are merged into every ad below the wrapper (VAST 4.1 §2.3.4 / design D6), so a wrapper whose response
/// is a large pod used to copy all of its trackers into each pod ad: quadratic memory (552 KiB of input → 8M trackers,
/// +119 MB). Each wrapper's trackers are now stored once and shared by the ads below it, and the resolution stops at a
/// total of `VASTResolver.maxMergedTrackers` merged tracker entries (default 50,000) with an error issue instead of
/// growing.
@Suite("VAST wrapper merge: shared layers and the tracker budget")
struct VASTMergeBudgetTests {
    private typealias F = VASTFixture

    static func wrapper(impressions: Int, errors: Int = 0, adTagURI: String) -> String {
        let impressionXML = (0..<impressions).map { "<Impression>https://t.example/w/i\($0)</Impression>" }.joined()
        let errorXML = (0..<errors).map { "<Error>https://t.example/w/e\($0)</Error>" }.joined()
        return """
        <VAST version="3.0"><Ad id="w"><Wrapper allowMultipleAds="true"><AdSystem>S</AdSystem>
        <VASTAdTagURI><![CDATA[\(adTagURI)]]></VASTAdTagURI>\(impressionXML)\(errorXML)</Wrapper></Ad></VAST>
        """
    }

    static func pod(_ count: Int) -> String {
        F.document(ads: (0..<count).map { F.inlineAd(id: "p\($0)", sequence: $0 + 1, name: "p\($0)") })
    }

    /// The reviewer's case: a wrapper with 10,000 Impressions whose response is an 800-ad pod. The resolution ends in
    /// time, within the budget, with the issue, and the ads it kept carry every merged tracker.
    @Test(.timeLimit(.minutes(1)))
    func aWrapperFanningOutIntoAHugePodStopsAtTheBudget() async throws {
        let fetcher = FakeVASTFetcher(["https://vast.example/pod": .body(Self.pod(800))])
        let clock = ContinuousClock()
        let started = clock.now
        let vast = await VASTResolver(fetcher: fetcher).resolve(.xml(Self.wrapper(impressions: 10_000, adTagURI: "https://vast.example/pod")))
        let elapsed = clock.now - started
        // The quadratic merge this replaced took minutes (≈6 GB at 3 MB of input); the bound leaves room for a 3-core CI runner.
        #expect(elapsed < .seconds(30), "\(elapsed)")
        let issue = try #require(vast.issues.first { $0.code == "vast.trackers.budget" })
        #expect(issue.severity == .error)
        #expect(issue.message.contains("50000") || issue.message.contains("50,000"))
        #expect(!vast.ads.isEmpty && vast.ads.count < 800)
        let merged = vast.ads.reduce(0) { $0 + $1.impressions.count + $1.errors.count + $1.trackingEvents.count + $1.clickTrackings.count }
        #expect(merged <= VASTResolver.defaultMaxMergedTrackers)
        #expect(vast.ads.first?.impressions.count == 10_001)
        #expect(vast.ads.first?.impressions.first == "https://t.example/w/i0")
        #expect(vast.ads.first?.impressions.last == "https://tracker.example/p0/impression")
        // Stopping fetches nothing more and fires no Error URL for the ads it dropped.
        #expect(await fetcher.calls.count == 1)
        #expect(vast.adFailures.allSatisfy { !$0.errorURLs.isEmpty })
    }

    /// Failed pod slots carry the Error URLs of the wrappers above them: they count against the budget too.
    @Test func failuresCountAgainstTheBudget() async throws {
        let failingPod = F.document(ads: (0..<50).map { F.wrapperAd(id: "f\($0)", sequence: $0 + 1, name: "f\($0)", adTagURI: "https://down.example/\($0)") })
        let fetcher = FakeVASTFetcher(["https://vast.example/pod": .body(failingPod)])
        let resolver = VASTResolver(fetcher: fetcher, maxMergedTrackers: 5_000)
        let vast = await resolver.resolve(.xml(Self.wrapper(impressions: 0, errors: 1_000, adTagURI: "https://vast.example/pod")))
        #expect(vast.issues.contains { $0.code == "vast.trackers.budget" })
        let materialised = vast.adFailures.reduce(vast.failureErrorURLs.count) { $0 + $1.errorURLs.count }
        #expect(materialised <= 5_000)
        #expect(await fetcher.calls.count < 50)
    }

    /// Within the budget nothing changes: the public accessors return wrapper trackers first, then the inline ad's, and
    /// a resolved ad equals the same ad built by hand.
    @Test func sharedLayersKeepThePublicAccessors() async throws {
        let inner = F.inline(name: "in")
        let vast = await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(F.wrapper(name: "w", adTagURI: F.dataURL(inner))))
        let ad = try #require(vast.ads.first)
        #expect(ad.impressions == [F.url("w", "impression"), F.url("in", "impression")])
        #expect(ad.errors == [F.url("w", "error?code=[ERRORCODE]"), F.url("in", "error?code=[ERRORCODE]")])
        #expect(!vast.issues.contains { $0.code == "vast.trackers.budget" })

        let byHand = ResolvedVASTAd(inline: ad.inline, sequence: ad.sequence, impressions: ad.impressions, errors: ad.errors,
                                    trackingEvents: ad.trackingEvents, clickTrackings: ad.clickTrackings,
                                    viewableImpression: ad.viewableImpression, verifications: ad.verifications, origin: ad.origin)
        #expect(byHand == ad)
        #expect(byHand.hashValue == ad.hashValue)

        var edited = ad
        edited.impressions = ["https://t.example/only"]
        #expect(edited.impressions == ["https://t.example/only"])
        #expect(edited.errors == ad.errors && edited.trackingEvents == ad.trackingEvents)
        #expect(edited != ad)
        #expect(ad.impressions.count == 2, "the original is a value: unchanged")
    }
}
