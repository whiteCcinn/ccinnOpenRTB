import CoreGraphics
import RTBKit

/// The mock in-feed app laid out in points (pure): an app bar, posts, the ad after the second post, and enough posts
/// below for the ad to scroll fully out at the top. `offset` is the feed's scroll position; the ad's visible fraction
/// follows from it, and the viewability slider maps a fraction back to an offset.
struct FeedGeometry: Equatable {
    static let appBarHeight: CGFloat = 52
    static let tabBarHeight: CGFloat = 50
    static let spacing: CGFloat = 12
    /// Mock post heights, repeated.
    static let postHeights: [CGFloat] = [276, 212, 248]
    static let postsAboveAd = 2
    /// Caption above display ads in the feed ("Advertisement"); Native ads label themselves.
    static let adCaptionHeight: CGFloat = 18
    /// Margin kept above the ad when the slider asks for 100%.
    static let revealMargin: CGFloat = 12

    struct Item: Equatable {
        enum Kind: Equatable { case post(Int), ad }
        var kind: Kind
        var frame: CGRect
    }

    /// The scrolling area inside `ScreenLayout.contentFrame` (below the app bar, above the tab bar).
    let viewport: CGRect
    let columnWidth: CGFloat
    /// Items in feed coordinates (y = 0 at the top of the scrolled content).
    let items: [Item]
    /// The ad's slot (ad plus caption) in feed coordinates.
    let adSlot: CGRect
    /// The ad itself in feed coordinates.
    let adFrame: CGRect
    let contentHeight: CGFloat

    init(layout: ScreenLayout, adSize: CGSize, captioned: Bool) {
        let content = layout.contentFrame.size
        let insets = layout.safeArea
        let top = CGFloat(insets.top) + Self.appBarHeight
        let bottom = CGFloat(insets.bottom) + Self.tabBarHeight
        viewport = CGRect(x: CGFloat(insets.leading), y: top, width: max(1, content.width - CGFloat(insets.leading + insets.trailing)),
                          height: max(1, content.height - top - bottom))
        columnWidth = max(1, min(viewport.width - AdSizing.feedHorizontalPadding * 2, AdSizing.maximumFeedColumnWidth))

        var items: [Item] = []
        var y = Self.spacing
        for index in 0..<Self.postsAboveAd {
            let height = Self.postHeights[index % Self.postHeights.count]
            items.append(Item(kind: .post(index), frame: CGRect(x: 0, y: y, width: columnWidth, height: height)))
            y += height + Self.spacing
        }
        let caption = captioned ? Self.adCaptionHeight : 0
        let adHeight = max(1, adSize.height)
        adSlot = CGRect(x: 0, y: y, width: columnWidth, height: caption + adHeight)
        adFrame = CGRect(x: max(0, (columnWidth - adSize.width) / 2), y: y + caption, width: adSize.width, height: adHeight)
        items.append(Item(kind: .ad, frame: adSlot))
        y += adSlot.height + Self.spacing
        var index = Self.postsAboveAd
        // Enough below the ad to scroll it out at the top (and at least three posts).
        while y < adFrame.maxY + viewport.height || index < Self.postsAboveAd + 3 {
            let height = Self.postHeights[index % Self.postHeights.count]
            items.append(Item(kind: .post(index), frame: CGRect(x: 0, y: y, width: columnWidth, height: height)))
            y += height + Self.spacing
            index += 1
        }
        self.items = items
        contentHeight = y
    }

    var maxOffset: CGFloat { max(0, contentHeight - viewport.height) }

    func clamped(_ offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return 0 }
        return min(maxOffset, max(0, offset))
    }

    /// The fraction of the ad's height inside the viewport at `offset`.
    func visibleFraction(offset: CGFloat) -> Double {
        let top = adFrame.minY - clamped(offset)
        let bottom = top + adFrame.height
        let visible = max(0, min(bottom, viewport.height) - max(top, 0))
        return Double(min(1, max(0, visible / adFrame.height)))
    }

    /// The offset that shows `fraction` of the ad: the ad scrolled up past the top edge by the rest; 100% keeps a
    /// margin above it (or leaves the feed at the top when the ad is already fully visible there).
    func offset(forVisibleFraction fraction: Double) -> CGFloat {
        let fraction = fraction.isFinite ? min(1, max(0, fraction)) : 1
        if fraction >= ViewabilityTracker.fullyVisible {
            if adFrame.maxY <= viewport.height { return 0 }
            return clamped(adSlot.minY - Self.revealMargin)
        }
        return clamped(adFrame.minY + CGFloat(1 - fraction) * adFrame.height)
    }
}
