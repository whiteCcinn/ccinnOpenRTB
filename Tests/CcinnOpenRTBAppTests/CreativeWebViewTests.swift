import CcinnOpenRTBKit
import Foundation
import Network
import RTBKit
import Testing
import WebKit
@testable import CcinnOpenRTB

/// A loopback HTTP server that counts connections and answers every request with a 1×1 GIF: the proof that the
/// Simulated-mode sandbox lets nothing out (and the control that, when allowed, the same page does connect).
final class LoopbackServer: @unchecked Sendable {
    private static let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00,
                                   0x00, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
                                   0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B])
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback")
    private let lock = NSLock()
    private var connections = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    func start() async -> UInt16? {
        listener.start(queue: queue)
        for _ in 0..<500 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        lock.lock()
        connections += 1
        lock.unlock()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
            var response = Data(("HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: \(Self.gif.count)\r\n"
                    + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n").utf8)
            response.append(Self.gif)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
final class ControllerEvents {
    private(set) var events: [CreativeWebController.Event] = []

    func attach(_ controller: CreativeWebController) {
        controller.onEvent = { [weak self] event in self?.events.append(event) }
    }

    var loaded: Bool { events.contains(.loaded) }
}

@MainActor
@Suite("Creative web view (WebKit)", .serialized)
struct CreativeWebViewTests {
    @MainActor
    private struct Harness {
        let controller: CreativeWebController
        let host: RecordingHost
        let events: ControllerEvents

        func evaluate(_ script: String) async throws -> Any? {
            try await controller.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }

        func entries(_ category: TrackerCategory = .creative) -> [NetworkEntry] {
            host.monitor.liveEntries.filter { $0.category == category }
        }
    }

    private static let recorder = """
    <script>
      window.__events = [];
      function note(name) { return function () { window.__events.push([name].concat(Array.prototype.slice.call(arguments))); }; }
      ['ready', 'stateChange', 'sizeChange', 'viewableChange', 'exposureChange', 'error'].forEach(function (e) { mraid.addEventListener(e, note(e)); });
    </script>
    <div style="width:320px;height:50px;background:#36c">Ad</div>
    """

    private func load(_ adm: String, blocks: Bool = true, mraid: Bool = true, placement: Placement = .inlineBanner) async -> Harness {
        let host = RecordingHost()
        let controller = CreativeWebController(host: host)
        let events = ControllerEvents()
        events.attach(controller)
        let request = RendererFixtures.request(.html(adm), placement: placement, visibleFraction: 1)
        controller.load(CreativeWebController.Content(document: HTMLDocumentBuilder.document(for: adm),
                                                      mraid: mraid ? MRAIDEnvironment(request: request) : nil, blocksNetwork: blocks,
                                                      disableScroll: true, networkParentID: nil, source: "bid 0.0 › adm"))
        let loaded = await Wait.until(timeout: .seconds(20)) { events.loaded }
        #expect(loaded, "the creative never finished loading: \(events.events)")
        return Harness(controller: controller, host: host, events: events)
    }

    @Test func mraidReportsVersionPlacementAndBecomesReady() async throws {
        let harness = await load(Self.recorder)
        defer { harness.controller.teardown() }
        #expect(try await harness.evaluate("return mraid.getVersion()") as? String == "3.0")
        #expect(try await harness.evaluate("return mraid.getPlacementType()") as? String == "inline")
        #expect(try await harness.evaluate("return MRAID_ENV.version") as? String == "3.0")
        let ready = await Wait.until { (try? await harness.evaluate("return mraid.getState()")) as? String == "default" }
        #expect(ready)
        let events = try await harness.evaluate("return window.__events.map(function (e) { return e[0]; })") as? [String] ?? []
        #expect(events.prefix(4) == ["stateChange", "ready", "viewableChange", "exposureChange"], "\(events)")
        #expect(try await harness.evaluate("return mraid.supports('sms')") as? Bool == false)
        #expect(try await harness.evaluate("return mraid.supports('inlineVideo')") as? Bool == true)
        #expect(harness.host.logs.contains { $0.origin == "MRAID" && $0.message.hasPrefix("mraid.getVersion() → \"3.0\"") })
    }

    @Test func expandResizeAndCloseWalkTheStates() async throws {
        let harness = await load(Self.recorder)
        defer { harness.controller.teardown() }
        _ = await Wait.until { (try? await harness.evaluate("return mraid.getState()")) as? String == "default" }
        _ = try await harness.evaluate("mraid.expand()")
        #expect(try await harness.evaluate("return mraid.getState()") as? String == "expanded")
        #expect(try await harness.evaluate("return mraid.getCurrentPosition().height") as? Double == 763)
        _ = try await harness.evaluate("mraid.close()")
        #expect(try await harness.evaluate("return mraid.getState()") as? String == "default")

        _ = try await harness.evaluate("mraid.resize()")
        let errors = try await harness.evaluate("return window.__events.filter(function (e) { return e[0] === 'error'; }).length") as? Int
        #expect(errors == 1, "resize() before setResizeProperties() is an error event")
        _ = try await harness.evaluate("mraid.setResizeProperties({width: 320, height: 250, offsetX: 0, offsetY: 0}); mraid.resize()")
        #expect(try await harness.evaluate("return mraid.getState()") as? String == "resized")
        _ = try await harness.evaluate("mraid.close(); mraid.close()")
        #expect(try await harness.evaluate("return mraid.getState()") as? String == "hidden")

        let reachedHidden = await Wait.until { harness.events.events.contains { if case .mraidState("hidden", _, _) = $0 { true } else { false } } }
        #expect(reachedHidden)
        #expect(harness.events.events.contains(.mraidState("resized", customClose: false, size: MRAIDSize(width: 320, height: 250))))
        #expect(harness.host.logs.contains { $0.level == .warning && $0.message.contains("setResizeProperties() must be called") })
    }

    @Test func interstitialsCannotExpandAndCustomCloseIsReported() async throws {
        let harness = await load(Self.recorder, placement: .interstitial)
        defer { harness.controller.teardown() }
        #expect(try await harness.evaluate("return mraid.getPlacementType()") as? String == "interstitial")
        _ = try await harness.evaluate("mraid.expand(); mraid.useCustomClose(true)")
        #expect(try await harness.evaluate("return mraid.getState()") as? String != "expanded")
        let custom = await Wait.until { harness.events.events.contains { if case .mraidState(_, true, _) = $0 { true } else { false } } }
        #expect(custom)
    }

    @Test func openIsAClickAndTheCreativeStaysInPlace() async throws {
        let harness = await load(Self.recorder)
        defer { harness.controller.teardown() }
        _ = try await harness.evaluate("mraid.open('https://adv.example/landing?a=1&b=2')")
        let opened = await Wait.until { harness.events.events.contains(.mraidOpen(url: "https://adv.example/landing?a=1&b=2")) }
        #expect(opened)
        #expect(harness.controller.webView.url == CreativeWebController.baseURL)
        #expect(harness.host.logs.contains { $0.message == #"mraid.open("https://adv.example/landing?a=1&b=2")"# })
    }

    @Test func exposureFollowsTheVisibleFraction() async throws {
        let harness = await load(Self.recorder)
        defer { harness.controller.teardown() }
        _ = await Wait.until { (try? await harness.evaluate("return mraid.getState()")) as? String == "default" }
        harness.controller.updateExposure(0)
        let hidden = await Wait.until { (try? await harness.evaluate("return mraid.isViewable()")) as? Bool == false }
        #expect(hidden)
        harness.controller.updateExposure(40)
        let partly = await Wait.until { (try? await harness.evaluate("return mraid.getExposure()")) as? Double == 40 }
        #expect(partly)
        let viewable = try await harness.evaluate("""
        return window.__events.filter(function (e) { return e[0] === 'viewableChange'; }).map(function (e) { return e[1]; })
        """) as? [Bool]
        #expect(viewable == [true, false, true])
    }

    @Test func simulatedModeBlocksAndRecordsEveryRequestKind() async throws {
        let server = try LoopbackServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let adm = """
        <img src="\(base)/markup.gif">
        <script>
          fetch('\(base)/fetch').catch(function () {});
          var xhr = new XMLHttpRequest(); xhr.open('GET', '\(base)/xhr'); xhr.send();
          navigator.sendBeacon('\(base)/beacon', 'x');
          new Image().src = '\(base)/pixel.gif';
          var s = document.createElement('script'); s.setAttribute('src', '\(base)/tag.js'); document.body.appendChild(s);
          try { new WebSocket('ws://127.0.0.1:\(port)/socket'); } catch (e) {}
        </script>
        """
        let harness = await load(adm, blocks: true, mraid: false)
        defer { harness.controller.teardown() }
        let paths = ["/markup.gif", "/fetch", "/xhr", "/beacon", "/pixel.gif", "/tag.js", "/socket"]
        let recorded = await Wait.until { paths.allSatisfy { path in harness.entries().contains { $0.url.hasSuffix(path) } } }
        #expect(recorded, "\(harness.entries().map(\.url))")
        #expect(harness.entries().allSatisfy { $0.state == .blocked && $0.delivery == .blocked })
        #expect(Set(harness.entries().map(\.trigger)).isSuperset(of: ["img", "fetch", "xhr", "beacon", "script", "websocket"]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.connectionCount == 0, "the Simulated-mode sandbox let a request out")
    }

    /// Adversarial: loads no hook reports (preconnect, CSS, fonts, workers, refresh) must still never connect.
    @Test func simulatedModeLetsNothingOutThroughSideChannels() async throws {
        let server = try LoopbackServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let adm = """
        <!DOCTYPE html><html><head>
        <link rel="preconnect" href="\(base)/preconnect">
        <link rel="dns-prefetch" href="\(base)/dns">
        <link rel="prefetch" href="\(base)/prefetch">
        <link rel="stylesheet" href="\(base)/style.css">
        <style>
          @font-face { font-family: Leak; src: url('\(base)/font.woff'); }
          body { font-family: Leak; background-image: url('\(base)/background.png'); }
        </style>
        <meta http-equiv="refresh" content="1;url=\(base)/refresh">
        </head><body>
        <iframe src="\(base)/frame"></iframe>
        <video src="\(base)/video.mp4" autoplay muted></video>
        <a id="ping" href="#" ping="\(base)/ping">x</a>
        <object data="\(base)/object"></object>
        <script>
          try { new EventSource('\(base)/events'); } catch (e) {}
          try {
            var code = "fetch('\(base)/worker').catch(function () {}); try { importScripts('\(base)/import.js'); } catch (e) {}";
            new Worker(URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
          } catch (e) {}
          try { document.getElementById('ping').click(); } catch (e) {}
          var blank = document.createElement('iframe'); document.body.appendChild(blank);
          try { blank.contentWindow.fetch('\(base)/blank-frame').catch(function () {}); } catch (e) {}
        </script>
        </body></html>
        """
        let harness = await load(adm, blocks: true, mraid: false)
        defer { harness.controller.teardown() }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(server.connectionCount == 0, "the Simulated-mode sandbox let a connection out")
        let url = harness.controller.webView.url?.absoluteString ?? ""
        #expect(url.hasPrefix(CreativeWebController.baseURL.absoluteString), "the refresh did not replace the creative: \(url)")
        #expect(harness.entries(.navigation).map(\.url) == ["\(base)/refresh"], "the in-page #anchor is not a navigation")
    }

    @Test func webRTCIsDisabledAndRecordedInTheSandbox() async throws {
        let harness = await load("<p>rtc</p>", blocks: true, mraid: false)
        defer { harness.controller.teardown() }
        let outcome = try await harness.evaluate("""
        try { new RTCPeerConnection({iceServers: [{urls: 'stun:127.0.0.1:3478'}]}); return 'created'; } catch (e) { return e.name; }
        """) as? String
        #expect(outcome == "NotAllowedError")
        let recorded = await Wait.until { harness.entries().contains { $0.url == "stun:127.0.0.1:3478" && $0.state == .blocked && $0.trigger == "webrtc" } }
        #expect(recorded)
    }

    @Test func aPageFloodingTheHandlerIsCapped() async throws {
        let harness = await load("<p>flood</p>", blocks: true, mraid: false)
        defer { harness.controller.teardown() }
        _ = try await harness.evaluate("""
        for (var i = 0; i < 5000; i++) { window.webkit.messageHandlers.ccinn.postMessage({channel: 'console', level: 'log', message: 'x' + i}); }
        """)
        let capped = await Wait.until { harness.host.logs.last?.message.contains("log limit reached") == true }
        #expect(capped)
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.host.logs.count == CreativeWebController.logCapacity)
    }

    @Test func allowingTheCreativeNetworkLoadsAndFinishesTheEntries() async throws {
        let server = try LoopbackServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let adm = #"<img id="p" src="http://127.0.0.1:\#(port)/allowed.gif">"#
        let harness = await load(adm, blocks: false, mraid: false)
        defer { harness.controller.teardown() }
        let connected = await Wait.until { server.connectionCount > 0 }
        #expect(connected, "control: with the network allowed the same page connects")
        let finished = await Wait.until { harness.entries().contains { $0.url.hasSuffix("/allowed.gif") && $0.state == .completed(status: 200) } }
        #expect(finished, "\(harness.entries().map(\.state))")
        #expect(harness.entries().allSatisfy { $0.delivery == .renderer })
    }

    @Test func httpScriptsInTheHTTPSCreativeAreMixedContentEvenWhenAllowed() async throws {
        let server = try LoopbackServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let harness = await load(#"<script src="http://127.0.0.1:\#(port)/tag.js"></script>"#, blocks: false, mraid: false)
        defer { harness.controller.teardown() }
        let explained = await Wait.until {
            harness.entries().contains { entry in
                if case let .failed(message) = entry.state { return entry.url.hasSuffix("/tag.js") && message.contains("mixed content") }
                return false
            }
        }
        #expect(explained, "\(harness.entries().map(\.state))")
        #expect(server.connectionCount == 0)
    }

    @Test func navigationsWithoutAGestureAreBlockedAutoRedirects() async throws {
        let harness = await load(Self.recorder)
        defer { harness.controller.teardown() }
        _ = try await harness.evaluate("window.open('https://popup.example/'); location.href = 'https://evil.example/'")
        let recorded = await Wait.until { harness.entries(.navigation).count == 2 }
        #expect(recorded)
        #expect(harness.entries(.navigation).allSatisfy { $0.trigger.hasPrefix("auto-redirect blocked") })
        #expect(!harness.events.events.contains { if case .click = $0 { true } else { false } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.controller.webView.url == CreativeWebController.baseURL, "the creative stays in place")
    }

    @Test func samplesAreServedLocallyAndRecorded() async throws {
        let harness = await load(#"<img id="s" src="ccinn-sample://image/banner.png">"#, blocks: true, mraid: false)
        defer { harness.controller.teardown() }
        let decoded = await Wait.until(timeout: .seconds(20)) {
            (try? await harness.evaluate("return document.getElementById('s').naturalWidth")) as? Int == 320
        }
        #expect(decoded)
        let entry = harness.entries().first { $0.url == "ccinn-sample://image/banner.png" }
        #expect(entry?.state == .completed(status: 200))
        #expect(entry?.mimeType == "image/png")
    }

    @Test func consoleOutputReachesTheRendererLog() async throws {
        let harness = await load("<script>console.warn('hello', {a: 1}); setTimeout(function () { throw new Error('boom'); }, 0);</script>",
                                 mraid: false)
        defer { harness.controller.teardown() }
        let logged = await Wait.until { harness.host.logs.contains { $0.origin == "HTML" && $0.message.contains("boom") } }
        #expect(logged)
        #expect(harness.host.logs.contains { $0.origin == "HTML" && $0.level == .warning && $0.message == #"console.warn: hello {"a":1}"# })
    }
}
