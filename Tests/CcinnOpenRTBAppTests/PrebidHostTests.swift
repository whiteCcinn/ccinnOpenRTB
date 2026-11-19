import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// A stand-in for Prebid.js's loader: the pbjs API the page uses, an auction that fetches one bid and makes an XHR,
/// an image user sync, a cookie, and a load the shim does not cover (a stylesheet), which the content rules must block.
private let fakeBundle = #"""
window.pbjs = window.pbjs || { que: [] };
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
    document.cookie = 'ok=1; path=/';
    var link = document.createElement('link'); link.rel = 'stylesheet'; link.href = 'https://evil.test/x.css'; document.head.appendChild(link);
    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'https://bidder.test/xhr');
    xhr.onload = function () { probe({ xhr: xhr.status, text: xhr.responseText, cookie: document.cookie, page: config.pageUrl }); };
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
      })
      .catch(function (e) { probe({ fetchError: String(e) }); options.bidsBackHandler({}); });
  };
  var queue = pbjs.que;
  pbjs.que = { push: function (f) { f(); } };
  queue.forEach(function (f) { f(); });
})();
"""#

@MainActor
@Suite("Prebid: host", .serialized)
struct PrebidHostTests {
    @Test func aPageRunsItsAuctionThroughTheMonitor() async throws {
        let transport = ScriptedTransport()
        transport.answer("https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", .init(headers: ["Content-Type": "application/javascript"], body: fakeBundle))
        transport.answer("https://bidder.test/bid", .init(body: #"{"cpm":2.5,"ad":"<div>${AUCTION_PRICE}</div>"}"#))
        transport.answer("https://bidder.test/xhr", .init(headers: ["Content-Type": "text/plain"], body: "pong"))
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let cache = TemporaryDirectory()
        defer { cache.cleanUp() }
        let library = PrebidLibrary(cacheDirectory: cache.url, upstreamBase: "https://cdn.test/npm/prebid.js@", monitor: { monitor }, userAgent: { "UA/1" })
        let bridge = PrebidNetworkBridge(monitor: { monitor }, userAgent: { "UA/1" })
        let host = PrebidHost(library: library, bridge: bridge, userAgent: "UA/1")
        defer { host.tearDown() }
        var events: [(type: String, payload: String)] = []
        host.onEvent = { events.append(($0, $1)) }
        let window = WindowHarness(PrebidWebView(host: host), size: CGSize(width: 360, height: 240))
        defer { window.close() }
        var setup = PrebidSetup(version: "1.0.0")
        setup.adUnits = [PrebidAdUnit(code: "div-1", mediaType: .banner, sizes: [AdSize(width: 300, height: 250)],
                                      bids: [PrebidBidderParams(bidder: "fake", params: #"{"placement": 1}"#)])]
        let catalog = ["fake": PrebidBidder(code: "fake", aliasOf: nil, gvlid: nil, module: "fakeBidAdapter")]

        await host.load(try PrebidPage.html(for: setup, catalog: catalog), at: try #require(PrebidPage.pageURL(of: setup)))
        let done = await Wait.until(timeout: .seconds(20)) {
            events.contains { $0.type == "bidsBack" } && events.contains { $0.type == "probe" } && events.contains { $0.type == "sync" }
        }
        #expect(done, "\(events.map(\.type))")

        let bids = PrebidBid.parseList(try #require(events.first { $0.type == "bidsBack" }?.payload))
        #expect(bids.map(\.cpm) == [2.5])
        #expect(bids.first?.candidate(index: 0).markup == .html("<div>2.5</div>"))
        let probe = try #require(events.first { $0.type == "probe" }?.payload)
        #expect(probe.contains("\"xhr\":200") && probe.contains("pong"), "\(probe)")
        #expect(probe.contains("ok=1"), "document.cookie works on the page: \(probe)")
        #expect(probe.contains("https://news.example/article"), "Prebid sees the real page URL: \(probe)")
        #expect(events.contains { $0.type == "sync" && $0.payload.contains("https://sync.dsp.example/pixel") })
        #expect(events.contains { $0.type == "ready" && $0.payload.contains("v-fake") })

        // Only the library and the bidder calls reached the network, each a recorded entry; the stylesheet and the sync
        // pixel did not.
        let urls = Set(transport.requests.map(\.url.absoluteString))
        #expect(urls == ["https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", "https://bidder.test/bid", "https://bidder.test/xhr"])
        let bid = try #require(transport.requests.first { $0.url.absoluteString == "https://bidder.test/bid" })
        #expect(bid.method == "POST")
        #expect(String(decoding: bid.body ?? Data(), as: UTF8.self).contains("div-1"))
        #expect(bid.headers["User-Agent"] == "UA/1")
        #expect(monitor.liveEntries.filter { $0.category == .bidRequest }.count == 2)
        #expect(monitor.liveEntries.contains { $0.category == .content && $0.url.hasSuffix("/dist/bundle.js") })
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
