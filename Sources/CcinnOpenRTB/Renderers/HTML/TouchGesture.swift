import Foundation

/// One gesture of the emulated finger on a touch device's HTML creative, as the touch script reports it when the finger
/// lifts (bridge channel `touch`). Coordinates are the frame's CSS pixels, which are device points.
struct TouchGesture: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Lifted within the slop of where it went down.
        case tap
        /// Moved farther before it lifted.
        case swipe
        /// Ended without a release (another press began, the window lost focus).
        case cancel
    }

    enum Direction: String, Sendable {
        case left, right, up, down
    }

    var kind: Kind
    /// Where the finger went down.
    var x: Double
    var y: Double
    /// From where it went down to where it lifted.
    var dx: Double
    var dy: Double
    /// Milliseconds from down to up.
    var duration: Double
    /// The creative called `preventDefault()` on the gesture's touch events: no click (tap); a swipe it handles itself,
    /// so nothing scrolls.
    var cancelledByCreative = false
    /// The drag scrolled an element of the creative.
    var scrolled = false

    /// A swipe's direction, by its main axis.
    var direction: Direction? {
        guard kind == .swipe else { return nil }
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down
    }

    /// "Tap at 120, 340", "Swipe left 180 pt in 220 ms, scrolling the creative".
    var logLine: String {
        let point = "\(Self.whole(x)), \(Self.whole(y))"
        switch kind {
        case .tap:
            return "Tap at \(point)" + (cancelledByCreative ? ": the creative cancelled it (preventDefault), so no click followed" : "")
        case .cancel:
            return "Touch at \(point) cancelled"
        case .swipe:
            let horizontal = direction == .left || direction == .right
            var line = "Swipe \(direction?.rawValue ?? "") \(Self.whole(abs(horizontal ? dx : dy))) pt in \(Self.duration(duration))"
            if cancelledByCreative {
                line += ", handled by the creative (it called preventDefault)"
            } else if scrolled {
                line += ", scrolling the creative"
            }
            return line
        }
    }

    private static func whole(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private static func duration(_ milliseconds: Double) -> String {
        milliseconds < 1_000 ? "\(whole(milliseconds)) ms" : String(format: "%.1f s", milliseconds / 1_000)
    }

    /// Defensive: the page is untrusted. Numbers must be finite and bounded, flags booleans (anything else is unset).
    static func decode(_ object: [String: Any]) -> TouchGesture? {
        guard let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let x = number(object["x"]), let y = number(object["y"]), let dx = number(object["dx"]), let dy = number(object["dy"]),
              let duration = number(object["duration"], range: 0...3_600_000) else { return nil }
        return TouchGesture(kind: kind, x: x, y: y, dx: dx, dy: dy, duration: duration, cancelledByCreative: flag(object["cancelled"]),
                            scrolled: flag(object["scrolled"]))
    }

    private static func number(_ value: Any?, range: ClosedRange<Double> = -100_000...100_000) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite && range.contains(double) ? double : nil
    }

    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}

/// Which presses and releases count as the user touching a creative (pure): a press on it, and the release of that press
/// wherever the pointer is then — a finger lifted after a swipe, when a creative typically opens its landing page.
struct GesturePressTracker {
    private var pressedOnCreative = false

    /// A press; whether it is on the creative.
    mutating func press(inside: Bool) -> Bool {
        pressedOnCreative = inside
        return inside
    }

    /// The release of the primary button; whether it ends a press that began on the creative.
    mutating func release() -> Bool {
        defer { pressedOnCreative = false }
        return pressedOnCreative
    }
}
