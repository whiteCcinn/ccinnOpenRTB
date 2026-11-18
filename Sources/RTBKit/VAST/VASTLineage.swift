import Foundation

// What each document of a wrapper chain contributes to the resolved ad. The resolver merges these parts layer by layer
// (outermost wrapper first, inline ad last); the tracking plan walks the same layers to name each URL's origin document
// and the request that delivered it. Keeping both on these accessors keeps the merge order and the attribution in step.

extension VASTAd.Body {
    var impressions: [String] {
        switch self {
        case let .inline(inline): inline.impressions
        case let .wrapper(wrapper): wrapper.impressions
        }
    }

    var errors: [String] {
        switch self {
        case let .inline(inline): inline.errors
        case let .wrapper(wrapper): wrapper.errors
        }
    }

    /// The linear `TrackingEvents`: every tracking-only Linear of a wrapper; the played Linear of an inline ad.
    var linearTrackings: [VASTTracking] {
        switch self {
        case let .inline(inline): inline.playedLinear?.trackingEvents ?? []
        case let .wrapper(wrapper): wrapper.creatives.compactMap(\.linear).flatMap(\.trackingEvents)
        }
    }

    /// `VideoClicks/ClickTracking`, chosen like `linearTrackings`.
    var linearClickTrackings: [String] {
        switch self {
        case let .inline(inline): inline.playedLinear?.clickTrackings ?? []
        case let .wrapper(wrapper): wrapper.creatives.compactMap(\.linear).flatMap(\.clickTrackings)
        }
    }

    var viewableImpression: VASTViewableImpression? {
        switch self {
        case let .inline(inline): inline.viewableImpression
        case let .wrapper(wrapper): wrapper.viewableImpression
        }
    }

    var verifications: [VASTVerification] {
        switch self {
        case let .inline(inline): inline.verifications
        case let .wrapper(wrapper): wrapper.verifications
        }
    }

    var isWrapper: Bool {
        if case .wrapper = self { return true }
        return false
    }
}

extension VASTInline {
    /// The creative a player plays: the first one with a Linear (an InLine ad should carry a single Linear).
    var playedCreative: VASTCreative? {
        creatives.first { $0.linear != nil }
    }

    /// The Linear of `playedCreative`.
    var playedLinear: VASTLinear? {
        playedCreative?.linear
    }
}

extension VASTViewableImpression {
    /// `self` followed by `other`, per outcome.
    func merged(with other: VASTViewableImpression?) -> VASTViewableImpression {
        guard let other else { return self }
        return VASTViewableImpression(viewable: viewable + other.viewable, notViewable: notViewable + other.notViewable,
                                      viewUndetermined: viewUndetermined + other.viewUndetermined)
    }
}

/// One document a resolved ad passed through.
struct VASTLayer: Sendable {
    let origin: VASTAdOrigin
    let hop: VASTHop
    let ad: VASTAd

    /// `VAST` for markup carried in the bid, `VAST hop 2` for a fetched document.
    var documentLabel: String {
        origin.hop == 0 && hop.url == nil ? "VAST" : "VAST hop \(origin.hop)"
    }

    /// `Wrapper Ad[1] id="w1"` / `InLine Ad[2] 'Title'`.
    var adLabel: String {
        let position = "Ad[" + VASTLabel.ordinal(origin.ad) + "]"
        switch ad.body {
        case .wrapper:
            return "Wrapper " + position + (ad.id.map { " id=\"\($0)\"" } ?? "")
        case let .inline(inline):
            return "InLine " + position + (inline.adTitle.map { " '\($0)'" } ?? ad.id.map { " id=\"\($0)\"" } ?? "")
        }
    }
}

extension VASTLayer {
    /// A wrapper layer's tracking-only companions (`Wrapper/Creatives/Creative/CompanionAds`); empty for the InLine layer.
    var wrapperCompanions: [VASTCompanion] {
        guard case let .wrapper(wrapper) = ad.body else { return [] }
        return wrapper.creatives.flatMap(\.companions)
    }
}

/// Which of a wrapper layer's companions carry tracking for an InLine companion. VAST says wrapper creatives may carry
/// companion tracking but not how it maps to the InLine companions, so the simulator matches (decision of the lead):
/// 1. by `id`;
/// 2. else by width × height;
/// 3. else the layer's only companion;
/// 4. else none (the resolver warns about it).
enum VASTCompanionMatch {
    /// Indices into `candidates`, in document order.
    static func wrapperCompanionIndices(for companion: VASTCompanion, in candidates: [VASTCompanion]) -> [Int] {
        if let id = companion.id {
            let byID = candidates.indices.filter { candidates[$0].id == id }
            if !byID.isEmpty { return byID }
        }
        if let width = companion.width, let height = companion.height {
            let bySize = candidates.indices.filter { candidates[$0].width == width && candidates[$0].height == height }
            if !bySize.isEmpty { return bySize }
        }
        return candidates.count == 1 ? [0] : []
    }
}

/// Labels for VAST requests and issues.
enum VASTLabel {
    /// The 1-based position of a 0-based index. Total: never overflows, even for an index nobody validated.
    static func ordinal(_ index: Int) -> String {
        let (next, overflow) = index.addingReportingOverflow(1)
        return overflow ? String(index) : String(next)
    }

    /// `Companion 2 id="c1"`, with ` 300×250` when `withSize` and both dimensions are known.
    static func companion(_ companion: VASTCompanion, index: Int, withSize: Bool = false) -> String {
        var label = "Companion " + ordinal(index) + (companion.id.map { " id=\"\($0)\"" } ?? "")
        if withSize, let width = companion.width, let height = companion.height { label += " \(width)×\(height)" }
        return label
    }
}

/// The layers of one resolved ad, recovered from `ResolvedVAST.chain` and the ad's `origin`.
struct VASTLineage: Sendable {
    let layers: [VASTLayer]

    /// `nil` when the origin does not lead through the chain to an inline ad (a hand-built `ResolvedVASTAd`).
    init?(origin: [VASTAdOrigin], chain: [VASTHop]) {
        var layers: [VASTLayer] = []
        for item in origin {
            guard chain.indices.contains(item.hop), let document = chain[item.hop].document, document.ads.indices.contains(item.ad) else {
                return nil
            }
            layers.append(VASTLayer(origin: item, hop: chain[item.hop], ad: document.ads[item.ad]))
        }
        guard let last = layers.last, !last.ad.body.isWrapper, layers.dropLast().allSatisfy(\.ad.body.isWrapper) else { return nil }
        self.layers = layers
    }

    var inlineLayer: VASTLayer? { layers.last }

    /// `merged` with the layer each value came from, when the layers' parts concatenate to exactly `merged`; otherwise
    /// every value without a layer (the merged list was not produced from this chain).
    func attribute<Value: Equatable>(_ merged: [Value], part: (VASTAd.Body) -> [Value]) -> [(value: Value, layer: VASTLayer?)] {
        let segments = layers.flatMap { layer in part(layer.ad.body).map { (value: $0, layer: Optional(layer)) } }
        guard segments.map(\.value) == merged else { return merged.map { (value: $0, layer: nil) } }
        return segments
    }
}
