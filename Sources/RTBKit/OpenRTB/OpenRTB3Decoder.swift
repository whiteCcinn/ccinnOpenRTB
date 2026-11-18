import Foundation

/// OpenRTB 3.0 `{"openrtb": {"response": …}}` with AdCOM 1.0 media → `ParsedInput` (design D3).
struct OpenRTB3Decoder {
    /// AdCOM 1.0 "Event Types": 1 loaded, 2 impression, 3 viewable-mrc50, 4 viewable-mrc100, 5 viewable-video50.
    static let validEventTypes = 1...5
    /// AdCOM 1.0 "Event Tracking Methods": 1 image pixel, 2 JavaScript.
    static let validEventMethods = 1...2

    let request: BidRequestSummary?
    var log = IssueLog()

    init(request: BidRequestSummary?) {
        self.request = request
    }

    mutating func decode(envelope: JSONObjectReader, response: JSONObjectReader) -> ParsedInput {
        let version = envelopeVersion(envelope)

        let responseID = response.nonBlankString("id", log: &log)
        if responseID == nil {
            log.error("openrtb.response.id.missing", "`id` (the bid request id) is required.", at: response.pointer.appending("id"))
        }
        ResponseChecks.responseID(responseID, root: response, request: request, log: &log)
        let bidResponseID = response.string("bidid", log: &log)
        let currency = ResponseChecks.currency(response, request: request, log: &log)
        let noBidReason = response.int("nbr", log: &log)

        var candidates: [AdCandidate] = []
        var bidReaders: [JSONObjectReader] = []
        if let seatbids = response.objects("seatbid", log: &log) {
            if seatbids.isEmpty, noBidReason == nil {
                log.warning("openrtb.response.seatbid.empty", "`seatbid` is empty: the response is a no-bid. Add `nbr` to say why.",
                            at: response.pointer.appending("seatbid"))
            }
            for (seatIndex, seatbid) in seatbids {
                let seat = seatbid.string("seat", log: &log)
                guard let bids = seatbid.objects("bid", log: &log), !bids.isEmpty else {
                    log.error("openrtb.seatbid.bid.missing", "Each `seatbid` needs a `bid` array with at least one bid.",
                              at: seatbid.pointer.appending("bid"))
                    continue
                }
                for (bidIndex, bid) in bids {
                    candidates.append(decodeBid(bid, id: "\(seatIndex).\(bidIndex)", seat: seat, currency: currency))
                    bidReaders.append(bid)
                }
            }
        } else if noBidReason == nil {
            log.warning("openrtb.response.seatbid.missing", "No `seatbid`: the response is a no-bid. Add `nbr` to say why.",
                        at: response.pointer.appending("seatbid"))
        }
        ResponseChecks.noBid(noBidReason, hasBids: !candidates.isEmpty, at: response.pointer.appending("nbr"), log: &log)
        ResponseChecks.duplicateBidIDs(candidates, readers: bidReaders, log: &log)
        return ParsedInput(kind: .bidResponse(.v3(version)), responseID: responseID, bidResponseID: bidResponseID, currency: currency,
                           noBidReason: noBidReason, candidates: candidates, issues: log.issues, request: request)
    }

    // MARK: Envelope

    private mutating func envelopeVersion(_ envelope: JSONObjectReader) -> String {
        let version = envelope.version("ver", log: &log)
        if version == nil {
            log.warning("openrtb3.ver.missing", "`openrtb.ver` is missing; assuming 3.0.", at: envelope.pointer.appending("ver"))
        } else if let version, SpecVersion(version)?.major != 3 {
            log.warning("openrtb3.ver.unexpected", "`openrtb.ver` \"\(version)\" is not a 3.x version.", at: envelope.pointer.appending("ver"))
        }
        let domainSpec = envelope.string("domainspec", log: &log) ?? "adcom"
        if domainSpec.lowercased() != "adcom" {
            log.warning("openrtb3.domainspec.unsupported", "Only the AdCOM domain specification is supported, found \"\(domainSpec)\".",
                        at: envelope.pointer.appending("domainspec"))
        }
        if envelope.string("domainver", log: &log) == nil {
            log.error("openrtb3.domainver.missing", "`openrtb.domainver` (the AdCOM version) is required.", at: envelope.pointer.appending("domainver"))
        }
        return version ?? "3.0"
    }

