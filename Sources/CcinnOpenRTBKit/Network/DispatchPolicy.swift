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
    /// Loaded by the monitor: served locally for a `.local` destination, otherwise sent by its transport.
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
    static let offlineNote = "Offline: recorded, not sent"

    /// Where a request would go: only a `.remote` one can leave the machine.
    enum Destination: Sendable, Hashable {
        /// `data:` and `ccinn-sample:` URLs, served on this Mac.
        case local
        /// Everything else.
        case remote

        init(url: String) {
            switch URLText.scheme(url) {
            case "data"?, SampleURL.scheme?: self = .local
            default: self = .remote
            }
        }
    }

    /// The decision for one request.
    /// - Trackers obey the mode: Simulated records, Real sends (script trackers are injected by the renderer).
    /// - Content is fetched in both modes (it is needed to render the ad), except remote content when `offline`.
    /// - Offline is Simulated tracking plus offline content: trackers are recorded whatever `mode` says.
    /// - A bid request the user sends (the Client tab) or a sync the user runs (the Sync tab) is no tracker: sent in either
    ///   mode, recorded and not sent when Offline.
    /// - Navigation and creative requests are never sent by the monitor.
    static func action(for category: TrackerCategory, isScript: Bool, mode: TrackingMode, offline: Bool = false,
                       destination: Destination = .remote) -> DispatchAction {
        switch category {
        case .navigation:
            return .record(.simulated, .simulated, note: navigationNote)
        case .creative:
            return .record(.simulated, .simulated, note: creativeNote)
        case .content:
            if offline, destination == .remote { return .record(.blocked, .offline, note: offlineNote) }
            return .send(SendPermit(category: category, mode: mode))
        case .bidRequest, .userSync:
            if offline { return .record(.blocked, .offline, note: offlineNote) }
            return .send(SendPermit(category: category, mode: mode))
        case .win, .billing, .loss, .impression, .viewability, .event, .click, .error, .verification:
            switch (offline ? .simulated : mode, isScript) {
            case (.simulated, false): return .record(.simulated, .simulated, note: simulatedNote)
            case (.simulated, true): return .record(.simulated, .simulated, note: scriptSimulatedNote)
            case (.real, true): return .renderer(note: scriptRealNote)
            case (.real, false): return .send(SendPermit(category: category, mode: mode))
            }
        }
    }

    /// A permit for the next hop of a chain, re-checked against the mode and Offline at that moment: switching back to
    /// Simulated stops a tracker's redirect chain before its next hop, and going Offline stops any chain.
    static func permit(for category: TrackerCategory, isScript: Bool, mode: TrackingMode, offline: Bool = false,
                       destination: Destination = .remote) -> SendPermit? {
        if case let .send(permit) = action(for: category, isScript: isScript, mode: mode, offline: offline, destination: destination) {
            return permit
        }
        return nil
    }
}
