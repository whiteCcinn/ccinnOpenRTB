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
    /// The Linear a player plays: the first creative that has one (an InLine ad should carry a single Linear).
    var playedLinear: VASTLinear? {
        creatives.lazy.compactMap(\.linear).first
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