    // MARK: Bid

    private mutating func decodeBid(_ bid: JSONObjectReader, id: String, seat: String?, currency: String) -> AdCandidate {
        let pointer = bid.pointer
        let bidID = bid.nonBlankString("id", log: &log)
        if bidID == nil { log.info("openrtb3.bid.id.missing", "`bid.id` is recommended for logging and tracking.", at: pointer.appending("id")) }
        let item = bid.nonBlankString("item", log: &log)
        if item == nil { log.error("openrtb3.bid.item.missing", "`bid.item` (the item id) is required.", at: pointer.appending("item")) }
        let price = ResponseChecks.price(bid, log: &log)
        let winURL = bid.nonBlankString("purl", log: &log)
        let billingURL = bid.nonBlankString("burl", log: &log)
        let lossURL = bid.nonBlankString("lurl", log: &log)
        for (key, url) in [("purl", winURL), ("burl", billingURL), ("lurl", lossURL)] {
            if let url { ResponseChecks.trackerURL(url, at: pointer.appending(key), log: &log) }
        }
        if bid.has("nurl") {
            log.warning("openrtb3.bid.nurl", "`nurl` is an OpenRTB 2.x field; OpenRTB 3.0 uses `purl` (pending/win notice).", at: pointer.appending("nurl"))
        }
        let impression = ResponseChecks.impression(item, request: request, at: pointer.appending("item"), log: &log)

        var macros: [String: String] = [:]
        for (_, macro) in bid.objects("macro", log: &log) ?? [] {
            guard let key = macro.nonBlankString("key", log: &log) else {
                log.error("openrtb3.macro.key.missing", "A `macro` needs `key`.", at: macro.pointer.appending("key"))
                continue
            }
            macros[key] = macro.string("value", log: &log) ?? ""
        }

        var media = MediaFacts()
        if let mediaReader = bid.object("media", log: &log) {
            if let ad = mediaReader.object("ad", log: &log) {
                media = decodeAd(ad, impression: impression)
            } else {
                log.error("adcom.media.ad.missing", "`media.ad` (the AdCOM Ad) is required.", at: mediaReader.pointer.appending("ad"))
            }
        } else if bid.has("mid") {
            log.warning("openrtb3.bid.media.reference", "The media is given by reference (`mid`); its markup is held by the exchange.",
                        at: pointer.appending("mid"))
        } else {
            log.error("openrtb3.bid.media.missing", "`bid.media` is required unless the media is referenced with `mid`.", at: pointer.appending("media"))
        }
        if let impression, !impression.formats.isEmpty, !impression.formats.contains(media.format) {
            log.warning("openrtb.bid.format.unrequested",
                        "The bid is \(media.format.rawValue) but item \(impression.id) offers \(impression.formats.map(\.rawValue).sorted().joined(separator: ", ")).",
                        at: pointer.appending("media"))
        }

        return AdCandidate(id: id, bidID: bidID ?? "", impID: item, seat: seat, price: price, currency: currency, dealID: bid.string("deal", log: &log),
                           adID: bid.string("mid", log: &log), creativeID: media.adID, campaignID: bid.string("cid", log: &log),
                           advertiserDomains: media.advertiserDomains, bundle: media.bundle, size: media.size ?? impression?.size,
                           format: media.format, markup: media.markup, markupURL: media.markupURL, winURL: winURL, billingURL: billingURL,
                           lossURL: lossURL, adcomEvents: media.events, customMacros: macros, expirySeconds: bid.int("exp", log: &log),
                           ext: bid.raw("ext"))
    }

