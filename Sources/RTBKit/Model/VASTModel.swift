import Foundation

// VAST 2.0 – 4.2 model (design D6).

/// A time offset in a linear ad (`skipoffset`, `progress` offsets).
public enum VASTOffset: Sendable, Hashable {
    case seconds(Double)
    /// 0–100.
    case percent(Double)

    /// The offset in seconds for an ad of `duration` seconds.
    public func seconds(inAdOf duration: Double) -> Double {
        switch self {
        case let .seconds(value): value
        case let .percent(value): duration * value / 100
        }
    }
}

/// Tracking events a VAST player reports.
public enum VASTEvent: Sendable, Hashable {
    case creativeView, start, firstQuartile, midpoint, thirdQuartile, complete
    case mute, unmute, pause, resume, rewind, skip
    case playerExpand, playerCollapse, fullscreen, exitFullscreen
    case closeLinear, close, acceptInvitation, acceptInvitationLinear
    case loaded, notUsed, otherAdInteraction, interactiveStart, timeSpentViewing
    case progress(VASTOffset)
    /// Any event name this model does not know, kept verbatim.
    case other(String)

    /// Events that fire at most once per ad (all except `progress` and user interactions).
    public var firesOnce: Bool {
        switch self {
        case .creativeView, .start, .firstQuartile, .midpoint, .thirdQuartile, .complete, .skip, .closeLinear, .close, .loaded, .notUsed:
            true
        default:
            false
        }
    }
}

public struct VASTTracking: Sendable, Hashable {
    public var event: VASTEvent
    public var url: String

    public init(event: VASTEvent, url: String) {
        self.event = event
        self.url = url
    }
}

public struct VASTMediaFile: Sendable, Hashable {
    public var url: String
    /// `progressive` / `streaming`.
    public var delivery: String?
    /// MIME type, e.g. `video/mp4`, `application/x-mpegURL`, `audio/mpeg`.
    public var type: String?
    public var width: Int?
    public var height: Int?
    public var bitrate: Int?
    public var minBitrate: Int?
    public var maxBitrate: Int?
    public var codec: String?
    /// `VPAID`, … (never run by the simulator: no supported media file, error 403).
    public var apiFramework: String?
    public var scalable: Bool?
    public var maintainAspectRatio: Bool?

    public init(url: String, delivery: String? = nil, type: String? = nil, width: Int? = nil, height: Int? = nil, bitrate: Int? = nil,
                minBitrate: Int? = nil, maxBitrate: Int? = nil, codec: String? = nil, apiFramework: String? = nil,
                scalable: Bool? = nil, maintainAspectRatio: Bool? = nil) {
        self.url = url
        self.delivery = delivery
        self.type = type
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.minBitrate = minBitrate
        self.maxBitrate = maxBitrate
        self.codec = codec
        self.apiFramework = apiFramework
        self.scalable = scalable
        self.maintainAspectRatio = maintainAspectRatio
    }
}

public struct VASTLinear: Sendable, Hashable {
    /// `Duration` in seconds (absent in wrappers).
    public var duration: Double?
    public var skipOffset: VASTOffset?
    public var mediaFiles: [VASTMediaFile]
    public var trackingEvents: [VASTTracking]
    public var clickThrough: String?
    public var clickTrackings: [String]
    public var customClicks: [String]
    public var adParameters: String?
    /// VAST 3.0+ `Icons/Icon` (industry icons such as AdChoices), in document order.
    public var icons: [VASTIcon]

    public init(duration: Double? = nil, skipOffset: VASTOffset? = nil, mediaFiles: [VASTMediaFile] = [], trackingEvents: [VASTTracking] = [],
                clickThrough: String? = nil, clickTrackings: [String] = [], customClicks: [String] = [], adParameters: String? = nil,
                icons: [VASTIcon] = []) {
        self.icons = icons
        self.duration = duration
        self.skipOffset = skipOffset
        self.mediaFiles = mediaFiles
        self.trackingEvents = trackingEvents
        self.clickThrough = clickThrough
        self.clickTrackings = clickTrackings
        self.customClicks = customClicks
        self.adParameters = adParameters
    }
}

