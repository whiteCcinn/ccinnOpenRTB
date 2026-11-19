import Foundation

// Tracking lifecycle and request contracts (design D7, D9).

/// What a request is for. Trackers can be simulated; content is always fetched; creative requests are the HTML
/// creative's own network; a bid request is one the user composed and sent from the Client tab, a user sync one the Sync
/// tab ran (a cookie-sync chain).
public enum TrackerCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case win, billing, loss, impression, viewability, event, click, navigation, error, verification
    case content, creative
    case bidRequest
    case userSync

    /// Trackers obey the Simulated / Real mode.
    public var isTracker: Bool {
        switch self {
        case .win, .billing, .loss, .impression, .viewability, .event, .click, .error, .verification: true
        case .content, .creative, .navigation, .bidRequest, .userSync: false
        }
    }
}

/// Viewability thresholds (MRC).
public enum ViewabilityLevel: String, Sendable, Hashable, Codable {
    /// 50% of pixels for 1 s (display) – Native event 2, AdCOM 3.
    case mrc50
    /// 100% of pixels for 1 s – Native event 3, AdCOM 4.
    case mrc100
    /// 50% for 2 s of playback – Native event 4, AdCOM 5 (VAST uses `.videoViewability`).
    case video50
}

/// Something that happened to the ad (driven by the creative, the player or the user's controls).
public enum AdLifecycleEvent: Sendable, Hashable {
    /// The auction was won (exchange sends the win notice).
    case won
    /// The ad was rendered: billing notice (`burl`), AdCOM events 1 (loaded) and 2 (impression), Native impression trackers.
    /// VAST impressions are NOT part of this event: they fire per pod ad with `.video(.creativeView, adIndex:)`.
    case rendered
    /// Display / Native viewability (Native eventtrackers 2–4, AdCOM events 3–5).
    case viewable(ViewabilityLevel)
    /// VAST `ViewableImpression` outcome for pod ad `adIndex`.
    case videoViewability(VideoViewability, adIndex: Int)
    /// A VAST player event for the ad at `adIndex` in the resolved pod (0 for single ads). `.creativeView` (first frame of
    /// that ad) also fires the ad's Impression URLs (impressions first) and its `verificationNotExecuted` trackers.
    case video(VASTEvent, adIndex: Int)
    /// A VAST companion was shown. `companionIndex` indexes `ads[adIndex].inline.creatives.flatMap(\.companions)`.
    case companionView(adIndex: Int, companionIndex: Int)
    /// A VAST companion was clicked (its CompanionClickTracking, then navigation to CompanionClickThrough).
    case companionClick(adIndex: Int, companionIndex: Int)
    /// A VAST industry icon (e.g. AdChoices) was shown: its IconViewTracking. `iconIndex` indexes `ads[adIndex].icons`
    /// (wrapper icons first, then the inline ad's).
    case iconView(adIndex: Int, iconIndex: Int)
    /// A VAST icon was clicked: its IconClickTracking, then a navigation to IconClickThrough (none on CTV).
    case iconClick(adIndex: Int, iconIndex: Int)
    /// A click on a display / Native ad: on a Native asset (`assetID`) or on the ad (`nil`).
    case click(assetID: Int?)
    /// A click on VAST pod ad `adIndex` (ClickTracking, then navigation to ClickThrough).
    case videoClick(adIndex: Int)
    case closed
    /// The bid lost; `reason` is the OpenRTB loss reason code.
    case loss(reason: Int)
    /// A VAST error for the ad at `adIndex` (or the whole chain when `nil`).
    case error(VASTErrorCode, adIndex: Int?)
}

/// VAST `ViewableImpression` outcomes.
public enum VideoViewability: String, Sendable, Hashable, Codable {
    case viewable, notViewable, undetermined
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
    /// List-valued macros (VAST 4.1/4.2 §6.1 `Array<T>`, e.g. `[BLOCKEDADCATEGORIES]`, `[UNIVERSALADID]`, `[VASTVERSIONS]`), keyed
    /// like `custom`. The expander percent-encodes each item on its own and joins them with literal commas
    /// (`abc%2Fdef,y%3Dz`). An entry here wins over the same key in `custom`.
    public var customLists: [String: [String]]

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
    /// VAST 4.1 §6.2 `[BREAKPOSITION]`: where the ad break sits in the content. `simulatorDefaults` sets it from the
    /// placement (an instream break on CTV is a pre-roll; mobile placements without content are standalone). A
    /// `custom["[BREAKPOSITION]"]` value overrides it; without either, it comes from `contentPlayhead`, else -1.
    public var breakPosition: VASTBreakPosition?
    /// VAST 4.1 §6.2 `[ADCOUNT]`: the number of ads in the pod or buffet that will play. `VASTTrackingPlan` sets it from
    /// the resolved VAST; `nil`: unknown (-1), e.g. in a VAST request URI.
    public var adCount: Int?

    public init(auctionID: String? = nil, bidID: String? = nil, impID: String? = nil, seatID: String? = nil, adID: String? = nil,
                price: Double? = nil, encryptedPrice: String? = nil, currency: String? = nil, marketBidRatio: Double? = nil,
                lossReason: Int? = nil, minimumToWin: Double? = nil, custom: [String: String] = [:], customLists: [String: [String]] = [:],
                errorCode: Int? = nil,
                adPlayhead: Double? = nil, contentPlayhead: Double? = nil, assetURI: String? = nil, playerWidth: Int? = nil,
                playerHeight: Int? = nil, reason: Int? = nil, timestamp: Date? = nil, cacheBuster: String? = nil, device: DeviceProfile? = nil,
                breakPosition: VASTBreakPosition? = nil, adCount: Int? = nil) {
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
        self.customLists = customLists
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
        self.breakPosition = breakPosition
        self.adCount = adCount
    }
}

/// VAST 4.1 §6.2 `[BREAKPOSITION]` values: "the position of the ad break within the underlying video content that the ad
/// is playing within".
public enum VASTBreakPosition: Int, Sendable, Hashable, CaseIterable {
    case preroll = 1, midroll = 2, postroll = 3
    /// No content: the ad plays on its own (outstream, in-feed, interstitial).
    case standalone = 4
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
