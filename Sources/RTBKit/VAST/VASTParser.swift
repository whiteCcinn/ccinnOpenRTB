import Foundation

/// VAST 2.0 – 4.2 parser (design D6). Owner: kit-vast.
public enum VASTParser {
    public static func parse(_ xml: String) -> (document: VASTDocument?, issues: [ValidationIssue]) {
        (nil, [])
    }
}

/// Follows wrapper chains and merges trackers (design D6). Owner: kit-vast.
public struct VASTResolver: Sendable {
    public var fetcher: any VASTFetcher
    public var maxDepth: Int

    public init(fetcher: any VASTFetcher, maxDepth: Int = 5) {
        self.fetcher = fetcher
        self.maxDepth = maxDepth
    }

    /// `parentRequestID` links the first fetch (for `.url` sources) to the request that delivered the markup.
    public func resolve(_ source: VASTSource, parentRequestID: UUID? = nil) async -> ResolvedVAST {
        ResolvedVAST()
    }
}

/// Picks the media file to play (design D6). Owner: kit-vast.
public enum VASTMediaSelector {
    public enum Choice: Sendable, Hashable {
        case play(VASTMediaFile)
        case unsupported(VASTErrorCode)
    }

    public static func choose(_ files: [VASTMediaFile], playerWidth: Int, playerHeight: Int, audioOnly: Bool = false) -> Choice {
        .unsupported(.noSupportedMedia)
    }
}

/// VAST part of the tracking plan (design D7). Owner: kit-vast.
public enum VASTTrackingPlan {
    public static func requests(for event: AdLifecycleEvent, vast: ResolvedVAST, candidate: AdCandidate?, context: MacroContext,
                                source: String) -> [TrackerRequest] {
        []
    }
}
