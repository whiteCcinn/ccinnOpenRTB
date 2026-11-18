import AppKit
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// Hosts a SwiftUI view in an offscreen window, as the simulator does.
@MainActor
final class WindowHarness {
    let window: NSWindow
    let hosting: NSHostingView<AnyView>

    init(_ view: some View, size: CGSize) {
        hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hosting.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
    }

    func close() {
        hosting.rootView = AnyView(EmptyView())
        window.orderOut(nil)
        window.contentView = nil
    }
}

@MainActor
@Suite("AdView (SwiftUI)", .serialized)
struct AdViewSmokeTests {
    private func show(_ request: RenderRequest, host: RecordingHost) -> WindowHarness {
        WindowHarness(AdView(request: request, host: host), size: request.adSize)
    }

    @Test func htmlIsRenderedOnce() async {
        let host = RecordingHost()
        let harness = show(RendererFixtures.request(.html("<div style='background:#36c;height:50px'>Ad</div>")), host: host)
        defer { harness.close() }
        #expect(await Wait.until(timeout: .seconds(20)) { host.events == [.rendered] }, "\(host.events)")
    }

    @Test func imageBannerIsRenderedWhenTheImageLoads() async {
        let host = RecordingHost()
        let banner = ImageBanner(imageURL: "ccinn-sample://image/banner.png")
        host.contents[banner.imageURL] = TestImages.png()
        let harness = show(RendererFixtures.request(.image(banner)), host: host)
        defer { harness.close() }
        #expect(await Wait.until { host.events == [.rendered] }, "\(host.events)")
    }

    @Test func nativeIsRenderedOnAppear() async {
        let host = RecordingHost()
        let ad = NativeAd(assets: [NativeAsset(id: 1, content: .title(text: "Hello"))], link: AdLink(url: "https://adv.example/"))
        let harness = show(RendererFixtures.request(.native("{}"), format: .native, native: ad, placement: .inFeed,
                                                    adSize: CGSize(width: 358, height: 280)), host: host)
        defer { harness.close() }
        #expect(await Wait.until { host.events == [.rendered] }, "\(host.events)")
    }

    @Test func videoStartsThePodWithoutReportingRenderedBeforeAFrame() async {
        let host = RecordingHost()
        let vast = ResolvedVAST(ads: [RendererFixtures.linearAd(media: [VASTMediaFile(url: "ccinn-sample://media/sample-15s.mp4",
                                                                                          type: "video/mp4", width: 1280, height: 720)])])
        let harness = show(RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, vast: vast, placement: .interstitial,
                                                    adSize: CGSize(width: 390, height: 844)), host: host)
        defer { harness.close() }
        // kit-vast's selector picks the offline MP4, so the sample plays: `loaded` first, never `.rendered` before a frame.
        let started = await Wait.until(timeout: .seconds(30)) { !host.events.isEmpty }
        #expect(started, "\(host.events)")
        #expect(host.events.first == .video(.loaded, adIndex: 0), "\(host.events)")
        #expect(!host.events.contains(.error(.noSupportedMedia, adIndex: 0)), "\(host.events)")
    }

    @Test func messagesNeedNoHostCalls() async throws {
        let host = RecordingHost()
        let harness = show(RendererFixtures.request(.none), host: host)
        defer { harness.close() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.events.isEmpty)
    }
}

@MainActor
@Suite("AdView script trackers (SwiftUI + WebKit)", .serialized)
struct AdViewScriptTrackerTests {
    @Test func trackersTheHostListsAreRunOnceThroughTheContract() async throws {
        let server = try LoopbackServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let host = RecordingHost()
        host.monitor.mode = .real
        let request = TrackerRequest(category: .impression, trigger: "impression (jstracker)", source: "bid 0.0 › native › jstracker",
                                     template: "", url: "<script>new Image().src = 'http://127.0.0.1:\(port)/js.gif';</script>", isScript: true)
        let tracker = ScriptTracker(entryID: host.monitor.dispatch(request, userAgent: "TestUA/1.0"), request: request)
        host.scriptTrackers = [tracker]
        let ad = NativeAd(assets: [NativeAsset(id: 1, content: .title(text: "Hello"))], link: AdLink(url: "https://adv.example/"))
        let renderRequest = RendererFixtures.request(.native("{}"), format: .native, native: ad, placement: .inFeed,
                                                     adSize: CGSize(width: 358, height: 200))
        let harness = WindowHarness(AdView(request: renderRequest, host: host), size: renderRequest.adSize)
        defer { harness.close() }
        let ran = await Wait.until(timeout: .seconds(20)) { host.monitor.entry(id: tracker.entryID)?.state == .completed(status: 200) }
        #expect(ran, "\(String(describing: host.monitor.entry(id: tracker.entryID)?.state))")
        #expect(await Wait.until { server.connectionCount == 1 })
    }
}

