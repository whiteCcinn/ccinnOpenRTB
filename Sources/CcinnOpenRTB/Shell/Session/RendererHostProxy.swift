import CcinnOpenRTBKit
import Foundation
import RTBKit

/// The `AdRenderingHost` a renderer gets: bound to one render generation of a session. While that generation is the
/// session's current one, every call goes to the session; afterwards (Render again, Reset, Lose, another device) the
/// renderer being torn down is ignored, so a late callback — a JavaScript bridge message, a player observer, a fetch that
/// finishes after the reset — can never fire trackers of the next render.
@MainActor
final class RendererHostProxy: AdRenderingHost {
    let generation: Int
    let monitor: NetworkMonitor
    /// The device of this render (a different device starts a new render).
    let device: DeviceProfile
    weak var session: AdSession?

    init(generation: Int, monitor: NetworkMonitor, device: DeviceProfile) {
        self.generation = generation
        self.monitor = monitor
        self.device = device
    }

    /// The session, while this proxy's render is still the current one.
    private var current: AdSession? {
        guard let session, session.generation == generation else { return nil }
        return session
    }

    func report(_ event: AdLifecycleEvent) {
        current?.report(event)
    }

    func navigate(to url: String, trigger: String, source: String) {
        current?.navigate(to: url, trigger: trigger, source: source)
    }

    func navigate(to url: String, trigger: String, source: String, vastAdIndex: Int) {
        current?.navigate(to: url, trigger: trigger, source: source, vastAdIndex: vastAdIndex)
    }

    func fetchContent(_ url: String, trigger: String, source: String) async throws -> Data {
        guard let session = current else { throw CancellationError() }
        return try await session.fetchContent(url, trigger: trigger, source: source)
    }

    func playbackChanged(_ status: PlaybackStatus) {
        current?.playbackChanged(status)
    }

    func rendererLog(_ entry: RendererLogEntry) {
        current?.rendererLog(entry)
    }

    /// The session's Real-mode script trackers while this render is current (read through, so it stays observable).
    var scriptTrackers: [ScriptTracker] {
        current?.scriptTrackers ?? []
    }

    func resolveVAST(_ source: VASTSource) async -> ResolvedVAST {
        guard let session = current else { return ResolvedVAST() }
        return await session.resolveVAST(source)
    }
}
