import Foundation

/// Which requests a lifecycle event produces (design D7). Pure and deterministic for a fixed context (apart from each
/// request's random `id`). Owner: kit-openrtb (auction, AdCOM and Native parts); the VAST part is `VASTTrackingPlan`
/// (kit-vast).
///
/// | Event | Requests, in order |
/// |---|---|
/// | `.won` | win notice (`nurl` / `purl`), unless `options.exchangeSendsWinNotice` is off |
/// | `.rendered` | `burl`; AdCOM events type 1 (loaded), then type 2 (impression); Native `imptrackers`, `eventtrackers` event 1, `jstracker` |
/// | `.viewable(level)` | AdCOM events 3 / 4 / 5; Native `eventtrackers` 2 / 3 / 4 |
/// | `.click(assetID)` | Native: asset link `clicktrackers`, ad link `clicktrackers`, then a navigation; image banner: `trkr`, then a navigation; HTML: nothing (the creative navigates itself) |
/// | `.loss(reason)` | `lurl` with `${AUCTION_LOSS}` = `reason` |
/// | `.closed` | nothing |
/// | `.video`, `.videoViewability`, `.videoClick`, `.companionView`, `.companionClick`, `.error` | `VASTTrackingPlan` (when `vast` is given) |
///
/// Exchange-side and SDK trackers substitute OpenRTB `${…}` macros only; VAST `[…]` macros are the player's.
///
/// Parents (decisions.md "Network relationships"): every request this plan builds (auction notices, AdCOM events,
/// Native trackers, click trackers and the navigation) is a child of `options.markupRequestID`, the request that
/// delivered the markup (nil for inline `adm`). A tracker never parents a navigation: one click's requests are siblings
/// sharing the trigger "click". VAST requests come from `VASTTrackingPlan` unchanged, each a child of its VAST hop.
public enum TrackingPlan {
    public struct Options: Sendable, Hashable {
        /// The exchange sends the win notice (`nurl`) itself.
        public var exchangeSendsWinNotice: Bool
        /// The network entry of the request that delivered the markup (`nurl`/`purl` or `display.curl`), the parent of
        /// every non-VAST request; `nil` when the markup is inline in the bid response.
        public var markupRequestID: UUID?

        public init(exchangeSendsWinNotice: Bool = true, markupRequestID: UUID? = nil) {
            self.exchangeSendsWinNotice = exchangeSendsWinNotice
            self.markupRequestID = markupRequestID
        }
    }

    public static func requests(for event: AdLifecycleEvent, candidate: AdCandidate, native: NativeAd?, vast: ResolvedVAST?,
                                context: MacroContext, options: Options = Options()) -> [TrackerRequest] {
        let factory = TrackerRequestFactory(candidate: candidate, context: context, parentID: options.markupRequestID)
        switch event {
        case .won:
            guard options.exchangeSendsWinNotice else { return [] }
            return AuctionTracking.win(candidate, factory: factory)
        case .rendered:
            return AuctionTracking.billing(candidate, factory: factory)
                + AdcomTracking.rendered(candidate.adcomEvents, factory: factory)
                + (native.map { NativeTracking.impression($0, factory: factory) } ?? [])
        case let .viewable(level):
            return AdcomTracking.viewable(candidate.adcomEvents, level: level, factory: factory)
                + (native.map { NativeTracking.viewable($0, level: level, factory: factory) } ?? [])
        case let .click(assetID):
            return displayClick(assetID: assetID, candidate: candidate, native: native, factory: factory)
        case .closed:
            return []
        case let .loss(reason):
            var lossContext = context
            lossContext.lossReason = reason
            return AuctionTracking.loss(candidate, reason: reason,
                                        factory: TrackerRequestFactory(candidate: candidate, context: lossContext, parentID: options.markupRequestID))
        case .video, .videoViewability, .videoClick, .companionView, .companionClick, .error:
            guard let vast else { return [] }
            return VASTTrackingPlan.requests(for: event, vast: vast, candidate: candidate, context: context,
                                             source: vastSource(native: native, factory: factory))
        }
    }

    /// Display and Native clicks. HTML creatives open their own destination (`mraid.open`, `window.open`, links), which the
    /// renderer records as a navigation; VAST clicks are `.videoClick`.
    private static func displayClick(assetID: Int?, candidate: AdCandidate, native: NativeAd?, factory: TrackerRequestFactory) -> [TrackerRequest] {
        switch candidate.markup {
        case .native:
            return native.map { NativeTracking.click($0, assetID: assetID, factory: factory) } ?? []
        case let .image(banner):
            return banner.link.map { AdcomTracking.click($0, factory: factory) } ?? []
        case .html, .vast, .none:
            return []
        }
    }

    /// The VAST of a Native ad is its video asset's; otherwise the bid's own.
    private static func vastSource(native: NativeAd?, factory: TrackerRequestFactory) -> String {
        guard let videoAsset = native?.assets.first(where: { $0.vastSource != nil }) else { return factory.source() }
        return factory.source("native", "asset \(videoAsset.id)", "video")
    }
}
