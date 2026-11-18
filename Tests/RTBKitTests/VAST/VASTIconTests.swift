import Foundation
import Testing
@testable import RTBKit

/// VAST 3.0+ industry icons (VAST 4.1 `Linear/Icons/Icon`, e.g. AdChoices): `program`, `width` / `height`, `xPosition`
/// (`left`, `right` or pixels), `yPosition` (`top`, `bottom` or pixels), `duration` and `offset` (HH:MM:SS(.mmm)), a
/// StaticResource / IFrameResource / HTMLResource, `IconClicks` (`IconClickThrough`, `IconClickTracking`) and
/// `IconViewTracking`. Icons are merged per ad (wrappers' first, like every other tracker). The player reports
/// `.iconView(adIndex:iconIndex:)` when it shows an icon (its IconViewTracking) and `.iconClick(adIndex:iconIndex:)` when
/// the viewer clicks it (IconClickTracking, then a navigation to IconClickThrough — none on CTV). `iconIndex` indexes
/// `ads[adIndex].icons`; indices outside it plan nothing.
@Suite("VAST icons")
struct VASTIconTests {
    private typealias F = VASTFixture

    static let adChoices = """
    <Icon program="AdChoices" width="20" height="20" xPosition="right" yPosition="top" duration="00:00:15" offset="00:00:01.500" apiFramework="none">
      <StaticResource creativeType="image/png"><![CDATA[https://cdn.example/adchoices.png]]></StaticResource>
      <IconClicks>
        <IconClickThrough><![CDATA[https://adchoices.example/info]]></IconClickThrough>
        <IconClickTracking><![CDATA[https://t.example/icon/click1]]></IconClickTracking>
        <IconClickTracking><![CDATA[https://t.example/icon/click2]]></IconClickTracking>
      </IconClicks>
      <IconViewTracking><![CDATA[https://t.example/icon/view]]></IconViewTracking>
    </Icon>
    """

    static let logo = """
    <Icon program="Logo" width="88" height="31" xPosition="10" yPosition="bottom">
      <HTMLResource><![CDATA[<b>logo</b>]]></HTMLResource>
      <IconViewTracking><![CDATA[https://t.example/logo/view]]></IconViewTracking>
    </Icon>
    """

    static func withIcons(_ xml: String, _ icons: String) -> String {
        xml.replacingOccurrences(of: "</TrackingEvents>", with: "</TrackingEvents><Icons>\(icons)</Icons>")
    }

