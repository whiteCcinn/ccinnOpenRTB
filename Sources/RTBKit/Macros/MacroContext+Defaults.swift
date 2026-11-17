import Foundation

extension MacroContext {
    /// The macro context the simulator uses for a bid (owner: kit-openrtb; refine freely, keep the signature).
    /// Auction values come from the bid and the optional request. The request's typed facts become macros here and only
    /// here (decisions.md, "Request facts for the remaining macros"): VAST values under bracketed `custom` keys
    /// (`"[DOMAIN]"`, …), VAST `Array<T>` values in `customLists`; plain keys stay `${KEY}` custom macros.
    ///
    /// - `responseBidID` (`BidResponse.bidid`) is `${AUCTION_BID_ID}`; `Bid.id` stands in only when the response has none.
    /// - `responseID` (`BidResponse.id`, by definition the ID of the bid request it answers) is `${AUCTION_ID}` when no
    ///   request was pasted; a pasted request's `id` wins.
    /// - `price` is the bid price (the default clearing price), so `${AUCTION_MBR}` (clearing / bid price) is 1.
    /// - OpenRTB 3.0 `bid.macro` keys are plain `custom` keys, referenced as `${CUSTOM_<KEY>}`.
    /// - `${AUCTION_MULTIPLIER}` (2.6 `imp.qty.multiplier`) and `${OPENRTB_ITEM_QTY}` (3.0 `item.qty`) come from the
    ///   impression the bid is for.
    /// - `[APPBUNDLE]` is the publisher app from the request only: `Bid.bundle` names the advertised app.
    /// - `[DEVICEUA]` is the request's `device.ua` when given; otherwise the expander uses the simulated device's.
    /// - `[VASTVERSIONS]` lists the VAST versions the simulator's player plays.
    /// - `playerWidth` / `playerHeight` (`[PLAYERSIZE]`) default to the bid's size.
    public static func simulatorDefaults(candidate: AdCandidate, request: BidRequestSummary?, device: DeviceProfile,
                                         playerWidth: Int? = nil, playerHeight: Int? = nil, responseID: String? = nil,
                                         responseBidID: String? = nil) -> MacroContext {
        var custom = candidate.customMacros
        var lists: [String: [String]] = ["[VASTVERSIONS]": VASTMacro.playableVASTVersions]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { custom[key] = value }
        }
        func nonEmpty(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }

        if let request {
            put("[DOMAIN]", request.domain)
            put("[PAGEURL]", request.pageURL)
            put("[APPBUNDLE]", request.appBundle)
            put("[IFA]", request.ifa)
            put("[IFATYPE]", request.ifaType)
            put("[LIMITADTRACKING]", request.limitAdTracking.map { $0 ? "1" : "0" })
            put("[TRANSACTIONID]", request.transactionID)
            put("[DEVICEIP]", request.deviceIP)
            put("[DEVICEUA]", request.deviceUserAgent)
            put("[GDPRCONSENT]", request.gdprConsent)
            put("[CONTENTID]", request.contentID)
            put("[CONTENTURI]", request.contentURL)
            put("[STOREURL]", request.storeURL)
            if let latitude = request.latitude.flatMap(MacroEncoding.decimal), let longitude = request.longitude.flatMap(MacroEncoding.decimal) {
                lists["[LATLONG]"] = [latitude, longitude]
            }
            if !request.blockedCategories.isEmpty { lists["[BLOCKEDADCATEGORIES]"] = request.blockedCategories }

            let impression = request.impressions.first { $0.id == candidate.impID }
            put(OpenRTBMacro.auctionMultiplier.rawValue, impression?.quantityMultiplier.flatMap(MacroEncoding.decimal))
            put(OpenRTBMacro.openRTBItemQuantity.rawValue, impression?.itemQuantity.map(String.init))
        }

        let hasPrice = candidate.price.isFinite && candidate.price > 0
        return MacroContext(auctionID: nonEmpty(request?.id) ?? nonEmpty(responseID), bidID: nonEmpty(responseBidID) ?? candidate.bidID,
                            impID: candidate.impID, seatID: candidate.seat, adID: candidate.adID, price: candidate.price,
                            currency: candidate.currency, marketBidRatio: hasPrice ? 1 : nil, custom: custom, customLists: lists,
                            playerWidth: playerWidth ?? candidate.size?.width, playerHeight: playerHeight ?? candidate.size?.height,
                            device: device)
    }
}