    // MARK: AdCOM Ad

    private struct MediaFacts {
        var adID: String?
        var advertiserDomains: [String] = []
        var bundle: String?
        var size: AdSize?
        var format: AdFormat = .banner
        var markup: AdMarkup = .none
        var markupURL: String?
        var events: [AdcomEvent] = []
    }

    private mutating func decodeAd(_ ad: JSONObjectReader, impression: BidRequestSummary.Impression?) -> MediaFacts {
        var facts = MediaFacts()
        facts.adID = ad.nonBlankString("id", log: &log)
        if facts.adID == nil { log.error("adcom.ad.id.missing", "`ad.id` is required.", at: ad.pointer.appending("id")) }
        facts.advertiserDomains = ad.strings("adomain", log: &log) ?? []
        facts.bundle = ad.strings("bundle", log: &log)?.first

        let display = ad.object("display", log: &log)
        let video = ad.object("video", log: &log)
        let audio = ad.object("audio", log: &log)
        let present = [display, video, audio].compactMap { $0 }
        if present.count > 1 {
            log.warning("adcom.ad.media.multiple", "An Ad carries exactly one of `display`, `video` or `audio`; the first one is used.", at: ad.pointer)
        }
        if let display {
            decodeDisplay(display, impression: impression, into: &facts)
        } else if let video {
            facts.format = .video
            facts.markup = vastMarkup(video, kind: "video")
        } else if let audio {
            facts.format = .audio
            facts.markup = vastMarkup(audio, kind: "audio")
        } else {
            log.error("adcom.ad.media.missing", "The Ad has none of `display`, `video` or `audio`.", at: ad.pointer)
        }
        return facts
    }

    private mutating func decodeDisplay(_ display: JSONObjectReader, impression: BidRequestSummary.Impression?, into facts: inout MediaFacts) {
        facts.size = OpenRTB2Decoder.size(display, log: &log)
        let adm = display.nonBlankString("adm", log: &log)
        let banner = display.object("banner", log: &log)
        let native = display.object("native", log: &log)
        let curl = display.nonBlankString("curl", log: &log)
        if [adm != nil, banner != nil, native != nil, curl != nil].filter({ $0 }).count > 1 {
            log.warning("adcom.display.markup.multiple", "`adm`, `banner`, `native` and `curl` are mutually exclusive; the first one is used.",
                        at: display.pointer)
        }
        if let adm {
            facts.format = .banner
            facts.markup = .html(adm)
        } else if let banner {
            facts.format = .banner
            facts.markup = imageBanner(banner, secure: impression?.secure == true)
        } else if let native {
            facts.format = .native
            let json = JSONValue.object(native.members).serialized()
            facts.markup = .native(json)
            nativeIssues(json, at: native.pointer, impression: impression)
        } else if let curl {
            facts.format = .banner
            facts.markup = .none
            facts.markupURL = curl
            log.info("adcom.display.curl", "The markup is fetched from `display.curl` (a content request, in both modes).",
                     at: display.pointer.appending("curl"))
            ResponseChecks.trackerURL(curl, at: display.pointer.appending("curl"), log: &log)
        } else {
            log.error("adcom.display.markup.missing", "`display` needs one of `adm`, `banner`, `native` or `curl`.", at: display.pointer)
        }
        facts.events = events(display, secure: impression?.secure == true)
    }

    /// AdCOM native is parsed by `NativeParser`; its issue paths are re-rooted from the serialised object to `display/native`.
    private mutating func nativeIssues(_ json: String, at pointer: JSONPointer, impression: BidRequestSummary.Impression?) {
        ResponseChecks.nativeMarkup(json, impression: impression, at: pointer, log: &log)
    }

