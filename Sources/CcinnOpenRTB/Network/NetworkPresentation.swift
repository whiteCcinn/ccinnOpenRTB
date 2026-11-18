import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// What the Network window shows about a request and the session, as plain values the views draw (and tests check).
enum NetworkPresentation {
    /// The category cell. Content (VAST tags and wrappers, media, images, markup) is fetched to render the ad in every
    /// mode; it is no tracker, so it gets a badge of its own that no tracker category resembles.
    struct CategoryLabel: Equatable {
        var text: String
        var systemImage: String
        var category: TrackerCategory
        var isContent: Bool
        var help: String
    }

    static func categoryBadge(for entry: NetworkEntry) -> CategoryLabel {
        if entry.category == .content {
            return CategoryLabel(text: "CONTENT", systemImage: "shippingbox", category: .content, isContent: true,
                                 help: "Content: fetched to render the ad in Simulated and Real mode, recorded and not sent when Offline (not a tracker)")
        }
        return CategoryLabel(text: Theme.label(for: entry.category), systemImage: Theme.icon(for: entry.category), category: entry.category,
                             isContent: false, help: help(for: entry.category))
    }

    private static func help(for category: TrackerCategory) -> String {
        if category.isTracker { return "Tracker: sent only in Real mode" }
        if category == .bidRequest { return "Bid request: sent from the Client tab in Simulated and Real mode, recorded and not sent when Offline" }
        return Theme.label(for: category)
    }

    /// The session's network state, for the window's subtitle and status bar.
    struct Session: Equatable {
        var title: String
        var subtitle: String
        var systemImage: String
        var delivery: NetworkDelivery
    }

    static func session(mode: TrackingMode, offline: Bool) -> Session {
        if offline {
            return Session(title: "Offline", subtitle: "Offline — trackers and remote content are recorded, not sent", systemImage: Theme.icon(for: .offline),
                           delivery: .offline)
        }
        return switch mode {
        case .real: Session(title: "Real", subtitle: "Real mode — trackers are sent", systemImage: "antenna.radiowaves.left.and.right", delivery: .network)
        case .simulated: Session(title: "Simulated", subtitle: "Simulated mode — trackers are recorded, not sent", systemImage: "circle.dashed",
                                 delivery: .simulated)
        }
    }

    /// Whether the headers shown are the ones that went over the wire: reported by the transport ("as sent"), the ones a
    /// request is being or was set up with when the wire never reported (a failed connection; the media entry, whose
    /// requests are its children), or the ones a request never sent would have had.
    static func requestHeadersTitle(for entry: NetworkEntry) -> String {
        if entry.requestHeadersAsSent { return "Request Headers (as sent)" }
        guard entry.delivery == .network else { return "Request Headers (not sent)" }
        return entry.state == .pending ? "Request Headers (to be sent)" : "Request Headers (planned)"
    }
}

/// The category cell: the CONTENT badge for content, the category's badge for everything else.
struct RequestCategoryBadge: View {
    let entry: NetworkEntry

    var body: some View {
        let badge = NetworkPresentation.categoryBadge(for: entry)
        Group {
            if badge.isContent {
                ContentBadge(text: badge.text, systemImage: badge.systemImage)
            } else {
                CategoryBadge(category: entry.category)
            }
        }
        .help(badge.help)
    }
}

/// Solid, so it never reads as one of the tinted tracker categories.
private struct ContentBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).imageScale(.small)
            Text(text).tracking(0.4)
        }
        .font(.caption2.weight(.bold))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(Color(nsColor: .textBackgroundColor))
        .background(Theme.color(for: .content), in: Capsule())
        .fixedSize()
    }
}
