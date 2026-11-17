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
    /// `VASTResolver(fetcher:).resolve(source, parentRequestID:)`.
    var resolveVAST: @Sendable (_ source: VASTSource, _ fetcher: any VASTFetcher, _ parentRequestID: UUID?) async -> ResolvedVAST
    /// `TrackingPlan.requests(for:candidate:native:vast:context:options:)`.
    var trackingRequests: @Sendable (_ event: AdLifecycleEvent, _ candidate: AdCandidate, _ native: NativeAd?, _ vast: ResolvedVAST?,
                                     _ context: MacroContext, _ options: TrackingPlan.Options) -> [TrackerRequest]
    /// `VASTTrackingPlan.resolutionRequests(vast:context:source:)`: the Error URLs of `adFailures`, fired once after resolving.
    var resolutionRequests: @Sendable (_ vast: ResolvedVAST, _ context: MacroContext, _ source: String) -> [TrackerRequest]
    /// `MacroExpander.expand(_:context:)`.
    var expand: @Sendable (_ template: String, _ context: MacroContext) -> ExpandedURL
    /// `SampleLibrary.all`.
    var samples: @Sendable () -> [Sample]
}

extension AdKitServices {
    /// The real kit.
    static let live = AdKitServices(
        parseInput: { text, request in InputParser.parse(text, request: request) },
        parseNative: { json, hints in NativeParser.parse(json, hints: hints) },
        parseVAST: { xml in VASTParser.parse(xml) },
        resolveVAST: { source, fetcher, parent in await VASTResolver(fetcher: fetcher).resolve(source, parentRequestID: parent) },
        trackingRequests: { event, candidate, native, vast, context, options in
            TrackingPlan.requests(for: event, candidate: candidate, native: native, vast: vast, context: context, options: options)
        },
        resolutionRequests: { vast, context, source in VASTTrackingPlan.resolutionRequests(vast: vast, context: context, source: source) },
        expand: { template, context in MacroExpander.expand(template, context: context) },
        samples: { SampleLibrary.all }
    )
}
