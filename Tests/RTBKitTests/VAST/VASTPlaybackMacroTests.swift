import Foundation
import Testing
@testable import RTBKit

/// VAST 4.1 §6.2 playback macros on tracking pixels: `[ASSETURI]`, `[BREAKPOSITION]` and `[ADCOUNT]`.
@Suite("VAST playback macros")
struct VASTPlaybackMacroTests {
    private typealias F = VASTFixture

    static func tracked(_ name: String) -> String {
        "<Tracking event=\"start\"><![CDATA[https://t.example/\(name)/m?a=[ASSETURI]&n=[ADCOUNT]&b=[BREAKPOSITION]]]></Tracking>"
    }

    static func inlineAd(_ name: String, sequence: Int?) -> String {
        F.inlineAd(id: name, sequence: sequence, name: name).replacingOccurrences(of: "<TrackingEvents>",
                                                                                  with: "<TrackingEvents>" + tracked(name))
    }

    static func resolve(_ xml: String) async -> ResolvedVAST {
        await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(xml))
    }

    static func startURL(_ vast: ResolvedVAST, adIndex: Int, context: MacroContext) -> String? {
        VASTTrackingPlan.requests(for: .video(.start, adIndex: adIndex), vast: vast, candidate: nil, context: context, source: "bid 0.0")
            .first { $0.template.contains("/m?") }?.url
    }

    /// §6.2 `[ASSETURI]`: "The URI of the ad asset currently being played" — the media file the player chose, which the
    /// host puts in the context; the plan never replaces it with -1.
    @Test func assetURIIsTheSelectedMediaFile() async throws {
        let vast = await Self.resolve(F.document(ads: [Self.inlineAd("a", sequence: nil)]))
        let context = MacroContext(assetURI: "https://cdn.example/a.mp4?x=1", breakPosition: .standalone)
        let url = try #require(Self.startURL(vast, adIndex: 0, context: context))
        #expect(url == "https://t.example/a/m?a=https%3A%2F%2Fcdn.example%2Fa.mp4%3Fx%3D1&n=1&b=4")
    }

    /// §6.2 `[ADCOUNT]`: "the number of ads expected to play" in the break: every ad of the resolved pod (or the one buffet
    /// ad that plays), on every pixel of each ad.
    @Test func adCountIsTheNumberOfAdsThatWillPlay() async throws {
        let pod = await Self.resolve(F.document(ads: [Self.inlineAd("p1", sequence: 1), Self.inlineAd("p2", sequence: 2),
                                                      Self.inlineAd("buffet", sequence: nil)]))
        #expect(pod.ads.count == 2)
        for index in 0..<2 {
            let url = try #require(Self.startURL(pod, adIndex: index, context: MacroContext()))
            #expect(url.contains("&n=2&"), "\(url)")
        }
        let single = await Self.resolve(F.document(ads: [Self.inlineAd("a", sequence: nil), Self.inlineAd("b", sequence: nil)]))
        #expect(try #require(Self.startURL(single, adIndex: 0, context: MacroContext())).contains("&n=1&"))
        // The plan's count wins over a stale host value.
        #expect(try #require(Self.startURL(pod, adIndex: 0, context: MacroContext(adCount: 7))).contains("&n=2&"))
    }

    /// No ad will play after a chain-wide failure: its Error URLs say 0.
    @Test func adCountIsZeroWhenNothingPlays() {
        let vast = ResolvedVAST(failure: .noAdsAfterWrapper, failureErrorURLs: ["https://t.example/e?n=[ADCOUNT]"])
        let requests = VASTTrackingPlan.requests(for: .error(.noAdsAfterWrapper, adIndex: nil), vast: vast, candidate: nil,
                                                 context: MacroContext(), source: "bid 0.0")
        #expect(requests.map(\.url) == ["https://t.example/e?n=0"])
    }

    /// §6.2 `[BREAKPOSITION]`: 1 pre-roll, 2 mid-roll, 3 post-roll, 4 standalone. The simulator's CTV player runs an
    /// instream break before (absent) content: a pre-roll. Phone, foldable and tablet placements show the ad on its own:
    /// standalone. The host may name the position, and a user's `custom` value overrides the default.
    @Test func breakPositionComesFromThePlacement() {
        let candidate = AdCandidate(id: "0.0", bidID: "b", price: 1, format: .video, markup: .vast(.xml("<VAST/>")))
        func value(_ context: MacroContext) -> String { MacroExpander.expandVAST("[BREAKPOSITION]", context: context).url }
        #expect(value(.simulatorDefaults(candidate: candidate, request: nil, device: TrackingFixtures.tv)) == "1")
        #expect(value(.simulatorDefaults(candidate: candidate, request: nil, device: TrackingFixtures.phone)) == "4")
        #expect(value(.simulatorDefaults(candidate: candidate, request: nil, device: TrackingFixtures.phone, breakPosition: .midroll)) == "2")
        var overridden = MacroContext.simulatorDefaults(candidate: candidate, request: nil, device: TrackingFixtures.tv)
        overridden.custom["[BREAKPOSITION]"] = "3"
        #expect(value(overridden) == "3")
        #expect(value(MacroContext(breakPosition: .postroll)) == "3")
    }
}
