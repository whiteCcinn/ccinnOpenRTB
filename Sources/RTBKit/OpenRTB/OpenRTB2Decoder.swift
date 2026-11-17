import Foundation

/// OpenRTB 2.0–2.6 `BidResponse` → `ParsedInput` (design D3), with the response-level and bid-level validation rules.
struct OpenRTB2Decoder {
    /// Bid fields first defined by OpenRTB 2.6 / 2.5: their presence proves the version.
    static let fieldsIntroducedIn26 = ["mtype", "slotinpod", "dur", "cattax", "langb"]
    static let fieldsIntroducedIn25 = ["burl", "lurl"]

    let request: BidRequestInfo?
    var log = IssueLog()

    init(request: BidRequestInfo?) {
        self.request = request
    }

    mutating func decode(_ root: JSONObjectReader) -> ParsedInput {
        let responseID = root.nonBlankString("id", log: &log)
        if responseID == nil {
            log.error("openrtb.response.id.missing", "`id` (the bid request id) is required.", at: root.pointer.appending("id"))
        }
        let bidResponseID = root.string("bidid", log: &log)
        let currency = ResponseChecks.currency(root, request: request?.summary, log: &log)
        let noBidReason = root.int("nbr", log: &log)
        ResponseChecks.responseID(responseID, root: root, request: request?.summary, log: &log)

        var candidates: [AdCandidate] = []
        var bidReaders: [JSONObjectReader] = []
        let seatbids = root.objects("seatbid", log: &log)
        if let seatbids {
            if seatbids.isEmpty, noBidReason == nil {
                log.warning("openrtb.response.seatbid.empty", "`seatbid` is empty: the response is a no-bid. Add `nbr` to say why.",
                            at: root.pointer.appending("seatbid"))
            }
            for (seatIndex, seatbid) in seatbids {
                let seat = seatbid.string("seat", log: &log)
                guard let bids = seatbid.objects("bid", log: &log), !bids.isEmpty else {
                    log.error("openrtb.seatbid.bid.missing", "Each `seatbid` needs a `bid` array with at least one bid.",
                              at: seatbid.pointer.appending("bid"))
                    continue
                }
                for (bidIndex, bid) in bids {
                    let id = "\(seatIndex).\(bidIndex)"
                    candidates.append(decodeBid(bid, id: id, seat: seat, currency: currency))
                    bidReaders.append(bid)
                }
            }
        } else if noBidReason == nil {
            log.warning("openrtb.response.seatbid.missing", "No `seatbid`: the response is a no-bid. Add `nbr` to say why.",
                        at: root.pointer.appending("seatbid"))
        }
        ResponseChecks.noBid(noBidReason, hasBids: !candidates.isEmpty, at: root.pointer.appending("nbr"), log: &log)
        ResponseChecks.duplicateBidIDs(candidates, readers: bidReaders, log: &log)

        let version = inferVersion(root, bids: bidReaders)
        return ParsedInput(kind: .bidResponse(.v2(version)), responseID: responseID, bidResponseID: bidResponseID, currency: currency,
                           noBidReason: noBidReason, candidates: candidates, issues: log.issues, request: request?.summary)
    }

    // MARK: Bid

