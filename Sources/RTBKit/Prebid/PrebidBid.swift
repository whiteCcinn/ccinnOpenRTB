import Foundation

/// A bid Prebid.js returned (a `bidResponse`, as the page serialises it), read leniently, and turned into the bid the
/// simulator renders. Pure.
public struct PrebidBid: Sendable, Hashable {
    public var bidderCode: String
    public var adID: String
    public var requestID: String?
    public var adUnitCode: String?
    public var cpm: Double
    public var originalCPM: Double?
    public var currency: String
    public var mediaType: String?
    public var width: Int?
    public var height: Int?
    public var ad: String?
    public var adURL: String?
    public var vastXML: String?
    public var vastURL: String?
    /// `native.ortb`: the OpenRTB Native response.
    public var nativeORTB: JSONValue?
    public var creativeID: String?
    public var dealID: String?
    public var advertiserDomains: [String]
    public var billingURL: String?

    /// One bid object; `nil` without a bidder or a price.
    public static func parse(_ json: String) -> PrebidBid? {
        guard case let .object(members)? = try? JSONValue.parse(json) else { return nil }
        return PrebidBid(members)
    }

    /// An array of bid objects; entries that are not bids are skipped.
    public static func parseList(_ json: String) -> [PrebidBid] {
        guard case let .array(elements)? = try? JSONValue.parse(json) else { return [] }
        return elements.compactMap { element in
            if case let .object(members) = element { PrebidBid(members) } else { nil }
        }
    }

    init?(_ members: [String: JSONValue]) {
        guard let bidder = Self.string(members["bidderCode"]) ?? Self.string(members["bidder"]), !bidder.isEmpty,
              let cpm = Self.number(members["cpm"]), cpm.isFinite else { return nil }
        bidderCode = bidder
        adID = Self.string(members["adId"]) ?? ""
        requestID = Self.string(members["requestId"])
        adUnitCode = Self.string(members["adUnitCode"])
        self.cpm = cpm
        originalCPM = Self.number(members["originalCpm"])
        currency = Self.string(members["currency"]) ?? "USD"
        mediaType = Self.string(members["mediaType"])
        width = Self.number(members["width"]).flatMap { Int(exactly: $0.rounded()) }
        height = Self.number(members["height"]).flatMap { Int(exactly: $0.rounded()) }
        ad = Self.string(members["ad"])
        adURL = Self.string(members["adUrl"])
        vastXML = Self.string(members["vastXml"])
        vastURL = Self.string(members["vastUrl"])
        if case let .object(native)? = members["native"] { nativeORTB = native["ortb"] }
        creativeID = Self.string(members["creativeId"])
        dealID = Self.string(members["dealId"])
        if case let .object(meta)? = members["meta"], case let .array(domains)? = meta["advertiserDomains"] {
            advertiserDomains = domains.compactMap { Self.string($0) }
        } else {
            advertiserDomains = []
        }
        billingURL = Self.string(members["burl"])
    }

    public var format: AdFormat {
        switch mediaType?.lowercased() {
        case "video": .video
        case "native": .native
        default: vastXML != nil || vastURL != nil ? .video : nativeORTB != nil ? .native : .banner
        }
    }

    /// What `pbjs.renderAd` puts into `${AUCTION_PRICE}`: `originalCpm || cpm`, as JavaScript prints a number.
    public var auctionPrice: String { Self.javaScriptNumber(originalCPM ?? cpm) }

    /// The bid as the simulator renders it: `ad` as HTML (or `adUrl` in an iframe) with `${AUCTION_PRICE}` and
    /// `${CLICKTHROUGH}` replaced as `renderAd` does, `vastXml` / `vastUrl` as VAST, `native.ortb` as Native.
    public func candidate(index: Int) -> AdCandidate {
        let size = width.flatMap { w in height.map { AdSize(width: w, height: $0) } }.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        return AdCandidate(id: "pb\(index)", bidID: adID, impID: adUnitCode, seat: bidderCode, price: cpm, currency: currency, dealID: dealID,
                           adID: adID, creativeID: creativeID, advertiserDomains: advertiserDomains, size: size, format: format, markup: markup(size: size),
                           billingURL: billingURL)
    }

    private func markup(size: AdSize?) -> AdMarkup {
        if let vastXML { return .vast(.xml(vastXML)) }
        if let vastURL { return .vast(.url(vastURL)) }
        if let nativeORTB { return .native(nativeORTB.serialized()) }
        if let ad { return .html(fillMacros(ad)) }
        if let adURL {
            let width = size.map { "\($0.width)" } ?? "100%"
            let height = size.map { "\($0.height)" } ?? "100%"
            let source = fillMacros(adURL).replacingOccurrences(of: "\"", with: "&quot;")
            return .html("<iframe src=\"\(source)\" width=\"\(width)\" height=\"\(height)\" frameborder=\"0\" scrolling=\"no\" style=\"border:0\"></iframe>")
        }
        return .none
    }

    private func fillMacros(_ text: String) -> String {
        text.replacingOccurrences(of: "${AUCTION_PRICE}", with: auctionPrice).replacingOccurrences(of: "${CLICKTHROUGH}", with: "")
    }

    static func javaScriptNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    private static func string(_ value: JSONValue?) -> String? {
        switch value {
        case let .string(text)?: text
        case let .int(number)?: String(number)
        default: nil
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case let .int(number)?: Double(number)
        case let .double(number)?: number
        case let .string(text)?: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}
