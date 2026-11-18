import RTBKit
import SwiftUI

/// Picks the renderer for a request (`RendererKind`) and runs the Real-mode script trackers the host lists.
struct RendererRoot: View {
    let request: RenderRequest
    let host: any AdRenderingHost

    var body: some View {
        content
            .environment(\.minimumTouchTarget, TouchTarget.minimumSide(for: request.device))
            .scriptTrackers(host: host)
    }

    @ViewBuilder private var content: some View {
        switch RendererKind.resolve(request) {
        case let .html(markup):
            HTMLAdView(markup: markup, request: request, host: host)
        case let .image(banner):
            ImageBannerView(banner: banner, request: request, host: host)
        case let .native(ad):
            NativeAdView(ad: ad, request: request, host: host)
        case let .video(vast):
            VASTPlayerView(vast: vast, request: request, host: host, role: .ad(audioOnly: false))
        case let .audio(vast):
            VASTPlayerView(vast: vast, request: request, host: host, role: .ad(audioOnly: true))
        case let .message(title, detail):
            RendererMessageView(symbol: "rectangle.dashed", title: title, detail: detail)
        }
    }
}

/// A renderer's own state message (nothing to draw, a load failure, a closed ad): in the simulator's text area (never
/// under a hinge) and at its text scale (the 10-foot UI on a CTV).
struct RendererMessageView: View {
    let symbol: String
    let title: String
    var detail: String?

    @Environment(\.simulatorTextScale) private var scale

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 90
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.08))
                Group {
                    if compact {
                        HStack(spacing: 6) {
                            Image(systemName: symbol)
                            Text(title).fontWeight(.semibold).lineLimit(1)
                            if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .font(.system(size: 11 * scale))
                        .padding(.horizontal, 6)
                    } else {
                        VStack(spacing: 6 * scale) {
                            Image(systemName: symbol).font(.system(size: 22 * scale, weight: .semibold))
                            Text(title).font(.system(size: 13 * scale, weight: .semibold)).multilineTextAlignment(.center)
                            if let detail {
                                Text(detail).font(.system(size: 11 * scale)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12 * scale)
                    }
                }
                .simulatorStatusPlacement()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .combine)
    }
}

extension RenderRequest {
    /// `bid 0.0`, the root of every network source path the renderers write.
    var sourceRoot: String { "bid \(candidate.id)" }

    /// Click-throughs exist on this device (not on CTV).
    var allowsClickThrough: Bool { device.supportsClickThrough && device.family != .ctv && placement != .ctvInstream }

    var isFullscreen: Bool { placement == .interstitial || placement == .rewarded }
}
