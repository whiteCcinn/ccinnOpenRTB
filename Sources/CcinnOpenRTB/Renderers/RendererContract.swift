import CcinnOpenRTBKit
import RTBKit
import SwiftUI

// Contract between the simulator shell (owner: app-shell) and the ad renderers (owner: app-renderers).

/// Where the ad appears in the simulated app.
enum Placement: String, CaseIterable, Identifiable, Sendable {
    case inlineBanner = "Inline banner"
    case inFeed = "In-feed"
    case interstitial = "Interstitial"
    case rewarded = "Rewarded"
    case ctvInstream = "CTV instream"

    var id: String { rawValue }
}

/// Everything a renderer needs to draw one bid.
struct RenderRequest: Equatable {
    var candidate: AdCandidate
    var native: NativeAd?
    /// Resolved before rendering (wrapper chain followed); `nil` for non-VAST markup.
    var vast: ResolvedVAST?
    var device: DeviceProfile
    var placement: Placement
    var landscape: Bool
    /// Dual-screen: the ad spans both screens.
    var spanned: Bool
    /// Foldable: the cover screen is used.
    var folded: Bool
    /// The ad's area in points inside the device screen.
    var adSize: CGSize
    /// 0…1 visible fraction from the simulator's viewability control.
    var visibleFraction: Double
    /// Incremented by the shell to restart playback / reload the creative.
    var generation: Int
}

/// Implemented by the shell's session; renderers report everything through it.
@MainActor
protocol AdRenderingHost: AnyObject {
    var monitor: NetworkMonitor { get }
    var device: DeviceProfile { get }
    /// A lifecycle event (impression, viewable, video events, click, close, error); the host fires the tracking plan.
    func report(_ event: AdLifecycleEvent)
    /// The creative or player wants to open `url` (click-through); the host records it (and opens it only if allowed).
    func navigate(to url: String, trigger: String, source: String)
    /// A content fetch through the monitor (images, media, dcourl), recorded as `content`.
    func fetchContent(_ url: String, trigger: String, source: String) async throws -> Data
}

/// The renderer entry point: picks HTML / image / Native / VAST by markup. Owner: app-renderers.
struct AdView: View {
    let request: RenderRequest
    let host: any AdRenderingHost

    var body: some View {
        Rectangle().fill(.quaternary).overlay(Text("Ad"))
    }
}
