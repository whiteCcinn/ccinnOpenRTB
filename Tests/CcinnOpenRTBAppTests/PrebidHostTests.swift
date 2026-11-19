import CcinnOpenRTBKit
import CryptoKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// A stand-in for Prebid.js's core chunk: the pbjs API the page uses and an auction that asks for its bid as Prebid 11's
/// ajax does (`fetch(new Request(…))`, credentials included, with a signal), plus what page code may try: an XHR, a
/// `no-cors` pixel, an aborted fetch, an image user sync, a cookie, a stylesheet (the content rules block it), a script
/// from elsewhere (refused), WebRTC / WebTransport / workers in the page and in a child frame, links, a smuggled method
/// and an http request (mixed content). It reports what it saw as `probe`.
private let fakeCore = #"""
(function () {
  var units = [], handlers = {}, config = {};
  pbjs.version = 'v-fake';
  pbjs.setConfig = function (c) { config = c; };
  pbjs.addAdUnits = function (u) { units = units.concat(u); };
  pbjs.onEvent = function (name, f) { (handlers[name] = handlers[name] || []).push(f); };
  function emit(name, data) { (handlers[name] || []).forEach(function (f) { f(data); }); }
  function probe(data) { window.webkit.messageHandlers.prebidEvents.postMessage({ type: 'probe', run: window.__ccinnRun, payload: JSON.stringify(data) }); }
  function settle(promise) { return promise.then(function (v) { return v; }, function (e) { return 'rejected ' + e.name + ': ' + e.message; }); }

  function sealed() {
    var first = document.createElement('iframe'); document.body.appendChild(first);
    var viaFrames = { rtc: typeof frames[frames.length - 1].RTCPeerConnection, worker: String(frames[frames.length - 1].Worker).indexOf('[native code]') < 0 };
    var second = document.createElement('iframe'); document.body.appendChild(second);
    var child = second.contentWindow;
    var workerError = null, childWorkerError = null;
    try { new Worker(URL.createObjectURL(new Blob(['1']))); } catch (e) { workerError = e.name; }
    try { new child.Worker('w.js'); } catch (e) { childWorkerError = e.name; }
    return { rtc: typeof RTCPeerConnection, webkitRTC: typeof webkitRTCPeerConnection, transport: typeof WebTransport,
             childRTC: typeof child.RTCPeerConnection, childTransport: typeof child.WebTransport, viaFrames: viaFrames,
             workerError: workerError, childWorkerError: childWorkerError, serviceWorker: typeof navigator.serviceWorker };
  }

  function links() {
    var before = location.href;
    var detached = document.createElement('a'); detached.href = 'https://elsewhere.example/a'; detached.click();
    detached.dispatchEvent(new MouseEvent('click'));
    var attached = document.createElement('a'); attached.href = 'https://elsewhere.example/b'; document.body.appendChild(attached);
    var listened = 0; attached.addEventListener('click', function () { listened += 1; });
    attached.click();
    return { stayed: location.href === before, listened: listened, href: attached.getAttribute('href') };
  }

  pbjs.requestBids = function (options) {
    emit('auctionInit', {});
    emit('auctionDebug', { type: 'WARNING', bidder: 'fake', arguments: ['Invalid bid sent to bidder fake:', { placement: 1 }] });
    console.warn('%cPrebid', 'display: inline-block; color: #fff', 'WARNING: styled');
    document.cookie = 'ok=1; path=/';
    var link = document.createElement('link'); link.rel = 'stylesheet'; link.href = 'https://evil.test/x.css'; document.head.appendChild(link);
    var foreign = document.createElement('script'); foreign.src = 'https://evil.test/x.js'; document.head.appendChild(foreign);

    var states = [];
    var xhr = new XMLHttpRequest();
    xhr.onreadystatechange = function () { states.push(xhr.readyState); };
    xhr.open('GET', 'https://bidder.test/xhr');
    var xhrDone = new Promise(function (resolve) { xhr.addEventListener('loadend', function () { resolve({ status: xhr.status, text: xhr.responseText }); }); });
    xhr.send();

    var smuggled = null;
    try { new XMLHttpRequest().open('GET /x HTTP/1.1', 'https://bidder.test/xhr'); } catch (e) { smuggled = e.name; }
    var aborter = new AbortController();
    var aborted = settle(fetch('https://bidder.test/slow', { signal: aborter.signal }));
    aborter.abort();
    var pixel = fetch('https://px.test/p', { mode: 'no-cors' }).then(function (r) { return r.type + ' ' + r.status; });
    var insecure = settle(fetch('http://bidder.test/plain'));
    var forbidden = settle(fetch('https://bidder.test/bid', { method: 'TRACE' }));
    var controller = new AbortController();
    var bid = fetch(new Request('https://bidder.test/bid', { method: 'POST', body: JSON.stringify({ units: units }), credentials: 'include', signal: controller.signal }))
      .then(function (r) { return r.json().then(function (j) { return { json: j, type: r.type, url: r.url, hidden: r.headers.get('x-secret'), shown: r.headers.get('content-type') }; }); });

    Promise.all([xhrDone, aborted, pixel, insecure, forbidden, bid]).then(function (results) {
      var answer = results[5];
      var made = { bidderCode: 'fake', adId: 'a1', adUnitCode: units[0].code, cpm: answer.json.cpm, currency: 'USD', width: 300, height: 250, mediaType: 'banner', ad: answer.json.ad };
      emit('bidResponse', made);
      emit('auctionEnd', {});
      var responses = {}; responses[units[0].code] = { bids: [made] };
      options.bidsBackHandler(responses);
      new Image().src = 'https://sync.dsp.example/pixel?uid=$UID';
      var frame = document.createElement('iframe'); frame.src = 'about:blank'; document.body.appendChild(frame);
      probe({ xhr: results[0], states: states, aborted: results[1], pixel: results[2], insecure: results[3], forbidden: results[4], smuggled: smuggled,
              bid: { type: answer.type, url: answer.url, hidden: answer.hidden, shown: answer.shown },
              cookie: document.cookie, page: config.pageUrl, href: location.href, modules: window.__modules,
              screen: screen.width + 'x' + screen.height, inner: innerWidth + 'x' + innerHeight, dpr: devicePixelRatio, platform: navigator.platform,
              touch: navigator.maxTouchPoints, language: navigator.language, vendor: navigator.vendor, secure: window.isSecureContext,
              sealed: sealed(), links: links() });
    }, function (e) { probe({ failed: String(e) }); options.bidsBackHandler({}); });
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

/// The bidder answers as Prebid needs for a credentialed request from the page.
private let bidderCORS = ["Content-Type": "application/json", "Access-Control-Allow-Origin": "https://news.example", "Access-Control-Allow-Credentials": "true",
                          "X-Secret": "not exposed"]

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

        init(core: String = fakeCore, integrity: String? = nil) {
            transport.answer("https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", .init(headers: ["Content-Type": "application/javascript"],
                                                                                           body: fakeLoader(chunk: "core.js", integrity: integrity ?? sha384(core))))
            transport.answer("https://cdn.test/npm/prebid.js@1.0.0/dist/chunks/core.js", .init(headers: ["Content-Type": "application/javascript"], body: core))
            transport.answer("https://bidder.test/bid", .init(headers: bidderCORS, body: #"{"cpm":2.5,"ad":"<div>${AUCTION_PRICE}</div>"}"#))
            transport.answer("https://bidder.test/xhr", .init(headers: ["Content-Type": "text/plain", "Access-Control-Allow-Origin": "*"], body: "pong"))
            transport.answer("https://bidder.test/slow", .init(headers: ["Access-Control-Allow-Origin": "*"], body: "late", delay: .seconds(5)))
            monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
            let monitor = monitor
            library = PrebidLibrary(cacheDirectory: cache.url, upstreamBase: "https://cdn.test/npm/prebid.js@", monitor: { monitor }, userAgent: { "UA/1" })
            host = PrebidHost(library: library, bridge: PrebidNetworkBridge(monitor: monitor, userAgent: { "UA/1" }), userAgent: "UA/1")
            window = WindowHarness(PrebidWebView(host: host), size: CGSize(width: 360, height: 240))
            setup.adUnits = [PrebidAdUnit(code: "div-1", mediaType: .banner, sizes: [AdSize(width: 300, height: 250)],
                                          bids: [PrebidBidderParams(bidder: "fake", params: #"{"placement": 1}"#)])]
        }

        func load(run: String = "run-1") async throws {
            let html = try PrebidPage.html(for: setup, catalog: catalog, distBase: library.distBase(version: setup.version), device: device, run: run)
            try await host.load(html, at: try #require(PrebidPage.pageURL(of: setup)), version: setup.version, userAgent: "UA/1", run: run)
        }

        func close() {
            host.tearDown()
            window.close()
            cache.cleanUp()
        }
    }

    @Test func aPageRunsItsAuctionThroughTheMonitor() async throws {
        var fixture = Fixture()
        fixture.setup.pageURL = "https://NEWS.example"
        defer { fixture.close() }
        var events: [(type: String, payload: String)] = []
        var outcomes: [PrebidNetworkBridge.Outcome] = []
        fixture.host.onEvent = { events.append(($0, $1)) }
        fixture.host.bridge.onRequest = { outcomes.append($0) }

        try await fixture.load()
        let done = await Wait.until(timeout: .seconds(20)) {
            events.contains { $0.type == "bidsBack" } && events.contains { $0.type == "probe" } && events.contains { $0.type == "sync" }
                && events.contains { $0.type == "log" && $0.payload.contains("Script blocked") }
        }
        #expect(done, "\(events.map { "\($0.type) \($0.payload.prefix(300))" })")

        let bids = PrebidBid.parseList(try #require(events.first { $0.type == "bidsBack" }?.payload))
        #expect(bids.map(\.cpm) == [2.5])
        #expect(bids.first?.candidate(index: 0).markup == .html("<div>2.5</div>"))
        let probe = try JSONValue.parse(try #require(events.first { $0.type == "probe" }?.payload))
        func value(_ path: String...) -> JSONValue? {
            path.reduce(Optional(probe)) { node, key in if case let .object(members)? = node { members[key] } else { nil } }
        }
        #expect(value("xhr", "status") == .int(200) && value("xhr", "text") == .string("pong"), "\(probe)")
        #expect(value("states") == .array([.int(1), .int(2), .int(3), .int(4)]), "XHR's readyState sequence")
        #expect(value("aborted")?.stringValue?.contains("AbortError") == true, "\(String(describing: value("aborted")))")
        #expect(value("pixel") == .string("opaque 0"), "a no-cors pixel is opaque to the page")
        #expect(value("insecure")?.stringValue?.contains("TypeError") == true, "http from the https page is mixed content")
        #expect(value("forbidden")?.stringValue?.contains("TypeError") == true, "TRACE is refused by the page's own Request")
        #expect(value("smuggled") == .string("SyntaxError"))
        #expect(value("bid", "type") == .string("cors") && value("bid", "url") == .string("https://bidder.test/bid"))
        #expect(value("bid", "shown") == .string("application/json") && value("bid", "hidden") == .null, "only exposed headers reach the page")
        #expect(value("cookie") == .string("ok=1"), "document.cookie works on the page")
        #expect(value("href") == .string("https://news.example/"), "the page is at its own (canonical) URL, as referer detection reads it")
        #expect(value("secure") == .bool(true))
        #expect(value("modules") == .string("fakeBidAdapter"), "the loader read its modules from its own src")
        #expect(value("screen") == .string("402x874") && value("inner") == .string("402x778") && value("dpr") == .int(3))
        #expect(value("platform") == .string("iPhone") && value("touch") == .int(5) && value("language") == .string("en-US"))
        #expect(value("vendor") == .string("Apple Computer, Inc."))
        // No network the app does not see: in the page, and in a child frame reached either way.
        #expect(value("sealed", "rtc") == .string("undefined") && value("sealed", "webkitRTC") == .string("undefined"))
        #expect(value("sealed", "transport") == .string("undefined"))
        #expect(value("sealed", "childRTC") == .string("undefined") && value("sealed", "childTransport") == .string("undefined"))
        #expect(value("sealed", "viaFrames", "rtc") == .string("undefined") && value("sealed", "viaFrames", "worker") == .bool(true), "\(probe)")
        #expect(value("sealed", "workerError") == .string("SecurityError") && value("sealed", "childWorkerError") == .string("SecurityError"))
        #expect(value("sealed", "serviceWorker") == .string("undefined"))
        #expect(value("links", "stayed") == .bool(true) && value("links", "listened") == .int(1), "links do nothing; their listeners still run")
        #expect(value("links", "href") == .string("https://elsewhere.example/b"), "the link keeps its href")

        #expect(events.filter { $0.type == "sync" }.count == 1, "the about:blank frame is no sync")
        #expect(events.contains { $0.type == "sync" && $0.payload.contains("https://sync.dsp.example/pixel") })
        #expect(events.contains { $0.type == "ready" && $0.payload.contains("v-fake") })
        #expect(events.contains { $0.type == "log" && $0.payload.contains("fake: Invalid bid sent to bidder fake: {\\\"placement\\\":1}") },
                "\(events.filter { $0.type == "log" }.map(\.payload))")
        #expect(events.contains { $0.type == "log" && $0.payload.contains("Prebid WARNING: styled") && !$0.payload.contains("%c") })
        #expect(events.contains { $0.type == "log" && $0.payload.contains("Navigation not followed") })
        #expect(outcomes.contains { $0.url == "http://bidder.test/plain" && $0.problem?.contains("Mixed content") == true })

        // Only the library and the bidder calls reached the network, each a recorded entry; the stylesheet, the foreign
        // script, the pixel (a tracker, Simulated mode), the http request and the sync image did not.
        let urls = Set(fixture.transport.requests.map(\.url.absoluteString))
        #expect(urls == ["https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", "https://cdn.test/npm/prebid.js@1.0.0/dist/chunks/core.js",
                         "https://bidder.test/bid", "https://bidder.test/xhr", "https://bidder.test/slow"])
        let bid = try #require(fixture.transport.requests.first { $0.url.absoluteString == "https://bidder.test/bid" })
        #expect(bid.method == "POST")
        #expect(String(decoding: bid.body ?? Data(), as: UTF8.self).contains("div-1"))
        #expect(bid.headers["User-Agent"] == "UA/1")
        #expect(bid.headers["Origin"] == "https://news.example")
        #expect(bid.headers["Referer"] == "https://news.example/")
        #expect(bid.headers["Sec-Fetch-Site"] == "cross-site" && bid.headers["Sec-Fetch-Mode"] == "cors")
        #expect(HTTPHeaders.value("Content-Type", in: bid.headers) == "text/plain;charset=UTF-8", "a string body is text/plain, as the browser sends it")
        #expect(bid.headers["Cookie"] == nil)
        #expect(!fixture.transport.requests.contains { $0.method == "OPTIONS" }, "Prebid's text/plain POST needs no preflight")
        #expect(fixture.monitor.liveEntries.contains { $0.category == .event && $0.url == "https://px.test/p" }, "the pixel is a recorded tracker")
        #expect(fixture.monitor.liveEntries.contains { $0.category == .content && $0.url.hasSuffix("/dist/chunks/core.js") })
    }

    /// The browser's CORS rules decide what reaches the page: a JSON POST gets its preflight; a bidder that does not allow
    /// the page's origin loses its answer (the page sees a network error), and the outcome says why.
    @Test func corsDecidesWhatThePageGets() async throws {
        let core = #"""
        (function () {
          pbjs.version = 'v-cors'; pbjs.setConfig = function () {}; pbjs.addAdUnits = function () {}; pbjs.onEvent = function () {};
          function settle(p) { return p.then(function (r) { return r.text(); }, function (e) { return 'rejected ' + e.name; }); }
          pbjs.requestBids = function () {
            Promise.all([
              settle(fetch('https://bidder.test/json', { method: 'POST', body: '{}', headers: { 'Content-Type': 'application/json' } })),
              settle(fetch('https://bidder.test/refused-preflight', { method: 'POST', body: '{}', headers: { 'Content-Type': 'application/json' } })),
              settle(fetch('https://bidder.test/no-acao', { method: 'POST', body: '{}' })),
              settle(fetch('https://bidder.test/wildcard', { method: 'POST', body: '{}', credentials: 'include' }))
            ]).then(function (results) {
              window.webkit.messageHandlers.prebidEvents.postMessage({ type: 'probe', run: window.__ccinnRun, payload: JSON.stringify(results) });
            });
          };
          pbjs.processQueue = function () { var q = pbjs.que; pbjs.que = { push: function (f) { f(); } }; q.forEach(function (f) { f(); }); };
        })();
        """#
        let fixture = Fixture(core: core)
        defer { fixture.close() }
        fixture.transport.answer("https://bidder.test/json", .init(headers: ["Access-Control-Allow-Origin": "https://news.example",
                                                                             "Access-Control-Allow-Headers": "Content-Type"], body: "json ok"))
        fixture.transport.answer("https://bidder.test/refused-preflight", .init(headers: ["Access-Control-Allow-Origin": "*"], body: "never"))
        fixture.transport.answer("https://bidder.test/no-acao", .init(body: "secret"))
        fixture.transport.answer("https://bidder.test/wildcard", .init(headers: ["Access-Control-Allow-Origin": "*"], body: "secret"))
        var events: [(type: String, payload: String)] = []
        var outcomes: [PrebidNetworkBridge.Outcome] = []
        fixture.host.onEvent = { events.append(($0, $1)) }
        fixture.host.bridge.onRequest = { outcomes.append($0) }

        try await fixture.load()
        #expect(await Wait.until(timeout: .seconds(20)) { events.contains { $0.type == "probe" } }, "\(events.map(\.type))")

        let results = try #require(events.first { $0.type == "probe" }?.payload)
        #expect(results == #"["json ok","rejected TypeError","rejected TypeError","rejected TypeError"]"#)
        let methods = fixture.transport.requests.filter { $0.url.host == "bidder.test" }.map { "\($0.method) \($0.url.path)" }
        #expect(methods.contains("OPTIONS /json") && methods.contains("POST /json"))
        #expect(methods.contains("OPTIONS /refused-preflight") && !methods.contains("POST /refused-preflight"), "a refused preflight stops the request")
        #expect(methods.contains("POST /no-acao"), "a simple request is sent; only its answer is withheld")
        let preflight = try #require(fixture.transport.requests.first { $0.method == "OPTIONS" && $0.url.path == "/json" })
        #expect(preflight.headers["Access-Control-Request-Method"] == "POST" && preflight.headers["Access-Control-Request-Headers"] == "content-type")
        #expect(preflight.headers["Origin"] == "https://news.example" && preflight.body == nil)
        #expect(outcomes.contains { $0.url.hasSuffix("/refused-preflight") && $0.problem?.contains("content-type") == true })
        #expect(outcomes.contains { $0.url.hasSuffix("/no-acao") && $0.problem?.contains("no Access-Control-Allow-Origin") == true })
        #expect(outcomes.contains { $0.url.hasSuffix("/wildcard") && $0.problem?.contains("credentials") == true })
    }

    /// The content rules are the backstop for loads the shim does not see: markup images, stylesheets and frames made from
    /// HTML never reach a real server (WebKit's own loads would not go through the scripted transport, so this one is real).
    @Test func theContentRulesBlockWhatTheShimDoesNotSee() async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let core = #"""
        (function () {
          pbjs.version = 'v-rules'; pbjs.setConfig = function () {}; pbjs.addAdUnits = function () {}; pbjs.onEvent = function () {};
          pbjs.requestBids = function () {
            var base = 'http://127.0.0.1:PORT/';
            document.body.insertAdjacentHTML('beforeend', '<img src="' + base + 'markup.gif"><link rel="stylesheet" href="' + base + 'style.css">'
              + '<iframe srcdoc="<img src=' + base + 'srcdoc.gif>"></iframe><video src="' + base + 'v.mp4"></video>'
              + '<div style="background:url(' + base + 'css.gif)">x</div><img srcset="' + base + 'set.gif 1x">');
            setTimeout(function () {
              window.webkit.messageHandlers.prebidEvents.postMessage({ type: 'probe', run: window.__ccinnRun, payload: '"done"' });
            }, 1500);
          };
          pbjs.processQueue = function () { var q = pbjs.que; pbjs.que = { push: function (f) { f(); } }; q.forEach(function (f) { f(); }); };
        })();
        """#.replacingOccurrences(of: "PORT", with: "\(port)")
        let fixture = Fixture(core: core)
        defer { fixture.close() }
        var events: [String] = []
        fixture.host.onEvent = { type, _ in events.append(type) }

        try await fixture.load()
        #expect(await Wait.until(timeout: .seconds(20)) { events.contains("probe") }, "\(events)")
        #expect(server.requests.isEmpty, "\(server.requests.map(\.target))")
    }

    /// A page being replaced says nothing more: while the next run loads, the old page still ticks (events and requests)
    /// until WebKit swaps it out, and none of it reaches the app.
    @Test func aReplacedPageIsSilent() async throws {
        let core = #"""
        (function () {
          pbjs.version = 'v-tick'; pbjs.setConfig = function () {}; pbjs.addAdUnits = function () {}; pbjs.onEvent = function () {};
          pbjs.requestBids = function () {
            setInterval(function () {
              window.webkit.messageHandlers.prebidEvents.postMessage({ type: 'tick', run: window.__ccinnRun, payload: JSON.stringify(window.__ccinnRun) });
              fetch('https://bidder.test/xhr').catch(function () {});
            }, 20);
          };
          pbjs.processQueue = function () { var q = pbjs.que; pbjs.que = { push: function (f) { f(); } }; q.forEach(function (f) { f(); }); };
        })();
        """#
        let fixture = Fixture(core: core)
        defer { fixture.close() }
        var ticks: [(payload: String, afterSwitch: Bool)] = []
        var switched = false
        fixture.host.onEvent = { type, payload in if type == "tick" { ticks.append((payload, switched)) } }

        try await fixture.load(run: "first")
        #expect(await Wait.until(timeout: .seconds(20)) { ticks.count >= 3 })
        switched = true
        try await fixture.load(run: "second")
        #expect(await Wait.until(timeout: .seconds(20)) { ticks.contains { $0.payload == #""second""# } })

        #expect(!ticks.contains { $0.afterSwitch && $0.payload == #""first""# }, "\(ticks.filter(\.afterSwitch).map(\.payload).prefix(5))")
        #expect(fixture.host.run == "second")
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

    /// The version list survives Offline (and a registry that answers nonsense): the last good answer is kept.
    @Test func theVersionsAreKeptForOffline() async throws {
        let transport = ScriptedTransport()
        transport.answer("https://registry.test/prebid.js", .init(body: #"{"time":{"1.0.0":"2026-10-01T00:00:00.000Z"}}"#))
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let cache = TemporaryDirectory()
        defer { cache.cleanUp() }
        let library = PrebidLibrary(cacheDirectory: cache.url, upstreamBase: "https://cdn.test/npm/prebid.js@", registry: "https://registry.test/prebid.js",
                                    monitor: { monitor }, userAgent: { "UA" })
        #expect(try await library.releaseDates().keys.sorted() == ["1.0.0"])

        transport.answer("https://registry.test/prebid.js", .init(status: 200, body: "<html>maintenance</html>"))
        #expect(try await library.releaseDates().keys.sorted() == ["1.0.0"], "nonsense does not replace the list")
        monitor.offline = true
        #expect(try await library.releaseDates().keys.sorted() == ["1.0.0"])

        let empty = PrebidLibrary(cacheDirectory: cache.url.appendingPathComponent("other"), upstreamBase: "https://cdn.test/npm/prebid.js@",
                                  registry: "https://registry.test/prebid.js", monitor: { monitor }, userAgent: { "UA" })
        await #expect(throws: (any Error).self) { _ = try await empty.releaseDates() }
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
