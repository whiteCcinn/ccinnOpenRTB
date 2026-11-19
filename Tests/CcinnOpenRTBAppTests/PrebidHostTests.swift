import CcinnOpenRTBKit
import CryptoKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// A stand-in for Prebid.js's core chunk: the pbjs API the page uses, an auction that fetches one bid and makes an XHR,
/// an image user sync, a cookie, a load the shim does not cover (a stylesheet, which the content rules must block), a
/// script from elsewhere (refused), and a probe of what the page looks like to a bidder.
private let fakeCore = #"""
(function () {
  var units = [], handlers = {}, config = {};
  pbjs.version = 'v-fake';
  pbjs.setConfig = function (c) { config = c; };
  pbjs.addAdUnits = function (u) { units = units.concat(u); };
  pbjs.onEvent = function (name, f) { (handlers[name] = handlers[name] || []).push(f); };
  function emit(name, data) { (handlers[name] || []).forEach(function (f) { f(data); }); }
  function probe(data) { window.webkit.messageHandlers.prebidEvents.postMessage({ type: 'probe', payload: JSON.stringify(data) }); }
  pbjs.requestBids = function (options) {
    emit('auctionInit', {});
    emit('auctionDebug', { type: 'WARNING', bidder: 'fake', arguments: ['Invalid bid sent to bidder fake:', { placement: 1 }] });
    console.warn('%cPrebid', 'display: inline-block; color: #fff', 'WARNING: styled');
    document.cookie = 'ok=1; path=/';
    var link = document.createElement('link'); link.rel = 'stylesheet'; link.href = 'https://evil.test/x.css'; document.head.appendChild(link);
    var foreign = document.createElement('script'); foreign.src = 'https://evil.test/x.js'; document.head.appendChild(foreign);
    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'https://bidder.test/xhr');
    xhr.onload = function () {
      probe({ xhr: xhr.status, text: xhr.responseText, cookie: document.cookie, page: config.pageUrl, href: location.href, modules: window.__modules,
              screen: screen.width + 'x' + screen.height, inner: innerWidth + 'x' + innerHeight, dpr: devicePixelRatio, platform: navigator.platform,
              touch: navigator.maxTouchPoints, language: navigator.language, secure: window.isSecureContext });
    };
    xhr.send();
    fetch('https://bidder.test/bid', { method: 'POST', body: JSON.stringify({ units: units }), credentials: 'include', headers: { 'Content-Type': 'text/plain' } })
      .then(function (r) { return r.json(); })
      .then(function (j) {
        var bid = { bidderCode: 'fake', adId: 'a1', adUnitCode: units[0].code, cpm: j.cpm, currency: 'USD', width: 300, height: 250, mediaType: 'banner', ad: j.ad };
        emit('bidResponse', bid);
        emit('auctionEnd', {});
        var responses = {}; responses[units[0].code] = { bids: [bid] };
        options.bidsBackHandler(responses);
        new Image().src = 'https://sync.dsp.example/pixel?uid=$UID';
        var frame = document.createElement('iframe'); frame.src = 'about:blank'; document.body.appendChild(frame);
      })
      .catch(function (e) { probe({ fetchError: String(e) }); options.bidsBackHandler({}); });
  };
  pbjs.processQueue = function () {
    var queue = pbjs.que;
    pbjs.que = { push: function (f) { f(); } };
    queue.forEach(function (f) { f(); });
  };
})();
"""#

/// A stand-in for the official loader: it reads its options from its own `src` and loads its chunk as Prebid's does —
/// `setAttribute('src')`, then `integrity`, then appended.
private func fakeLoader(chunk: String, integrity: String) -> String {
    """
    (function () {
      var params = new URL(document.currentScript.src).searchParams;
      window.__modules = params.get('modules');
      var script = document.createElement('script');
      script.setAttribute('src', params.get('distUrlBase') + '\(chunk)');
      script.setAttribute('crossorigin', 'anonymous');
      script.setAttribute('integrity', '\(integrity)');
      script.onload = function () { pbjs.processQueue(); };
      document.head.appendChild(script);
    })();
    """
}

private func sha384(_ text: String) -> String {
    "sha384-" + Data(SHA384.hash(data: Data(text.utf8))).base64EncodedString()
}

@MainActor
@Suite("Prebid: host", .serialized)
struct PrebidHostTests {
    @MainActor
    private struct Fixture {
        let transport = ScriptedTransport()
        let monitor: NetworkMonitor
        let cache = TemporaryDirectory()
        let host: PrebidHost
        let library: PrebidLibrary
        let window: WindowHarness
        var setup = PrebidSetup(version: "1.0.0")
        let catalog = ["fake": PrebidBidder(code: "fake", aliasOf: nil, gvlid: nil, module: "fakeBidAdapter")]
        let device = PrebidDevice(screenWidth: 402, screenHeight: 874, viewportWidth: 402, viewportHeight: 778, pixelRatio: 3, platform: "iPhone",
                                  maxTouchPoints: 5)

        init(integrity: String = sha384(fakeCore)) {
            transport.answer("https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", .init(headers: ["Content-Type": "application/javascript"],
                                                                                           body: fakeLoader(chunk: "core.js", integrity: integrity)))
            transport.answer("https://cdn.test/npm/prebid.js@1.0.0/dist/chunks/core.js", .init(headers: ["Content-Type": "application/javascript"], body: fakeCore))
            transport.answer("https://bidder.test/bid", .init(body: #"{"cpm":2.5,"ad":"<div>${AUCTION_PRICE}</div>"}"#))
            transport.answer("https://bidder.test/xhr", .init(headers: ["Content-Type": "text/plain"], body: "pong"))
            monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
            let monitor = monitor
            library = PrebidLibrary(cacheDirectory: cache.url, upstreamBase: "https://cdn.test/npm/prebid.js@", monitor: { monitor }, userAgent: { "UA/1" })
            host = PrebidHost(library: library, bridge: PrebidNetworkBridge(monitor: { monitor }, userAgent: { "UA/1" }), userAgent: "UA/1")
            window = WindowHarness(PrebidWebView(host: host), size: CGSize(width: 360, height: 240))
            setup.adUnits = [PrebidAdUnit(code: "div-1", mediaType: .banner, sizes: [AdSize(width: 300, height: 250)],
                                          bids: [PrebidBidderParams(bidder: "fake", params: #"{"placement": 1}"#)])]
        }

        func load() async throws {
            let html = try PrebidPage.html(for: setup, catalog: catalog, distBase: library.distBase(version: setup.version), device: device)
            try await host.load(html, at: try #require(PrebidPage.pageURL(of: setup)), version: setup.version, userAgent: "UA/1")
        }

        func close() {
            host.tearDown()
            window.close()
            cache.cleanUp()
        }
    }

    @Test func aPageRunsItsAuctionThroughTheMonitor() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        var events: [(type: String, payload: String)] = []
        fixture.host.onEvent = { events.append(($0, $1)) }

        try await fixture.load()
        let done = await Wait.until(timeout: .seconds(20)) {
            events.contains { $0.type == "bidsBack" } && events.contains { $0.type == "probe" } && events.contains { $0.type == "sync" }
                && events.contains { $0.type == "log" && $0.payload.contains("Script blocked") }
        }
        #expect(done, "\(events.map { "\($0.type) \($0.payload.prefix(200))" })")

        let bids = PrebidBid.parseList(try #require(events.first { $0.type == "bidsBack" }?.payload))
        #expect(bids.map(\.cpm) == [2.5])
        #expect(bids.first?.candidate(index: 0).markup == .html("<div>2.5</div>"))
        let probe = try #require(events.first { $0.type == "probe" }?.payload)
        #expect(probe.contains("\"xhr\":200") && probe.contains("pong"), "\(probe)")
        #expect(probe.contains("ok=1"), "document.cookie works on the page: \(probe)")
        #expect(probe.contains(#""href":"https://news.example/article""#), "the page is at its own URL, as Prebid's referer detection reads it: \(probe)")
        #expect(probe.contains(#""secure":true"#))
        #expect(probe.contains(#""modules":"fakeBidAdapter""#), "the loader read its modules from its own src: \(probe)")
        #expect(probe.contains(#""screen":"402x874""#) && probe.contains(#""inner":"402x778""#) && probe.contains(#""dpr":3"#), "the device: \(probe)")
        #expect(probe.contains(#""platform":"iPhone""#) && probe.contains(#""touch":5"#) && probe.contains(#""language":"en-US""#))
        #expect(events.filter { $0.type == "sync" }.count == 1, "the about:blank frame is no sync")
        #expect(events.contains { $0.type == "sync" && $0.payload.contains("https://sync.dsp.example/pixel") })
        #expect(events.contains { $0.type == "ready" && $0.payload.contains("v-fake") })
        #expect(events.contains { $0.type == "log" && $0.payload.contains("fake: Invalid bid sent to bidder fake: {\\\"placement\\\":1}") },
                "\(events.filter { $0.type == "log" }.map(\.payload))")
        #expect(events.contains { $0.type == "log" && $0.payload.contains("Prebid WARNING: styled") && !$0.payload.contains("%c") })

        // Only the library and the bidder calls reached the network, each a recorded entry; the stylesheet, the foreign
        // script and the sync pixel did not.
        let urls = Set(fixture.transport.requests.map(\.url.absoluteString))
        #expect(urls == ["https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", "https://cdn.test/npm/prebid.js@1.0.0/dist/chunks/core.js",
                         "https://bidder.test/bid", "https://bidder.test/xhr"])
        let bid = try #require(fixture.transport.requests.first { $0.url.absoluteString == "https://bidder.test/bid" })
        #expect(bid.method == "POST")
        #expect(String(decoding: bid.body ?? Data(), as: UTF8.self).contains("div-1"))
        #expect(bid.headers["User-Agent"] == "UA/1")
        #expect(bid.headers["Origin"] == "https://news.example")
        #expect(bid.headers["Referer"] == "https://news.example/")
        #expect(bid.headers["Sec-Fetch-Site"] == "cross-site")
        #expect(HTTPHeaders.value("Content-Type", in: bid.headers) == "text/plain")
        #expect(bid.headers["Cookie"] == nil)
        #expect(fixture.monitor.liveEntries.filter { $0.category == .bidRequest }.count == 2)
        #expect(fixture.monitor.liveEntries.contains { $0.category == .content && $0.url.hasSuffix("/dist/chunks/core.js") })
    }

    /// A chunk whose bytes do not match its `integrity` does not run: WebKit refuses it, and the page says so.
    @Test func aChunkFailingItsIntegrityCheckDoesNotRun() async throws {
        let fixture = Fixture(integrity: sha384("something else"))
        defer { fixture.close() }
        var events: [(type: String, payload: String)] = []
        fixture.host.onEvent = { events.append(($0, $1)) }

        try await fixture.load()
        let failed = await Wait.until(timeout: .seconds(20)) { events.contains { $0.type == "scriptError" } }

        #expect(failed, "\(events.map(\.type))")
        #expect(events.first { $0.type == "scriptError" }?.payload.contains("integrity") == true)
        #expect(!events.contains { $0.type == "ready" }, "the core never ran")
        #expect(!fixture.transport.requests.contains { $0.url.host == "bidder.test" })
    }

    @Test func theLibraryServesOnlyPrebidFiles() async throws {
        let transport = ScriptedTransport()
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let cache = TemporaryDirectory()
        defer { cache.cleanUp() }
        let library = PrebidLibrary(cacheDirectory: cache.url, upstreamBase: "https://cdn.test/npm/prebid.js@", monitor: { monitor }, userAgent: { "UA" })
        for (version, path) in [("1.0.0", "../../etc/passwd"), ("1.0.0", "dist/../../x"), ("latest", "dist/bundle.js"), ("1.0.0", "src/a.js"),
                                ("1.0.0", "dist/chunks/a b.js"), ("1.0", "dist/bundle.js")] {
            await #expect(throws: PrebidLibrary.Failure.self) { _ = try await library.file(version: version, path: path) }
        }
        #expect(transport.requests.isEmpty)
        #expect(PrebidLibrary.isValid(path: "dist/chunks/appnexusBidAdapter.js"))
        #expect(PrebidLibrary.isValid(path: "metadata/modules.json"))
        // Scripts: only the dist/ of the version the page runs.
        for url in ["https://evil.test/npm/prebid.js@1.0.0/dist/bundle.js", "https://cdn.test/npm/prebid.js@2.0.0/dist/bundle.js",
                    "https://cdn.test/npm/prebid.js@1.0.0/metadata/modules.json", "https://cdn.test/npm/prebid.js@1.0.0/dist/",
                    "https://cdn.test/npm/prebid.js@1.0.0/dist/%2e%2e/x.js", "https://cdn.test/npm/prebid.js@1.0.0/dist/../../x.js"] {
            await #expect(throws: PrebidLibrary.Failure.self, "\(url)") { _ = try await library.script(at: url, version: "1.0.0") }
        }
        #expect(transport.requests.isEmpty)
    }

    /// A version once loaded runs Offline: the cache serves it, nothing is fetched.
    @Test func aCachedVersionNeedsNoNetwork() async throws {
        let transport = ScriptedTransport()
        transport.answer("https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", .init(body: "/* loader */"))
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let cache = TemporaryDirectory()
        defer { cache.cleanUp() }
        let library = PrebidLibrary(cacheDirectory: cache.url, upstreamBase: "https://cdn.test/npm/prebid.js@", monitor: { monitor }, userAgent: { "UA" })
        _ = try await library.file(version: "1.0.0", path: "dist/bundle.js")
        monitor.offline = true
        #expect(String(decoding: try await library.file(version: "1.0.0", path: "dist/bundle.js"), as: UTF8.self) == "/* loader */")
        #expect(transport.requests.count == 1)
    }
}
