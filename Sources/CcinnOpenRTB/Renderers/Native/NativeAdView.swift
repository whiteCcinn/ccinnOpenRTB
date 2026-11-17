import RTBKit
import SwiftUI

/// A Native ad in one of the three layouts (design D5): in-feed card, content stream, app install.
struct NativeAdView: View {
    let ad: NativeAd
    let request: RenderRequest
    let host: any AdRenderingHost

    @State private var model: NativeAdModel?

    var body: some View {
        ZStack {
            if let model {
                FullscreenChrome(placement: request.placement, isClosed: model.isClosed, onClose: model.close) {
                    NativeLayoutView(model: model, request: request, host: host)
                }
            }
        }
        .task(id: request.generation) {
            let active = model ?? NativeAdModel(ad: ad, request: request, host: host)
            model = active
            active.appeared()
            async let images: Void = active.loadImages()
            async let video: Void = active.resolveVideo()
            _ = await (images, video)
        }
    }
}

private struct NativeLayoutView: View {
    let model: NativeAdModel
    let request: RenderRequest
    let host: any AdRenderingHost

    private var content: NativeAdContent { model.content }

    static let fullscreenChromeInset: CGFloat = 50

    var body: some View {
        Group {
            switch model.layout {
            case .inFeedCard: inFeedCard
            case .contentStream: contentStream
            case .appInstall: appInstall
            }
        }
        .padding(10)
        // Full screen: centred, and clear of the container's close control (top right), so AdChoices stays reachable.
        .padding(.top, request.isFullscreen ? Self.fullscreenChromeInset : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: request.isFullscreen ? .center : .top)
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.click(assetID: nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Native ad")
    }

    // MARK: Layouts

    private var inFeedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                imageAsset(content.icon, size: 36, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    title(lines: 2)
                    sponsoredLine
                }
                Spacer(minLength: 4)
                adChoices
            }
            textAsset(content.body, font: .system(size: 12), lines: 3)
            media
            HStack {
                textAsset(content.displayURL, font: .system(size: 11), lines: 1, secondary: true)
                Spacer(minLength: 4)
                callToAction(fallback: nil)
            }
        }
    }

    private var contentStream: some View {
        VStack(alignment: .leading, spacing: 6) {
            media
                .overlay(alignment: .topTrailing) { adChoices.padding(4) }
            title(lines: 2)
            textAsset(content.body, font: .system(size: 12), lines: 2)
            HStack {
                sponsoredLine
                Spacer(minLength: 4)
                callToAction(fallback: nil)
            }
        }
    }

    private var appInstall: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                imageAsset(content.icon, size: 56, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    title(lines: 2)
                    HStack(spacing: 6) {
                        if let rating = content.rating { StarRating(value: rating) }
                        textAsset(content.downloads, font: .system(size: 11), lines: 1, secondary: true)
                    }
                    HStack(spacing: 6) {
                        textAsset(content.salePrice, font: .system(size: 12, weight: .semibold), lines: 1)
                        textAsset(content.price, font: .system(size: 11), lines: 1, secondary: true,
                                  strikethrough: content.salePrice != nil)
                    }
                    sponsoredLine
                }
                Spacer(minLength: 4)
                adChoices
            }
            if content.mainImage != nil || content.video != nil { media }
            textAsset(content.body, font: .system(size: 12), lines: 2)
            callToAction(fallback: "Install", fullWidth: true)
        }
    }

    // MARK: Pieces

    @ViewBuilder private func title(lines: Int) -> some View {
        textAsset(content.title, font: .system(size: 14, weight: .semibold), lines: lines)
    }

    private var sponsoredLine: some View {
        HStack(spacing: 4) {
            Text("Ad")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color.yellow))
                .foregroundStyle(.black)
            if let sponsored = content.sponsored {
                tappable(sponsored.assetID) {
                    Text(sponsored.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Sponsored").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var adChoices: some View {
        if model.ad.privacyURL?.isEmpty == false {
            Button(action: model.openPrivacy) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("AdChoices")
            .accessibilityLabel("AdChoices")
        }
    }

    @ViewBuilder private var media: some View {
        switch model.video {
        case let .ready(vast):
            if let item = content.video {
                GeometryReader { proxy in
                    VASTPlayerView(vast: vast, request: request, host: host, role: .nativeVideo(assetID: item.assetID), playerSize: proxy.size)
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .resolving:
            ZStack {
                Color.black
                ProgressView().controlSize(.small).tint(.white)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .none, .unavailable:
            if let main = content.mainImage {
                tappable(main.assetID) {
                    RemoteImageView(state: model.image(main) ?? .loading, contentMode: .fill)
                        .aspectRatio(Self.aspect(main), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder private func imageAsset(_ item: NativeImageItem?, size: CGFloat, cornerRadius: CGFloat) -> some View {
        if let item {
            tappable(item.assetID) {
                RemoteImageView(state: model.image(item) ?? .loading, contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
        }
    }

    @ViewBuilder private func textAsset(_ item: NativeTextItem?, font: Font, lines: Int, secondary: Bool = false,
                                        strikethrough: Bool = false) -> some View {
        if let item {
            tappable(item.assetID) {
                Text(item.text)
                    .font(font)
                    .strikethrough(strikethrough)
                    .foregroundStyle(secondary ? Color.secondary : Color.primary)
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder private func callToAction(fallback: String?, fullWidth: Bool = false) -> some View {
        if let cta = content.callToAction {
            ctaButton(cta.text, fullWidth: fullWidth) { model.click(assetID: cta.assetID) }
        } else if let fallback {
            // The layout's own button (an app-install template always has one): a click on the ad.
            ctaButton(fallback, fullWidth: fullWidth) { model.click(assetID: nil) }
        }
    }

    private func ctaButton(_ text: String, fullWidth: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent))
        }
        .buttonStyle(.plain)
    }

    private func tappable(_ assetID: Int, @ViewBuilder _ label: () -> some View) -> some View {
        label()
            .contentShape(Rectangle())
            .onTapGesture { model.click(assetID: assetID) }
    }

    static func aspect(_ item: NativeImageItem) -> CGFloat {
        guard let width = item.width, let height = item.height, width > 0, height > 0 else { return 1.91 }
        return min(4, max(0.5, CGFloat(width) / CGFloat(height)))
    }
}

private struct StarRating: View {
    let value: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                let fill = value - Double(index)
                Image(systemName: fill >= 0.75 ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            Text(String(format: "%.1f", value)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "Rated %.1f of 5", value))
    }
}
