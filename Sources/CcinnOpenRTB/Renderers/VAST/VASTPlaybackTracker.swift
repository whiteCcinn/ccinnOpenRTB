import RTBKit

/// Maps what a linear ad's player observes (playhead ticks, duration, user actions) to VAST tracking events.
///
/// Pure value type with no clock of its own: the player feeds it playhead updates, so it is deterministic under test.
/// Guarantees:
/// - `loaded`, `creativeView`, `start`, the quartiles, `complete`, `skip` and `closeLinear` fire at most once;
/// - each distinct `progress` offset fires at most once, when the furthest playhead reached crosses it;
/// - events that are crossed together are returned in time order (a quartile before a progress offset at the same instant);
/// - after `skip` or `close` nothing fires any more; after `complete` only `rewind` (a replay) can.
struct VASTPlaybackTracker: Sendable {
    /// A seek backwards larger than this (seconds) is a rewind; smaller steps are observer jitter.
    static let rewindThreshold = 1.0

    private enum Milestone: Hashable {
        case quartile(Int)
        case progress(VASTOffset)

        var event: VASTEvent {
            switch self {
            case .quartile(1): .firstQuartile
            case .quartile(2): .midpoint
            case .quartile: .thirdQuartile
            case let .progress(offset): .progress(offset)
            }
        }

        /// Ordering tie-break at the same instant: quartiles first.
        var rank: Int {
            if case .quartile = self { 0 } else { 1 }
        }
    }

    private var duration: Double?
    private let progressOffsets: [VASTOffset]
    private var fired: Set<Milestone> = []
    private var lastPlayhead: Double = 0
    private var furthestPlayhead: Double = 0
    private var hasLoaded = false
    private(set) var hasStarted = false
    private(set) var isPaused = false
    private(set) var isMuted: Bool
    private(set) var isCompleted = false
    private(set) var isSkipped = false
    private(set) var isClosed = false

    /// - Parameters:
    ///   - duration: the VAST `Duration`; replaced by the media duration through `setDuration(_:)` when known.
    ///   - progressOffsets: the offsets of the ad's `progress` tracking events (duplicates and negative values are dropped).
    ///   - muted: the initial audio state (autoplay muted); it is state, not an event.
    init(duration: Double?, progressOffsets: [VASTOffset] = [], muted: Bool = false) {
        self.duration = Self.validDuration(duration)
        var unique: [VASTOffset] = []
        for offset in progressOffsets where Self.isValid(offset) && !unique.contains(offset) {
            unique.append(offset)
        }
        self.progressOffsets = unique
        self.isMuted = muted
    }

    /// Skipped or closed: the ad is over and fires nothing more.
    var isFinished: Bool { isSkipped || isClosed }

    /// The duration quartiles are computed against, if known.
    var effectiveDuration: Double? { duration }

    mutating func loaded() -> [VASTEvent] {
        guard !hasLoaded, !isFinished else { return [] }
        hasLoaded = true
        return [.loaded]
    }

    /// The media reported its real duration; milestones already passed fire now.
    mutating func setDuration(_ newDuration: Double) -> [VASTEvent] {
        guard let valid = Self.validDuration(newDuration) else { return [] }
        duration = valid
        guard hasStarted, !isFinished else { return [] }
        return crossedMilestones(upTo: furthestPlayhead)
    }

    /// A playhead observation (seconds into the ad).
    mutating func advance(to playhead: Double) -> [VASTEvent] {
        guard playhead.isFinite, playhead >= 0, !isFinished else { return [] }
        var events: [VASTEvent] = []
        if playhead < lastPlayhead - Self.rewindThreshold, hasStarted {
            events.append(.rewind)
        }
        lastPlayhead = playhead
        if isCompleted { return events }
        if !hasStarted, playhead > 0 {
            events += startEvents()
        }
        guard hasStarted else { return events }
        furthestPlayhead = max(furthestPlayhead, playhead)
        events += crossedMilestones(upTo: furthestPlayhead)
        return events
    }

    mutating func pause() -> [VASTEvent] {
        guard hasStarted, !isPaused, !isCompleted, !isFinished else { return [] }
        isPaused = true
        return [.pause]
    }

    mutating func resume() -> [VASTEvent] {
        guard isPaused, !isFinished else { return [] }
        isPaused = false
        return [.resume]
    }

    mutating func setMuted(_ muted: Bool) -> [VASTEvent] {
        guard muted != isMuted, !isFinished else { return [] }
        isMuted = muted
        return [muted ? .mute : .unmute]
    }

    mutating func skip() -> [VASTEvent] {
        guard !isCompleted, !isFinished else { return [] }
        isSkipped = true
        return [.skip]
    }

    /// The media played to its end: any milestone the observer missed fires first, then `complete`.
    mutating func complete() -> [VASTEvent] {
        guard !isCompleted, !isFinished else { return [] }
        var events: [VASTEvent] = []
        if !hasStarted {
            events += startEvents()
        }
        isPaused = false
        let end = duration ?? furthestPlayhead
        furthestPlayhead = max(furthestPlayhead, end)
        if duration == nil { duration = end > 0 ? end : nil }
        events += crossedMilestones(upTo: furthestPlayhead, includeQuartilesWithoutDuration: true)
        isCompleted = true
        return events + [.complete]
    }

    /// The user closed the ad: `closeLinear` before it completed, nothing after.
    mutating func close() -> [VASTEvent] {
        guard !isFinished else { return [] }
        isClosed = true
        return isCompleted ? [] : [.closeLinear]
    }

    // MARK: - Private

    private mutating func startEvents() -> [VASTEvent] {
        hasStarted = true
        return [.creativeView, .start]
    }

    private mutating func crossedMilestones(upTo playhead: Double, includeQuartilesWithoutDuration: Bool = false) -> [VASTEvent] {
        var due: [(time: Double, milestone: Milestone)] = []
        if let duration {
            for quarter in 1...3 {
                let milestone = Milestone.quartile(quarter)
                let time = duration * Double(quarter) / 4
                if !fired.contains(milestone), playhead >= time { due.append((time, milestone)) }
            }
        } else if includeQuartilesWithoutDuration {
            for quarter in 1...3 where !fired.contains(.quartile(quarter)) {
                due.append((Double(quarter), .quartile(quarter)))
            }
        }
        for offset in progressOffsets {
            let milestone = Milestone.progress(offset)
            guard !fired.contains(milestone), let time = seconds(of: offset), playhead >= time else { continue }
            due.append((time, milestone))
        }
        due.sort { lhs, rhs in
            lhs.time == rhs.time ? lhs.milestone.rank < rhs.milestone.rank : lhs.time < rhs.time
        }
        for entry in due { fired.insert(entry.milestone) }
        return due.map(\.milestone.event)
    }

    /// The offset in seconds, or `nil` while a percent offset waits for the duration.
    private func seconds(of offset: VASTOffset) -> Double? {
        switch offset {
        case let .seconds(value): value
        case .percent: duration.map { offset.seconds(inAdOf: $0) }
        }
    }

    private static func validDuration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func isValid(_ offset: VASTOffset) -> Bool {
        switch offset {
        case let .seconds(value): value.isFinite && value >= 0
        case let .percent(value): value.isFinite && value >= 0 && value <= 100
        }
    }
}