/// VAST 3.0+ industry icon (VAST 4.1 `Linear/Icons/Icon`, e.g. AdChoices): an overlay the player draws on the linear ad,
/// with its own view and click tracking.
public struct VASTIcon: Sendable, Hashable {
    /// `xPosition`: `left`, `right`, or pixels from the left edge.
    public enum HorizontalPosition: Sendable, Hashable {
        case left, right
        case pixels(Int)
    }

    /// `yPosition`: `top`, `bottom`, or pixels from the top edge.
    public enum VerticalPosition: Sendable, Hashable {
        case top, bottom
        case pixels(Int)
    }

    /// The industry initiative the icon represents (`AdChoices`, …).
    public var program: String?
    /// Pixels.
    public var width: Int?
    public var height: Int?
    public var xPosition: HorizontalPosition?
    public var yPosition: VerticalPosition?
    /// Seconds the icon stays on screen; `nil`: as long as the ad.
    public var duration: Double?
    /// Seconds after the ad starts before the icon shows; `nil`: from the start.
    public var offset: Double?
    public var apiFramework: String?
    /// VAST 4.1 `pxratio`: the pixel ratio the icon was designed for.
    public var pixelRatio: Double?
    /// `StaticResource` / `IFrameResource` / `HTMLResource`, in document order.
    public var resources: [VASTCompanion.Resource]
    /// `IconClicks/IconClickThrough`.
    public var clickThrough: String?
    /// `IconClicks/IconClickTracking`.
    public var clickTrackings: [String]
    /// `IconViewTracking`: fired when the icon is shown.
    public var viewTrackings: [String]

    public init(program: String? = nil, width: Int? = nil, height: Int? = nil, xPosition: HorizontalPosition? = nil,
                yPosition: VerticalPosition? = nil, duration: Double? = nil, offset: Double? = nil, apiFramework: String? = nil,
                pixelRatio: Double? = nil, resources: [VASTCompanion.Resource] = [], clickThrough: String? = nil, clickTrackings: [String] = [],
                viewTrackings: [String] = []) {
        self.program = program
        self.width = width
        self.height = height
        self.xPosition = xPosition
        self.yPosition = yPosition
        self.duration = duration
        self.offset = offset
        self.apiFramework = apiFramework
        self.pixelRatio = pixelRatio
        self.resources = resources
        self.clickThrough = clickThrough
        self.clickTrackings = clickTrackings
        self.viewTrackings = viewTrackings
    }
}

public struct VASTCompanion: Sendable, Hashable {
    public enum Resource: Sendable, Hashable {
        case staticResource(url: String, creativeType: String?)
        case iframe(url: String)
        case html(String)
    }

    public var id: String?
    public var width: Int?
    public var height: Int?
    public var resources: [Resource]
    public var clickThrough: String?
    public var clickTrackings: [String]
    /// Usually `creativeView`.
    public var trackingEvents: [VASTTracking]

    public init(id: String? = nil, width: Int? = nil, height: Int? = nil, resources: [Resource] = [], clickThrough: String? = nil,
                clickTrackings: [String] = [], trackingEvents: [VASTTracking] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.resources = resources
        self.clickThrough = clickThrough
        self.clickTrackings = clickTrackings
        self.trackingEvents = trackingEvents
    }
}

public struct VASTCreative: Sendable, Hashable {
    public var id: String?
    public var adID: String?
    public var sequence: Int?
    public var linear: VASTLinear?
    public var companions: [VASTCompanion]
    /// Present when the creative is NonLinear (rendered as an overlay note, not played).
    public var hasNonLinear: Bool
    /// VAST 4.0+ `UniversalAdId` elements (one in 4.0 / 4.1, several from 4.2), in document order.
    public var universalAdIDs: [VASTUniversalAdID]
    /// VAST 3.0+ `CompanionAds@required` (VAST 4.1 §3.13.1); `.none`, the spec's default, when absent.
    public var companionsRequired: VASTCompanionRequirement

