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

/// Parses a Native object (`{"ver", "assets"}`) into its assets, with the parser's issues. The single seam to kit-openrtb's
/// asset parsing: the default is `NativeParser.parse`; tests may inject another.
typealias NativeAssetsParser = @Sendable (_ nativeJSON: String) -> (assets: [NativeAsset]?, issues: [ValidationIssue])

/// The Native 1.2 `assetsurl` response (§5.1: it mirrors the `assets` array of the bid response).
enum NativeAssetsDocument {
    enum Failure: Error, Equatable, LocalizedError {
        case notJSON
        case noAssetsArray
        case emptyAssets

        var errorDescription: String? {
            switch self {
            case .notJSON: "The assetsurl response is not JSON."
            case .noAssetsArray: "The assetsurl response has no assets array."
            case .emptyAssets: "The assetsurl response has no assets."
            }
        }
    }

    static let defaultParser: NativeAssetsParser = { json in
        let parsed = NativeParser.parse(json)
        return (parsed.ad?.assets, parsed.issues)
    }

    /// The response as a Native object the asset parser reads. Accepts `{"assets": […]}` (the spec's shape),
    /// `{"native": {"assets": […]}}` and a bare `[…]`.
    static func nativeJSON(from data: Data, version: String?) -> Result<String, Failure> {
        guard !data.isEmpty, let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .failure(.notJSON)
        }
        let assets: [Any]?
        switch value {
        case let array as [Any]:
            assets = array
        case let object as [String: Any]:
            assets = (object["assets"] as? [Any]) ?? ((object["native"] as? [String: Any])?["assets"] as? [Any])
        default:
            assets = nil
        }
        guard let assets else { return .failure(.noAssetsArray) }
        guard !assets.isEmpty else { return .failure(.emptyAssets) }
        let document: [String: Any] = ["ver": version ?? "1.2", "assets": assets]
        guard JSONSerialization.isValidJSONObject(document),
              let encoded = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return .failure(.notJSON) }
        return .success(text)
    }
}

/// One Native ad on screen: `.rendered` once when it appears with its assets (imptrackers, eventtrackers 1); asset clicks
/// `.click(assetID:)` (the tracking plan fires the asset's then the ad's clicktrackers and records the navigation);
/// AdChoices opens the privacy URL (a navigation, not an ad click); images are fetched as content; the video asset's VAST
/// is resolved by the host (`resolveVAST`, so its events map to it) and plays in a nested player.
///
/// Native 1.2 `assetsurl`: when the response has no inline assets, they are fetched as content and parsed with the Native
/// asset parsing; the ad renders (and reports `.rendered`) once they arrive, or shows the error. Inline assets win.
/// `dcourl` (DCO, beta) is not fetched.
@MainActor
@Observable
final class NativeAdModel {
    enum AssetsState: Equatable {
        case loading, ready
        case failed(String)
    }

    enum VideoState: Equatable {
        case none
        case resolving
        case ready(ResolvedVAST)
        /// Not playable; the layout falls back to the main image.
        case unavailable(String)
    }

    private(set) var content: NativeAdContent
    private(set) var layout: NativeLayoutKind
    private(set) var assets: AssetsState
    private(set) var images: [Int: RemoteImageState] = [:]
    private(set) var video: VideoState = .none
    private(set) var isClosed = false

    @ObservationIgnored private(set) var ad: NativeAd
    @ObservationIgnored private weak var host: (any AdRenderingHost)?
    @ObservationIgnored private let source: String
    @ObservationIgnored private let placement: Placement
    @ObservationIgnored private let allowsClickThrough: Bool
    @ObservationIgnored private let parseAssets: NativeAssetsParser
    @ObservationIgnored private var renderedReported = false
    @ObservationIgnored private var hasAppeared = false
    @ObservationIgnored private var assetsRequested = false
    @ObservationIgnored private var imagesRequested = false
    @ObservationIgnored private var videoRequested = false

    init(ad: NativeAd, request: RenderRequest, host: any AdRenderingHost, parseAssets: @escaping NativeAssetsParser = NativeAssetsDocument.defaultParser) {
        self.ad = ad
        self.host = host
        self.parseAssets = parseAssets
        let initialContent = NativeAdContent(ad: ad)
        content = initialContent
        layout = NativeLayoutKind.choose(placement: request.placement, content: initialContent)
        placement = request.placement
        source = request.sourceRoot + " › native"
        allowsClickThrough = request.allowsClickThrough
        let assetsURL = Self.nonBlank(ad.assetsURL)
        let waitsForAssets = ad.assets.isEmpty && assetsURL != nil
        assets = waitsForAssets ? .loading : .ready
        if let assetsURL, !ad.assets.isEmpty {
            log(.info, "assetsurl \(assetsURL) is not fetched: the response has inline assets, which win")
        }
        if let dcoURL = Self.nonBlank(ad.dcoURL) {
            log(.info, "dcourl \(dcoURL) (dynamic creative, beta in Native 1.2) is not supported and is not fetched")
        }
        if !waitsForAssets { describeContent() }
    }

    /// The ad is on screen: `.rendered` once its assets are there.
    func appeared() {
        hasAppeared = true
        reportRenderedIfReady()
    }

    /// Fetches the `assetsurl` assets when the response has none inline (once).
    func loadAssets() async {
        guard assets == .loading, !assetsRequested, let host, let url = Self.nonBlank(ad.assetsURL) else { return }
        assetsRequested = true
        let data: Data
        do {
            data = try await host.fetchContent(url, trigger: "Native assetsurl", source: source + " › assetsurl")
        } catch {
            failAssets("The assetsurl \(url) did not load: \(error.localizedDescription)")
            return
        }
        let json: String
        switch NativeAssetsDocument.nativeJSON(from: data, version: ad.version) {
        case let .success(text): json = text
        case let .failure(failure):
            failAssets("The assetsurl \(url) response is not usable: \(failure.localizedDescription)")
            return
        }
        let parsed = parseAssets(json)
        // Only the assets' own issues: the wrapper is synthetic (no link, trackers), so anything else is not the DSP's.
        for issue in parsed.issues.filter({ $0.path == "/assets" || $0.path.hasPrefix("/assets/") }).prefix(20) {
            let level: RendererLogEntry.Level = switch issue.severity {
            case .error: .error
            case .warning: .warning
            case .info: .info
            }
            log(level, "assetsurl \(issue.path): \(issue.message)")
        }
        guard let fetched = parsed.assets, !fetched.isEmpty else {
            failAssets("The assetsurl \(url) response has no renderable asset")
            return
        }
        ad.assets = fetched
        content = NativeAdContent(ad: ad)
        layout = NativeLayoutKind.choose(placement: placement, content: content)
        assets = .ready
        log(.info, "\(fetched.count) assets from assetsurl \(url)")
        describeContent()
        reportRenderedIfReady()
    }

    private func failAssets(_ message: String) {
        assets = .failed(message)
        log(.error, message)
    }

    private func reportRenderedIfReady() {
        guard hasAppeared, assets == .ready, !renderedReported, !isClosed else { return }
        renderedReported = true
        host?.report(.rendered)
    }

    private func describeContent() {
        let inferred = content.inferredAssetIDs
        if !inferred.isEmpty {
            log(.info, "Asset slots inferred (no type in the response or request): \(inferred.map(String.init).joined(separator: ", "))")
        }
        log(.info, "Layout: \(layout.rawValue)")
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func loadImages() async {
        guard assets == .ready, !imagesRequested, let host else { return }
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
        guard assets == .ready, !videoRequested, let item = content.video, let host else { return }
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
