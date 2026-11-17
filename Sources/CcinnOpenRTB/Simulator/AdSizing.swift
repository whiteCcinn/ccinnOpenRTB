import CoreGraphics
import RTBKit

/// `RenderRequest.adSize`: the ad's area in points inside the device screen (pure).
///
/// - Interstitial, rewarded and CTV instream cover the screen in use (both screens and the hinge when a dual-screen
///   device spans); renderers keep their own chrome inside `device.safeArea`.
/// - Inline banners use the bid size (`w`×`h`), scaled down proportionally — never up — when it is wider (or taller)
///   than the safe area of the screen.
/// - In-feed ads sit in the feed column (screen width minus the feed padding, capped on wide screens). Native ads take the
///   column width with a nominal card height (1.91:1 main image plus title, text and call to action); video without a
///   size is 16:9.
enum AdSizing {
    static let feedHorizontalPadding: CGFloat = 12
    static let maximumFeedColumnWidth: CGFloat = 600
    /// Native card height above and below the 1.91:1 main image (header, title, description, call to action).
    static let nativeCardChromeHeight: CGFloat = 132
    static let audioCardHeight: CGFloat = 120
    static let maximumDefaultVideoWidth: CGFloat = 640
    static let defaultBanner = CGSize(width: 320, height: 50)
    static let defaultFeedBanner = CGSize(width: 300, height: 250)

    static func adSize(bidSize: AdSize?, format: AdFormat, placement: Placement, layout: ScreenLayout) -> CGSize {
        let content = layout.contentFrame.size
        if placement.isFullScreen { return content }

        let insets = layout.safeArea
        var availableWidth = content.width - CGFloat(insets.leading + insets.trailing)
        if placement == .inFeed {
            availableWidth = min(availableWidth - feedHorizontalPadding * 2, maximumFeedColumnWidth)
        }
        availableWidth = max(1, availableWidth)
        let availableHeight = max(1, content.height - CGFloat(insets.top + insets.bottom))

        let natural: CGSize
        if format == .native {
            natural = CGSize(width: availableWidth, height: (availableWidth / 1.91).rounded() + nativeCardChromeHeight)
        } else if let bidSize, bidSize.width > 0, bidSize.height > 0 {
            natural = CGSize(width: bidSize.width, height: bidSize.height)
        } else {
            natural = defaultSize(for: format, placement: placement, availableWidth: availableWidth)
        }
        return fit(natural, within: CGSize(width: availableWidth, height: availableHeight))
    }

    private static func defaultSize(for format: AdFormat, placement: Placement, availableWidth: CGFloat) -> CGSize {
        switch format {
        case .banner, .native:
            return placement == .inFeed ? defaultFeedBanner : defaultBanner
        case .video:
            let width = placement == .inFeed ? availableWidth : min(availableWidth, maximumDefaultVideoWidth)
            return CGSize(width: width, height: (width * 9 / 16).rounded())
        case .audio:
            return CGSize(width: availableWidth, height: audioCardHeight)
        }
    }

    /// Scales `size` down (never up) to fit `bounds`, keeping its aspect ratio; whole points, at least 1×1.
    static func fit(_ size: CGSize, within bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}