    private mutating func imageBanner(_ banner: JSONObjectReader, secure: Bool) -> AdMarkup {
        let image = banner.nonBlankString("img", log: &log)
        if image == nil { log.error("adcom.banner.img.missing", "`banner.img` (the image URL) is required.", at: banner.pointer.appending("img")) }
        var link: AdLink?
        if let linkReader = banner.object("link", log: &log) {
            let url = linkReader.nonBlankString("url", log: &log)
            if url == nil { log.error("adcom.link.url.missing", "`link.url` is required.", at: linkReader.pointer.appending("url")) }
            let trackers = linkReader.strings("trkr", log: &log) ?? []
            link = AdLink(url: url ?? "", clickTrackers: trackers, fallback: linkReader.string("urlfb", log: &log))
            if secure {
                for (index, tracker) in trackers.enumerated() where URLRules.isHTTP(tracker) {
                    ResponseChecks.insecure(tracker, isTracker: true, at: linkReader.pointer.appending("trkr").appending(index), log: &log)
                }
            }
        }
        if secure, let image, URLRules.isHTTP(image) {
            ResponseChecks.insecure(image, isTracker: false, at: banner.pointer.appending("img"), log: &log)
        }
        return .image(ImageBanner(imageURL: image ?? "", link: link))
    }

    /// `video` / `audio`: `adm` (VAST XML) or `curl` (VAST tag URL).
    private mutating func vastMarkup(_ media: JSONObjectReader, kind: String) -> AdMarkup {
        let adm = media.nonBlankString("adm", log: &log)
        let curl = media.nonBlankString("curl", log: &log)
        if adm != nil, curl != nil {
            log.warning("adcom.\(kind).markup.multiple", "`adm` and `curl` are mutually exclusive; `adm` is used.", at: media.pointer)
        }
        if let adm {
            if !MarkupSniffer.isVASTDocument(adm.trimmingCharacters(in: .whitespacesAndNewlines)) {
                log.warning("openrtb.bid.markup.mismatch", "`\(kind).adm` is not VAST XML.", at: media.pointer.appending("adm"))
            }
            return .vast(.xml(adm))
        }
        if let curl {
            ResponseChecks.trackerURL(curl, at: media.pointer.appending("curl"), log: &log)
            return .vast(.url(curl.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        log.error("adcom.\(kind).markup.missing", "`\(kind)` needs `adm` (VAST XML) or `curl` (a VAST URL).", at: media.pointer)
        return .none
    }

    /// `display.event[]`.
    private mutating func events(_ display: JSONObjectReader, secure: Bool) -> [AdcomEvent] {
        var result: [AdcomEvent] = []
        for (_, event) in display.objects("event", log: &log) ?? [] {
            let type = event.int("type", log: &log)
            let method = event.int("method", log: &log)
            guard let type, let method else {
                log.warning("adcom.event.incomplete", "An event needs `type` and `method`; it was skipped.", at: event.pointer)
                continue
            }
            if !Self.validEventTypes.contains(type), type < 500 {
                log.warning("adcom.event.type.invalid",
                            "Event type \(type) is not 1 (loaded), 2 (impression), 3 (viewable-mrc50), 4 (viewable-mrc100), 5 (viewable-video50) or 500+.",
                            at: event.pointer.appending("type"))
            }
            if !Self.validEventMethods.contains(method), method < 500 {
                log.warning("adcom.event.method.invalid", "Method \(method) is not 1 (image pixel), 2 (JavaScript) or 500+.",
                            at: event.pointer.appending("method"))
            }
            let url = event.nonBlankString("url", log: &log)
            let script = url == nil ? event.nonBlankString("jstrk", log: &log) : nil
            if url == nil, script == nil {
                log.warning("adcom.event.url.missing", "An image or JavaScript event needs `url`; it was skipped.", at: event.pointer.appending("url"))
                continue
            }
            if secure, let url, URLRules.isHTTP(url) {
                ResponseChecks.insecure(url, isTracker: true, at: event.pointer.appending("url"), log: &log)
            }
            result.append(AdcomEvent(type: type, method: method, url: url, script: script))
        }
        return result
    }
}
