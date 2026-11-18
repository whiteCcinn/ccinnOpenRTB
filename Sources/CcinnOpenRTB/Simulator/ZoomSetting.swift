import CoreGraphics

/// The simulator's zoom: fit the device into the pane, or a fixed magnification.
enum ZoomSetting: Hashable, Sendable {
    case fit
    case scale(Double)

    static let levels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2]
    static let minimum = 0.1
    static let maximum = 3.0
    /// Fit never magnifies beyond actual size (1 pt on the device = 1 pt on the Mac).
    static let maximumFit = 1.0

    /// The magnification that fits `content` (plus `margin` on every side) into `available`.
    static func fitScale(content: CGSize, available: CGSize, margin: CGFloat) -> Double {
        guard content.width > 0, content.height > 0 else { return 1 }
        let width = max(1, available.width - margin * 2)
        let height = max(1, available.height - margin * 2)
        let scale = Double(min(width / content.width, height / content.height))
        guard scale.isFinite else { return 1 }
        return min(maximumFit, max(minimum, scale))
    }

    /// The magnification to use in a pane: `fitScale` for `.fit`, else the fixed value clamped.
    func magnification(fitting fit: Double) -> Double {
        switch self {
        case .fit: fit
        case let .scale(value): Self.clamped(value)
        }
    }

    /// The next preset above `current`.
    static func zoomedIn(from current: Double) -> ZoomSetting {
        .scale(levels.first { $0 > current + 0.005 } ?? clamped(current * 1.25))
    }

    /// The next preset below `current`.
    static func zoomedOut(from current: Double) -> ZoomSetting {
        .scale(levels.last { $0 < current - 0.005 } ?? clamped(current / 1.25))
    }

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(maximum, max(minimum, value))
    }

    var label: String {
        switch self {
        case .fit: "Fit"
        case let .scale(value): "\(Int((Self.clamped(value) * 100).rounded()))%"
        }
    }
}
