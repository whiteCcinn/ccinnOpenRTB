import CoreGraphics
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("VAST pod plan")
struct VASTPodPlanTests {
    @Test func itemsFollowThePodWithTheirLinearFacts() {
        let progress = [VASTTracking(event: .progress(.seconds(5)), url: "https://t.example/p5"),
                        VASTTracking(event: .start, url: "https://t.example/s"),
                        VASTTracking(event: .progress(.percent(80)), url: "https://t.example/p80")]
        let first = RendererFixtures.linearAd(duration: 15, skipOffset: .seconds(5), tracking: progress, sequence: 1)
        let second = RendererFixtures.linearAd(duration: 30, clickThrough: nil, sequence: 2)
        let items = VASTPodPlan.items(for: ResolvedVAST(ads: [first, second]), source: "bid 0.0 › VAST")
        #expect(items.map(\.adIndex) == [0, 1])
        #expect(items[0].declaredDuration == 15)
        #expect(items[0].skipOffset == .seconds(5))
        #expect(items[0].progressOffsets == [.seconds(5), .percent(80)])
        #expect(items[0].clickThrough == "https://adv.example/landing")
        #expect(items[1].clickThrough == nil)
        #expect(items[0].source == "bid 0.0 › VAST › ad 1 of 2 'Ad'")
        #expect(items[0].linear != nil)
    }

    @Test func companionsAreIndexedAcrossCreatives() {
        let a = VASTCompanion(id: "a", width: 300, height: 250, resources: [.staticResource(url: "https://c.example/a.png", creativeType: "image/png")])
        let b = VASTCompanion(id: "b", width: 728, height: 90, resources: [.html("<b>hi</b>")])
        let c = VASTCompanion(id: "c", width: 300, height: 60, resources: [.iframe(url: "https://c.example/frame")])
        let linear = VASTLinear(duration: 10, mediaFiles: [VASTMediaFile(url: "https://m.example/a.mp4", type: "video/mp4")])
        let inline = VASTInline(adTitle: "T", creatives: [VASTCreative(linear: linear, companions: [a]), VASTCreative(companions: [b, c])])
        let items = VASTPodPlan.items(for: ResolvedVAST(ads: [ResolvedVASTAd(inline: inline)]), source: "s")
        #expect(items[0].companions.map(\.companionIndex) == [0, 1, 2])
        #expect(items[0].companions.map(\.companion.id) == ["a", "b", "c"])
    }

    @Test func mediaIsParentedToTheHopThatDeliveredTheInlineAd() {
        let wrapperFetch = UUID()
        let inlineFetch = UUID()
        var ad = RendererFixtures.linearAd()
        ad.origin = [VASTAdOrigin(hop: 0, ad: 0), VASTAdOrigin(hop: 1, ad: 0)]
        let vast = ResolvedVAST(chain: [VASTHop(requestID: wrapperFetch), VASTHop(requestID: inlineFetch)], ads: [ad])
        #expect(VASTPodPlan.items(for: vast, source: "s").first?.mediaParentID == inlineFetch)
        ad.origin = [VASTAdOrigin(hop: 7, ad: 0)]
        #expect(VASTPodPlan.items(for: ResolvedVAST(chain: [], ads: [ad]), source: "s").first?.mediaParentID == nil, "out of range")
    }

    @Test func adsWithoutALinearCreativeAreMarked() {
        let inline = VASTInline(creatives: [VASTCreative(hasNonLinear: true)])
        let item = VASTPodPlan.items(for: ResolvedVAST(ads: [ResolvedVASTAd(inline: inline)]), source: "s")[0]
        #expect(item.linear == nil)
        #expect(item.isNonLinearOnly)
        #expect(item.missingLinearError == .unexpectedLinearity)
        let empty = VASTPodPlan.items(for: ResolvedVAST(ads: [ResolvedVASTAd(inline: VASTInline())]), source: "s")[0]
        #expect(empty.missingLinearError == .linearError)
    }
}