    public init(id: String? = nil, adID: String? = nil, sequence: Int? = nil, linear: VASTLinear? = nil, companions: [VASTCompanion] = [],
                hasNonLinear: Bool = false, universalAdIDs: [VASTUniversalAdID] = [], companionsRequired: VASTCompanionRequirement = .none) {
        self.id = id
        self.adID = adID
        self.sequence = sequence
        self.linear = linear
        self.companions = companions
        self.hasNonLinear = hasNonLinear
        self.universalAdIDs = universalAdIDs
        self.companionsRequired = companionsRequired
    }
}

/// VAST 3.0+ `CompanionAds@required` (VAST 4.1 §3.13.1): which of the creative's companions the player must display for
/// the ad to play.
public enum VASTCompanionRequirement: String, Sendable, Hashable, CaseIterable {
    /// "the player must attempt to display the contents for all <Companion> elements provided; if all Companion creative
    /// cannot be displayed, the player should not display the ad".
    case all
    /// "the player must attempt to display content from at least one of the <Companion> elements provided … if none of the
    /// Companion creative can be displayed, the player should not display the ad".
    case any
    /// "the player may choose to not display any of the Companion creative" — the default when the attribute is absent.
    case none
}

/// VAST 4.0+ `Creative/UniversalAdId` (VAST 4.1 / 4.2 §3.7.1): the creative's identifier in a registry such as Ad-ID.
public struct VASTUniversalAdID: Sendable, Hashable {
    /// `idRegistry`; "unknown" when absent (the spec's default).
    public var registry: String
    /// The element's content, which is the source of truth from VAST 4.1. Falls back to VAST 4.0's `idValue` attribute,
    /// then to "unknown" (the spec's default).
    public var value: String

    public init(registry: String = "unknown", value: String = "unknown") {
        self.registry = registry
        self.value = value
    }
}

/// VAST 4.1 `AdVerifications/Verification` (or 3.0 `Extensions` equivalent).
public struct VASTVerification: Sendable, Hashable {
    public var vendor: String?
    public var javaScriptResource: String?
    public var parameters: String?
    /// `verificationNotExecuted` trackers.
    public var trackingEvents: [VASTTracking]

    public init(vendor: String? = nil, javaScriptResource: String? = nil, parameters: String? = nil, trackingEvents: [VASTTracking] = []) {
        self.vendor = vendor
        self.javaScriptResource = javaScriptResource
        self.parameters = parameters
        self.trackingEvents = trackingEvents
    }
}

/// VAST 4.x `ViewableImpression`.
public struct VASTViewableImpression: Sendable, Hashable {
    public var viewable: [String]
    public var notViewable: [String]
    public var viewUndetermined: [String]

    public init(viewable: [String] = [], notViewable: [String] = [], viewUndetermined: [String] = []) {
        self.viewable = viewable
        self.notViewable = notViewable
        self.viewUndetermined = viewUndetermined
    }
}

public struct VASTInline: Sendable, Hashable {
    public var adSystem: String?
    public var adTitle: String?
    public var impressions: [String]
    public var errors: [String]
    public var creatives: [VASTCreative]
    public var viewableImpression: VASTViewableImpression?
    public var verifications: [VASTVerification]
    /// VAST 4.1+ `AdServingId` (§3.4.3): the ad server's pseudo-unique id for this ad, for `[ADSERVINGID]`.
    public var adServingID: String?
    /// VAST 4.0+ `Category` elements (§3.4.5): the ad content's categories.
    public var categories: [VASTCategory]

    public init(adSystem: String? = nil, adTitle: String? = nil, impressions: [String] = [], errors: [String] = [],
                creatives: [VASTCreative] = [], viewableImpression: VASTViewableImpression? = nil, verifications: [VASTVerification] = [],
                adServingID: String? = nil, categories: [VASTCategory] = []) {
        self.adSystem = adSystem
        self.adTitle = adTitle
        self.impressions = impressions
        self.errors = errors
        self.creatives = creatives
        self.viewableImpression = viewableImpression
        self.verifications = verifications
        self.adServingID = adServingID
        self.categories = categories
    }
}

/// VAST 4.0+ `InLine/Category` (VAST 4.1 / 4.2 §3.4.5): an ad content category code, and the list it comes from.
public struct VASTCategory: Sendable, Hashable {
    /// The category code or label (e.g. `232` in the IAB Ad Product Taxonomy).
    public var code: String
    /// `authority`: the URL of the organisation that maintains the list. Required whenever categories are given.
    public var authority: String?

