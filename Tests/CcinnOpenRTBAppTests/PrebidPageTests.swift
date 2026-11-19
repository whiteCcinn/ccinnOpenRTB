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

    private let distBase = "https://cdn.jsdelivr.net/npm/prebid.js@11.51.0/dist/"
    private let device = PrebidDevice(screenWidth: 402, screenHeight: 874, viewportWidth: 402, viewportHeight: 778, pixelRatio: 3,
                                      platform: "iPhone", maxTouchPoints: 5)

    /// The page: the official loader from where it lives, with the bidders' modules and its chunk base, then config, ad
    /// units, events and the auction. Everything typed is JSON, and `</script>` cannot close the page's script.
    @Test func thePageLoadsTheOfficialLoaderAndRunsTheAuction() throws {
        var consented = setup()
        consented.consent.gdprApplies = true
        consented.consent.tcString = "CPtc"
        consented.consent.usPrivacy = "1YNN"
        let html = try PrebidPage.html(for: consented, catalog: catalog, distBase: distBase, device: device, run: "run-1")
        let loader = "https://cdn.jsdelivr.net/npm/prebid.js@11.51.0/dist/bundle.js?modules=appnexusBidAdapter,consentManagementTcf,consentManagementUsp,rubiconBidAdapter&distUrlBase=https://cdn.jsdelivr.net/npm/prebid.js@11.51.0/dist/chunks/"
        #expect(PrebidPage.loaderURL(distBase: distBase, modules: try consented.modules(catalog: catalog)) == loader)
        #expect(html.contains("loader.src = " + PrebidPage.json(.string(loader))), "the loader is created by script, so the shim hands it over")
        #expect(!html.contains("<script src="), "no script the parser would fetch itself")
        #expect(html.contains(#""pageUrl":"https:\/\/news.example\/article""#) || html.contains(#""pageUrl":"https://news.example/article""#))
        #expect(!html.contains("\"debug\""), "production: Prebid's debug mode loads its DevTools module and changes behaviour")
        #expect(html.contains("auctionDebug"), "warnings and errors come from Prebid's auctionDebug events")
        #expect(html.contains(#""cmpApi":"static""#))
        #expect(html.contains("\"32\":true") && html.contains("\"52\":true"), "the bidders' vendors are consented")
        #expect(html.contains("requestBids"))
        #expect(html.contains("bidResponse") && html.contains("noBid") && html.contains("bidTimeout") && html.contains("auctionEnd"))
        #expect(!html.contains("</script><b>"))
        #expect(html.contains("\\u003c/script\\u003e\\u003cb\\u003e"), "typed text reaches the page as JSON escapes")
        #expect(html.contains(#"content="\#(PrebidPage.contentSecurityPolicy)""#) && PrebidPage.contentSecurityPolicy.contains("worker-src 'none'"))
        #expect(html.contains(#"var run = "run-1";"#))
        #expect(html.contains(#""screenWidth":402"#) && html.contains(#""platform":"iPhone""#), "the device is emulated")
        #expect(PrebidPage.pageURL(of: consented)?.absoluteString == "https://news.example/article")
    }

    /// The page URL as WebKit holds it: the headers and the navigation guard then agree with what the page sees.
    @Test func thePageURLIsCanonical() {
        var setup = setup()
        for (typed, canonical) in [("https://news.example", "https://news.example/"), ("https://NEWS.example/a", "https://news.example/a"),
                                   ("https://news.example:443/a", "https://news.example/a"), ("https://news.example/a/../b?x=1", "https://news.example/b?x=1"),
                                   (" https://news.example:8443/a ", "https://news.example:8443/a")] {
            setup.pageURL = typed
            #expect(PrebidPage.pageURL(of: setup)?.absoluteString == canonical, "\(typed)")
        }
    }

    @Test func onlyAnHTTPSPageIsAPage() {
        var setup = setup()
        for url in ["http://news.example/", "ccinn-prebid://news.example/", "https://", "not a url"] {
            setup.pageURL = url
            #expect(PrebidPage.pageURL(of: setup) == nil, "\(url)")
        }
    }

    /// `<!--<script>` in a typed value would put the HTML tokenizer into its double-escaped state and the page script
    /// would never run: nothing typed can reach the tokenizer as markup.
    @Test func typedMarkupCannotReachTheTokenizer() throws {
        var setup = setup()
        setup.adUnits[0].code = "<!--<script>"
        setup.consent.gdprApplies = true
        setup.consent.tcString = "a&b>c</script>"
        let html = try PrebidPage.html(for: setup, catalog: catalog, distBase: distBase, device: device, run: "r")
        let scripts = html.components(separatedBy: "<script>").dropFirst().map { $0.components(separatedBy: "</script>")[0] }
        #expect(scripts.count == 1)
        #expect(scripts.allSatisfy { !$0.contains("<!--") && !$0.contains("<script") && !$0.contains("</") })
        #expect(try JSONValue.parse(PrebidPage.json(.string("<!--<script>&"))) == .string("<!--<script>&"), "the escapes read back")
    }

    @Test func withoutConsentNoConsentModuleIsConfigured() throws {
        let html = try PrebidPage.html(for: setup(), catalog: catalog, distBase: distBase, device: device, run: "run-1")
        #expect(!html.contains("consentManagement"))
    }

    @Test func setupsRoundTripThroughCodable() throws {
        let original = setup()
        #expect(try JSONDecoder().decode(PrebidSetup.self, from: JSONEncoder().encode(original)) == original)
    }
}

