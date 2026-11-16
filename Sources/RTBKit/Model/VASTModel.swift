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
    /// `VPAID`, … (unsupported → error 901).
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

    public init(duration: Double? = nil, skipOffset: VASTOffset? = nil, mediaFiles: [VASTMediaFile] = [], trackingEvents: [VASTTracking] = [],
                clickThrough: String? = nil, clickTrackings: [String] = [], customClicks: [String] = [], adParameters: String? = nil) {
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

    public init(id: String? = nil, adID: String? = nil, sequence: Int? = nil, linear: VASTLinear? = nil, companions: [VASTCompanion] = [],
                hasNonLinear: Bool = false) {
        self.id = id
        self.adID = adID
        self.sequence = sequence
        self.linear = linear
        self.companions = companions
        self.hasNonLinear = hasNonLinear
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

    public init(adSystem: String? = nil, adTitle: String? = nil, impressions: [String] = [], errors: [String] = [],
                creatives: [VASTCreative] = [], viewableImpression: VASTViewableImpression? = nil, verifications: [VASTVerification] = []) {
        self.adSystem = adSystem
        self.adTitle = adTitle
        self.impressions = impressions
        self.errors = errors
        self.creatives = creatives
        self.viewableImpression = viewableImpression
        self.verifications = verifications
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

    public init(adTagURI: String, impressions: [String] = [], errors: [String] = [], creatives: [VASTCreative] = [],
                viewableImpression: VASTViewableImpression? = nil, verifications: [VASTVerification] = [],
                followAdditionalWrappers: Bool = true, allowMultipleAds: Bool = false, fallbackOnNoAd: Bool = false) {
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

    public init(id: String? = nil, sequence: Int? = nil, body: Body) {
        self.id = id
        self.sequence = sequence
        self.body = body
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

/// VAST error codes used by the simulator.
public enum VASTErrorCode: Int, Sendable, Hashable, CaseIterable {
    case xmlParsing = 100, schemaValidation = 101, unsupportedVersion = 102
    case traffickingError = 200, unexpectedLinearity = 201, unexpectedDuration = 202, unexpectedSize = 203
    case wrapperError = 300, wrapperTimeout = 301, wrapperLimit = 302, noAdsAfterWrapper = 303, inlineResponseTimeout = 304
    case linearError = 400, fileNotFound = 401, mediaTimeout = 402, noSupportedMedia = 403, mediaDisplayProblem = 405
    case mezzanineRequired = 406, mezzanineDownloading = 407, conditionalAdRejected = 408
    case interactiveCreativeError = 409, codeResourceError = 410
    case nonLinearError = 500, companionError = 600, undefinedError = 900, vpaidError = 901
}

/// One hop of a wrapper chain.
public struct VASTHop: Sendable, Hashable {
    /// `nil` for the document the bid carried inline.
    public var url: String?
    public var document: VASTDocument?
    public var error: VASTErrorCode?

    public init(url: String? = nil, document: VASTDocument? = nil, error: VASTErrorCode? = nil) {
        self.url = url
        self.document = document
        self.error = error
    }
}

/// An inline ad with every tracker of the wrappers above it merged in (wrapper trackers first, in chain order).
public struct ResolvedVASTAd: Sendable, Hashable {
    public var inline: VASTInline
    public var sequence: Int?
    /// Impression URLs of all wrappers and the inline ad.
    public var impressions: [String]
    /// Error URLs of all wrappers and the inline ad.
    public var errors: [String]
    /// Per inline linear creative: all tracking events (wrappers + inline).
    public var trackingEvents: [VASTTracking]
    /// ClickTracking of all wrappers and the inline ad.
    public var clickTrackings: [String]
    public var viewableImpression: VASTViewableImpression
    public var verifications: [VASTVerification]

    public init(inline: VASTInline, sequence: Int? = nil, impressions: [String] = [], errors: [String] = [], trackingEvents: [VASTTracking] = [],
                clickTrackings: [String] = [], viewableImpression: VASTViewableImpression = VASTViewableImpression(),
                verifications: [VASTVerification] = []) {
        self.inline = inline
        self.sequence = sequence
        self.impressions = impressions
        self.errors = errors
        self.trackingEvents = trackingEvents
        self.clickTrackings = clickTrackings
        self.viewableImpression = viewableImpression
        self.verifications = verifications
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
    public var issues: [ValidationIssue]

    public init(chain: [VASTHop] = [], ads: [ResolvedVASTAd] = [], failure: VASTErrorCode? = nil, failureErrorURLs: [String] = [],
                issues: [ValidationIssue] = []) {
        self.chain = chain
        self.ads = ads
        self.failure = failure
        self.failureErrorURLs = failureErrorURLs
        self.issues = issues
    }
}

/// Fetches VAST documents for wrapper resolution (the app records each fetch as a content request).
public protocol VASTFetcher: Sendable {
    /// `parentRequestID` links the fetch to the wrapper that asked for it in the network monitor.
    func fetchVAST(_ url: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?)
}
