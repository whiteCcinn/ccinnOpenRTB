import CcinnOpenRTBKit
import Foundation
import RTBKit

/// The RTBKit entry points the session uses, injectable so the session's orchestration (ordering, once-per-render
/// rules, Real-mode gating, generations) is tested with fakes and does not depend on the kit implementations.
struct AdKitServices: Sendable {
    /// `InputParser.parse(text, request:)` (runs off the main actor: inputs can be megabytes).
    var parseInput: @Sendable (_ text: String, _ request: String?) -> ParsedInput
    /// `NativeParser.parse(json, hints:)`.
    var parseNative: @Sendable (_ json: String, _ hints: NativeRequestHints?) -> (ad: NativeAd?, issues: [ValidationIssue])
    /// `VASTParser.parse(xml)` (inspector and Real-mode host list before resolution).
    var parseVAST: @Sendable (_ xml: String) -> (document: VASTDocument?, issues: [ValidationIssue])
    /// `VASTResolver(fetcher:macroContext:).resolve(source, parentRequestID:)`: the player expands VAST `[…]` macros in
    /// each request URI (the tag, every VASTAdTagURI) when it fetches it (VAST 4.1 §6.1).
    var resolveVAST: @Sendable (_ source: VASTSource, _ fetcher: any VASTFetcher, _ parentRequestID: UUID?, _ macroContext: MacroContext) async
        -> ResolvedVAST
    /// `TrackingPlan.requests(for:candidate:native:vast:context:options:)`.
    var trackingRequests: @Sendable (_ event: AdLifecycleEvent, _ candidate: AdCandidate, _ native: NativeAd?, _ vast: ResolvedVAST?,
                                     _ context: MacroContext, _ options: TrackingPlanOptions) -> [TrackerRequest]
    /// `VASTTrackingPlan.resolutionRequests(vast:context:source:)`: the Error URLs of `adFailures`, fired once after resolving.
    var resolutionRequests: @Sendable (_ vast: ResolvedVAST, _ context: MacroContext, _ source: String) -> [TrackerRequest]
    /// `MacroExpander.expand(_:context:)`.
    var expand: @Sendable (_ template: String, _ context: MacroContext) -> ExpandedURL
    /// `MacroExpander.expandOpenRTB(_:context:)`: a bid-response URL (nurl, burl, lurl), OpenRTB `${…}` only.
    var expandOpenRTB: @Sendable (_ template: String, _ context: MacroContext) -> ExpandedURL
    /// `MacroExpander.expandMarkup(_:context:)`: the exchange's substitution of OpenRTB macros in `adm`.
    var expandMarkup: @Sendable (_ markup: String, _ context: MacroContext) -> ExpandedURL
    /// `SampleLibrary.all`.
    var samples: @Sendable () -> [Sample]
}

extension AdKitServices {
    /// The real kit.
    static let live = AdKitServices(
        parseInput: { text, request in InputParser.parse(text, request: request) },
        parseNative: { json, hints in NativeParser.parse(json, hints: hints) },
        parseVAST: { xml in VASTParser.parse(xml) },
        resolveVAST: { source, fetcher, parent, context in
            await VASTResolver(fetcher: fetcher, macroContext: context).resolve(source, parentRequestID: parent)
        },
        trackingRequests: { event, candidate, native, vast, context, options in
            TrackingPlan.requests(for: event, candidate: candidate, native: native, vast: vast, context: context, options: options.kitOptions)
        },
        resolutionRequests: { vast, context, source in VASTTrackingPlan.resolutionRequests(vast: vast, context: context, source: source) },
        expand: { template, context in MacroExpander.expand(template, context: context) },
        expandOpenRTB: { template, context in MacroExpander.expandOpenRTB(template, context: context) },
        expandMarkup: { markup, context in MacroExpander.expandMarkup(markup, context: context) },
        samples: { SampleLibrary.all }
    )
}

/// What the session tells the tracking plan about the ad on the device (`TrackingPlan.Options`).
struct TrackingPlanOptions: Equatable, Sendable {
    /// The exchange sends the win notice (`nurl`) itself, so `.won` fires it; off when the win notice delivered the markup
    /// (it was sent to fetch it).
    var exchangeSendsWinNotice: Bool
    /// The monitor entry of the request that delivered the markup (the nurl/purl win notice, or AdCOM `display.curl`);
    /// `nil` for inline `adm`. The plan parents the bid's OpenRTB, Native and AdCOM trackers, clicktrackers and
    /// navigations to it (decisions.md, "Network relationships"); VAST requests keep their own hops.
    var markupRequestID: UUID?

    /// The kit's options, built here and nowhere else.
    var kitOptions: TrackingPlan.Options {
        TrackingPlan.Options(exchangeSendsWinNotice: exchangeSendsWinNotice, markupRequestID: markupRequestID)
    }
}
