import Foundation
import RTBKit

/// A companion with its index in `ads[adIndex].inline.creatives.flatMap(\.companions)` (the index the tracking plan uses).
struct IndexedCompanion: Equatable, Sendable {
    var companionIndex: Int
    var companion: VASTCompanion
}

/// What the player needs to know about one pod ad (pure, derived from the resolved VAST).
struct VASTPodItem: Equatable, Sendable {
    /// Index into `ResolvedVAST.ads` — the `adIndex` of every event this ad reports.
    var adIndex: Int
    var title: String?
    var advertiser: String?
    /// The first linear creative; `nil` when the ad has none.
    var linear: VASTLinear?
    var isNonLinearOnly: Bool
    var companions: [IndexedCompanion]
    /// The fetch that delivered the inline document (network parent of the media request); `nil` for inline markup.
    var mediaParentID: UUID?
    /// Network source path: `bid 0.0 › VAST › ad 1 of 2 'Title'`.
    var source: String

    var declaredDuration: Double? { linear?.duration }
    var skipOffset: VASTOffset? { linear?.skipOffset }
    var clickThrough: String? {
        guard let url = linear?.clickThrough?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        return url
    }

    var mediaFiles: [VASTMediaFile] { linear?.mediaFiles ?? [] }
    /// `progress` offsets of the merged tracking events (wrappers + inline), in document order.
    var progressOffsets: [VASTOffset]

    /// The error an ad without a linear creative reports: 201 (expected linear, got non-linear) or 400.
    var missingLinearError: VASTErrorCode { isNonLinearOnly ? .unexpectedLinearity : .linearError }
}

enum VASTPodPlan {
    static func items(for vast: ResolvedVAST, source: String) -> [VASTPodItem] {
        let count = vast.ads.count
        return vast.ads.enumerated().map { index, ad in
            let creatives = ad.inline.creatives
            let linear = creatives.lazy.compactMap(\.linear).first
            let companions = creatives.flatMap(\.companions).enumerated().map { IndexedCompanion(companionIndex: $0.offset, companion: $0.element) }
            let progress = ad.trackingEvents.compactMap { tracking -> VASTOffset? in
                if case let .progress(offset) = tracking.event { return offset }
                return nil
            }
            var label = "\(source) › ad \(index + 1) of \(count)"
            if let title = ad.inline.adTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                label += " '\(title.prefix(60))'"
            }
            return VASTPodItem(adIndex: index, title: ad.inline.adTitle, advertiser: ad.inline.adSystem, linear: linear,
                               isNonLinearOnly: linear == nil && creatives.contains(where: \.hasNonLinear), companions: companions,
                               mediaParentID: parentID(of: ad, in: vast), source: label, progressOffsets: progress)
        }
    }

    private static func parentID(of ad: ResolvedVASTAd, in vast: ResolvedVAST) -> UUID? {
        guard let hop = ad.origin.last?.hop, vast.chain.indices.contains(hop) else { return nil }
        return vast.chain[hop].requestID
    }
}
