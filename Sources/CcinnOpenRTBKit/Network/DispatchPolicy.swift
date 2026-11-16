import Foundation
import RTBKit

/// Proof that a request may go out over the network. Only `DispatchPolicy` can create one, and the monitor's single
/// call site of `HTTPTransport.perform` requires it, so a Simulated-mode tracker cannot reach the transport: there is
/// no permit to pass (design D9, "never send a tracker in Simulated mode").
struct SendPermit: Sendable, Hashable {
    let category: TrackerCategory
    let mode: TrackingMode

    fileprivate init(category: TrackerCategory, mode: TrackingMode) {
        self.category = category
        self.mode = mode
    }
}

/// What the monitor does with a request: the one place that decides between recording and sending.
enum DispatchAction: Sendable, Hashable {
    /// Recorded only; nothing leaves the machine.
    case record(NetworkEntryState, NetworkDelivery, note: String?)
    /// Sent by the monitor's transport.
    case send(SendPermit)
    /// Loaded by the renderer (Real-mode script trackers); the monitor records it and waits for the renderer's report.
    case renderer(note: String)
}

enum DispatchPolicy {
    static let simulatedNote = "Simulated: recorded, not sent"
    static let scriptSimulatedNote = "Script tracker: injected only in Real mode"
    static let scriptRealNote = "Injected by renderer"
    static let navigationNote = "Click-through: recorded, not followed in the simulator"
    static let creativeNote = "Creative requests are loaded by the web view"

    /// The decision for one request.
    /// - Trackers obey the mode: Simulated records, Real sends (script trackers are injected by the renderer).
    /// - Content is always fetched (it is needed to render the ad).
    /// - Navigation and creative requests are never sent by the monitor.
    static func action(for category: TrackerCategory, isScript: Bool, mode: TrackingMode) -> DispatchAction {
        switch category {
        case .navigation:
            return .record(.simulated, .simulated, note: navigationNote)
        case .creative:
            return .record(.simulated, .simulated, note: creativeNote)
        case .content:
            return .send(SendPermit(category: category, mode: mode))
        default:
            switch (mode, isScript) {
            case (.simulated, false): return .record(.simulated, .simulated, note: simulatedNote)
            case (.simulated, true): return .record(.simulated, .simulated, note: scriptSimulatedNote)
            case (.real, true): return .renderer(note: scriptRealNote)
            case (.real, false): return .send(SendPermit(category: category, mode: mode))
            }
        }
    }

    /// A permit for the next hop of a chain, re-checked against the mode at that moment: switching back to Simulated
    /// stops a tracker's redirect chain before its next hop.
    static func permit(for category: TrackerCategory, isScript: Bool, mode: TrackingMode) -> SendPermit? {
        if case let .send(permit) = action(for: category, isScript: isScript, mode: mode) { return permit }
        return nil
    }
}
