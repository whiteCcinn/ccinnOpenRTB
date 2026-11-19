import Foundation
import Testing
@testable import RTBKit

private func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

@Suite("Prebid: versions")
struct PrebidVersionTests {
    /// The registry's `time` map: release dates, plus `created` / `modified`.
    private let registry = Data(#"""
    {"name":"prebid.js","time":{"created":"2016-01-01T00:00:00.000Z","modified":"2026-11-18T22:53:04.000Z",
      "11.52.0":"2026-11-18T22:53:04.000Z","11.51.0":"2026-11-04T18:00:00.000Z","11.50.0":"2026-10-28T18:00:00.000Z",
      "11.9.0":"2025-01-01T00:00:00.000Z","11.10.0":"2025-02-01T00:00:00.000Z","12.0.0-beta.1":"2026-10-01T00:00:00.000Z"}}
    """#.utf8)

    @Test func releaseDatesAreReadFromTheRegistry() throws {
        let times = try #require(PrebidVersions.releaseDates(fromRegistry: registry))
        #expect(times.count == 6)
        #expect(times["11.52.0"] == date("2026-11-18T22:53:04Z"))
        #expect(times["created"] == nil)
    }

    /// The user's rule: the newest stable release at least two weeks old (a brand-new release may carry fresh
    /// regressions, or a compromised publish).
    @Test func theDefaultIsTheNewestStableReleaseAtLeastTwoWeeksOld() throws {
        let times = try #require(PrebidVersions.releaseDates(fromRegistry: registry))
        #expect(PrebidVersions.defaultVersion(releasedAt: times, now: date("2026-11-19T12:00:00Z")) == "11.51.0")
        #expect(PrebidVersions.defaultVersion(releasedAt: times, now: date("2026-11-12T12:00:00Z")) == "11.50.0")
        #expect(PrebidVersions.defaultVersion(releasedAt: [:], now: Date()) == nil)
    }

    /// Numeric order, prereleases left out.
    @Test func versionsAreOrderedAsNumbers() throws {
        let times = try #require(PrebidVersions.releaseDates(fromRegistry: registry))
        #expect(PrebidVersions.stableVersions(times) == ["11.52.0", "11.51.0", "11.50.0", "11.10.0", "11.9.0"])
    }

    @Test func somethingElseIsNoRegistry() {
        #expect(PrebidVersions.releaseDates(fromRegistry: Data("[]".utf8)) == nil)
        #expect(PrebidVersions.releaseDates(fromRegistry: Data("nope".utf8)) == nil)
    }
}

@Suite("Prebid: adapter catalogue")
struct PrebidCatalogTests {
    /// A version's `metadata/modules/<x>BidAdapter.json`: one component per bidder code, aliases included.
    @Test func biddersComeFromTheModuleMetadata() {
        let metadata = Data(#"""
        {"NOTICE":"generated","components":[
          {"componentType":"bidder","componentName":"appnexus","aliasOf":null,"gvlid":32},
          {"componentType":"bidder","componentName":"appnexusAst","aliasOf":"appnexus","gvlid":32},
          {"componentType":"rtd","componentName":"notABidder"}]}
        """#.utf8)
        let bidders = PrebidCatalog.bidders(fromMetadata: metadata, module: "appnexusBidAdapter")
        #expect(bidders == [PrebidBidder(code: "appnexus", aliasOf: nil, gvlid: 32, module: "appnexusBidAdapter"),
                            PrebidBidder(code: "appnexusAst", aliasOf: "appnexus", gvlid: 32, module: "appnexusBidAdapter")])
    }

    /// An aggregate file (`metadata/modules.json`) nests the same components per module.
    @Test func anAggregateFileIsReadToo() {
        let aggregate = Data(#"""
        {"rubiconBidAdapter":{"components":[{"componentType":"bidder","componentName":"rubicon","gvlid":52}]},
         "fanBidAdapter":{"components":[{"componentType":"bidder","componentName":"freedomadnetwork"}]}}
        """#.utf8)
        let bidders = PrebidCatalog.bidders(fromMetadata: aggregate)
        #expect(Set(bidders.map(\.code)) == ["rubicon", "freedomadnetwork"])
        #expect(bidders.first { $0.code == "freedomadnetwork" }?.module == "fanBidAdapter")
    }

    /// jsDelivr's flat listing of a version: one chunk per bid adapter module.
    @Test func modulesComeFromThePackageListing() {
        let listing = Data(#"""
        {"type":"npm","name":"prebid.js","version":"11.51.0","files":[
          {"name":"/dist/chunks/appnexusBidAdapter.js","hash":"x","size":1},
          {"name":"/dist/chunks/prebid-core.js","hash":"x","size":1},
          {"name":"/dist/chunks/rubiconBidAdapter.js","hash":"x","size":1},
          {"name":"/modules/rubiconBidAdapter.js","hash":"x","size":1}]}
        """#.utf8)
        #expect(PrebidCatalog.bidAdapterModules(fromListing: listing) == ["appnexusBidAdapter", "rubiconBidAdapter"])
    }
}

@Suite("Prebid: bids on the device")
struct PrebidBidTests {
    /// `renderAd` puts `originalCpm || cpm` into `${AUCTION_PRICE}` and empties `${CLICKTHROUGH}`.
    @Test func aBannerBidIsHTMLWithThePriceFilled() throws {
        let bid = try #require(PrebidBid.parse(#"""
        {"bidderCode":"appnexus","adId":"a1","requestId":"r1","adUnitCode":"div-banner","cpm":1.2,"originalCpm":2.5,"currency":"USD",
         "mediaType":"banner","width":300,"height":250,"ad":"<img src='https://win.example/p?price=${AUCTION_PRICE}'><a href='${CLICKTHROUGH}'>x</a>",
         "creativeId":"cr-7","dealId":"d-1","meta":{"advertiserDomains":["brand.example"]},"burl":"https://bill.example/b"}
        """#))
        let candidate = bid.candidate(index: 0)
        #expect(candidate.format == .banner)
        #expect(candidate.markup == .html("<img src='https://win.example/p?price=2.5'><a href=''>x</a>"))
        #expect(candidate.size == AdSize(width: 300, height: 250))
        #expect(candidate.price == 1.2)
        #expect(candidate.seat == "appnexus")
        #expect(candidate.impID == "div-banner")
        #expect(candidate.bidID == "a1")
        #expect(candidate.creativeID == "cr-7")
        #expect(candidate.dealID == "d-1")
        #expect(candidate.advertiserDomains == ["brand.example"])
        #expect(candidate.billingURL == "https://bill.example/b")
    }

    @Test func anAdURLIsFramed() throws {
        let bid = try #require(PrebidBid.parse(#"{"bidderCode":"x","adId":"a","cpm":1,"mediaType":"banner","width":320,"height":50,"adUrl":"https://ad.example/a?p=${AUCTION_PRICE}"}"#))
        guard case let .html(html) = bid.candidate(index: 0).markup else { Issue.record("not HTML"); return }
        #expect(html.contains("src=\"https://ad.example/a?p=1\""))
        #expect(html.contains("<iframe"))
    }

    @Test func videoBidsAreVAST() throws {
        let inline = try #require(PrebidBid.parse(#"{"bidderCode":"x","adId":"a","cpm":3,"mediaType":"video","width":640,"height":360,"vastXml":"<VAST version=\"4.2\"/>"}"#))
        #expect(inline.candidate(index: 0).markup == .vast(.xml("<VAST version=\"4.2\"/>")))
        #expect(inline.candidate(index: 0).format == .video)
        let tag = try #require(PrebidBid.parse(#"{"bidderCode":"x","adId":"a","cpm":3,"mediaType":"video","vastUrl":"https://vast.example/t"}"#))
        #expect(tag.candidate(index: 0).markup == .vast(.url("https://vast.example/t")))
    }

    @Test func nativeBidsCarryTheirORTBResponse() throws {
        let bid = try #require(PrebidBid.parse(#"""
        {"bidderCode":"x","adId":"a","cpm":1,"mediaType":"native","native":{"ortb":{"ver":"1.2","assets":[{"id":1,"title":{"text":"Hi"}}],"link":{"url":"https://l.example/"}}}}
        """#))
        let candidate = bid.candidate(index: 2)
        #expect(candidate.format == .native)
        guard case let .native(json) = candidate.markup else { Issue.record("not native"); return }
        #expect(json.contains("\"assets\""))
        #expect(NativeParser.parse(json, hints: nil).ad?.assets.count == 1)
    }

    /// Bids come from the page as JSON: lenient about types, never trapping.
    @Test func lenientParsing() throws {
        let stringy = try #require(PrebidBid.parse(#"{"bidderCode":"x","adId":"a","cpm":"1.5","width":"728","height":"90","ad":"<div/>"}"#))
        #expect(stringy.cpm == 1.5)
        #expect(stringy.candidate(index: 0).size == AdSize(width: 728, height: 90))
        #expect(PrebidBid.parse("not json") == nil)
        #expect(PrebidBid.parse(#"{"adId":"a"}"#) == nil, "a bid needs a bidder and a price")
        #expect(PrebidBid.parseList(#"[{"bidderCode":"x","adId":"a","cpm":1,"ad":"<div/>"},{"bad":1}]"#).count == 1)
    }
}

@Suite("Prebid: bids as an OpenRTB response")
struct PrebidResponseTests {
    /// The simulator's own path renders a Prebid bid: an OpenRTB 2.6 response with one seat per bidder.
    @Test func bidsBecomeAnOpenRTB26Response() throws {
        let banner = try #require(PrebidBid.parse(#"{"bidderCode":"appnexus","adId":"a1","adUnitCode":"div-1","cpm":2.5,"currency":"EUR","mediaType":"banner","width":300,"height":250,"ad":"<div>${AUCTION_PRICE}</div>","creativeId":"cr","dealId":"d","meta":{"advertiserDomains":["brand.example"]},"burl":"https://bill.example/b"}"#))
        let video = try #require(PrebidBid.parse(#"{"bidderCode":"rubicon","adId":"v1","adUnitCode":"div-2","cpm":4,"mediaType":"video","vastUrl":"https://vast.example/tag"}"#))
        let json = PrebidBid.openRTBResponse(for: [banner, video], auctionID: "auction-1")

        let parsed = InputParser.parse(json)
        #expect(parsed.kind == .bidResponse(.v2("2.6")))
        #expect(parsed.responseID == "auction-1")
        #expect(parsed.candidates.count == 2)
        let first = try #require(parsed.candidates.first)
        #expect(first.seat == "appnexus")
        #expect(first.format == .banner)
        #expect(first.markup == .html("<div>2.5</div>"))
        #expect(first.price == 2.5)
        #expect(first.currency == "EUR")
        #expect(first.size == AdSize(width: 300, height: 250))
        #expect(first.billingURL == "https://bill.example/b")
        #expect(first.dealID == "d")
        let second = try #require(parsed.candidates.last)
        #expect(second.format == .video)
        guard case let .vast(.xml(xml)) = second.markup else { Issue.record("not VAST XML: \(second.markup)"); return }
        #expect(xml.contains("<VASTAdTagURI><![CDATA[https://vast.example/tag]]></VASTAdTagURI>"))
        #expect(VASTParser.parse(xml).document?.ads.count == 1)
    }

    @Test func noBidsIsANoBidResponse() {
        let parsed = InputParser.parse(PrebidBid.openRTBResponse(for: [], auctionID: "a"))
        #expect(parsed.candidates.isEmpty)
        guard case .bidResponse = parsed.kind else { Issue.record("not a bid response: \(parsed.kind)"); return }
        #expect(parsed.noBidReason == nil, "no bids is no error")
    }
}
