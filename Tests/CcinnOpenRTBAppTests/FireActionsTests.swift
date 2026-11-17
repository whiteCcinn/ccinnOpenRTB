import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Fire actions")
struct FireActionsTests {
    @Test func displayOffersImpressionViewabilityClickAndClose() {
        let ad = PreparedAd(candidate: Fixtures.candidate(.html("<p>")), markupEntryID: nil, markupFromWinNotice: false)
        let events = FireActions.sections(for: ad).flatMap(\.actions).map(\.event)
        #expect(events == [.rendered, .viewable(.mrc50), .viewable(.mrc100), .click(assetID: nil), .closed])
        #expect(FireActions.sections(for: nil).isEmpty)
    }

    @Test func nativeAddsVideoViewabilityAndAssetClicks() {
        let native = NativeAd(assets: [NativeAsset(id: 4, content: .video(vastTag: "<VAST/>")),
                                       NativeAsset(id: 7, content: .title(text: "t"), link: AdLink(url: "https://a.example"))])
        let ad = PreparedAd(candidate: Fixtures.candidate(.native("{}"), format: .native), native: native, markupEntryID: nil,
                            markupFromWinNotice: false)
        let events = FireActions.sections(for: ad).flatMap(\.actions).map(\.event)
        #expect(events.contains(.viewable(.video50)))
        #expect(events.contains(.click(assetID: 7)))
        #expect(!events.contains(.click(assetID: 4)))
    }

    @Test func vastPodsGetOneSectionPerAdAndNeverAnAutomaticRendered() {
        var pod = Fixtures.vast(ads: 2)
        pod.ads[1].inline.creatives = [VASTCreative(companions: [VASTCompanion(width: 300, height: 250)])]
        let ad = PreparedAd(candidate: Fixtures.candidate(.vast(.xml("<VAST/>")), format: .video), vast: pod, markupEntryID: nil,
                            markupFromWinNotice: false)
        let sections = FireActions.sections(for: ad)
        #expect(sections.map(\.title) == ["Ad 1 of 2", "Ad 2 of 2", "Whole ad"])
        #expect(sections[0].actions.first?.event == .video(.creativeView, adIndex: 0))
        #expect(sections[1].actions.map(\.event).contains(.companionClick(adIndex: 1, companionIndex: 0)))
        #expect(sections[2].actions.map(\.event) == [.rendered, .closed])
    }
}
