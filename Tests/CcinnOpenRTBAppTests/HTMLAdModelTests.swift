import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
import WebKit
@testable import CcinnOpenRTB

@MainActor
@Suite("HTML ad model (WebKit)", .serialized)
struct HTMLAdModelTests {
    private func load(_ adm: String, device: DeviceProfile = RendererFixtures.phone, placement: Placement = .inlineBanner)
        async -> (HTMLAdModel, RecordingHost, RenderRequest) {
        let host = RecordingHost(device: device)
        let model = HTMLAdModel(host: host)
        let request = RendererFixtures.request(.html(adm), device: device, placement: placement)
        model.load(markup: adm, request: request, blocksNetwork: true)
        let ready = await Wait.until(timeout: .seconds(20)) { model.status == .ready }
        #expect(ready, "the creative never loaded: \(model.status)")
        return (model, host, request)
    }

    private func evaluate(_ model: HTMLAdModel, _ script: String) async throws -> Any? {
        try await model.controller.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test func renderedOnceEvenWhenTheCreativeReloads() async throws {
        let (model, host, request) = await load("<p>ad</p>")
        defer { model.teardown() }
        #expect(host.events == [.rendered])
        var next = request
        next.generation += 1
        model.load(markup: "<p>ad</p>", request: next, blocksNetwork: true)
        model.load(markup: "<p>ad</p>", request: next, blocksNetwork: true)
        let reloaded = await Wait.until { model.status == .ready && host.logs.contains { $0.message.hasPrefix("Reloading") } }
        #expect(reloaded)
        #expect(host.events == [.rendered], "the gate-free renderer itself reports .rendered once per ad")
        #expect(host.logs.filter { $0.message.hasPrefix("Reloading") }.count == 1, "an unchanged request does not reload")
    }

    @Test func mraidOpenIsAClickThenANavigation() async throws {
        let (model, host, _) = await load("<p>ad</p>")
        defer { model.teardown() }
        _ = try await evaluate(model, "mraid.open('https://adv.example/landing')")
        let clicked = await Wait.until { host.navigations.count == 1 }
        #expect(clicked)
        #expect(host.events == [.rendered, .click(assetID: nil)])
        #expect(host.navigations == [.init(url: "https://adv.example/landing", trigger: "mraid.open")])
    }

    @Test func ctvRecordsNoClick() async throws {
        let (model, host, _) = await load("<p>ad</p>", device: RendererFixtures.tv, placement: .ctvInstream)
        defer { model.teardown() }
        _ = try await evaluate(model, "mraid.open('https://adv.example/landing')")
        let logged = await Wait.until { host.logs.contains { $0.message.contains("click-through is disabled") } }
        #expect(logged)
        #expect(host.events == [.rendered])
        #expect(host.navigations.isEmpty)
    }

    @Test func expandAndCloseWalkTheViewStateAndCloseReportsClosedOnce() async throws {
        let (model, host, _) = await load("<p>ad</p>")
        defer { model.teardown() }
        _ = try await evaluate(model, "mraid.expand()")
        #expect(await Wait.until { model.isExpanded })
        #expect(model.expandedSize == MRAIDSize(width: 390, height: 763))
        model.containerClose(fullscreen: false)
        #expect(await Wait.until { !model.isExpanded && model.mraidState == "default" })
        #expect(!model.isClosed)
        _ = try await evaluate(model, "mraid.close(); mraid.close()")
        #expect(await Wait.until { model.isClosed })
        #expect(host.events == [.rendered, .closed])
    }

    @Test func theFullscreenCloseClosesAtOnceEvenIfThePageIsStuck() async throws {
        let (model, host, _) = await load("<script>mraid.useCustomClose(true)</script>", placement: .interstitial)
        defer { model.teardown() }
        #expect(await Wait.until { model.customClose })
        model.containerClose(fullscreen: true)
        #expect(model.isClosed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.events == [.rendered, .closed], "the page's own hidden state does not close twice")
    }

    @Test func theSandboxFollowsTheMonitor() {
        let monitor = NetworkMonitor(transport: OfflineTransport(), publishInterval: .zero)
        #expect(HTMLAdModel.blocksNetwork(monitor))
        monitor.allowCreativeNetwork = true
        #expect(!HTMLAdModel.blocksNetwork(monitor))
        monitor.allowCreativeNetwork = false
        monitor.mode = .real
        #expect(!HTMLAdModel.blocksNetwork(monitor), "Real mode lets the creative load")
    }
}

@MainActor
@Suite("Script tracker injection (WebKit)", .serialized)
struct ScriptTrackerInjectorTests {
    private func tracker(_ url: String, monitor: NetworkMonitor) -> ScriptTracker {
        let request = TrackerRequest(category: .impression, trigger: "impression (jstracker)", source: "bid 0.0 › native › jstracker",
                                     template: url, url: url, isScript: true)
        return ScriptTracker(entryID: monitor.dispatch(request, userAgent: "TestUA/1.0"), request: request)
    }

