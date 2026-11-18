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
/// | `.click(assetID)` | Native: the clicked asset's own link, else the ad's main link (Native 1.2 §5.4) — its `clicktrackers`, then a navigation; image banner: `trkr`, then a navigation; HTML: nothing (the creative navigates itself) |
/// | `.loss(reason)` | `lurl` with `${AUCTION_LOSS}` = `reason` (every other event is a won bid: `${AUCTION_LOSS}` = 0, "Bid Won") |
/// | `.closed` | nothing |
/// | `.video`, `.videoViewability`, `.videoClick`, `.companionView`, `.companionClick`, `.iconView`, `.iconClick`, `.error` | `VASTTrackingPlan` (when `vast` is given) |
///
/// Macros by document origin (decisions.md "Macros"): the bid response's own URLs substitute OpenRTB `${…}` only, as the
/// exchange does; Native URLs fire as written (an inline `adm` was substituted before parsing, delivered markup never
/// is); VAST URLs expand VAST `[…]` only (`VASTTrackingPlan`). Whatever is left is listed in `unknownMacros`.
///
/// Parents (decisions.md "Network relationships"): a request's parent is the request that delivered the document
/// containing its URL. The pasted bid response has none, so its URLs (nurl/purl, burl, lurl, AdCOM `display.event`, the
/// AdCOM banner link) are roots. URLs inside the markup (Native trackers, clicktrackers and link) are children of
/// `options.markupRequestID`, the nurl/purl or `display.curl` request that delivered it. A tracker never parents a
/// navigation: one click's requests are siblings sharing the trigger "click". VAST requests come from
/// `VASTTrackingPlan` unchanged, each a child of its VAST hop.
public enum TrackingPlan {
    public struct Options: Sendable, Hashable {
        /// The exchange sends the win notice (`nurl`) itself.
        public var exchangeSendsWinNotice: Bool
        /// The network entry of the request that delivered the markup (`nurl`/`purl` or `display.curl`), the parent of the
        /// URLs inside that markup; `nil` when the markup is inline in the bid response.
        public var markupRequestID: UUID?

        public init(exchangeSendsWinNotice: Bool = true, markupRequestID: UUID? = nil) {
            self.exchangeSendsWinNotice = exchangeSendsWinNotice
            self.markupRequestID = markupRequestID
        }
    }

    public static func requests(for event: AdLifecycleEvent, candidate: AdCandidate, native: NativeAd?, vast: ResolvedVAST?,
                                context hostContext: MacroContext, options: Options = Options()) -> [TrackerRequest] {
        // OpenRTB 2.6 §4.4 / §5.25: a loss reason exists only on the loss notice. Every other event belongs to a won bid,
        // whose `${AUCTION_LOSS}` is 0 ("Bid Won") whatever the host's context still carries.
        var context = hostContext
        if case let .loss(reason) = event {
            context.lossReason = reason
        } else {
            context.lossReason = OpenRTBMacro.bidWonLossReason
        }
        // One factory per document: the pasted response (no parent) and the markup (its delivering request, if any).
        let response = TrackerRequestFactory(candidate: candidate, context: context, origin: .bidResponse)
        let markup = TrackerRequestFactory(candidate: candidate, context: context, origin: .markup, parentID: options.markupRequestID)
        switch event {
        case .won:
            guard options.exchangeSendsWinNotice else { return [] }
            return AuctionTracking.win(candidate, factory: response)
        case .rendered:
            return AuctionTracking.billing(candidate, factory: response)
                + AdcomTracking.rendered(candidate.adcomEvents, factory: response)
                + (native.map { NativeTracking.impression($0, factory: markup) } ?? [])
        case let .viewable(level):
            return AdcomTracking.viewable(candidate.adcomEvents, level: level, factory: response)
                + (native.map { NativeTracking.viewable($0, level: level, factory: markup) } ?? [])
        case let .click(assetID):
            return displayClick(assetID: assetID, candidate: candidate, native: native, response: response, markup: markup)
        case .closed:
            return []
        case let .loss(reason):
            return AuctionTracking.loss(candidate, reason: reason, factory: response)
        case .video, .videoViewability, .videoClick, .companionView, .companionClick, .iconView, .iconClick, .error:
            guard let vast else { return [] }
            return VASTTrackingPlan.requests(for: event, vast: vast, candidate: candidate, context: context,
                                             source: vastSource(native: native, factory: response))
        }
    }

    /// Display and Native clicks. HTML creatives open their own destination (`mraid.open`, `window.open`, links), which the
    /// renderer records as a navigation; VAST clicks are `.videoClick`. The Native link is in the markup; the AdCOM
    /// banner link is in the bid response.
    private static func displayClick(assetID: Int?, candidate: AdCandidate, native: NativeAd?, response: TrackerRequestFactory,
                                     markup: TrackerRequestFactory) -> [TrackerRequest] {
        switch candidate.markup {
        case .native:
            return native.map { NativeTracking.click($0, assetID: assetID, factory: markup) } ?? []
        case let .image(banner):
            return banner.link.map { AdcomTracking.click($0, factory: response) } ?? []
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