@Suite("Prebid: the browser's request headers")
struct PrebidFetchHeadersTests {
    private let page = URL(string: "https://news.example/article?id=7#comments")!

    /// A bidder on another site: Origin, the page's origin as Referer, cross-site, CORS.
    @Test func aCrossSiteBidRequest() {
        let headers = PrebidFetchHeaders.headers(for: URL(string: "https://ib.adnxs.com/ut/v3/prebid")!, method: "post", mode: "cors", page: page,
                                                 pageHeaders: ["Content-Type": "text/plain", "Origin": "https://evil.example", "Cookie": "a=1", "referer": "x"])
        #expect(headers == ["Content-Type": "text/plain", "Origin": "https://news.example", "Referer": "https://news.example/",
                            "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty"])
    }

    /// The same site (another subdomain) is same-site, and a same-origin GET carries the full page URL but no Origin.
    @Test func sameSiteAndSameOrigin() {
        let sameSite = PrebidFetchHeaders.headers(for: URL(string: "https://ads.news.example/bid")!, method: "GET", mode: "cors", page: page, pageHeaders: [:])
        #expect(sameSite["Sec-Fetch-Site"] == "same-site")
        #expect(sameSite["Origin"] == "https://news.example")
        let sameOrigin = PrebidFetchHeaders.headers(for: URL(string: "https://news.example/hb")!, method: "GET", mode: "cors", page: page, pageHeaders: [:])
        #expect(sameOrigin["Sec-Fetch-Site"] == "same-origin")
        #expect(sameOrigin["Origin"] == nil)
        #expect(sameOrigin["Referer"] == "https://news.example/article?id=7", "no fragment")
        let post = PrebidFetchHeaders.headers(for: URL(string: "https://news.example/hb")!, method: "POST", mode: "cors", page: page, pageHeaders: [:])
        #expect(post["Origin"] == "https://news.example")
    }

    /// strict-origin-when-cross-origin: nothing from https to http; a beacon is no-cors.
    @Test func downgradesAndBeacons() {
        let insecure = PrebidFetchHeaders.headers(for: URL(string: "http://bidder.example/b")!, method: "POST", mode: "no-cors", page: page, pageHeaders: [:])
        #expect(insecure["Referer"] == nil)
        #expect(insecure["Sec-Fetch-Mode"] == "no-cors")
        #expect(PrebidFetchHeaders.origin(of: URL(string: "https://news.example:8443/a")!) == "https://news.example:8443")
        #expect(PrebidFetchHeaders.origin(of: URL(string: "https://NEWS.example:443/a")!) == "https://news.example")
        #expect(PrebidFetchHeaders.origin(of: URL(string: "ccinn-prebid://news.example/")!) == nil)
    }

    /// A no-cors GET (a pixel) carries no Origin; forbidden names the page tried never pass; Chrome's hints go to https.
    @Test func noCORSForbiddenNamesAndClientHints() {
        let pixel = PrebidFetchHeaders.headers(for: URL(string: "https://px.example/p")!, method: "GET", mode: "no-cors", page: page,
                                               pageHeaders: ["Sec-CH-UA": "forged", "Accept-Encoding": "identity", "Proxy-Authorization": "x", "X-Ok": "1"])
        #expect(pixel["Origin"] == nil)
        #expect(pixel["Sec-Fetch-Mode"] == "no-cors")
        #expect(pixel["Sec-CH-UA"] == nil && pixel["Accept-Encoding"] == nil && pixel["Proxy-Authorization"] == nil)
        #expect(pixel["X-Ok"] == "1")
        let hints = ["Sec-CH-UA": #""Chromium";v="157""#, "Sec-CH-UA-Mobile": "?1", "Sec-CH-UA-Platform": #""Android""#]
        #expect(PrebidFetchHeaders.headers(for: URL(string: "https://b.example/")!, method: "GET", mode: "cors", page: page, pageHeaders: [:],
                                           clientHints: hints)["Sec-CH-UA-Mobile"] == "?1")
        #expect(PrebidFetchHeaders.headers(for: URL(string: "http://127.0.0.1/")!, method: "GET", mode: "cors", page: page, pageHeaders: [:],
                                           clientHints: hints)["Sec-CH-UA-Mobile"] == nil)
    }
}