    public init(code: String, authority: String? = nil) {
        self.code = code
        self.authority = authority
    }
}

public struct VASTWrapper: Sendable, Hashable {
    public var adTagURI: String
    public var impressions: [String]
    public var errors: [String]
    /// Tracking-only creatives (their events and click trackings are merged into the inline ad).
    public var creatives: [VASTCreative]
    public var viewableImpression: VASTViewableImpression?
    public var verifications: [VASTVerification]
    public var followAdditionalWrappers: Bool
    public var allowMultipleAds: Bool
    public var fallbackOnNoAd: Bool
    /// VAST 4.1 `BlockedAdCategories` (§3.19.2): categories the wrapper does not accept from below, one entry per code
    /// (an element may list several, comma-separated), with that element's `authority`.
    public var blockedAdCategories: [VASTCategory]

    public init(adTagURI: String, impressions: [String] = [], errors: [String] = [], creatives: [VASTCreative] = [],
                viewableImpression: VASTViewableImpression? = nil, verifications: [VASTVerification] = [],
                followAdditionalWrappers: Bool = true, allowMultipleAds: Bool = false, fallbackOnNoAd: Bool = false,
                blockedAdCategories: [VASTCategory] = []) {
        self.blockedAdCategories = blockedAdCategories
        self.adTagURI = adTagURI
        self.impressions = impressions
        self.errors = errors
        self.creatives = creatives
        self.viewableImpression = viewableImpression
        self.verifications = verifications
        self.followAdditionalWrappers = followAdditionalWrappers
        self.allowMultipleAds = allowMultipleAds
        self.fallbackOnNoAd = fallbackOnNoAd
    }
}

public struct VASTAd: Sendable, Hashable {
    public enum Body: Sendable, Hashable {
        case inline(VASTInline)
        case wrapper(VASTWrapper)
    }

    public var id: String?
    /// Position in an ad pod; `nil` = stand-alone / buffet.
    public var sequence: Int?
    public var body: Body
    /// VAST 4.1+ `adType` attribute (§3.3.2): `video`, `audio` or `hybrid`, as written; `nil` when absent (the spec then
    /// assumes `video`).
    public var adType: String?

    public init(id: String? = nil, sequence: Int? = nil, body: Body, adType: String? = nil) {
        self.id = id
        self.sequence = sequence
        self.body = body
        self.adType = adType
    }
}

public struct VASTDocument: Sendable, Hashable {
    /// Declared `version` attribute.
    public var version: String?
    public var ads: [VASTAd]
    /// Root-level `<Error>` URLs (no-ad responses).
    public var errors: [String]

    public init(version: String? = nil, ads: [VASTAd] = [], errors: [String] = []) {
        self.version = version
        self.ads = ads
        self.errors = errors
    }
}

/// VAST error codes (VAST 4.1 §2.3.6.3, VAST 4.2 error table).
public enum VASTErrorCode: Int, Sendable, Hashable, CaseIterable {
    case xmlParsing = 100, schemaValidation = 101, unsupportedVersion = 102
    case traffickingError = 200, unexpectedLinearity = 201, unexpectedDuration = 202, unexpectedSize = 203
    /// 204 "Ad category was required but not provided."
    case adCategoryRequired = 204
    /// 205 "Inline Category violates Wrapper BlockedAdCategories (refer 3.19.2)."
    case blockedAdCategory = 205
    /// 206 "Ad Break shortened. Ad was not served."
    case adBreakShortened = 206
    case wrapperError = 300, wrapperTimeout = 301, wrapperLimit = 302, noAdsAfterWrapper = 303, inlineResponseTimeout = 304
    case linearError = 400, fileNotFound = 401, mediaTimeout = 402, noSupportedMedia = 403, mediaDisplayProblem = 405
    case mezzanineRequired = 406, mezzanineDownloading = 407, conditionalAdRejected = 408
    case interactiveCreativeError = 409, codeResourceError = 410
    case nonLinearError = 500
    /// 501 "Unable to display NonLinearAd because creative dimensions do not align with creative display area (i.e.
    /// creative dimension too large)."
    case nonLinearDimensions = 501
    /// 502 "Unable to fetch NonLinearAds/NonLinear resource."
    case nonLinearResourceUnavailable = 502
    /// 503 "Couldn't find NonLinear resource with supported type."
    case nonLinearResourceUnsupported = 503
    case companionError = 600
    /// 601 "Unable to display Companion because creative dimensions do not fit within Companion display area (i.e., no
    /// available space)."
    case companionDimensions = 601
    /// 602 "Unable to display Required Companion."
    case requiredCompanionUnavailable = 602
    /// 603 "Unable to fetch CompanionAds/Companion resource."
    case companionResourceUnavailable = 603
    /// 604 "Couldn't find Companion resource with supported type."
    case companionResourceUnsupported = 604
    case undefinedError = 900, vpaidError = 901
}

