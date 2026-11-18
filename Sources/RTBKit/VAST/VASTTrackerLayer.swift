import Foundation

// Merged wrapper trackers without copies (design D6). A wrapper's trackers belong to every ad below it; a wrapper whose
// response is a pod used to copy them into each pod ad, so memory grew with (wrapper trackers × pod size). Each document
// layer now stores its own trackers once, linked to the layer above, and every ad below shares the chain by reference.

/// The tracker lists one document layer contributes to an ad, or (flattened) an ad's merged lists.
struct VASTTrackerLists: Sendable, Hashable {
    var impressions: [String] = []
    var errors: [String] = []
    var trackingEvents: [VASTTracking] = []
    var clickTrackings: [String] = []
    var viewableImpression = VASTViewableImpression()
    var verifications: [VASTVerification] = []

    init(impressions: [String] = [], errors: [String] = [], trackingEvents: [VASTTracking] = [], clickTrackings: [String] = [],
         viewableImpression: VASTViewableImpression = VASTViewableImpression(), verifications: [VASTVerification] = []) {
        self.impressions = impressions
        self.errors = errors
        self.trackingEvents = trackingEvents
        self.clickTrackings = clickTrackings
        self.viewableImpression = viewableImpression
        self.verifications = verifications
    }

    /// What one `<Ad>` contributes (the parts `VASTLineage` attributes, in the same order).
    init(_ body: VASTAd.Body) {
        self.init(impressions: body.impressions, errors: body.errors, trackingEvents: body.linearTrackings,
                  clickTrackings: body.linearClickTrackings, viewableImpression: body.viewableImpression ?? VASTViewableImpression(),
                  verifications: body.verifications)
    }

    /// The number of entries, the unit of the resolver's tracker budget.
    var count: Int {
        [impressions.count, errors.count, trackingEvents.count, clickTrackings.count, viewableImpression.viewable.count,
         viewableImpression.notViewable.count, viewableImpression.viewUndetermined.count, verifications.count]
            .reduce(0, VASTTrackerLayer.saturatingSum)
    }
}

/// One document layer of a resolved ad, linked to the layer above it (outermost wrapper at the root). Immutable and
/// shared: every ad below a wrapper references the wrapper's layer instead of copying its trackers.
final class VASTTrackerLayer: Sendable {
    let parent: VASTTrackerLayer?
    /// The `<Ad>` this layer is.
    let origin: VASTAdOrigin
    let own: VASTTrackerLists
    /// A wrapper's `BlockedAdCategories`, by lower-cased code.
    private let blockedByCode: [String: [VASTCategory]]
    /// Whether this layer or one above blocks any category.
    let blocksCategories: Bool
    /// Budget entries of this layer and every layer above it: the merged lists, plus the companion tracking the
    /// layer's creatives carry (wrapper companions are matched to each ad's companions when planned).
    let cumulativeCount: Int
    /// Error URLs of this layer and every layer above it.
    let cumulativeErrorCount: Int

    init(parent: VASTTrackerLayer?, body: VASTAd.Body, origin: VASTAdOrigin) {
        let own = VASTTrackerLists(body)
        self.parent = parent
        self.origin = origin
        self.own = own
        if case let .wrapper(wrapper) = body {
            blockedByCode = Dictionary(grouping: wrapper.blockedAdCategories) { Self.normalizedCode($0.code) }
        } else {
            blockedByCode = [:]
        }
        blocksCategories = !blockedByCode.isEmpty || parent?.blocksCategories == true
        let companionTrackers = body.creatives.lazy.flatMap(\.companions)
            .reduce(0) { Self.saturatingSum($0, Self.saturatingSum($1.trackingEvents.count, $1.clickTrackings.count)) }
        cumulativeCount = Self.saturatingSum(parent?.cumulativeCount ?? 0, Self.saturatingSum(own.count, companionTrackers))
        cumulativeErrorCount = Self.saturatingSum(parent?.cumulativeErrorCount ?? 0, own.errors.count)
    }