@Suite("Prebid: the device the page sees")
struct PrebidDeviceTests {
    @Test func theDefaultIPhone() {
        let profile = DeviceCatalog.defaultDevice
        let device = PrebidDevice(device: profile, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) Safari/604.1")
        #expect(device.screenWidth == Int(profile.screenWidth.rounded()))
        #expect(device.screenHeight == Int(profile.screenHeight.rounded()))
        #expect(device.viewportHeight < device.screenHeight)
        #expect(device.pixelRatio == profile.scale)
        #expect(device.platform == "iPhone")
        #expect(device.maxTouchPoints == 5)
        #expect(device.languages == ["en-US", "en"])
    }

    /// Chrome on Android: Google's vendor and its client hints (Prebid reads them into `device.sua`); Safari has none.
    @Test func chromeHasClientHints() throws {
        let pixel = try #require(DeviceCatalog.all.first { $0.os == "Android" && $0.family == .androidPhone })
        let agent = SyncBrowser.chrome.userAgent(for: pixel)
        let device = PrebidDevice(device: pixel, userAgent: agent)
        let hints = try #require(device.chrome)
        #expect(device.vendor == "Google Inc.")
        #expect(hints.major == SyncBrowser.chromeMajor)
        #expect(hints.brand == "Google Chrome" && hints.mobile && hints.platform == "Android" && hints.model == pixel.model)
        #expect(hints.headers["Sec-CH-UA"]?.contains(#""Google Chrome";v="\#(SyncBrowser.chromeMajor)""#) == true)
        #expect(hints.headers["Sec-CH-UA-Platform"] == #""Android""#)
        let webView = PrebidDevice(device: pixel, userAgent: "Mozilla/5.0 (Linux; Android 17; Pixel 10 Build/X; wv) AppleWebKit/537.36 Chrome/157.0.0.0 Mobile Safari/537.36")
        #expect(webView.chrome?.brand == "Android WebView")
        let safari = PrebidDevice(device: DeviceCatalog.defaultDevice, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) Version/27.2 Safari/604.1")
        #expect(safari.chrome == nil && safari.vendor == "Apple Computer, Inc.")
    }

    @Test func thePlatformFollowsTheUserAgent() {
        #expect(PrebidDevice.platform(forUserAgent: "Mozilla/5.0 (Linux; Android 16; Pixel 10) Chrome/142.0 Mobile Safari/537.36") == "Linux armv81")
        #expect(PrebidDevice.platform(forUserAgent: "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X)") == "iPad")
        #expect(PrebidDevice.platform(forUserAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)") == "MacIntel")
    }

    /// Nothing typed or odd can make the page divide by zero or read a negative screen.
    @Test func valuesAreSane() {
        let device = PrebidDevice(screenWidth: 0, screenHeight: -5, viewportWidth: 0, viewportHeight: 0, pixelRatio: .nan, platform: "", maxTouchPoints: -1,
                                  languages: [])
        #expect(device.screenWidth == 1 && device.screenHeight == 1 && device.viewportWidth == 1)
        #expect(device.pixelRatio == 1)
        #expect(device.maxTouchPoints == 0)
        #expect(device.languages == PrebidDevice.languages)
    }
}
