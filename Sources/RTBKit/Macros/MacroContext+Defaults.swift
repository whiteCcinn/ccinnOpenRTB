import Foundation

extension MacroContext {
    /// The macro context the simulator uses for a bid (owner: kit-openrtb; refine freely, keep the signature).
    /// Auction values come from the bid and the optional request; request-derived VAST values are stored in `custom` under
    /// bracketed keys (`"[DOMAIN]"`, …) so that `MacroExpander` finds them; plain keys stay `${KEY}` custom macros.
    public static func simulatorDefaults(candidate: AdCandidate, request: BidRequestSummary?, device: DeviceProfile,
                                         playerWidth: Int? = nil, playerHeight: Int? = nil) -> MacroContext {
        var custom = candidate.customMacros
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { custom[key] = value }
        }
        put("[DOMAIN]", request?.domain)
        put("[PAGEURL]", request?.pageURL)
        put("[APPBUNDLE]", request?.appBundle ?? candidate.bundle)
        put("[IFA]", request?.ifa)
        put("[LIMITADTRACKING]", request?.limitAdTracking.map { $0 ? "1" : "0" })
        put("[TRANSACTIONID]", request?.transactionID)
        return MacroContext(auctionID: request?.id, bidID: candidate.bidID, impID: candidate.impID, seatID: candidate.seat,
                            adID: candidate.adID, price: candidate.price, currency: candidate.currency, custom: custom,
                            playerWidth: playerWidth, playerHeight: playerHeight, device: device)
    }
}
