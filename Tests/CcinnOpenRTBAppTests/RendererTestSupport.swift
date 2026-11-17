import AppKit
import AVFoundation
import CcinnOpenRTBKit
import Foundation
import RTBKit
@testable import CcinnOpenRTB

/// A transport that fails every request: renderer tests must never reach the network.
struct OfflineTransport: HTTPTransport {
    struct Offline: Error {}

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw Offline()
    }
}

/// A host that records everything the renderers report.
@MainActor
final class RecordingHost: AdRenderingHost {
    struct Navigation: Equatable {
        var url: String
        var trigger: String
    }

    struct NotFound: Error {}

    let monitor: NetworkMonitor
    var device: DeviceProfile
    private(set) var events: [AdLifecycleEvent] = []
    private(set) var navigations: [Navigation] = []
    private(set) var statuses: [PlaybackStatus] = []
    private(set) var logs: [RendererLogEntry] = []
    var contents: [String: Data] = [:]

    init(device: DeviceProfile = RendererFixtures.phone) {
        monitor = NetworkMonitor(transport: OfflineTransport(), publishInterval: .zero)
        self.device = device
    }

    func report(_ event: AdLifecycleEvent) { events.append(event) }

    func navigate(to url: String, trigger: String, source: String) { navigations.append(Navigation(url: url, trigger: trigger)) }

    func fetchContent(_ url: String, trigger: String, source: String) async throws -> Data {
        guard let data = contents[url] else { throw NotFound() }
        return data
    }

    func playbackChanged(_ status: PlaybackStatus) { statuses.append(status) }

    func rendererLog(_ entry: RendererLogEntry) { logs.append(entry) }

    /// What `resolveVAST` answers (the default resolver is a kit placeholder until kit-vast merges).
    var vastResolution = ResolvedVAST()
    private(set) var resolvedSources: [VASTSource] = []

    func resolveVAST(_ source: VASTSource) async -> ResolvedVAST {
        resolvedSources.append(source)
        return vastResolution
    }

    /// The VAST events reported for one pod ad, in order.
    func videoEvents(adIndex: Int) -> [VASTEvent] {
        events.compactMap { event in
            if case let .video(videoEvent, index) = event, index == adIndex { return videoEvent }
            return nil
        }
    }
}

/// A playback engine driven by the test.
@MainActor
final class FakeEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var avPlayer: AVPlayer? { nil }
    private(set) var loaded: [URL] = []
    private(set) var isPlaying = false
    private(set) var muted: Bool?
    private(set) var stops = 0

    func load(_ url: URL) { loaded.append(url) }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func setMuted(_ muted: Bool) { self.muted = muted }

    func stop() {
        isPlaying = false
        stops += 1
    }

    func send(_ event: PlaybackEngineEvent) { onEvent?(event) }

    /// Ticks from `from` to `to` (inclusive) every `step` seconds.
    func tick(from: Double, to: Double, step: Double = 0.1) {
        var playhead = from
        while playhead <= to + 1e-9 {
            send(.tick(playhead))
            playhead += step
        }
    }
}

enum Wait {
    /// Polls `condition` on the main actor until it holds (or fails the wait after `timeout`).
    @MainActor
    static func until(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// The same for a condition that has to ask the web view.
    @MainActor
    static func until(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while await !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

enum TestImages {
    /// A solid PNG of `width` × `height` pixels.
    static func png(width: Int = 4, height: Int = 2) -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        for x in 0..<width {
            for y in 0..<height { bitmap.setColor(.systemTeal, atX: x, y: y) }
        }
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}
