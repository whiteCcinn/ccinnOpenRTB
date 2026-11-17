import CcinnOpenRTBKit
import Foundation
import Observation
import RTBKit

extension NativeVideoItem {
    /// The asset's `vasttag` as a VAST source: markup when it is XML, a tag URL when it is one (http(s), `data:`, samples).
    var vastSource: VASTSource {
        let trimmed = vastTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { return .xml(trimmed) }
        if let scheme = URLText.scheme(trimmed)?.lowercased(), ["http", "https", "data", SampleURL.scheme].contains(scheme),
           !trimmed.contains(where: \.isWhitespace) {
            return .url(trimmed)
        }
        return .xml(trimmed)
    }
}

/// One Native ad on screen: `.rendered` once when it appears (imptrackers, eventtrackers 1); asset clicks
/// `.click(assetID:)` (the tracking plan fires the asset's then the ad's clicktrackers and records the navigation);
/// AdChoices opens the privacy URL (a navigation, not an ad click); images are fetched as content; the video asset's VAST
/// is resolved by the host (`resolveVAST`, so its events map to it) and plays in a nested player.
@MainActor
@Observable
final class NativeAdModel {
    enum VideoState: Equatable {
        case none
        case resolving
        case ready(ResolvedVAST)
        /// Not playable; the layout falls back to the main image.
        case unavailable(String)
    }

    let content: NativeAdContent
    let layout: NativeLayoutKind
    private(set) var images: [Int: RemoteImageState] = [:]
    private(set) var video: VideoState = .none
    private(set) var isClosed = false

    @ObservationIgnored let ad: NativeAd
    @ObservationIgnored private weak var host: (any AdRenderingHost)?
    @ObservationIgnored private let source: String
    @ObservationIgnored private let allowsClickThrough: Bool
    @ObservationIgnored private var renderedReported = false
    @ObservationIgnored private var imagesRequested = false
    @ObservationIgnored private var videoRequested = false

    init(ad: NativeAd, request: RenderRequest, host: any AdRenderingHost) {
        self.ad = ad
        self.host = host
        content = NativeAdContent(ad: ad)
        layout = NativeLayoutKind.choose(placement: request.placement, content: content)
        source = request.sourceRoot + " › native"
        allowsClickThrough = request.allowsClickThrough
        let inferred = content.inferredAssetIDs
        if !inferred.isEmpty {
            log(.info, "Asset slots inferred (no type in the response or request): \(inferred.map(String.init).joined(separator: ", "))")
        }
        log(.info, "Layout: \(layout.rawValue)")
    }

    /// The ad is on screen.
    func appeared() {
        guard !renderedReported, !isClosed else { return }
        renderedReported = true
        host?.report(.rendered)
    }

    func loadImages() async {
        guard !imagesRequested, let host else { return }
        imagesRequested = true
        let slots: [(NativeImageItem, String)] = [(content.icon, "icon"), (content.mainImage, "main image"), (content.logo, "logo")]
            .compactMap { item, name in item.map { ($0, name) } }
        for (item, _) in slots { images[item.assetID] = .loading }
        // At most three images (icon, main, logo), in layout order.
        for (item, name) in slots {
            let state = await RemoteImageLoader.load(item.url, host: host, trigger: "native \(name)",
                                                     source: source + " › asset \(item.assetID) (\(name))")
            images[item.assetID] = state
            if case let .failed(message) = state { log(.warning, "Image asset \(item.assetID) did not load: \(message)") }
        }
    }

    func resolveVideo() async {
        guard !videoRequested, let item = content.video, let host else { return }
        videoRequested = true
        video = .resolving
        let resolved = await host.resolveVAST(item.vastSource)
        if resolved.ads.isEmpty {
            let reason = resolved.failure.map { "VAST error \($0.rawValue)" } ?? "the VAST has no ad"
            log(.warning, "Video asset \(item.assetID) is not playable (\(reason)); showing the main image")
            video = .unavailable(reason)
        } else {
            video = .ready(resolved)
        }
    }

    func click(assetID: Int?) {
        guard !isClosed else { return }
        guard allowsClickThrough else {
            log(.info, "Click ignored: click-through is disabled on this device")
            return
        }
        host?.report(.click(assetID: assetID))
    }

    /// AdChoices: the privacy notice opens; it is not a click on the ad.
    func openPrivacy() {
        guard let url = ad.privacyURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
        guard allowsClickThrough else {
            log(.info, "AdChoices: click-through is disabled on this device")
            return
        }
        host?.navigate(to: url, trigger: "AdChoices (privacy)", source: source + " › privacy")
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        host?.report(.closed)
    }

    func image(_ item: NativeImageItem?) -> RemoteImageState? {
        item.flatMap { images[$0.assetID] }
    }

    private func log(_ level: RendererLogEntry.Level, _ message: String) {
        host?.rendererLog(RendererLogEntry(.native, level, message))
    }
}
