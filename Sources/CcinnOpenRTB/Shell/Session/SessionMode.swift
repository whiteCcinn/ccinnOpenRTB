import CcinnOpenRTBKit
import Foundation

/// What a window's session loads and sends: the toolbar's "Offline · Simulated · Real". Simulated is the default;
/// Offline is opt-in (remembered per window); Real asks for confirmation every time and is never remembered.
enum SessionMode: String, CaseIterable, Identifiable, Sendable {
    /// Simulated tracking, and no content from the network either: only `data:` URLs and built-in samples load.
    case offline
    /// Trackers and notices are recorded, never sent; the ad's content loads from the markup's URLs.
    case simulated
    /// Trackers and notices are sent.
    case real

    var id: Self { self }

    var title: String {
        switch self {
        case .offline: "Offline"
        case .simulated: "Simulated"
        case .real: "Real"
        }
    }

    var systemImage: String {
        switch self {
        case .offline: "wifi.slash"
        case .simulated: "shield.lefthalf.filled"
        case .real: "dot.radiowaves.left.and.right"
        }
    }

    /// The tooltip: what this mode loads and sends.
    var help: String {
        switch self {
        case .offline: "Offline: nothing is loaded or sent; only data: URLs and built-in samples render, the rest shows a placeholder"
        case .simulated: "Simulated: trackers and notices are never sent; ad content loads from the markup's URLs"
        case .real: "Real: trackers and notices are sent to their servers (asks for confirmation first)"
        }
    }

    /// The mode of `monitor`.
    @MainActor
    init(_ monitor: NetworkMonitor) {
        self = monitor.offline ? .offline : monitor.mode == .real ? .real : .simulated
    }
}
