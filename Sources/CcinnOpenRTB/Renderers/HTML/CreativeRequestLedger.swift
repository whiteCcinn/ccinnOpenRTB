import Foundation

/// Bookkeeping of the requests one creative document made, between the injected instrumentation and the network monitor
/// (pure; the recording itself is a closure so the ledger is unit-tested without a monitor).
///
/// - `start` records a request once per request id (`<frame token>:<counter>`); `end` hands back its entry once, so the
///   renderer can report the outcome of a load the web view performed.
/// - `timing` records a load the hooks could not see (CSS backgrounds, fonts) — resource timing reports it after the fact.
/// - At most `capacity` requests are recorded per document; the first one over the limit returns `.overflow` (log it once),
///   later ones are ignored. A creative that floods requests cannot flood the log or the bridge.
struct CreativeRequestLedger {
    enum Outcome: Equatable {
        case recorded(UUID)
        /// Duplicate request id, or over capacity after the overflow was reported.
        case ignored
        /// The first request over capacity.
        case overflow
    }

    typealias Record = (_ url: String, _ kind: String, _ blocked: Bool) -> UUID

    static let defaultCapacity = 1000

    let capacity: Int
    private(set) var recordedCount = 0
    private var overflowed = false
    private var open: [String: UUID] = [:]
    private var seen: Set<String> = []

    init(capacity: Int = CreativeRequestLedger.defaultCapacity) {
        self.capacity = max(0, capacity)
    }

    mutating func start(rid: String, url: String, kind: String, blocked: Bool, record: Record) -> Outcome {
        guard !seen.contains(rid) else { return .ignored }
        guard let admitted = admit() else { return .ignored }
        guard admitted else { return .overflow }
        seen.insert(rid)
        let id = record(url, kind, blocked)
        open[rid] = id
        return .recorded(id)
    }

    /// The entry of a request that finished, once.
    mutating func end(rid: String) -> UUID? {
        open.removeValue(forKey: rid)
    }

    /// Every request still waiting for its outcome (the document is going away); the ledger forgets them.
    mutating func drainOpen() -> [UUID] {
        defer { open.removeAll() }
        return Array(open.values)
    }

    mutating func timing(url: String, kind: String, blocked: Bool, record: Record) -> Outcome {
        guard let admitted = admit() else { return .ignored }
        guard admitted else { return .overflow }
        return .recorded(record(url, kind, blocked))
    }

    /// `true` admitted, `false` first overflow, `nil` already overflowed.
    private mutating func admit() -> Bool? {
        if recordedCount < capacity {
            recordedCount += 1
            return true
        }
        if overflowed { return nil }
        overflowed = true
        return false
    }
}
