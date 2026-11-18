import Foundation
import RTBKit

/// The Skip button of a linear ad.
enum SkipButtonState: Equatable, Sendable {
    /// Not skippable (no `skipoffset`, the offset is not before the end, or skipping is disabled for the placement).
    case hidden
    /// "Skip in N".
    case countdown(Int)
    /// "Skip Ad".
    case available

    static func make(skipOffset: VASTOffset?, playhead: Double, duration: Double?, enabled: Bool = true) -> SkipButtonState {
        guard enabled, let skipOffset else { return .hidden }
        let skipAt: Double
        switch skipOffset {
        case let .seconds(value): skipAt = value
        case .percent:
            guard let duration, duration.isFinite, duration > 0 else { return .hidden }
            skipAt = skipOffset.seconds(inAdOf: duration)
        }
        guard skipAt.isFinite, skipAt >= 0 else { return .hidden }
        if let duration, duration.isFinite, duration > 0, skipAt >= duration { return .hidden }
        let position = playhead.isFinite ? max(0, playhead) : 0
        if position >= skipAt { return .available }
        return .countdown(max(1, PlayerClock.wholeSeconds(skipAt - position)))
    }
}

enum PlayerClock {
    /// The ceiling every displayed or counted duration is clamped to: durations and offsets come from the markup, and an
    /// out-of-range `Int` conversion traps.
    static let maxSeconds = 1_000_000_000

    /// Whole seconds, rounded up, clamped to 0…`maxSeconds` (non-finite → 0).
    static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let rounded = seconds.rounded(.up)
        return rounded >= Double(maxSeconds) ? maxSeconds : Int(rounded)
    }

    /// `m:ss` for a number of seconds (negative / non-finite → `0:00`).
    static func format(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Whole seconds left, rounded up, never negative.
    static func remaining(playhead: Double, duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        let position = playhead.isFinite ? playhead : 0
        return max(0, duration - position)
    }

    /// 0…1 progress for the bar.
    static func fraction(playhead: Double, duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0, playhead.isFinite else { return 0 }
        return min(1, max(0, playhead / duration))
    }
}

/// A control of the CTV player that the remote can focus.
enum CTVControl: Int, CaseIterable, Comparable, Sendable {
    case playPause, learnMore, skip

    static func < (lhs: CTVControl, rhs: CTVControl) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Remote-style focus between the CTV player's controls: arrows move along one row, without wrapping.
struct CTVFocusModel: Equatable, Sendable {
    enum Direction: Sendable { case left, right, up, down }

    private(set) var available: [CTVControl] = [.playPause]
    private(set) var focused: CTVControl = .playPause

    /// The controls currently on screen; focus falls back to Play/Pause when the focused one disappears.
    mutating func setAvailable(_ controls: Set<CTVControl>) {
        var sorted = controls.sorted()
        if sorted.isEmpty { sorted = [.playPause] }
        available = sorted
        if !sorted.contains(focused) {
            focused = sorted.contains(.playPause) ? .playPause : sorted[0]
        }
    }

    mutating func move(_ direction: Direction) {
        guard let index = available.firstIndex(of: focused) else {
            focused = available.first ?? .playPause
            return
        }
        switch direction {
        case .left, .up:
            if index > 0 { focused = available[index - 1] }
        case .right, .down:
            if index < available.count - 1 { focused = available[index + 1] }
        }
    }
}

/// A key of the TV remote (arrows, select, play/pause, back), as the simulator maps the keyboard.
enum CTVRemoteKey: Sendable {
    case left, right, up, down
    /// Return / the remote's select button.
    case select
    /// Space / the remote's play-pause button.
    case playPause
    /// Escape / the remote's Back button.
    case back
}

/// What a remote key does in the CTV player.
enum CTVRemoteAction: Equatable, Sendable {
    case none, togglePlayback, skip, close
}

enum CTVRemote {
    /// Moves the focus or picks the action of the key (pure). Select activates the focused control; Play/Pause always
    /// toggles playback; Back closes the ad.
    static func handle(_ key: CTVRemoteKey, focus: inout CTVFocusModel) -> CTVRemoteAction {
        switch key {
        case .left: focus.move(.left)
        case .right: focus.move(.right)
        case .up: focus.move(.up)
        case .down: focus.move(.down)
        case .playPause: return .togglePlayback
        case .back: return .close
        case .select:
            switch focus.focused {
            case .playPause: return .togglePlayback
            case .skip: return .skip
            // Click-through does not exist on CTV.
            case .learnMore: return .none
            }
        }
        return .none
    }
}
