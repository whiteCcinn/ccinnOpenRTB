import SwiftUI

/// The container chrome of a full-screen display ad (HTML, image, Native): interstitials get a close button after
/// `FullscreenChromePolicy.interstitialCloseDelay`, rewarded ads a countdown before it. Inline placements get nothing.
/// A creative that uses MRAID custom close keeps an invisible 50 × 50 close region (MRAID: the container always provides one).
struct FullscreenChrome<Content: View>: View {
    let placement: Placement
    var customClose = false
    let isClosed: Bool
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var shownAt = Date()

    var body: some View {
        if isClosed {
            RendererMessageView(symbol: "xmark.circle", title: "Ad closed", detail: "Render again (⌘R) to show it again.")
        } else {
            content()
                .overlay(alignment: .topTrailing) {
                    if placement == .interstitial || placement == .rewarded {
                        TimelineView(.periodic(from: shownAt, by: 0.25)) { context in
                            ChromeControls(phase: FullscreenChromePolicy.phase(placement: placement,
                                                                                elapsed: context.date.timeIntervalSince(shownAt)),
                                           customClose: customClose, onClose: onClose)
                        }
                    }
                }
        }
    }
}

private struct ChromeControls: View {
    let phase: FullscreenChromePhase
    let customClose: Bool
    let onClose: () -> Void

    var body: some View {
        switch phase {
        case .none:
            EmptyView()
        case let .closeIn(seconds):
            pill("Close in \(seconds)")
        case let .rewardIn(seconds):
            pill("Reward in \(seconds) s", symbol: "gift")
        case .closable:
            if customClose {
                // The creative draws its own close control; the container's region stays tappable.
                Color.clear
                    .frame(width: 50, height: 50)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityLabel("Close ad")
                    .accessibilityAddTraits(.isButton)
            } else {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Close ad")
            }
        }
    }

    private func pill(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text).monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.6)))
        .padding(10)
    }
}