    private mutating func decodeBid(_ bid: JSONObjectReader, id: String, seat: String?, currency: String) -> AdCandidate {
        let pointer = bid.pointer
        let bidID = bid.nonBlankString("id", log: &log)
        if bidID == nil { log.error("openrtb.bid.id.missing", "`bid.id` is required.", at: pointer.appending("id")) }
        let impID = bid.nonBlankString("impid", log: &log)
        if impID == nil { log.error("openrtb.bid.impid.missing", "`bid.impid` is required.", at: pointer.appending("impid")) }
        let price = ResponseChecks.price(bid, log: &log)

        let winURL = bid.nonBlankString("nurl", log: &log)
        let billingURL = bid.nonBlankString("burl", log: &log)
        let lossURL = bid.nonBlankString("lurl", log: &log)
        for (key, url) in [("nurl", winURL), ("burl", billingURL), ("lurl", lossURL)] {
            if let url { ResponseChecks.trackerURL(url, at: pointer.appending(key), log: &log) }
        }

        let impression = ResponseChecks.impression(impID, request: request?.summary, at: pointer.appending("impid"), log: &log)
        let markupType = bid.int("mtype", log: &log)
        var mtypeFormat: AdFormat?
        if let markupType {
            mtypeFormat = Self.format(forMarkupType: markupType)
            if mtypeFormat == nil {
                log.error("openrtb.bid.mtype.invalid", "`mtype` \(markupType) is not 1 (banner), 2 (video), 3 (audio) or 4 (native).",
                          at: pointer.appending("mtype"))
            }
        }

        let adm = readMarkup(bid)
        let sniffed = adm.map(MarkupSniffer.kind(of:))
        let format = inferFormat(mtype: mtypeFormat, impression: impression, adm: adm, sniffed: sniffed)
        if let impression, !impression.formats.isEmpty, !impression.formats.contains(format) {
            log.warning("openrtb.bid.format.unrequested",
                        "The bid is \(format.rawValue) but impression \(impression.id) offers \(impression.formats.map(\.rawValue).sorted().joined(separator: ", ")).",
                        at: pointer.appending(markupType == nil ? "impid" : "mtype"))
        }
        let markup = buildMarkup(adm: adm, sniffed: sniffed, format: format, winURL: winURL, at: pointer)

        var candidate = AdCandidate(id: id, bidID: bidID ?? "", impID: impID, seat: seat, price: price, currency: currency,
                                    dealID: bid.string("dealid", log: &log), adID: bid.string("adid", log: &log),
                                    creativeID: bid.string("crid", log: &log), campaignID: bid.string("cid", log: &log),
                                    advertiserDomains: bid.strings("adomain", log: &log) ?? [], bundle: bid.string("bundle", log: &log),
                                    size: Self.size(bid, log: &log), format: format, markup: markup, winURL: winURL, billingURL: billingURL,
                                    lossURL: lossURL, expirySeconds: bid.int("exp", log: &log), markupType: markupType, ext: bid.raw("ext"))
        if candidate.size == nil, format == .banner { candidate.size = impression?.size }
        if case let .native(json) = markup {
            ResponseChecks.nativeMarkup(json, impression: impression, at: pointer.appending("adm"), log: &log)
        }
        return candidate
    }

    /// `adm` as a string; a JSON object (Native sent by value) is accepted with a warning.
    private mutating func readMarkup(_ bid: JSONObjectReader) -> String? {
        switch bid.raw("adm") {
        case let .object(members)?:
            log.warning("openrtb.type.mismatch", "`adm` must be a string; the Native object was serialised.", at: bid.pointer.appending("adm"))
            return JSONValue.object(members).serialized()
        case .some:
            return bid.nonBlankString("adm", log: &log)
        case nil:
            return nil
        }
    }

    /// mtype → impression type → `adm` sniff (design D3).
    private func inferFormat(mtype: AdFormat?, impression: BidRequestSummary.Impression?, adm: String?, sniffed: MarkupSniffer.Kind?) -> AdFormat {
        if let mtype { return mtype }
        let sniffedFormat = adm.flatMap { Self.format(forSniffed: sniffed, adm: $0, impression: impression) }
        if let formats = impression?.formats, !formats.isEmpty {
            if formats.count == 1, let only = formats.first { return only }
            if let sniffedFormat, formats.contains(sniffedFormat) { return sniffedFormat }
        }
        return sniffedFormat ?? .banner
    }

    private static func format(forSniffed kind: MarkupSniffer.Kind?, adm: String, impression: BidRequestSummary.Impression?) -> AdFormat? {
        switch kind {
        case .vast?:
            if impression?.formats.contains(.audio) == true, impression?.formats.contains(.video) != true { return .audio }
            return MarkupSniffer.vastLooksAudioOnly(adm) ? .audio : .video
        case .native?: return .native
        case .html?: return .banner
        case .url?, nil: return nil
        }
    }