    /// The layers from the outermost down to this one.
    var chain: [VASTTrackerLayer] {
        var layers: [VASTTrackerLayer] = []
        var cursor: VASTTrackerLayer? = self
        while let layer = cursor {
            layers.append(layer)
            cursor = layer.parent
        }
        return layers.reversed()
    }

    /// `part` of every layer, outermost first.
    func collect<Value>(_ part: (VASTTrackerLists) -> [Value]) -> [Value] {
        chain.flatMap { part($0.own) }
    }

    var mergedViewableImpression: VASTViewableImpression {
        chain.reduce(VASTViewableImpression()) { $0.merged(with: $1.own.viewableImpression) }
    }

    func flattened() -> VASTTrackerLists {
        let layers = chain
        return VASTTrackerLists(impressions: layers.flatMap(\.own.impressions), errors: layers.flatMap(\.own.errors),
                                trackingEvents: layers.flatMap(\.own.trackingEvents), clickTrackings: layers.flatMap(\.own.clickTrackings),
                                viewableImpression: layers.reduce(VASTViewableImpression()) { $0.merged(with: $1.own.viewableImpression) },
                                verifications: layers.flatMap(\.own.verifications))
    }

    /// The first of `categories` (an InLine ad's) that this layer or one above blocks (VAST 4.1 §3.19.2), outermost
    /// wrapper first: same code (case-insensitive), and the same authority when both name one.
    func block(of categories: [VASTCategory]) -> (index: Int, blockedBy: VASTCategory, wrapper: VASTAdOrigin)? {
        guard blocksCategories, !categories.isEmpty else { return nil }
        for layer in chain where !layer.blockedByCode.isEmpty {
            for (index, category) in categories.enumerated() {
                let candidates = layer.blockedByCode[Self.normalizedCode(category.code)] ?? []
                if let blocked = candidates.first(where: { Self.sameAuthority($0.authority, category.authority) }) {
                    return (index, blocked, layer.origin)
                }
            }
        }
        return nil
    }

    private static func normalizedCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Authorities agree when either is absent, or when they name the same list (case and trailing slashes aside).
    private static func sameAuthority(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return true }
        func normalized(_ text: String) -> Substring {
            var value = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            while value.hasSuffix("/") { value = value.dropLast() }
            return value
        }
        return normalized(lhs) == normalized(rhs)
    }

    static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

/// A resolved ad's merged lists: a shared layer chain (resolver-built) or the ad's own lists (hand-built, or after a
/// setter). Reading builds the list; writing gives the ad its own copy of every list.
struct VASTMergedTrackers: Sendable {
    private enum Storage: Sendable {
        case shared(VASTTrackerLayer?)
        case own(VASTTrackerLists)
    }

    private var storage: Storage

    init(layer: VASTTrackerLayer?) {
        storage = .shared(layer)
    }

    init(lists: VASTTrackerLists) {
        storage = .own(lists)
    }

    func collect<Value>(_ part: (VASTTrackerLists) -> [Value]) -> [Value] {
        switch storage {
        case let .shared(layer): layer?.collect(part) ?? []
        case let .own(lists): part(lists)
        }
    }

    var viewableImpression: VASTViewableImpression {
        switch storage {
        case let .shared(layer): layer?.mergedViewableImpression ?? VASTViewableImpression()
        case let .own(lists): lists.viewableImpression
        }
    }

    var lists: VASTTrackerLists {
        switch storage {
        case let .shared(layer): layer?.flattened() ?? VASTTrackerLists()
        case let .own(lists): lists
        }
    }

    mutating func modify(_ change: (inout VASTTrackerLists) -> Void) {
        var current = lists
        change(&current)
        storage = .own(current)
    }
}

extension VASTAd.Body {
    var creatives: [VASTCreative] {
        switch self {
        case let .inline(inline): inline.creatives
        case let .wrapper(wrapper): wrapper.creatives
        }
    }
}
