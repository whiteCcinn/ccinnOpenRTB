import Foundation

extension VASTTrackingPlan {
    /// Error trackers for `ResolvedVAST.adFailures` (pod slots / buffet ads that failed without stopping playback), fired
    /// once by the host right after resolution. Placeholder on main — kit-vast replaces this file with the real
    /// implementation.
    public static func resolutionRequests(vast: ResolvedVAST, context: MacroContext, source: String) -> [TrackerRequest] {
        []
    }
}