/// A VAST companion's URLs are in the ad's inline document, so its requests (the image, an HTML / iframe companion's own
/// loads) hang under the hop that delivered that document — the media's parent — not under the bid's markup request
/// (decisions.md, "Network relationships").
@MainActor
@Suite("Companion network parents (SwiftUI + WebKit)", .serialized)
struct CompanionNetworkParentTests {
    private func player(hop: UUID, companion: VASTCompanion, host: RecordingHost) -> VASTPlayerModel {
        var ad = RendererFixtures.linearAd(companions: [companion])
        ad.origin = [VASTAdOrigin(hop: 0, ad: 0)]
        let vast = ResolvedVAST(chain: [VASTHop(url: "https://ads.example/inline.xml", requestID: hop)], ads: [ad])
        let configuration = VASTPlayerConfiguration(placement: .interstitial, device: RendererFixtures.phone,
                                                    playerSize: CGSize(width: 390, height: 219), audioOnly: false, source: "bid 0.0 › VAST")
        return VASTPlayerModel(vast: vast, configuration: configuration, host: host, engine: FakeEngine(), chooseMedia: VASTMediaSelector.choose)
    }

    @Test func anImageCompanionIsFetchedUnderItsHop() async throws {
        let host = RecordingHost()
        let hop = UUID()
        let companion = VASTCompanion(id: "c", width: 300, height: 250,
                                      resources: [.staticResource(url: "ccinn-sample://image/companion.png", creativeType: "image/png")])
        let model = player(hop: hop, companion: companion, host: host)
        let choice = try #require(CompanionPicker.pick(model.items[0].companions, fitting: nil))
        let harness = WindowHarness(CompanionView(choice: choice, adIndex: 0, player: model, host: host, source: "bid 0.0 › VAST › ad 1 of 1"),
                                    size: CGSize(width: 300, height: 250))
        defer { harness.close() }
        let fetched = await Wait.until(timeout: .seconds(20)) {
            host.monitor.liveEntries.contains { $0.url == "ccinn-sample://image/companion.png" && $0.state == .completed(status: 200) }
        }
        #expect(fetched, "\(host.monitor.liveEntries.map(\.dumpLine))")
        let image = host.monitor.liveEntries.filter { $0.url == "ccinn-sample://image/companion.png" }
        #expect(image.count == 1 && image.allSatisfy { $0.parentID == hop }, "\(image.map(\.dumpLine))")
        #expect(host.events.contains(.companionView(adIndex: 0, companionIndex: 0)))
    }

    @Test func anHTMLCompanionsOwnRequestsHangUnderItsHop() async throws {
        let host = RecordingHost()
        let hop = UUID()
        let companion = VASTCompanion(id: "h", width: 300, height: 250, resources: [.html(#"<img src="https://pixel.example/companion.gif">"#)])
        let model = player(hop: hop, companion: companion, host: host)
        let choice = try #require(CompanionPicker.pick(model.items[0].companions, fitting: nil))
        let harness = WindowHarness(CompanionView(choice: choice, adIndex: 0, player: model, host: host, source: "bid 0.0 › VAST › ad 1 of 1"),
                                    size: CGSize(width: 300, height: 250))
        defer { harness.close() }
        let blocked = await Wait.until(timeout: .seconds(20)) {
            host.monitor.liveEntries.contains { $0.category == .creative && $0.url.hasPrefix("https://pixel.example/") }
        }
        #expect(blocked, "\(host.monitor.liveEntries.map(\.dumpLine))")
        let creative = host.monitor.liveEntries.filter { $0.category == .creative }
        #expect(!creative.isEmpty && creative.allSatisfy { $0.parentID == hop }, "\(creative.map(\.dumpLine))")
    }
}

/// VAST icons on screen (SwiftUI): the icon's image is fetched under the hop that delivered its document, and its
/// IconViewTracking fires once the image is shown.
@MainActor
@Suite("VAST icon view (SwiftUI)", .serialized)
struct VASTIconViewTests {
    @Test func theIconIsFetchedUnderItsHopAndViewedWhenShown() async throws {
        let host = RecordingHost()
        let hop = UUID()
        var ad = RendererFixtures.linearAd(duration: 10)
        ad.origin = [VASTAdOrigin(hop: 0, ad: 0)]
        ad.icons = [VASTIcon(program: "AdChoices", width: 40, height: 15, xPosition: .right, yPosition: .top,
                             resources: [.staticResource(url: "ccinn-sample://image/40x15.png", creativeType: "image/png")],
                             clickThrough: "https://privacy.example/")]
        let vast = ResolvedVAST(chain: [VASTHop(url: "https://ads.example/inline.xml", requestID: hop)], ads: [ad])
        let configuration = VASTPlayerConfiguration(placement: .interstitial, device: RendererFixtures.phone,
                                                    playerSize: CGSize(width: 390, height: 219), audioOnly: false, source: "bid 0.0 › VAST")
        let engine = FakeEngine()
        let model = VASTPlayerModel(vast: vast, configuration: configuration, host: host, engine: engine,
                                    chooseMedia: { files, _, _, _ in files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia) })
        model.start()
        #expect(await Wait.until { !engine.loaded.isEmpty })
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        let harness = WindowHarness(IconsOverlay(model: model, host: host, size: CGSize(width: 390, height: 219)), size: CGSize(width: 390, height: 219))
        defer { harness.close() }
        #expect(await Wait.until(timeout: .seconds(20)) { host.events.contains(.iconView(adIndex: 0, iconIndex: 0)) },
                "\(host.events) \(host.monitor.liveEntries.map(\.dumpLine))")
        let image = host.monitor.liveEntries.filter { $0.url == "ccinn-sample://image/40x15.png" }
        #expect(image.count == 1 && image.allSatisfy { $0.parentID == hop && $0.trigger == "VAST icon" }, "\(image.map(\.dumpLine))")
    }
}
