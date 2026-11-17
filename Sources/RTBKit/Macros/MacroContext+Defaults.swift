import Foundation

extension MacroContext {
    /// The macro context the simulator uses for a bid (owner: kit-openrtb; refine freely, keep the signature).
    /// Auction values come from the bid and the optional request; request-derived VAST values are stored in `custom` under
    /// bracketed keys (`"[DOMAIN]"`, …) so that `MacroExpander` finds them; plain keys stay `${KEY}` custom macros.
    ///
    /// - `responseBidID` (`BidResponse.bidid`) is `${AUCTION_BID_ID}`; `Bid.id` stands in only when the response has none.
    /// - `responseID` (`BidResponse.id`, by definition the ID of the bid request it answers) is `${AUCTION_ID}` when no
    ///   request was pasted; a pasted request's `id` wins.
    /// - `price` is the bid price (the default clearing price), so `${AUCTION_MBR}` (clearing / bid price) is 1.
    /// - OpenRTB 3.0 `bid.macro` keys are plain `custom` keys, referenced as `${CUSTOM_<KEY>}`.
    /// - `[APPBUNDLE]` is the publisher app from the request only: `Bid.bundle` names the advertised app.
    /// - `playerWidth` / `playerHeight` (`[PLAYERSIZE]`) default to the bid's size.
    public static func simulatorDefaults(candidate: AdCandidate, request: BidRequestSummary?, device: DeviceProfile,
                                         playerWidth: Int? = nil, playerHeight: Int? = nil, responseID: String? = nil,
                                         responseBidID: String? = nil) -> MacroContext {
        var custom = candidate.customMacros
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { custom[key] = value }
        }
        put("[DOMAIN]", request?.domain)
        put("[PAGEURL]", request?.pageURL)
        put("[APPBUNDLE]", request?.appBundle)
        put("[IFA]", request?.ifa)
        put("[LIMITADTRACKING]", request?.limitAdTracking.map { $0 ? "1" : "0" })
        put("[TRANSACTIONID]", request?.transactionID)
        func nonEmpty(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
        let hasPrice = candidate.price.isFinite && candidate.price > 0
        return MacroContext(auctionID: nonEmpty(request?.id) ?? nonEmpty(responseID), bidID: nonEmpty(responseBidID) ?? candidate.bidID,
                            impID: candidate.impID, seatID: candidate.seat, adID: candidate.adID, price: candidate.price,
                            currency: candidate.currency, marketBidRatio: hasPrice ? 1 : nil, custom: custom,
                            playerWidth: playerWidth ?? candidate.size?.width, playerHeight: playerHeight ?? candidate.size?.height,
                            device: device)
    }
}