@Suite("Companions")
struct CompanionTests {
    private func companion(_ id: String, _ width: Int?, _ height: Int?, _ resources: [VASTCompanion.Resource]) -> IndexedCompanion {
        IndexedCompanion(companionIndex: Int(id.unicodeScalars.first?.value ?? 0), companion: VASTCompanion(id: id, width: width, height: height,
                                                                                                             resources: resources))
    }

    @Test func resourcesMapToWhatTheRendererCanShow() {
        #expect(CompanionPicker.resource(of: VASTCompanion(resources: [.staticResource(url: "https://c.example/a.png", creativeType: "image/png")]))
            == .image(url: "https://c.example/a.png"))
        #expect(CompanionPicker.resource(of: VASTCompanion(resources: [.staticResource(url: "https://c.example/a.JPG?x=1", creativeType: nil)]))
            == .image(url: "https://c.example/a.JPG?x=1"))
        guard case let .html(script) = CompanionPicker.resource(of: VASTCompanion(resources: [
            .staticResource(url: "https://c.example/a.js?a=1&b=\"2\"", creativeType: "application/x-javascript"),
        ])) else {
            Issue.record("script companion not wrapped")
            return
        }
        #expect(script == #"<script src="https://c.example/a.js?a=1&amp;b=&quot;2&quot;"></script>"#)
        #expect(CompanionPicker.resource(of: VASTCompanion(resources: [.iframe(url: "https://c.example/f"), .html("<i>x</i>")])) == .html("<i>x</i>"),
                "HTML is preferred over an iframe that the Simulated sandbox would block")
        #expect(CompanionPicker.resource(of: VASTCompanion(resources: [.iframe(url: "https://c.example/f")])) == .iframe(url: "https://c.example/f"))
        #expect(CompanionPicker.resource(of: VASTCompanion(resources: [.staticResource(url: "", creativeType: "image/png")])) == nil)
    }

    @Test func picksTheLargestRenderableCompanionThatFits() {
        let big = companion("a", 728, 90, [.staticResource(url: "https://c.example/728.png", creativeType: "image/png")])
        let medium = companion("b", 300, 250, [.staticResource(url: "https://c.example/300.png", creativeType: "image/png")])
        let small = companion("c", 300, 50, [.html("<b>x</b>")])
        let broken = companion("d", 300, 600, [])
        let pick = CompanionPicker.pick([big, medium, small, broken], fitting: CGSize(width: 390, height: 400))
        #expect(pick?.companion.id == "b")
        #expect(CompanionPicker.pick([big, medium, small], fitting: CGSize(width: 390, height: 60))?.companion.id == "c")
        #expect(CompanionPicker.pick([big], fitting: CGSize(width: 390, height: 400)) == nil)
        #expect(CompanionPicker.pick([big, small], fitting: nil)?.companion.id == "a", "an end card scales the largest one down")
        #expect(CompanionPicker.pick([broken], fitting: nil) == nil)
    }

    @Test func belowThePlayerOnlyWhenItFits() {
        let tall = CompanionArrangement.make(container: CGSize(width: 390, height: 844), videoAspect: 16.0 / 9,
                                             companion: CGSize(width: 300, height: 250), isCTV: false)
        #expect(tall.companionFrame != nil)
        #expect(tall.playerFrame.width == 390)
        #expect(abs(tall.playerFrame.height - 219.375) < 0.001)
        let inline = CompanionArrangement.make(container: CGSize(width: 390, height: 219), videoAspect: 16.0 / 9,
                                               companion: CGSize(width: 300, height: 250), isCTV: false)
        #expect(inline.companionFrame == nil)
        #expect(inline.playerFrame == CGRect(x: 0, y: 0, width: 390, height: 219))
        let tv = CompanionArrangement.make(container: CGSize(width: 1920, height: 1080), videoAspect: 16.0 / 9,
                                           companion: CGSize(width: 300, height: 250), isCTV: true)
        #expect(tv.companionFrame == nil, "CTV plays full screen")
        let degenerate = CompanionArrangement.make(container: CGSize(width: -1, height: CGFloat.nan), videoAspect: 0, companion: nil, isCTV: false)
        #expect(degenerate.playerFrame == .zero)
    }
}
