import Foundation
import Testing
@testable import RTBKit

/// Companion tracking carried by wrappers (`Wrapper/Creatives/Creative/CompanionAds`): fired with the InLine companion it
/// matches, outermost wrapper first. Matching: `id`, else width × height, else the layer's only companion, else none
/// (with a warning at resolve time).
@Suite("VAST wrapper companion tracking")
struct VASTWrapperCompanionTests {
    private typealias F = VASTFixture
    private static let context = MacroContext(timestamp: Date(timeIntervalSince1970: 1_700_000_000), cacheBuster: "12345678")

    private func plan(_ event: AdLifecycleEvent, _ vast: ResolvedVAST, context: MacroContext = Self.context) -> [TrackerRequest] {
        VASTTrackingPlan.requests(for: event, vast: vast, candidate: nil, context: context, source: "bid 0.0")
    }

    /// A tracking-only wrapper companion: `creativeView` and CompanionClickTracking named after `name`.
    private static func trackingCompanion(_ name: String, attributes: String = "", view: String? = nil) -> String {
        """
        <Companion\(attributes.isEmpty ? "" : " " + attributes)>
          <TrackingEvents><Tracking event="creativeView">\(view ?? "https://tracker.example/\(name)/view")</Tracking></TrackingEvents>
          <CompanionClickTracking>https://tracker.example/\(name)/click</CompanionClickTracking>
        </Companion>
        """
    }

    private static func wrapper(_ name: String, adTagURI: String, companions: [String]) -> String {
        """
        <VAST version="3.0"><Ad id="\(name)"><Wrapper><AdSystem>w</AdSystem>
          <VASTAdTagURI><![CDATA[\(adTagURI)]]></VASTAdTagURI>
          <Impression>https://tracker.example/\(name)/impression</Impression>
          <Creatives><Creative><CompanionAds>\(companions.joined())</CompanionAds></Creative></Creatives>
        </Wrapper></Ad></VAST>
        """
    }

    /// InLine companions: 1 `c-static` 300×250 image, 2 no id 320×50 image, 3 `x` 728×90 HTML.
    private static let inline = """
    <VAST version="3.0"><Ad id="end"><InLine><AdSystem>s</AdSystem><AdTitle>end</AdTitle><Impression>https://tracker.example/end/impression</Impression>
    <Creatives>
      <Creative><Linear><Duration>00:00:15</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1280" height="720">https://cdn.example/a.mp4</MediaFile></MediaFiles>
      </Linear></Creative>
      <Creative><CompanionAds>
        <Companion id="c-static" width="300" height="250">
          <StaticResource creativeType="image/png">https://cdn.example/c.png</StaticResource>
          <TrackingEvents><Tracking event="creativeView">https://tracker.example/end/c-static/view</Tracking></TrackingEvents>
          <CompanionClickThrough>https://advertiser.example/c-static</CompanionClickThrough>
          <CompanionClickTracking>https://tracker.example/end/c-static/click</CompanionClickTracking>
        </Companion>
        <Companion width="320" height="50">
          <StaticResource creativeType="image/png">https://cdn.example/b.png</StaticResource>
          <TrackingEvents><Tracking event="creativeView">https://tracker.example/end/banner/view</Tracking></TrackingEvents>
          <CompanionClickTracking>https://tracker.example/end/banner/click</CompanionClickTracking>
        </Companion>
        <Companion id="x" width="728" height="90">
          <HTMLResource><![CDATA[<b>x</b>]]></HTMLResource>
          <TrackingEvents><Tracking event="creativeView">https://tracker.example/end/x/view</Tracking></TrackingEvents>
          <CompanionClickTracking>https://tracker.example/end/x/click</CompanionClickTracking>
        </Companion>
      </CompanionAds></Creative>
    </Creatives></InLine></Ad></VAST>
    """