    private mutating func buildMarkup(adm: String?, sniffed: MarkupSniffer.Kind?, format: AdFormat, winURL: String?, at pointer: JSONPointer) -> AdMarkup {
        let admPointer = pointer.appending("adm")
        guard let adm, let sniffed else {
            if winURL != nil {
                log.info("openrtb.bid.markup.winnotice",
                         "No `adm`: the markup is delivered by the win notice (`nurl`) response. Real mode fetches it; Simulated mode records the win notice only.",
                         at: admPointer)
            } else {
                log.error("openrtb.bid.markup.missing", "The bid has neither `adm` nor `nurl`: there is no way to get its markup.", at: admPointer)
            }
            return .none
        }
        switch format {
        case .video, .audio:
            switch sniffed {
            case .vast:
                return .vast(.xml(adm))
            case .url:
                log.warning("openrtb.bid.adm.url", "`adm` holds a VAST tag URL; OpenRTB expects the VAST document itself. It is fetched as a wrapper.",
                            at: admPointer)
                return .vast(.url(adm.trimmingCharacters(in: .whitespacesAndNewlines)))
            case .native, .html:
                log.warning("openrtb.bid.markup.mismatch", "The bid is \(format.rawValue) but `adm` is not VAST XML.", at: admPointer)
                return .vast(.xml(adm))
            }
        case .native:
            if sniffed != .native { log.warning("openrtb.bid.markup.mismatch", "The bid is native but `adm` is not Native JSON.", at: admPointer) }
            return .native(adm)
        case .banner:
            switch sniffed {
            case .vast, .native:
                log.warning("openrtb.bid.markup.mismatch", "The bid is a banner but `adm` is \(sniffed == .vast ? "VAST XML" : "Native JSON").",
                            at: admPointer)
            case .url:
                log.warning("openrtb.bid.adm.url", "`adm` holds a URL rather than markup.", at: admPointer)
            case .html:
                break
            }
            return .html(adm)
        }
    }

    // MARK: Version

    private mutating func inferVersion(_ root: JSONObjectReader, bids: [JSONObjectReader]) -> String {
        let declared = root.version("ver", log: &log)
        var declaredVersion: SpecVersion?
        if let declared {
            log.info("openrtb.response.ver.nonstandard", "`ver` is not a 2.x BidResponse field; it is used as the declared version.",
                     at: root.pointer.appending("ver"))
            if let parsed = SpecVersion(declared), parsed.major == 2 { declaredVersion = parsed }
        }
        var uses26 = false
        var uses25 = false
        for bid in bids {
            for field in Self.fieldsIntroducedIn26 where bid.has(field) {
                uses26 = true
                if let declaredVersion, declaredVersion < SpecVersion(major: 2, minor: 6) {
                    log.info("openrtb.version.field", "`\(field)` was introduced in OpenRTB 2.6; the response declares \(declared ?? "").",
                             at: bid.pointer.appending(field))
                }
            }
            for field in Self.fieldsIntroducedIn25 where bid.has(field) {
                uses25 = true
                if let declaredVersion, declaredVersion < SpecVersion(major: 2, minor: 5) {
                    log.info("openrtb.version.field", "`\(field)` was introduced in OpenRTB 2.5; the response declares \(declared ?? "").",
                             at: bid.pointer.appending(field))
                }
            }
        }
        if uses26 { return "2.6" }
        if uses25 { return "2.5" }
        if let declaredVersion { return "\(declaredVersion.major).\(declaredVersion.minor)" }
        return "2.x"
    }

    // MARK: Helpers

    static func format(forMarkupType markupType: Int) -> AdFormat? {
        switch markupType {
        case 1: .banner
        case 2: .video
        case 3: .audio
        case 4: .native
        default: nil
        }
    }

    static func size(_ reader: JSONObjectReader, log: inout IssueLog) -> AdSize? {
        guard let width = reader.int("w", log: &log), let height = reader.int("h", log: &log), width > 0, height > 0 else { return nil }
        return AdSize(width: width, height: height)
    }
}
