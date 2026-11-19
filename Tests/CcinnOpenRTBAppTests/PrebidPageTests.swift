import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Prebid: setup and page")
struct PrebidPageTests {
    private let catalog = ["appnexus": PrebidBidder(code: "appnexus", aliasOf: nil, gvlid: 32, module: "appnexusBidAdapter"),
                           "rubicon": PrebidBidder(code: "rubicon", aliasOf: nil, gvlid: 52, module: "rubiconBidAdapter"),
                           "appnexusAst": PrebidBidder(code: "appnexusAst", aliasOf: "appnexus", gvlid: 32, module: "appnexusBidAdapter")]

    private func setup() -> PrebidSetup {
        var setup = PrebidSetup(version: "11.51.0")
        setup.adUnits = [PrebidAdUnit(code: "div-banner", mediaType: .banner, sizes: [AdSize(width: 300, height: 250), AdSize(width: 320, height: 50)],
                                      bids: [PrebidBidderParams(bidder: "appnexus", params: #"{"placementId": 13144370}"#),
                                             PrebidBidderParams(bidder: "appnexusAst", params: #"{"placementId": 1}"#)]),
                         PrebidAdUnit(code: "div-video", mediaType: .video, sizes: [AdSize(width: 640, height: 480)],
                                      bids: [PrebidBidderParams(bidder: "rubicon", params: #"{"accountId": 1, "siteId": 2, "zoneId": 3, "note": "</script><b>"}"#)])]
        return setup
    }

    @Test func modulesAreTheBiddersAdaptersOnce() throws {
        #expect(try setup().modules(catalog: catalog) == ["appnexusBidAdapter", "rubiconBidAdapter"])
        var consented = setup()
        consented.consent.gdprApplies = true
        consented.consent.tcString = "CPtc"
        #expect(try consented.modules(catalog: catalog) == ["appnexusBidAdapter", "consentManagementTcf", "rubiconBidAdapter"])
    }

    @Test func problemsAreFoundBeforeTheAuction() {
        var broken = setup()
        broken.adUnits[0].code = " "
        broken.adUnits[0].bids[0].params = "[1]"
        broken.adUnits[1].bids.append(PrebidBidderParams(bidder: "nosuchbidder", params: "{}"))
        broken.adUnits[1].sizes = []
        let problems = broken.problems(catalog: catalog)
        #expect(problems.contains(.missingCode(index: 0)))
        #expect(problems.contains(.paramsNotAnObject(adUnit: " ", bidder: "appnexus")))
        #expect(problems.contains(.unknownBidder("nosuchbidder")))
        #expect(problems.contains(.noSizes(adUnit: "div-video")))
        #expect(problems.allSatisfy { !$0.message.isEmpty })
        #expect(throws: PrebidSetup.Invalid.self) { try broken.modules(catalog: catalog) }
        #expect(setup().problems(catalog: catalog).isEmpty)
    }

    /// The page: the official loader with the bidders' modules and our chunk base, then config, ad units, events and the
    /// auction. Everything typed is JSON, and `</script>` cannot close the page's script.
    @Test func thePageLoadsTheOfficialLoaderAndRunsTheAuction() throws {
        var consented = setup()
        consented.consent.gdprApplies = true
        consented.consent.tcString = "CPtc"
        consented.consent.usPrivacy = "1YNN"
        let html = try PrebidPage.html(for: consented, catalog: catalog)
        #expect(html.contains(#"src="ccinn-prebid://news.example/prebid/11.51.0/dist/bundle.js?modules=appnexusBidAdapter,consentManagementTcf,consentManagementUsp,rubiconBidAdapter&amp;distUrlBase=ccinn-prebid://news.example/prebid/11.51.0/dist/chunks/""#))
        #expect(html.contains(#""pageUrl":"https:\/\/news.example\/article""#) || html.contains(#""pageUrl":"https://news.example/article""#))
        #expect(html.contains(#""cmpApi":"static""#))
        #expect(html.contains("\"32\":true") && html.contains("\"52\":true"), "the bidders' vendors are consented")
        #expect(html.contains("requestBids"))
        #expect(html.contains("bidResponse") && html.contains("noBid") && html.contains("bidTimeout") && html.contains("auctionEnd"))
        #expect(!html.contains("</script><b>"))
        #expect(html.contains("<\\/script>"))
        #expect(PrebidPage.host(of: consented) == "news.example")
    }

    @Test func withoutConsentNoConsentModuleIsConfigured() throws {
        let html = try PrebidPage.html(for: setup(), catalog: catalog)
        #expect(!html.contains("consentManagement"))
    }

    @Test func setupsRoundTripThroughCodable() throws {
        let original = setup()
        #expect(try JSONDecoder().decode(PrebidSetup.self, from: JSONEncoder().encode(original)) == original)
    }
}