    static func resolve(_ xml: String) async -> ResolvedVAST {
        await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(xml))
    }

    static func plan(_ event: AdLifecycleEvent, _ vast: ResolvedVAST, device: DeviceProfile = TrackingFixtures.phone) -> [PlannedRequest] {
        VASTTrackingPlan.requests(for: event, vast: vast, candidate: nil, context: MacroContext(device: device), source: "bid 0.0")
            .map(PlannedRequest.init)
    }

    @Test func iconsAreParsed() throws {
        let (document, issues) = try parsedDocument(Self.withIcons(F.inline(version: "4.1"), Self.adChoices + Self.logo))
        guard case let .inline(inline) = try #require(document.ads.first).body else {
            Issue.record("expected an inline ad")
            return
        }
        let icons = try #require(inline.playedLinear?.icons)
        #expect(icons == [
            VASTIcon(program: "AdChoices", width: 20, height: 20, xPosition: .right, yPosition: .top, duration: 15, offset: 1.5,
                     apiFramework: "none", resources: [.staticResource(url: "https://cdn.example/adchoices.png", creativeType: "image/png")],
                     clickThrough: "https://adchoices.example/info",
                     clickTrackings: ["https://t.example/icon/click1", "https://t.example/icon/click2"],
                     viewTrackings: ["https://t.example/icon/view"]),
            VASTIcon(program: "Logo", width: 88, height: 31, xPosition: .pixels(10), yPosition: .bottom, resources: [.html("<b>logo</b>")],
                     viewTrackings: ["https://t.example/logo/view"]),
        ])
        #expect(!issues.contains { $0.code == "vast.element.unknown" }, "\(issues.codes())")
    }

    @Test func invalidIconAttributesAreReported() throws {
        let icon = #"<Icon program="X" width="20" xPosition="middle" yPosition="-3" duration="soon"><StaticResource creativeType="image/png">https://cdn.example/x.png</StaticResource></Icon>"#
        let (document, issues) = try parsedDocument(Self.withIcons(F.inline(version: "4.1"), icon))
        guard case let .inline(inline) = try #require(document.ads.first).body else { return }
        let parsed = try #require(inline.playedLinear?.icons.first)
        #expect(parsed.xPosition == nil && parsed.yPosition == nil && parsed.duration == nil && parsed.height == nil)
        let path = "VAST/Ad[1]/InLine/Creatives/Creative[1]/Linear/Icons/Icon[1]"
        #expect(issues.contains { $0.code == "vast.icon.position.invalid" && $0.path == path + "@xPosition" })
        #expect(issues.contains { $0.code == "vast.icon.position.invalid" && $0.path == path + "@yPosition" })
        #expect(issues.contains { $0.code == "vast.icon.time.invalid" && $0.path == path + "@duration" })
        #expect(issues.contains { $0.code == "vast.icon.height.missing" && $0.path == path + "@height" })
    }

    /// Wrapper icons come first, then the inline ad's, like every merged tracker.
    @Test func iconsAreMergedPerAd() async throws {
        let inner = Self.withIcons(F.inline(name: "in"), Self.logo)
        let wrapper = Self.withIcons(F.wrapper(name: "w", adTagURI: F.dataURL(inner)), Self.adChoices)
        let vast = await Self.resolve(wrapper)
        let ad = try #require(vast.ads.first)
        #expect(ad.icons.map(\.program) == ["AdChoices", "Logo"])
    }

    @Test func iconViewFiresItsViewTracking() async throws {
        let inner = Self.withIcons(F.inline(name: "in"), Self.logo)
        let vast = await Self.resolve(Self.withIcons(F.wrapper(name: "w", adTagURI: F.dataURL(inner)), Self.adChoices))
        #expect(Self.plan(.iconView(adIndex: 0, iconIndex: 0), vast) == [
            PlannedRequest(.event, "VAST icon view", "bid 0.0 › VAST › Wrapper Ad[1] id=\"wrapper\" › Icon 1 program=\"AdChoices\"/IconViewTracking",
                           "https://t.example/icon/view"),
        ])
        #expect(Self.plan(.iconView(adIndex: 0, iconIndex: 1), vast) == [
            PlannedRequest(.event, "VAST icon view", "bid 0.0 › VAST hop 1 › InLine Ad[1] 'in' › Icon 2 program=\"Logo\"/IconViewTracking",
                           "https://t.example/logo/view", hasParent: true),
        ])
    }

    /// One trigger per action: the IconClickTracking, then the navigation to IconClickThrough (none on CTV).
    @Test func iconClickFiresClickTrackingThenTheClickThrough() async throws {
        let vast = await Self.resolve(Self.withIcons(F.inline(name: "in"), Self.adChoices))
        let element = "bid 0.0 › VAST › InLine Ad[1] 'in' › Icon 1 program=\"AdChoices\"/IconClicks/"
        #expect(Self.plan(.iconClick(adIndex: 0, iconIndex: 0), vast) == [
            PlannedRequest(.click, "VAST icon click", element + "IconClickTracking", "https://t.example/icon/click1"),
            PlannedRequest(.click, "VAST icon click", element + "IconClickTracking", "https://t.example/icon/click2"),
            PlannedRequest(.navigation, "VAST icon click", element + "IconClickThrough", "https://adchoices.example/info"),
        ])
        #expect(Self.plan(.iconClick(adIndex: 0, iconIndex: 0), vast, device: TrackingFixtures.tv).map(\.category) == [.click, .click])
    }

    @Test func indicesOutsideTheIconsPlanNothing() async throws {
        let vast = await Self.resolve(Self.withIcons(F.inline(name: "in"), Self.adChoices))
        for (adIndex, iconIndex) in [(0, 1), (0, -1), (0, Int.max), (1, 0), (-1, 0), (Int.min, Int.min)] {
            #expect(Self.plan(.iconView(adIndex: adIndex, iconIndex: iconIndex), vast).isEmpty, "\(adIndex), \(iconIndex)")
            #expect(Self.plan(.iconClick(adIndex: adIndex, iconIndex: iconIndex), vast).isEmpty, "\(adIndex), \(iconIndex)")
        }
    }

    /// `TrackingPlan` hands icon events to the VAST plan.
    @Test func trackingPlanDelegatesIconEvents() async throws {
        let vast = await Self.resolve(Self.withIcons(F.inline(name: "in"), Self.adChoices))
        let candidate = AdCandidate(id: "0.0", bidID: "v", price: 1, format: .video, markup: .vast(.xml("<VAST/>")))
        for event: AdLifecycleEvent in [.iconView(adIndex: 0, iconIndex: 0), .iconClick(adIndex: 0, iconIndex: 0)] {
            let expected = VASTTrackingPlan.requests(for: event, vast: vast, candidate: candidate, context: TrackingFixtures.context, source: "bid 0.0")
                .map(PlannedRequest.init)
            #expect(!expected.isEmpty)
            #expect(TrackingFixtures.plan(event, candidate, vast: vast) == expected, "\(event)")
        }
    }
}
