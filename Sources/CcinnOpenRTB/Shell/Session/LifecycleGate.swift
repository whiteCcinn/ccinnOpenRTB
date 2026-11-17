import RTBKit

/// Once-per-render bookkeeping for lifecycle events (pure).
///
/// - Fire-once events: `won`, `rendered`, each viewability level, one VAST viewability outcome per pod ad, each VAST
///   event that fires once per ad (and each `progress` offset once), each companion view, `closed`, the loss notice and
///   each error code per ad. Clicks and player interactions (mute, pause, …) may repeat.
/// - Win and loss exclude each other: a lost bid is never rendered, and a won bid never sends a loss notice.
struct LifecycleGate {
    enum Key: Hashable {
        case won, rendered, closed, loss
        case viewable(ViewabilityLevel)
        case videoViewability(adIndex: Int)
        case video(VASTEvent, adIndex: Int)
        case companionView(adIndex: Int, companionIndex: Int)
        case error(VASTErrorCode, adIndex: Int?)
    }

    enum Verdict: Equatable {
        case admitted
        case alreadyFired
        /// The other auction outcome already happened.
        case contradictsOutcome
    }

    private(set) var fired: Set<Key> = []

    var hasLost: Bool { fired.contains(.loss) }
    var hasWonOrRendered: Bool { fired.contains(.won) || fired.contains(.rendered) }

    /// Records `event` when it may fire now.
    mutating func admit(_ event: AdLifecycleEvent) -> Verdict {
        if case .loss = event {
            if hasWonOrRendered { return .contradictsOutcome }
        } else if hasLost {
            return .contradictsOutcome
        }
        guard let key = Self.onceKey(for: event) else { return .admitted }
        return fired.insert(key).inserted ? .admitted : .alreadyFired
    }

    func hasFired(_ event: AdLifecycleEvent) -> Bool {
        Self.onceKey(for: event).map(fired.contains) ?? false
    }

    /// The key of a fire-once event; `nil` for events that may repeat.
    static func onceKey(for event: AdLifecycleEvent) -> Key? {
        switch event {
        case .won: .won
        case .rendered: .rendered
        case .closed: .closed
        case .loss: .loss
        case let .viewable(level): .viewable(level)
        case let .videoViewability(_, adIndex): .videoViewability(adIndex: adIndex)
        case let .video(videoEvent, adIndex):
            switch videoEvent {
            case .progress: .video(videoEvent, adIndex: adIndex)
            default: videoEvent.firesOnce ? .video(videoEvent, adIndex: adIndex) : nil
            }
        case let .companionView(adIndex, companionIndex): .companionView(adIndex: adIndex, companionIndex: companionIndex)
        case let .error(code, adIndex): .error(code, adIndex: adIndex)
        case .click, .videoClick, .companionClick: nil
        }
    }
}
