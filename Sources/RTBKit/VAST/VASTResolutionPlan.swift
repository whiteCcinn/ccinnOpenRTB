import Foundation

extension VASTTrackingPlan {
    /// Error trackers for `ResolvedVAST.adFailures`: pod slots or buffet ads that failed during resolution without
    /// stopping playback. The host calls this once, right after resolving. A chain-wide `ResolvedVAST.failure` is not
    /// included here: the host reports it as `.error(failure, adIndex: nil)`.
    ///
    /// For each failure, in resolution order, every Error URL of the documents it passed through (outermost wrapper first,
    /// then the root `<Error>` of a no-ad response) gets that failure's own `[ERRORCODE]` and the `[PODSEQUENCE]` of its
    /// slot. Each request names the document the URL came from in `source`, and its `parentID` is the `requestID` of the hop
    /// that delivered that document.
    public static func resolutionRequests(vast: ResolvedVAST, context: MacroContext, source: String) -> [TrackerRequest] {
        let planner = VASTPlanner(vast: vast, context: context, source: source)
        return vast.adFailures.flatMap(planner.failureRequests)
    }
}