/// Where an ad came from: `hop` indexes `ResolvedVAST.chain`, `ad` indexes that hop's `document.ads`.
public struct VASTAdOrigin: Sendable, Hashable {
    public var hop: Int
    public var ad: Int

    public init(hop: Int, ad: Int) {
        self.hop = hop
        self.ad = ad
    }
}

/// One hop of a wrapper chain.
public struct VASTHop: Sendable, Hashable {
    /// The URL actually requested: `template` with its VAST `[…]` macros expanded when the resolver has a macro context
    /// (VAST 4.1 §6.1/§6.2); `nil` for the document the bid carried inline.
    public var url: String?
    /// The request URI as written (the `VASTAdTagURI`, or the pasted / `curl` tag URL), before macro expansion; `nil` for
    /// the document the bid carried inline.
    public var template: String?
    public var document: VASTDocument?
    public var error: VASTErrorCode?
    /// The fetcher's request id (network monitor entry); `nil` for markup carried in the bid.
    public var requestID: UUID?
    /// The wrapper ad whose `VASTAdTagURI` produced this hop; `nil` for the first hop.
    public var parent: VASTAdOrigin?

    public init(url: String? = nil, document: VASTDocument? = nil, error: VASTErrorCode? = nil, requestID: UUID? = nil,
                parent: VASTAdOrigin? = nil, template: String? = nil) {
        self.url = url
        self.template = template
        self.document = document
        self.error = error
        self.requestID = requestID
        self.parent = parent
    }
}

/// A failure that did not stop playback (a pod slot or buffet ad that could not be resolved). Its Error URLs are fired
/// once after resolution (`VASTTrackingPlan.resolutionRequests`).
public struct VASTAdFailure: Sendable, Hashable {
    public var code: VASTErrorCode
    public var errorURLs: [String]
    /// Outermost wrapper first.
    public var origin: [VASTAdOrigin]

    public init(code: VASTErrorCode, errorURLs: [String] = [], origin: [VASTAdOrigin] = []) {
        self.code = code
        self.errorURLs = errorURLs
        self.origin = origin
    }
}

/// An inline ad with every tracker of the wrappers above it merged in (wrapper trackers first, in chain order).
///
/// The merged lists are computed views. An ad the resolver produced shares its wrappers' trackers with every other ad
/// below the same wrapper (one copy per document layer, not per ad), so a wrapper whose response is a large pod costs
/// memory linear in the input. Reading a list builds it; setting one gives this ad its own copy of every list.
public struct ResolvedVASTAd: Sendable, Hashable {
    public var inline: VASTInline
    public var sequence: Int?
    /// The documents this ad passed through: outermost wrapper first, the inline ad last.
    public var origin: [VASTAdOrigin]
    private var trackers: VASTMergedTrackers

    /// Impression URLs of all wrappers and the inline ad.
    public var impressions: [String] {
        get { trackers.collect(\.impressions) }
        set { trackers.modify { $0.impressions = newValue } }
    }

    /// Error URLs of all wrappers and the inline ad.
    public var errors: [String] {
        get { trackers.collect(\.errors) }
        set { trackers.modify { $0.errors = newValue } }
    }

    /// Per inline linear creative: all tracking events (wrappers + inline).
    public var trackingEvents: [VASTTracking] {
        get { trackers.collect(\.trackingEvents) }
        set { trackers.modify { $0.trackingEvents = newValue } }
    }

