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
        // With kit-vast's selector the sample plays (`loaded` first); with the placeholder selector it is error 403.
        let started = await Wait.until(timeout: .seconds(30)) {
            host.events.first == .video(.loaded, adIndex: 0) || host.events.first == .error(.noSupportedMedia, adIndex: 0)
        }
        #expect(started, "\(host.events)")
        #expect(host.events.first != .rendered)
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
