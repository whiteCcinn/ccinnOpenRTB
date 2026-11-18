import Foundation
import RTBKit

/// MRC viewability timers for one render (pure state machine; time is passed in, so tests drive it with any clock).
///
/// - Display: ≥ 50% of the ad's pixels in view for 1 continuous second → `mrc50`; 100% for 1 second → `mrc100`.
/// - Video: ≥ 50% in view during 2 continuous seconds of playback → `video50` (a pause or dropping below 50% restarts it).
/// - Nothing counts before the ad has rendered; each level fires at most once.
///
/// Every mutating call first settles deadlines that passed before it, so a timer that expired between ticks still fires
/// even when the next thing that happens is the ad scrolling away.
struct ViewabilityTracker {
    enum Rule: Equatable {
        case display, video, none

        var levels: [ViewabilityLevel] {
            switch self {
            case .display: [.mrc50, .mrc100]
            case .video: [.video50]
            case .none: []
            }
        }
    }

    /// 100% within floating-point noise of scroll geometry.
    static let fullyVisible = 0.999

    let rule: Rule
    private(set) var fired: [ViewabilityLevel] = []
    private(set) var renderedAt: Double?
    private(set) var fraction: Double = 0
    private(set) var isPlaying = false
    /// When the current qualifying streak of each unfired level began.
    private var streakStart: [ViewabilityLevel: Double] = [:]

    init(rule: Rule) {
        self.rule = rule
    }

    var hasMetVideoStandard: Bool { fired.contains(.video50) }

    static func requiredDuration(of level: ViewabilityLevel) -> Double {
        switch level {
        case .mrc50, .mrc100: 1
        case .video50: 2
        }
    }

    mutating func didRender(at time: Double) -> [ViewabilityLevel] {
        guard renderedAt == nil else { return advance(to: time) }
        renderedAt = time
        refreshStreaks(at: time)
        return advance(to: time)
    }

    mutating func update(fraction newValue: Double, at time: Double) -> [ViewabilityLevel] {
        var result = advance(to: time)
        fraction = newValue.isFinite ? min(1, max(0, newValue)) : 0
        refreshStreaks(at: time)
        result += advance(to: time)
        return result
    }

    mutating func setPlaying(_ playing: Bool, at time: Double) -> [ViewabilityLevel] {
        var result = advance(to: time)
        isPlaying = playing
        refreshStreaks(at: time)
        result += advance(to: time)
        return result
    }

    /// Fires every level whose streak has lasted long enough by `time`, in `rule.levels` order.
    mutating func advance(to time: Double) -> [ViewabilityLevel] {
        var result: [ViewabilityLevel] = []
        for level in rule.levels where !fired.contains(level) {
            guard let start = streakStart[level], time - start >= Self.requiredDuration(of: level) else { continue }
            fired.append(level)
            streakStart[level] = nil
            result.append(level)
        }
        return result
    }

    /// The earliest time a running streak completes, if any.
    var nextDeadline: Double? {
        rule.levels.compactMap { level in streakStart[level].map { $0 + Self.requiredDuration(of: level) } }.min()
    }

    /// 0…1 progress of `level`'s timer at `time` (1 once fired).
    func progress(of level: ViewabilityLevel, at time: Double) -> Double {
        if fired.contains(level) { return 1 }
        guard rule.levels.contains(level), let start = streakStart[level] else { return 0 }
        return min(1, max(0, (time - start) / Self.requiredDuration(of: level)))
    }

    private func qualifies(_ level: ViewabilityLevel) -> Bool {
        guard renderedAt != nil else { return false }
        switch level {
        case .mrc50: return fraction >= 0.5
        case .mrc100: return fraction >= Self.fullyVisible
        case .video50: return isPlaying && fraction >= 0.5
        }
    }

    private mutating func refreshStreaks(at time: Double) {
        for level in rule.levels where !fired.contains(level) {
            if qualifies(level) {
                if streakStart[level] == nil { streakStart[level] = time }
            } else {
                streakStart[level] = nil
            }
        }
    }
}
