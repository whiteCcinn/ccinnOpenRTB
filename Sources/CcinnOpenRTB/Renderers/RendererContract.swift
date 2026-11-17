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

/// What the renderer is playing (VAST pod ad `adIndex`, or a Native video asset with `adIndex` 0). Reported about 4 Hz
/// and on every play / pause / seek / end; the shell's viewability timers run on it.
struct PlaybackStatus: Equatable, Sendable {
    var adIndex: Int
    /// Seconds.
    var playhead: Double
    /// Seconds; `nil` until known.
    var duration: Double?
    var isPlaying: Bool
    var isMuted: Bool
}

/// One line of the renderer console (MRAID bridge, VAST player, Native, HTML).
struct RendererLogEntry: Equatable, Sendable {
    enum Level: String, Sendable { case info, warning, error }

    var date: Date
    /// "MRAID", "VAST", "Native", "HTML".
    var origin: String
    var level: Level
    var message: String
}

/// A JavaScript tracker the host recorded in Real mode for the renderer to run (Native `jstracker`, `eventtrackers` /
/// AdCOM events with method 2). The renderer runs each one exactly once (identity: `entryID`) in a hidden, non-persistent
/// web view: `<script src>` when `request.url` is http(s), otherwise as markup. It then calls
/// `monitor.finishRendererLoad(entryID, …)`. In Simulated mode the host records script trackers and never lists them here.
struct ScriptTracker: Identifiable, Equatable, Sendable {
    var entryID: UUID
    var request: TrackerRequest
    var id: UUID { entryID }
}

/// Implemented by the shell's session; renderers report everything through it.
/// Members with default implementations are protocol REQUIREMENTS, so the session's implementations are dynamically
/// dispatched through `any AdRenderingHost`.
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
    /// Playback state for viewability (VAST and Native video).
    func playbackChanged(_ status: PlaybackStatus)
    /// The renderer console.
    func rendererLog(_ entry: RendererLogEntry)
    /// Resolves a VAST tag for a Native video asset. The session overrides this with its monitor-backed fetcher and
    /// remembers the result, so `.video(e, adIndex:)` from that player maps to it.
    func resolveVAST(_ source: VASTSource) async -> ResolvedVAST
    /// Real-mode script trackers waiting to be run, oldest first (observable on the session).
    var scriptTrackers: [ScriptTracker] { get }
}

extension AdRenderingHost {
    var scriptTrackers: [ScriptTracker] { [] }

    func playbackChanged(_ status: PlaybackStatus) {}

    func rendererLog(_ entry: RendererLogEntry) {}

    func resolveVAST(_ source: VASTSource) async -> ResolvedVAST {
        await VASTResolver(fetcher: MonitorVASTFetcher(monitor: monitor, userAgent: device.userAgent)).resolve(source)
    }
}

/// The renderer entry point: picks HTML / image / Native / VAST by markup. Owner: app-renderers.
struct AdView: View {
    let request: RenderRequest
    let host: any AdRenderingHost

    var body: some View {
        Rectangle().fill(.quaternary).overlay(Text("Ad"))
    }
}
