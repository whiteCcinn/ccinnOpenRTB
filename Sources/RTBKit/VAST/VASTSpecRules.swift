import Foundation

/// Facts about the VAST 2.0–4.2 schemas that the decoder checks: which child elements each element may have, the
/// version that introduced an element, attribute or event, and the tracking event names.
enum VASTSpecRules {
    // MARK: - Known children (anything else is reported as info and ignored)

    static let knownChildren: [String: Set<String>] = [
        "VAST": ["Ad", "Error"],
        "Ad": ["InLine", "Wrapper"],
        "InLine": ["AdSystem", "AdTitle", "AdServingId", "Impression", "Category", "Description", "Advertiser", "Pricing", "Survey",
                   "Error", "Extensions", "ViewableImpression", "AdVerifications", "Creatives", "Expires"],
        "Wrapper": ["AdSystem", "Impression", "VASTAdTagURI", "AdVerifications", "BlockedAdCategories", "Error", "Extensions",
                    "Creatives", "ViewableImpression", "Pricing"],
        "Creatives": ["Creative"],
        "Creative": ["Linear", "CompanionAds", "NonLinearAds", "UniversalAdId", "CreativeExtensions"],
        "Linear": ["Duration", "MediaFiles", "TrackingEvents", "VideoClicks", "AdParameters", "Icons"],
        "MediaFiles": ["MediaFile", "Mezzanine", "InteractiveCreativeFile", "ClosedCaptionFiles"],
        "VideoClicks": ["ClickThrough", "ClickTracking", "CustomClick"],
        "TrackingEvents": ["Tracking"],
        "CompanionAds": ["Companion"],
        "Companion": ["StaticResource", "IFrameResource", "HTMLResource", "AdParameters", "AltText", "CompanionClickThrough",
                      "CompanionClickTracking", "TrackingEvents", "CreativeExtensions"],
        "ViewableImpression": ["Viewable", "NotViewable", "ViewUndetermined"],
        "AdVerifications": ["Verification"],
        "Verification": ["JavaScriptResource", "ExecutableResource", "FlashResource", "VerificationParameters", "TrackingEvents",
                         "ViewableImpression"],
    ]

    // MARK: - Version history (reported as info when a document declares an older version)

    /// `Parent/Child` elements and `Element@attribute` attributes, with the version that introduced them.
    static let introducedIn: [String: VASTSpecVersion] = [
        "VAST/Error": .v3_0,
        "Ad@sequence": .v3_0,
        "InLine/Advertiser": .v3_0,
        "InLine/Pricing": .v3_0,
        "Wrapper/Pricing": .v3_0,
        "Wrapper@followAdditionalWrappers": .v3_0,
        "Wrapper@allowMultipleAds": .v3_0,
        "Wrapper@fallbackOnNoAd": .v3_0,
        "Creative/CreativeExtensions": .v3_0,
        "Linear@skipoffset": .v3_0,
        "Linear/Icons": .v3_0,
        "MediaFile@minBitrate": .v3_0,
        "MediaFile@maxBitrate": .v3_0,
        "MediaFile@codec": .v3_0,
        "Companion/CompanionClickTracking": .v3_0,
        "CompanionAds@required": .v3_0,
        "InLine/ViewableImpression": .v4_0,
        "Wrapper/ViewableImpression": .v4_0,
        "InLine/AdVerifications": .v4_0,
        "Wrapper/AdVerifications": .v4_0,
        "InLine/Category": .v4_0,
        "Creative/UniversalAdId": .v4_0,
        "MediaFiles/Mezzanine": .v4_0,
        "MediaFiles/InteractiveCreativeFile": .v4_0,
        "InLine/AdServingId": .v4_1,
        "InLine/Expires": .v4_1,
        "Wrapper/BlockedAdCategories": .v4_1,
        "MediaFiles/ClosedCaptionFiles": .v4_1,
        "Ad@adType": .v4_1,
        "MediaFile@fileSize": .v4_1,
        "MediaFile@mediaType": .v4_1,
        "Verification/ExecutableResource": .v4_1,
        "Verification/VerificationParameters": .v4_1,
    ]

    /// Linear tracking events added after VAST 2.0.
    static let eventIntroducedIn: [String: VASTSpecVersion] = [
        "progress": .v3_0,
        "skip": .v3_0,
        "closeLinear": .v3_0,
        "exitFullscreen": .v3_0,
        "acceptInvitationLinear": .v3_0,
        "playerExpand": .v4_0,
        "playerCollapse": .v4_0,
        "notUsed": .v4_0,
        "verificationNotExecuted": .v4_1,
    ]