    @Test func realModeInjectsURLAndMarkupTrackersOnce() async throws {
        let server = try LoopbackServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let host = RecordingHost()
        host.monitor.mode = .real
        let injector = ScriptTrackerInjector(host: host)
        defer { injector.teardown() }
        let byURL = tracker("http://127.0.0.1:\(port)/tracker.js", monitor: host.monitor)
        let byMarkup = tracker("<script>new Image().src = 'http://127.0.0.1:\(port)/pixel.gif';</script>", monitor: host.monitor)
        injector.inject([byURL, byMarkup])
        injector.inject([byURL, byMarkup])
        let finished = await Wait.until(timeout: .seconds(20)) {
            [byURL, byMarkup].allSatisfy { host.monitor.entry(id: $0.entryID)?.state == .completed(status: 200) }
        }
        #expect(finished, "\([byURL, byMarkup].map { host.monitor.entry(id: $0.entryID)?.state })")
        #expect(await Wait.until { server.connectionCount >= 2 })
        let children = host.monitor.liveEntries.filter { $0.category == .creative }
        #expect(children.contains { $0.url.hasSuffix("/tracker.js") && $0.parentID == byURL.entryID })
        #expect(children.contains { $0.url.hasSuffix("/pixel.gif") && $0.parentID == byMarkup.entryID })
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.connectionCount == 2, "each tracker is injected once")
    }

    @Test func nothingIsInjectedOutsideRealMode() async throws {
        let server = try LoopbackServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let host = RecordingHost()
        host.monitor.mode = .real
        let pending = tracker("http://127.0.0.1:\(port)/late.js", monitor: host.monitor)
        host.monitor.mode = .simulated
        let injector = ScriptTrackerInjector(host: host)
        defer { injector.teardown() }
        injector.inject([pending])
        #expect(injector.runningCount == 0)
        if case let .failed(message)? = host.monitor.entry(id: pending.entryID)?.state {
            #expect(message.contains("Simulated"))
        } else {
            Issue.record("the waiting entry gets an outcome: \(String(describing: host.monitor.entry(id: pending.entryID)?.state))")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.connectionCount == 0)
    }

    @Test func teardownFinishesWhatIsStillLoading() async {
        let host = RecordingHost()
        host.monitor.mode = .real
        let injector = ScriptTrackerInjector(host: host)
        // Port 9 (discard) on loopback: nothing answers quickly enough to finish before the teardown.
        let slow = tracker("<script>for(;;){}</script>", monitor: host.monitor)
        injector.inject([slow])
        injector.teardown()
        if case .failed? = host.monitor.entry(id: slow.entryID)?.state {} else {
            Issue.record("teardown leaves no entry pending: \(String(describing: host.monitor.entry(id: slow.entryID)?.state))")
        }
    }

    @Test func scriptURLsAndMarkupAreTold() {
        #expect(ScriptTrackerDocument.isScriptURL(" https://t.example/a.js?x=1 "))
        #expect(!ScriptTrackerDocument.isScriptURL("<script src=\"https://t.example/a.js\"></script>"))
        #expect(!ScriptTrackerDocument.isScriptURL("javascript:alert(1)"))
        let request = TrackerRequest(category: .impression, trigger: "t", source: "s", template: "", url: "https://t.example/a.js?a=1&b=\"2\"",
                                     isScript: true)
        #expect(!ScriptTrackerDocument.document(for: request).contains("src=\"https://t.example/a.js?a=1&b=\"2\"\""), "a quote cannot break out")
    }
}