    /// w1 (two companions: `c-static` by id, 320×50 by size) → w2 (one companion without id or size) → the InLine ad.
    private func chain(root: UUID? = nil) async -> (ResolvedVAST, [FakeVASTFetcher.Call]) {
        let w2 = Self.wrapper("w2", adTagURI: F.dataURL(Self.inline), companions: [Self.trackingCompanion("w2/only")])
        let w1 = Self.wrapper("w1", adTagURI: F.dataURL(w2), companions: [
            Self.trackingCompanion("w1/c-static", attributes: #"id="c-static" width="300" height="250""#),
            Self.trackingCompanion("w1/320x50", attributes: #"id="banner-w1" width="320" height="50""#),
        ])
        let fetcher = FakeVASTFetcher()
        let vast = await resolved(w1, fetcher: fetcher, parentRequestID: root)
        return (vast, await fetcher.calls)
    }

    @Test func companionViewFiresMatchingWrapperTrackingOutermostFirst() async throws {
        let root = UUID()
        let (vast, calls) = await chain(root: root)
        try #require(calls.count == 2)
        let byID = plan(.companionView(adIndex: 0, companionIndex: 0), vast)
        #expect(byID.map(\.template) == ["https://tracker.example/w1/c-static/view", "https://tracker.example/w2/only/view",
                                         "https://tracker.example/end/c-static/view"])
        #expect(byID.map(\.parentID) == [root, calls[0].requestID, calls[1].requestID])
        #expect(byID.map(\.category) == [.event, .event, .event])
        #expect(byID.map(\.source) == [
            "bid 0.0 › VAST › Wrapper Ad[1] id=\"w1\" › Companion 1 id=\"c-static\"/creativeView",
            "bid 0.0 › VAST hop 1 › Wrapper Ad[1] id=\"w2\" › Companion 1/creativeView",
            "bid 0.0 › VAST hop 2 › InLine Ad[1] 'end' › Companion 1 id=\"c-static\"/creativeView",
        ])
        // No id: matched by size in w1, by being w2's only companion.
        #expect(plan(.companionView(adIndex: 0, companionIndex: 1), vast).map(\.template) == [
            "https://tracker.example/w1/320x50/view", "https://tracker.example/w2/only/view", "https://tracker.example/end/banner/view",
        ])
        // Neither id nor size matches in w1 (two companions): nothing from w1.
        #expect(plan(.companionView(adIndex: 0, companionIndex: 2), vast).map(\.template) == [
            "https://tracker.example/w2/only/view", "https://tracker.example/end/x/view",
        ])
    }

    @Test func companionClickFiresMatchingWrapperClickTrackingThenTheNavigation() async throws {
        let root = UUID()
        let (vast, calls) = await chain(root: root)
        try #require(calls.count == 2)
        let click = plan(.companionClick(adIndex: 0, companionIndex: 0), vast)
        #expect(click.map(\.template) == ["https://tracker.example/w1/c-static/click", "https://tracker.example/w2/only/click",
                                          "https://tracker.example/end/c-static/click", "https://advertiser.example/c-static"])
        #expect(click.map(\.category) == [.click, .click, .click, .navigation])
        #expect(click.map(\.parentID) == [root, calls[0].requestID, calls[1].requestID, calls[1].requestID])
        // The HTML companion: trackers of every layer, no navigation.
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 2), vast).map(\.category) == [.click, .click])
    }

    @Test func ctvFiresWrapperCompanionTrackingWithoutNavigation() async throws {
        let (vast, _) = await chain()
        var tvContext = Self.context
        tvContext.device = DeviceProfile(id: "tv", name: "TV", family: .ctv, screenWidth: 1920, screenHeight: 1080, scale: 1, os: "tvOS",
                                         osVersion: "18", make: "Apple", model: "AppleTV", userAgent: "AppleTV", openRTBDeviceType: 3,
                                         input: .remote, supportsClickThrough: false)
        #expect(plan(.companionClick(adIndex: 0, companionIndex: 0), vast, context: tvContext).map(\.category) == [.click, .click, .click])
    }

    @Test func unmatchedCompanionsAreReportedAtResolveTime() async throws {
        let (vast, _) = await chain()
        let unmatched = vast.issues.filter { $0.code == "vast.wrapper.companion.unmatched" }
        #expect(unmatched.count == 1)
        let issue = try #require(unmatched.first)
        #expect(issue.severity == .warning)
        #expect(issue.path == "VAST/Ad[1]/Wrapper/Creatives")
        #expect(issue.message.contains("Companion 3 id=\"x\" 728×90"))
    }

    @Test func identicalURLsFireOncePerEvent() async throws {
        let inline = """
        <VAST version="3.0"><Ad><InLine><AdSystem>s</AdSystem><AdTitle>t</AdTitle><Impression>https://tracker.example/i</Impression><Creatives>
        <Creative><Linear><Duration>00:00:10</Duration><MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1" height="1">https://cdn.example/a.mp4</MediaFile></MediaFiles></Linear></Creative>
        <Creative><CompanionAds><Companion id="c" width="300" height="250"><StaticResource creativeType="image/png">https://cdn.example/c.png</StaticResource>
        <TrackingEvents><Tracking event="creativeView">https://tracker.example/shared/view</Tracking><Tracking event="creativeView">https://tracker.example/shared/view</Tracking></TrackingEvents>
        </Companion></CompanionAds></Creative></Creatives></InLine></Ad></VAST>
        """
        let wrapper = Self.wrapper("w", adTagURI: F.dataURL(inline), companions: [
            Self.trackingCompanion("w", attributes: #"id="c""#, view: "https://tracker.example/shared/view"),
        ])
        let vast = await resolved(wrapper)
        let view = plan(.companionView(adIndex: 0, companionIndex: 0), vast)
        #expect(view.map(\.template) == ["https://tracker.example/shared/view"])
        #expect(view.first?.source.hasPrefix("bid 0.0 › VAST › Wrapper Ad[1]") == true)
    }

    @Test func wrapperCompanionsNeedNoResourceAndDoNotTouchOtherEvents() async throws {
        let (vast, _) = await chain()
        #expect(!vast.issues.codes().contains("vast.companion.resource.missing"))
        #expect(!plan(.video(.creativeView, adIndex: 0), vast).contains { $0.template.contains("/view") && $0.template.contains("/w") })
    }

    @Test func handBuiltAdsFireOnlyTheirOwnCompanionTracking() {
        let companion = VASTCompanion(id: "c", trackingEvents: [VASTTracking(event: .creativeView, url: "https://tracker.example/own")])
        let inline = VASTInline(creatives: [VASTCreative(companions: [companion])])
        let vast = ResolvedVAST(ads: [ResolvedVASTAd(inline: inline)])
        #expect(plan(.companionView(adIndex: 0, companionIndex: 0), vast).map(\.template) == ["https://tracker.example/own"])
    }

    @Test func matchingRule() {
        func match(_ companion: VASTCompanion, _ candidates: [VASTCompanion]) -> [Int] {
            VASTCompanionMatch.wrapperCompanionIndices(for: companion, in: candidates)
        }
        let a = VASTCompanion(id: "a", width: 300, height: 250)
        let b = VASTCompanion(id: "b", width: 728, height: 90)
        let sized = VASTCompanion(width: 300, height: 250)
        #expect(match(VASTCompanion(id: "b", width: 300, height: 250), [a, b]) == [1])
        #expect(match(VASTCompanion(id: "z", width: 300, height: 250), [a, b]) == [0])
        #expect(match(VASTCompanion(width: 300, height: 250), [b, sized, a]) == [1, 2])
        #expect(match(VASTCompanion(id: "z", width: 1, height: 1), [b]) == [0])
        #expect(match(VASTCompanion(id: "z", width: 1, height: 1), [a, b]) == [])
        #expect(match(VASTCompanion(), [a, b]) == [])
        #expect(match(VASTCompanion(id: "a"), []) == [])
    }
}
