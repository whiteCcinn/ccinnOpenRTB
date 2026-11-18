import AppKit
import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
import WebKit
@testable import CcinnOpenRTB

/// Writes a PNG of each renderer with synthetic input, for looking at them:
/// `CCINN_RENDERER_SNAPSHOTS=/path/to/dir swift test --filter RendererSnapshotTests`.
/// Video frames (AVPlayerLayer) and web content are drawn by other processes and appear black / blank in the SwiftUI
/// snapshots; the HTML creative has its own WebKit snapshot.
@MainActor
@Suite("Renderer snapshots", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CCINN_RENDERER_SNAPSHOTS"] != nil))
struct RendererSnapshotTests {
    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CCINN_RENDERER_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    private static let playSample: VASTMediaChooser = { files, _, _, _ in
        files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia)
    }

    private static let nativeAd = NativeAd(
        version: "1.2",
        assets: [
            NativeAsset(id: 1, content: .title(text: "Ccinn Racing — the fastest kart game on your phone")),
            NativeAsset(id: 2, content: .image(url: SampleURL.image("icon"), width: 80, height: 80, type: .icon)),
            NativeAsset(id: 3, content: .image(url: SampleURL.image("main"), width: 1200, height: 627, type: .main)),
            NativeAsset(id: 4, content: .data(value: "Ccinn Games", label: nil, type: .sponsored)),
            NativeAsset(id: 5, content: .data(value: "Race friends online, unlock 40 tracks and build your dream kart.", label: nil,
                                              type: .description)),
            NativeAsset(id: 6, content: .data(value: "4.6", label: nil, type: .rating)),
            NativeAsset(id: 7, content: .data(value: "Free", label: nil, type: .price)),
            NativeAsset(id: 8, content: .data(value: "Install", label: nil, type: .callToAction)),
            NativeAsset(id: 9, content: .data(value: "10M+ downloads", label: nil, type: .downloads)),
        ],
        link: AdLink(url: "https://adv.example/"), privacyURL: "https://privacy.example/")

    private func snapshot(_ name: String, _ request: RenderRequest, host: RecordingHost, settle: Duration = .seconds(2),
                          view: AnyView? = nil) async throws {
        let harness = WindowHarness(view ?? AnyView(AdView(request: request, host: host)), size: request.adSize)
        defer { harness.close() }
        try await Task.sleep(for: settle)
        try write(harness.hosting, name: name)
        let html = harness.hosting.subviews(of: WKWebView.self).first
        if let html {
            let image = try await html.takeSnapshot(configuration: nil)
            try writePNG(image, name: name + "-webview")
        }
    }

    private func write(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try save(bitmap, name: name)
    }

    private func writePNG(_ image: NSImage, name: String) throws {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try save(bitmap, name: name)
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: Self.directory.appendingPathComponent(name + ".png"))
    }

    private func host(_ device: DeviceProfile = RendererFixtures.phone) -> RecordingHost {
        let host = RecordingHost(device: device)
        host.fetchesThroughMonitor = true
        return host
    }

    @Test func native() async throws {
        try await snapshot("native-app-install", RendererFixtures.request(.native("{}"), format: .native, native: Self.nativeAd, placement: .inFeed,
                                                                           adSize: CGSize(width: 358, height: 330)), host: host())
        var stream = Self.nativeAd
        stream.assets.removeAll { [6, 7, 9].contains($0.id) }
        stream.assets.removeAll { $0.id == 8 }
        stream.assets.append(NativeAsset(id: 8, content: .data(value: "Learn more", label: nil, type: .callToAction)))
        try await snapshot("native-in-feed", RendererFixtures.request(.native("{}"), format: .native, native: stream, placement: .inFeed,
                                                                       adSize: CGSize(width: 358, height: 330)), host: host())
        try await snapshot("native-content-stream", RendererFixtures.request(.native("{}"), format: .native, native: stream,
                                                                              placement: .interstitial, adSize: CGSize(width: 390, height: 763)),
                           host: host())
    }

    @Test func imageBanners() async throws {
        try await snapshot("image-banner", RendererFixtures.request(.image(ImageBanner(imageURL: SampleURL.image("banner"))),
                                                                     adSize: CGSize(width: 320, height: 50)), host: host())
        try await snapshot("image-rewarded", RendererFixtures.request(.image(ImageBanner(imageURL: SampleURL.image("interstitial"))),
                                                                       placement: .rewarded, adSize: CGSize(width: 390, height: 763)),
                           host: host())
    }

    @Test func html() async throws {
        let adm = """
        <div style="font:600 15px -apple-system;color:#fff;background:linear-gradient(90deg,#0e7490,#22d3ee);height:50px;display:flex;\
        align-items:center;justify-content:center">MRAID <span id="v"></span>&nbsp;banner</div>
        <script>document.getElementById('v').textContent = mraid.getVersion();</script>
        """
        try await snapshot("html-banner", RendererFixtures.request(.html(adm), adSize: CGSize(width: 320, height: 50)), host: host())
    }

    @Test func video() async throws {
        let companion = VASTCompanion(width: 300, height: 250, resources: [.staticResource(url: SampleURL.image("companion"), creativeType: "image/png")],
                                      clickThrough: "https://adv.example/companion")
        let first = RendererFixtures.linearAd(duration: 15, media: [VASTMediaFile(url: SampleURL.video, type: "video/mp4", width: 1280, height: 720)],
                                              skipOffset: .seconds(5), companions: [companion], sequence: 1)
        let second = RendererFixtures.linearAd(duration: 15, media: [VASTMediaFile(url: SampleURL.video, type: "video/mp4", width: 1280, height: 720)],
                                               sequence: 2)
        let pod = ResolvedVAST(ads: [first, second])
        for (name, device, placement, size) in [
            ("video-interstitial", RendererFixtures.phone, Placement.interstitial, CGSize(width: 390, height: 763)),
            ("video-in-feed", RendererFixtures.phone, Placement.inFeed, CGSize(width: 358, height: 201)),
            ("video-ctv", RendererFixtures.tv, Placement.ctvInstream, CGSize(width: 1920, height: 1080)),
        ] {
            let request = RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, vast: pod, device: device, placement: placement,
                                                   adSize: size)
            let recording = host(device)
            let view = AnyView(VASTPlayerView(vast: pod, request: request, host: recording, role: .ad(audioOnly: false), chooseMedia: Self.playSample))
            try await snapshot(name, request, host: recording, settle: .seconds(4), view: view)
        }
        let audio = ResolvedVAST(ads: [RendererFixtures.linearAd(duration: 15, media: [VASTMediaFile(url: SampleURL.audio, type: "audio/mp4")],
                                                                 companions: [companion])])
        let request = RendererFixtures.request(.vast(.xml("<VAST/>")), format: .audio, vast: audio, placement: .inFeed,
                                               adSize: CGSize(width: 358, height: 330))
        let recording = host()
        try await snapshot("audio", request, host: recording, settle: .seconds(4),
                           view: AnyView(VASTPlayerView(vast: audio, request: request, host: recording, role: .ad(audioOnly: true),
                                                        chooseMedia: Self.playSample)))
    }
}

private extension NSView {
    func subviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? $0.subviews(of: type) }
    }
}
