import RTBKit

/// Turns visibility and playback into viewability lifecycle events for one render (pure; time is passed in).
///
/// - Display and Native: MRC 50% / 100% for 1 s from `.rendered` → `.viewable(.mrc50)`, `.viewable(.mrc100)`.
/// - Native video asset: 50% for 2 s of playback → `.viewable(.video50)` (Native event 4).
/// - VAST, per pod ad: 50% for 2 continuous seconds of playback → `.videoViewability(.viewable, adIndex:)`; an ad that ends
///   (`complete`, `skip`, `close`, `closeLinear`) or is closed before that → `.notViewable`. Audio ads cannot be seen:
///   `.undetermined` when they end.
/// - Every outcome at most once per render (the session's `LifecycleGate` enforces it again).
struct ViewabilityController {
    enum Kind: Equatable {
        case display
        case native
        case video
        case audio
        case none
    }

    let kind: Kind
    private var display: ViewabilityTracker
    private var nativeVideo: ViewabilityTracker
    private var podAds: [Int: ViewabilityTracker] = [:]
    private var decidedAds: Set<Int> = []
    private var fraction: Double = 1
    private var playing: [Int: Bool] = [:]

    init(kind: Kind) {
        self.kind = kind
        display = ViewabilityTracker(rule: kind == .display || kind == .native ? .display : .none)
        nativeVideo = ViewabilityTracker(rule: kind == .native ? .video : .none)
        // Fully in view until told otherwise (nothing counts before the ad renders, so the time is irrelevant).
        _ = display.update(fraction: fraction, at: 0)
        _ = nativeVideo.update(fraction: fraction, at: 0)
    }

    /// The ad was rendered (display and Native start their MRC timers).
    mutating func rendered(at time: Double) -> [AdLifecycleEvent] {
        Self.displayEvents(display.didRender(at: time))
    }

    mutating func visibility(_ newFraction: Double, at time: Double) -> [AdLifecycleEvent] {
        fraction = newFraction.isFinite ? min(1, max(0, newFraction)) : 0
        var events = Self.displayEvents(display.update(fraction: fraction, at: time))
        events += nativeVideoEvents(nativeVideo.update(fraction: fraction, at: time))
        for index in podAds.keys.sorted() {
            guard var tracker = podAds[index] else { continue }
            let fired = tracker.update(fraction: fraction, at: time)
            podAds[index] = tracker
            events += podEvents(fired, adIndex: index)
        }
        return events
    }

    /// Playback state from the renderer (`PlaybackStatus`).
    mutating func playback(adIndex: Int, isPlaying: Bool, at time: Double) -> [AdLifecycleEvent] {
        playing[adIndex] = isPlaying
        switch kind {
        case .native:
            return nativeVideoEvents(nativeVideo.setPlaying(isPlaying, at: time))
        case .video:
            guard var tracker = podAds[adIndex] else { return [] }
            let fired = tracker.setPlaying(isPlaying, at: time)
            podAds[adIndex] = tracker
            return podEvents(fired, adIndex: adIndex)
        case .display, .audio, .none:
            return []
        }
    }

    /// A player event of pod ad `adIndex` (or of the Native video asset).
    mutating func videoEvent(_ event: VASTEvent, adIndex: Int, at time: Double) -> [AdLifecycleEvent] {
        var events = advance(to: time)
        switch event {
        case .creativeView, .start:
            switch kind {
            case .native:
                events += nativeVideoEvents(nativeVideo.didRender(at: time))
            case .video where podAds[adIndex] == nil && !decidedAds.contains(adIndex):
                var tracker = ViewabilityTracker(rule: .video)
                _ = tracker.didRender(at: time)
                _ = tracker.update(fraction: fraction, at: time)
                events += podEvents(tracker.setPlaying(playing[adIndex] ?? false, at: time), adIndex: adIndex)
                if !decidedAds.contains(adIndex) { podAds[adIndex] = tracker }
            default:
                break
            }
        case .complete, .skip, .close, .closeLinear:
            events += endOfAd(adIndex)
        default:
            break
        }
        return events
    }

    /// The whole ad was closed: every pod ad still undecided ends.
    mutating func closed(at time: Double) -> [AdLifecycleEvent] {
        var events = advance(to: time)
        for index in podAds.keys.sorted() { events += endOfAd(index) }
        return events
    }

    /// Fires every timer that completed by `time`.
    mutating func advance(to time: Double) -> [AdLifecycleEvent] {
        var events = Self.displayEvents(display.advance(to: time))
        events += nativeVideoEvents(nativeVideo.advance(to: time))
        for index in podAds.keys.sorted() {
            guard var tracker = podAds[index] else { continue }
            let fired = tracker.advance(to: time)
            podAds[index] = tracker
            events += podEvents(fired, adIndex: index)
        }
        return events
    }

    var nextDeadline: Double? {
        ([display.nextDeadline, nativeVideo.nextDeadline] + podAds.values.map(\.nextDeadline)).compactMap { $0 }.min()
    }

    /// 0…1 progress of the display MRC 50 timer (UI).
    func displayProgress(of level: ViewabilityLevel, at time: Double) -> Double {
        level == .video50 ? nativeVideo.progress(of: .video50, at: time) : display.progress(of: level, at: time)
    }

    private mutating func endOfAd(_ adIndex: Int) -> [AdLifecycleEvent] {
        switch kind {
        case .video:
            guard podAds[adIndex] != nil, !decidedAds.contains(adIndex) else { return [] }
            podAds[adIndex] = nil
            decidedAds.insert(adIndex)
            return [.videoViewability(.notViewable, adIndex: adIndex)]
        case .audio:
            guard decidedAds.insert(adIndex).inserted else { return [] }
            return [.videoViewability(.undetermined, adIndex: adIndex)]
        case .display, .native, .none:
            return []
        }
    }

    private mutating func podEvents(_ levels: [ViewabilityLevel], adIndex: Int) -> [AdLifecycleEvent] {
        guard levels.contains(.video50), !decidedAds.contains(adIndex) else { return [] }
        decidedAds.insert(adIndex)
        podAds[adIndex] = nil
        return [.videoViewability(.viewable, adIndex: adIndex)]
    }

    private func nativeVideoEvents(_ levels: [ViewabilityLevel]) -> [AdLifecycleEvent] {
        levels.contains(.video50) ? [.viewable(.video50)] : []
    }

    private static func displayEvents(_ levels: [ViewabilityLevel]) -> [AdLifecycleEvent] {
        levels.map { .viewable($0) }
    }
}
