import AVFoundation
import CcinnOpenRTBKit
import Foundation

/// What a playback engine observed.
enum PlaybackEngineEvent: Equatable, Sendable {
    /// The media can play; `duration` when the media knows it.
    case ready(duration: Double?)
    /// The playhead (seconds), about 10 times a second while the media plays.
    case tick(Double)
    /// The media played to its end.
    case ended
    case failed(String)
}

/// Plays one media URL at a time. The VAST player model drives it and turns its observations into tracking; tests use a
/// fake. All calls and events happen on the main actor.
@MainActor
protocol PlaybackEngine: AnyObject {
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }
    /// The player a video layer shows (`nil` for engines without one).
    var avPlayer: AVPlayer? { get }
    /// Replaces the current media; events of earlier media stop.
    func load(_ url: URL)
    /// Replaces the current media with `url` answered by `resourceLoader` (remote media from `NetworkMonitor.prepareMedia`:
    /// the monitor fetches every byte); a `nil` loader is a plain `load(url)`.
    func load(_ url: URL, resourceLoader: MediaResourceLoader?)
    func play()
    func pause()
    func setMuted(_ muted: Bool)
    /// Stops and releases the media; no event follows until the next `load`.
    func stop()
}

extension PlaybackEngine {
    func load(_ url: URL, resourceLoader: MediaResourceLoader?) {
        load(url)
    }
}

/// `AVPlayer` engine: a periodic time observer (0.1 s), item status KVO and end / failure notifications. Every observer is
/// tied to a load token, so a late callback of replaced media is dropped; `stop()` removes them all.
///
/// Remote media never reaches AVFoundation's own networking: it arrives as a private-scheme URL with the kit's
/// `MediaResourceLoader`, installed on the `AVURLAsset` and kept here while its item is current (AVFoundation holds its
/// resource-loader delegate weakly).
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    static let tickInterval = CMTime(value: 1, timescale: 10)

    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private let player: AVPlayer
    private var token = 0
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var notificationObservers: [any NSObjectProtocol] = []
    private var isReady = false
    /// The current item's resource loader (remote media).
    private var resourceLoader: MediaResourceLoader?

    var avPlayer: AVPlayer? { player }

    init() {
        player = AVPlayer()
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func load(_ url: URL) {
        load(url, resourceLoader: nil)
    }

    func load(_ url: URL, resourceLoader: MediaResourceLoader?) {
        detachItem()
        token &+= 1
        isReady = false
        let token = token
        let asset = AVURLAsset(url: url)
        resourceLoader?.attach(to: asset)
        self.resourceLoader = resourceLoader
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let duration = Self.seconds(item.duration)
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in self?.statusChanged(status, duration: duration, error: message, token: token) }
        }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.deliver(.ended, token: token) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.localizedDescription ?? "Playback failed"
                Task { @MainActor [weak self] in self?.deliver(.failed(message), token: token) }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.tickInterval, queue: .main) { [weak self] time in
            let seconds = Self.seconds(time)
            Task { @MainActor [weak self] in
                guard let self, self.isReady, let seconds else { return }
                self.deliver(.tick(seconds), token: token)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func setMuted(_ muted: Bool) { player.isMuted = muted }

    func stop() {
        token &+= 1
        player.pause()
        detachItem()
        player.replaceCurrentItem(with: nil)
    }

    private func detachItem() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers = []
        resourceLoader = nil
    }

    private func statusChanged(_ status: AVPlayerItem.Status, duration: Double?, error: String?, token: Int) {
        switch status {
        case .readyToPlay:
            guard !isReady else { return }
            isReady = true
            deliver(.ready(duration: duration), token: token)
        case .failed:
            deliver(.failed(error ?? "The media could not be played"), token: token)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func deliver(_ event: PlaybackEngineEvent, token: Int) {
        guard token == self.token else { return }
        onEvent?(event)
    }

    nonisolated static func seconds(_ time: CMTime) -> Double? {
        guard time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}
