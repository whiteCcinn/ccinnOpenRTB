import Foundation

/// OpenRTB auction notices (2.x `nurl`/`burl`/`lurl`, 3.0 `purl`/`burl`/`lurl`). The exchange sends them server-side;
/// the simulator records them (Simulated) or sends them (Real) on the exchange's behalf.
enum AuctionTracking {
    /// `.won`: the win notice.
    static func win(_ candidate: AdCandidate, factory: TrackerRequestFactory) -> [TrackerRequest] {
        notice(candidate.winURL, category: .win, trigger: "win", key: "win notice", factory: factory)
    }

    /// `.rendered`: the billing notice (2.5+ / 3.0 `burl`).
    static func billing(_ candidate: AdCandidate, factory: TrackerRequestFactory) -> [TrackerRequest] {
        notice(candidate.billingURL, category: .billing, trigger: "billing", key: "burl", factory: factory)
    }

    /// `.loss(reason)`: the loss notice; `factory` carries `reason` as `${AUCTION_LOSS}`.
    static func loss(_ candidate: AdCandidate, reason: Int, factory: TrackerRequestFactory) -> [TrackerRequest] {
        notice(candidate.lossURL, category: .loss, trigger: "loss (\(reason))", key: "lurl", factory: factory)
    }

    private static func notice(_ template: String?, category: TrackerCategory, trigger: String, key: String,
                               factory: TrackerRequestFactory) -> [TrackerRequest] {
        guard let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [factory.url(template, category: category, trigger: trigger, source: factory.source(key))]
    }
}
