import RTBKit
import SwiftUI

struct ImageBannerView: View {
    let banner: ImageBanner
    let request: RenderRequest
    let host: any AdRenderingHost

    @State private var model: ImageBannerModel?

    var body: some View {
        ZStack {
            if let model {
                FullscreenChrome(placement: request.placement, isClosed: model.isClosed, onClose: model.close) {
                    ZStack {
                        if request.isFullscreen { Color.black }
                        RemoteImageView(state: model.image)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.click(banner, request: request) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Banner ad")
                }
            }
        }
        .task(id: banner.imageURL) {
            let active = model ?? ImageBannerModel(host: host)
            model = active
            await active.load(banner, request: request)
        }
    }
}
