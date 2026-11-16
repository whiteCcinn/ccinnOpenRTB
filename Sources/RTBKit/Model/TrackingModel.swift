import Foundation

// Tracking lifecycle and request contracts (design D7, D9).

/// What a request is for. Trackers can be simulated; content is always fetched; creative requests are the HTML
/// creative's own network.
public enum TrackerCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case win, billing, loss, impression, viewability, event, click, navigation, error, verification
    case content, creative

    /// Trackers obey the Simulated / Real mode.
    public var isTracker: Bool {
        switch self {
        case .content, .creative, .navigation: false
        default: true
        }
    }
}

/// Viewability thresholds (MRC).
public enum ViewabilityLevel: String, Sendable, Hashable, Codable {
    /// 50% of pixels for 1 s (display) – Native event 2, AdCOM 2.
    case mrc50
    /// 100% of pixels for 1 s – Native event 3, AdCOM 3.
    case mrc100
    /// 50% for 2 s of playback – Native event 4, AdCOM 4, VAST ViewableImpression.
    case video50
}

/// Something that happened to the ad (driven by the creative, the player or the user's controls).
public enum AdLifecycleEvent: Sendable, Hashable {
    /// The auction was won (exchange sends the win notice).
    case won
    /// The ad was rendered: billing notice and impression trackers.
    case rendered
    case viewable(ViewabilityLevel)
    /// The ad was not viewable / viewability undetermined (VAST ViewableImpression).
    case notViewable
    case viewUndetermined
    /// A VAST player event for the ad at `adIndex` in the resolved pod (0 for single ads).
    case video(VASTEvent, adIndex: Int)
    /// A click, on a Native asset (`assetID`) or on the ad/player (`nil`).
    case click(assetID: Int?)
    case closed
    /// The bid lost; `reason` is the OpenRTB loss reason code.
    case loss(reason: Int)
    /// A VAST error for the ad at `adIndex` (or the whole chain when `nil`).
    case error(VASTErrorCode, adIndex: Int?)
}

/// One request the simulator wants to make (not yet dispatched).
public struct TrackerRequest: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var parentID: UUID?
    public var category: TrackerCategory
    /// Short trigger label: "win", "impression", "VAST firstQuartile", "click", "loss (102)".
    public var trigger: String
    /// Where the URL came from: "bid 0.0 › VAST wrapper 1 › inline 'Acme' › creative 1 › TrackingEvents".
    public var source: String
    /// The URL as written in the markup.
    public var template: String
    /// The URL with macros expanded.
    public var url: String
    public var replacedMacros: [String]
    public var unknownMacros: [String]
    /// Script trackers (Native `jstracker`, method 2) are recorded, and injected only in Real mode.
    public var isScript: Bool

    public init(id: UUID = UUID(), parentID: UUID? = nil, category: TrackerCategory, trigger: String, source: String, template: String,
                url: String, replacedMacros: [String] = [], unknownMacros: [String] = [], isScript: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.category = category
        self.trigger = trigger
        self.source = source
        self.template = template
        self.url = url
        self.replacedMacros = replacedMacros
        self.unknownMacros = unknownMacros
        self.isScript = isScript
    }
}

/// Values for OpenRTB and VAST macro substitution (design D4).
public struct MacroContext: Sendable, Hashable {
    public var auctionID: String?
    public var bidID: String?
    public var impID: String?
    public var seatID: String?
    public var adID: String?
    /// Clearing price (defaults to the bid price).
    public var price: Double?
    /// Opaque encrypted price substituted verbatim for `${AUCTION_PRICE}` when set.
    public var encryptedPrice: String?
    public var currency: String?
    public var marketBidRatio: Double?
    public var lossReason: Int?
    public var minimumToWin: Double?
    public var custom: [String: String]

    // VAST
    public var errorCode: Int?
    /// Playhead in seconds.
    public var adPlayhead: Double?
    public var contentPlayhead: Double?
    public var assetURI: String?
    public var playerWidth: Int?
    public var playerHeight: Int?
    public var reason: Int?
    /// Fixed timestamp for deterministic tests; `nil` = now.
    public var timestamp: Date?
    /// Fixed cache-buster for deterministic tests; `nil` = random 8 digits.
    public var cacheBuster: String?
    public var device: DeviceProfile?

    public init(auctionID: String? = nil, bidID: String? = nil, impID: String? = nil, seatID: String? = nil, adID: String? = nil,
                price: Double? = nil, encryptedPrice: String? = nil, currency: String? = nil, marketBidRatio: Double? = nil,
                lossReason: Int? = nil, minimumToWin: Double? = nil, custom: [String: String] = [:], errorCode: Int? = nil,
                adPlayhead: Double? = nil, contentPlayhead: Double? = nil, assetURI: String? = nil, playerWidth: Int? = nil,
                playerHeight: Int? = nil, reason: Int? = nil, timestamp: Date? = nil, cacheBuster: String? = nil, device: DeviceProfile? = nil) {
        self.auctionID = auctionID
        self.bidID = bidID
        self.impID = impID
        self.seatID = seatID
        self.adID = adID
        self.price = price
        self.encryptedPrice = encryptedPrice
        self.currency = currency
        self.marketBidRatio = marketBidRatio
        self.lossReason = lossReason
        self.minimumToWin = minimumToWin
        self.custom = custom
        self.errorCode = errorCode
        self.adPlayhead = adPlayhead
        self.contentPlayhead = contentPlayhead
        self.assetURI = assetURI
        self.playerWidth = playerWidth
        self.playerHeight = playerHeight
        self.reason = reason
        self.timestamp = timestamp
        self.cacheBuster = cacheBuster
        self.device = device
    }
}

/// A URL after macro expansion.
public struct ExpandedURL: Sendable, Hashable {
    public var url: String
    public var replaced: [String]
    public var unknown: [String]

    public init(url: String, replaced: [String] = [], unknown: [String] = []) {
        self.url = url
        self.replaced = replaced
        self.unknown = unknown
    }
}
