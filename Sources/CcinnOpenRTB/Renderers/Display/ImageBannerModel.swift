import Foundation
import Observation
import RTBKit

/// An OpenRTB 3.0 / AdCOM `display.banner` (an image and a link): the image is fetched as content; `.rendered` once it is
/// shown; a click reports `.click(assetID: nil)`, whose tracking plan fires the link's `trkr` and records the navigation;
/// the full-screen chrome's close reports `.closed` once.
@MainActor
@Observable
final class ImageBannerModel {
    private(set) var image: RemoteImageState = .loading
    private(set) var isClosed = false

    @ObservationIgnored private weak var host: (any AdRenderingHost)?
    @ObservationIgnored private var loadedURL: String?
    @ObservationIgnored private var renderedReported = false

    init(host: any AdRenderingHost) {
        self.host = host
    }

    func load(_ banner: ImageBanner, request: RenderRequest) async {
        guard let host, loadedURL != banner.imageURL else { return }
        loadedURL = banner.imageURL
        image = .loading
        let state = await RemoteImageLoader.load(banner.imageURL, host: host, trigger: "banner image",
                                                 source: request.sourceRoot + " › display.banner.img")
        guard loadedURL == banner.imageURL else { return }
        image = state
        switch state {
        case .loaded:
            if !renderedReported {
                renderedReported = true
                host.report(.rendered)
            }
        case let .failed(message):
            host.rendererLog(RendererLogEntry(.display, .error, "The banner image did not load: \(message)"))
        case .loading:
            break
        }
    }

    func click(_ banner: ImageBanner, request: RenderRequest) {
        guard let host, image.image != nil, !isClosed else { return }
        guard request.allowsClickThrough else {
            host.rendererLog(RendererLogEntry(.display, .info, "Click ignored: click-through is disabled on this device"))
            return
        }
        if banner.link == nil {
            host.rendererLog(RendererLogEntry(.display, .warning, "The banner has no link: the click has no destination"))
        }
        host.report(.click(assetID: nil))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        host?.report(.closed)
    }
}