    /// Events VAST 4 replaced with `playerExpand` / `playerCollapse`.
    static let eventsReplacedInVAST4: [String: String] = [
        "fullscreen": "playerExpand",
        "exitFullscreen": "playerCollapse",
        "expand": "playerExpand",
        "collapse": "playerCollapse",
    ]

    // MARK: - Tracking event names

    /// Spec spelling → event. VAST 2.0/3.0 `expand` / `collapse` are the same player action as VAST 4 `playerExpand` /
    /// `playerCollapse`. `progress` is handled separately because it needs `offset`.
    static let eventsByName: [String: VASTEvent] = [
        "creativeView": .creativeView, "start": .start, "firstQuartile": .firstQuartile, "midpoint": .midpoint,
        "thirdQuartile": .thirdQuartile, "complete": .complete,
        "mute": .mute, "unmute": .unmute, "pause": .pause, "resume": .resume, "rewind": .rewind, "skip": .skip,
        "playerExpand": .playerExpand, "playerCollapse": .playerCollapse, "expand": .playerExpand, "collapse": .playerCollapse,
        "fullscreen": .fullscreen, "exitFullscreen": .exitFullscreen,
        "closeLinear": .closeLinear, "close": .close, "acceptInvitation": .acceptInvitation,
        "acceptInvitationLinear": .acceptInvitationLinear,
        "loaded": .loaded, "notUsed": .notUsed, "otherAdInteraction": .otherAdInteraction, "interactiveStart": .interactiveStart,
        "timeSpentViewing": .timeSpentViewing,
    ]

    /// The `verificationNotExecuted` event of `AdVerifications/Verification/TrackingEvents` (VAST 4.1).
    static let verificationNotExecuted = "verificationNotExecuted"

    /// Case-insensitive lookup table for misspelled event names (`FirstQuartile`).
    static let canonicalEventNames: [String: String] = {
        var table: [String: String] = [:]
        for name in eventsByName.keys {
            table[name.lowercased()] = name
        }
        table["progress"] = "progress"
        table[verificationNotExecuted.lowercased()] = verificationNotExecuted
        return table
    }()

    // MARK: - Media

    static let deliveryValues: Set<String> = ["progressive", "streaming"]

    // MARK: - Ad

    /// VAST 4.1 §3.3.2 `Ad@adType` values.
    static let adTypes: Set<String> = ["video", "audio", "hybrid"]
}

public extension VASTEvent {
    /// The VAST spelling of the event (`firstQuartile`, `progress`, or the verbatim name of an unknown event).
    var vastName: String {
        switch self {
        case .creativeView: "creativeView"
        case .start: "start"
        case .firstQuartile: "firstQuartile"
        case .midpoint: "midpoint"
        case .thirdQuartile: "thirdQuartile"
        case .complete: "complete"
        case .mute: "mute"
        case .unmute: "unmute"
        case .pause: "pause"
        case .resume: "resume"
        case .rewind: "rewind"
        case .skip: "skip"
        case .playerExpand: "playerExpand"
        case .playerCollapse: "playerCollapse"
        case .fullscreen: "fullscreen"
        case .exitFullscreen: "exitFullscreen"
        case .closeLinear: "closeLinear"
        case .close: "close"
        case .acceptInvitation: "acceptInvitation"
        case .acceptInvitationLinear: "acceptInvitationLinear"
        case .loaded: "loaded"
        case .notUsed: "notUsed"
        case .otherAdInteraction: "otherAdInteraction"
        case .interactiveStart: "interactiveStart"
        case .timeSpentViewing: "timeSpentViewing"
        case .progress: "progress"
        case let .other(name): name
        }
    }

    /// A label for the network monitor: `firstQuartile`, `progress 00:00:10`, `progress 25%`.
    var vastLabel: String {
        if case let .progress(offset) = self { return "progress " + VASTTimeFormat.format(offset) }
        return vastName
    }
}

public extension VASTOffset {
    /// The VAST spelling (`00:00:10`, `00:00:10.500`, `25%`).
    var vastText: String { VASTTimeFormat.format(self) }

    /// Parses a VAST offset (`HH:MM:SS(.mmm)` or `n%`).
    init?(vastText: String) {
        guard let offset = VASTTimeFormat.offset(from: vastText) else { return nil }
        self = offset
    }
}
