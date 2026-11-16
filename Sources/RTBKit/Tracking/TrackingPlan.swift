import Foundation

/// Which requests a lifecycle event produces (design D7). Pure and deterministic for a fixed context.
/// Owner: kit-openrtb (auction, AdCOM and Native parts); the VAST part is `VASTTrackingPlan` (kit-vast).
public enum TrackingPlan {
    public struct Options: Sendable, Hashable {
        /// The exchange sends the win notice (`nurl`) itself.
        public var exchangeSendsWinNotice: Bool

        public init(exchangeSendsWinNotice: Bool = true) {
            self.exchangeSendsWinNotice = exchangeSendsWinNotice
        }
    }

    public static func requests(for event: AdLifecycleEvent, candidate: AdCandidate, native: NativeAd?, vast: ResolvedVAST?,
                                context: MacroContext, options: Options = Options()) -> [TrackerRequest] {
        []
    }
}
