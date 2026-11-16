import Foundation

/// What the full-screen chrome (interstitial / rewarded) shows at a moment of the ad's display.
enum FullscreenChromePhase: Equatable, Sendable {
    /// Inline placements: no chrome.
    case none
    /// Interstitial: the close button appears in N seconds.
    case closeIn(Int)
    /// Rewarded: "Reward in N s"; the ad cannot be closed yet.
    case rewardIn(Int)
    case closable
}

enum FullscreenChromePolicy {
    static let interstitialCloseDelay: TimeInterval = 5
    /// How long a rewarded display (HTML / image / Native) ad must stay on screen.
    static let displayRewardDuration: TimeInterval = 15

    static func phase(placement: Placement, elapsed: TimeInterval, rewardDuration: TimeInterval = displayRewardDuration)
        -> FullscreenChromePhase
    {
        let seconds = elapsed.isFinite ? max(0, elapsed) : 0
        switch placement {
        case .inlineBanner, .inFeed, .ctvInstream:
            return .none
        case .interstitial:
            return seconds < interstitialCloseDelay ? .closeIn(remaining(interstitialCloseDelay - seconds)) : .closable
        case .rewarded:
            let duration = rewardDuration.isFinite ? max(0, rewardDuration) : displayRewardDuration
            return seconds < duration ? .rewardIn(remaining(duration - seconds)) : .closable
        }
    }

    private static func remaining(_ seconds: TimeInterval) -> Int {
        max(1, Int(seconds.rounded(.up)))
    }
}
