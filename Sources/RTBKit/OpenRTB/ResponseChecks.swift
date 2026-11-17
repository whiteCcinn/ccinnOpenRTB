import Foundation

/// Validation rules shared by the OpenRTB 2.x and 3.0 decoders. Codes are stable; paths are JSON pointers.
enum ResponseChecks {
    /// `cur` (default `USD`): ISO 4217, and one of the request's `cur` when a request is given.
    static func currency(_ response: JSONObjectReader, request: BidRequestSummary?, log: inout IssueLog) -> String {
        let pointer = response.pointer.appending("cur")
        guard let currency = response.nonBlankString("cur", log: &log) else { return "USD" }
        if !CurrencyCodes.isISO4217(currency) {
            log.warning("openrtb.response.cur.invalid", "`cur` \"\(currency)\" is not an ISO 4217 alphabetic currency code.", at: pointer)
        }
        if let accepted = request?.currencies, !accepted.isEmpty, !accepted.contains(currency) {
            log.warning("openrtb.response.cur.unrequested", "The request accepts \(accepted.joined(separator: ", ")), not \(currency).", at: pointer)
        }
        return currency
    }

    static func responseID(_ id: String?, root: JSONObjectReader, request: BidRequestSummary?, log: inout IssueLog) {
        guard let id, let request, !request.id.isEmpty, id != request.id else { return }
        log.warning("openrtb.response.id.mismatch", "`id` \"\(id)\" does not match the bid request id \"\(request.id)\".", at: root.pointer.appending("id"))
    }

    /// `price` (required). Non-positive prices are legal JSON but cannot win an auction.
    static func price(_ bid: JSONObjectReader, log: inout IssueLog) -> Double {
        let pointer = bid.pointer.appending("price")
        guard let price = bid.double("price", log: &log) else {
            if !bid.has("price") { log.error("openrtb.bid.price.missing", "`price` is required.", at: pointer) }
            return 0
        }
        if price <= 0 { log.warning("openrtb.bid.price.nonpositive", "`price` is \(MacroEncoding.decimal(price) ?? "0"); a bid must be above 0.", at: pointer) }
        return price
    }

    /// Auction notices must be absolute http(s) URLs (macros allowed).
    static func trackerURL(_ url: String, at pointer: JSONPointer, log: inout IssueLog) {
        if !URLRules.isAbsoluteHTTPURL(url.trimmingCharacters(in: .whitespacesAndNewlines)) {
            log.warning("openrtb.url.invalid", "\"\(url.prefix(120))\" is not an absolute http(s) URL.", at: pointer)
        }
    }

    /// The request impression a bid refers to.
    static func impression(_ impID: String?, request: BidRequestSummary?, at pointer: JSONPointer, log: inout IssueLog) -> BidRequestSummary.Impression? {
        guard let request else { return nil }
        guard let impID else { return nil }
        if let impression = request.impressions.first(where: { $0.id == impID }) { return impression }
        log.warning("openrtb.bid.impid.unknown", "No impression \"\(impID)\" in the bid request.", at: pointer)
        return nil
    }

    static func noBid(_ reason: Int?, hasBids: Bool, at pointer: JSONPointer, log: inout IssueLog) {
        guard let reason else { return }
        if hasBids {
            log.warning("openrtb.response.nbr.ignored", "`nbr` is set although the response has bids; the bids are used.", at: pointer)
        } else {
            log.info("openrtb.response.nobid", "No bid: \(reason) – \(OpenRTBCodes.noBidReasonName(reason)).", at: pointer)
        }
    }

    static func duplicateBidIDs(_ candidates: [AdCandidate], readers: [JSONObjectReader], log: inout IssueLog) {
        var seen: Set<String> = []
        for (candidate, reader) in zip(candidates, readers) where !candidate.bidID.isEmpty {
            if !seen.insert(candidate.bidID).inserted {
                log.warning("openrtb.bid.id.duplicate", "Bid id \"\(candidate.bidID)\" is used by more than one bid.", at: reader.pointer.appending("id"))
            }
        }
    }

    /// Native markup in a bid: its own issues (re-rooted under `pointer`) and, for a secure impression, plain-HTTP trackers.
    static func nativeMarkup(_ json: String, impression: BidRequestSummary.Impression?, at pointer: JSONPointer, log: inout IssueLog) {
        let (decoded, nativeIssues) = NativeParser.decode(json, hints: impression?.nativeHints)
        log.append(contentsOf: nativeIssues, under: pointer)
        guard let decoded, impression?.secure == true else { return }
        for item in NativeValidator.clientSideURLs(decoded) where URLRules.isHTTP(item.url) {
            insecure(item.url, isTracker: item.isTracker, at: pointer.appending(pointer: item.pointer.description), log: &log)
        }
    }

    /// A plain-HTTP URL that a secure impression (`imp.secure = 1`) loads on the device.
    static func insecure(_ url: String, isTracker: Bool, at pointer: JSONPointer, log: inout IssueLog) {
        if isTracker {
            log.warning("openrtb.tracker.insecure", "The impression requires HTTPS but this tracker is plain HTTP.", at: pointer)
        } else {
            log.warning("openrtb.asset.insecure", "The impression requires HTTPS but this creative asset is plain HTTP.", at: pointer)
        }
    }
}