    /// ClickTracking of all wrappers and the inline ad.
    public var clickTrackings: [String] {
        get { trackers.collect(\.clickTrackings) }
        set { trackers.modify { $0.clickTrackings = newValue } }
    }

    public var viewableImpression: VASTViewableImpression {
        get { trackers.viewableImpression }
        set { trackers.modify { $0.viewableImpression = newValue } }
    }

    public var verifications: [VASTVerification] {
        get { trackers.collect(\.verifications) }
        set { trackers.modify { $0.verifications = newValue } }
    }

    /// The icons of the played Linear of all wrappers and the inline ad (`.iconView` / `.iconClick` index this list).
    public var icons: [VASTIcon] {
        get { trackers.collect(\.icons) }
        set { trackers.modify { $0.icons = newValue } }
    }

    public init(inline: VASTInline, sequence: Int? = nil, impressions: [String] = [], errors: [String] = [], trackingEvents: [VASTTracking] = [],
                clickTrackings: [String] = [], viewableImpression: VASTViewableImpression = VASTViewableImpression(),
                verifications: [VASTVerification] = [], origin: [VASTAdOrigin] = [], icons: [VASTIcon] = []) {
        self.inline = inline
        self.sequence = sequence
        self.origin = origin
        trackers = VASTMergedTrackers(lists: VASTTrackerLists(impressions: impressions, errors: errors, trackingEvents: trackingEvents,
                                                             clickTrackings: clickTrackings, viewableImpression: viewableImpression,
                                                             verifications: verifications, icons: icons))
    }

    /// The resolver's ad: `layer` is the inline ad's layer, linked to the wrappers above it.
    init(inline: VASTInline, sequence: Int?, origin: [VASTAdOrigin], layer: VASTTrackerLayer?) {
        self.inline = inline
        self.sequence = sequence
        self.origin = origin
        trackers = VASTMergedTrackers(layer: layer)
    }

    public static func == (lhs: ResolvedVASTAd, rhs: ResolvedVASTAd) -> Bool {
        lhs.inline == rhs.inline && lhs.sequence == rhs.sequence && lhs.origin == rhs.origin && lhs.trackers.lists == rhs.trackers.lists
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(inline)
        hasher.combine(sequence)
        hasher.combine(origin)
        hasher.combine(trackers.lists)
    }
}

/// The outcome of resolving a VAST source through its wrappers.
public struct ResolvedVAST: Sendable, Hashable {
    public var chain: [VASTHop]
    /// Playable ads in play order (pod order by `sequence`, else document order).
    public var ads: [ResolvedVASTAd]
    /// Set when no ad could be produced; its Error URLs (all known so far) must be fired with this code.
    public var failure: VASTErrorCode?
    /// Error URLs to fire for `failure`.
    public var failureErrorURLs: [String]
    /// Failures that did not stop playback (pod slots / buffet ads that could not be resolved).
    public var adFailures: [VASTAdFailure]
    public var issues: [ValidationIssue]

    public init(chain: [VASTHop] = [], ads: [ResolvedVASTAd] = [], failure: VASTErrorCode? = nil, failureErrorURLs: [String] = [],
                adFailures: [VASTAdFailure] = [], issues: [ValidationIssue] = []) {
        self.chain = chain
        self.ads = ads
        self.failure = failure
        self.failureErrorURLs = failureErrorURLs
        self.adFailures = adFailures
        self.issues = issues
    }
}

/// Fetches VAST documents for wrapper resolution (the app records each fetch as a content request).
public protocol VASTFetcher: Sendable {
    /// `parentRequestID` links the fetch to the wrapper that asked for it in the network monitor.
    func fetchVAST(_ url: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?)
    /// The resolver's call: `url` is the URL to request (VAST macros expanded), `template` the URI as written, so a fetcher
    /// that records requests can show both. The default forwards to `fetchVAST(_:parentRequestID:)`.
    func fetchVAST(_ url: String, template: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?)
}

public extension VASTFetcher {
    func fetchVAST(_ url: String, template: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?) {
        try await fetchVAST(url, parentRequestID: parentRequestID)
    }
}
