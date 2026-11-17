import Foundation

/// Produces the substitution text for one macro token. One resolver serves one expansion, so `[CACHEBUSTING]` and
/// `[TIMESTAMP]` are stable across repeated occurrences in the same URL.
struct MacroValueResolver {
    private let context: MacroContext
    private let timeZone: TimeZone
    private var cachedCacheBuster: String?
    private var cachedNow: Date?

    init(context: MacroContext, timeZone: TimeZone) {
        self.context = context
        self.timeZone = timeZone
    }

    // MARK: OpenRTB `${NAME[:ALG]}`

    /// The text to substitute, or `nil` when the macro is unknown (left in place and reported).
    mutating func openRTBValue(name: String, algorithm: String?) -> String? {
        let standard = OpenRTBMacro(rawValue: name)
        if let algorithm, algorithm != "B64" {
            // `:X` = an algorithm agreed between the parties. The only value the simulator can stand in for it is the
            // user-supplied encrypted price, which is already the output of that algorithm.
            if standard?.isPrice == true, let encrypted = context.encryptedPrice { return encrypted }
            return nil
        }
        let raw: String
        if let standard {
            if algorithm == nil, standard.isPrice, let encrypted = context.encryptedPrice { return encrypted }
            raw = standardValue(standard) ?? ""
        } else if let custom = customValue(name: name) {
            raw = custom
        } else {
            return nil
        }
        return algorithm == nil ? MacroEncoding.percentEncode(raw) : MacroEncoding.base64URL(raw)
    }

    /// Exchange-defined values the context models directly; the rest come from `context.custom` under the macro name.
    private mutating func standardValue(_ macro: OpenRTBMacro) -> String? {
        switch macro {
        case .auctionID, .openRTBID: return context.auctionID
        case .auctionBidID, .openRTBBidID: return context.bidID
        case .auctionImpID, .openRTBItemID: return context.impID
        case .auctionSeatID, .openRTBSeatID: return context.seatID
        case .auctionAdID, .openRTBMediaID: return context.adID
        case .auctionPrice, .openRTBPrice: return context.price.flatMap(MacroEncoding.decimal)
        case .auctionCurrency, .openRTBCurrency: return context.currency
        case .auctionMBR, .openRTBMBR: return context.marketBidRatio.flatMap(MacroEncoding.decimal)
        case .auctionLoss, .openRTBLoss: return context.lossReason.map(String.init)
        case .auctionMinToWin, .openRTBMinToWin: return context.minimumToWin.flatMap(MacroEncoding.decimal)
        case .auctionImpTimestamp:
            if let custom = context.custom[macro.rawValue] { return custom }
            return MacroEncoding.unixMilliseconds(now())
        case .auctionMultiplier, .auctionDiscountPercent, .auctionDiscountCPM, .openRTBItemQuantity:
            return context.custom[macro.rawValue]
        }
    }

    /// `${KEY}` (user-defined exchange macro) or `${CUSTOM_KEY}` (OpenRTB 3.0 `bid.macro`, key matched exactly).
    private func customValue(name: String) -> String? {
        if let value = context.custom[name] { return value }
        let prefix = "CUSTOM_"
        guard name.hasPrefix(prefix) else { return nil }
        return context.custom[String(name.dropFirst(prefix.count))]
    }

    // MARK: VAST `[NAME]`

    /// The text to substitute, or `nil` when the macro is unknown. Known macros without a value become `-1`
    /// (VAST 4.1 §6.1: "unknown or not available").
    mutating func vastValue(name: String) -> String? {
        let macro = VASTMacro(rawValue: name)
        if let macro, let value = contextValue(macro) { return MacroEncoding.percentEncode(value) }
        if let custom = context.custom["[" + name + "]"] { return MacroEncoding.percentEncode(custom) }
        if let macro, let value = derivedValue(macro) { return MacroEncoding.percentEncode(value) }
        return macro == nil ? nil : MacroEncoding.unknownVASTValue
    }

    /// Values the player sets on the context for this request.
    private func contextValue(_ macro: VASTMacro) -> String? {
        switch macro {
        case .errorCode: return context.errorCode.map(String.init)
        case .reason: return context.reason.map(String.init)
        case .timestamp: return context.timestamp.flatMap { MacroEncoding.iso8601($0, timeZone: timeZone) }
        case .cacheBusting: return context.cacheBuster
        case .adPlayhead: return context.adPlayhead.flatMap(MacroEncoding.playhead)
        case .contentPlayhead, .mediaPlayhead: return context.contentPlayhead.flatMap(MacroEncoding.playhead)
        case .assetURI: return context.assetURI
        case .playerSize:
            guard let width = context.playerWidth, let height = context.playerHeight else { return nil }
            return "\(width),\(height)"
        case .deviceUA: return context.device?.userAgent
        default: return nil
        }
    }

    /// Values the simulator can always produce.
    private mutating func derivedValue(_ macro: VASTMacro) -> String? {
        switch macro {
        case .timestamp: return MacroEncoding.iso8601(now(), timeZone: timeZone)
        case .cacheBusting: return cacheBuster()
        case .breakPosition:
            // 1 pre-roll, 2 mid-roll, 3 post-roll, 4 standalone (no content).
            guard let playhead = context.contentPlayhead, playhead.isFinite, playhead >= 0 else { return "4" }
            return playhead == 0 ? "1" : "2"
        case .vastVersions:
            // AdCOM Creative Subtypes the simulator plays: VAST 2.0, 3.0, 2.0/3.0 wrappers, 4.0, 4.0 wrapper, 4.1, 4.1 wrapper,
            // 4.2, 4.2 wrapper.
            return "2,3,5,6,7,8,11,12,13,14"
        case .serverSide:
            return "0"
        default:
            return nil
        }
    }

    // MARK: Clock and randomness

    private mutating func now() -> Date {
        if let fixed = context.timestamp { return fixed }
        if let cachedNow { return cachedNow }
        let date = Date()
        cachedNow = date
        return date
    }

    private mutating func cacheBuster() -> String {
        if let cachedCacheBuster { return cachedCacheBuster }
        let value = String(UInt32.random(in: 10_000_000...99_999_999))
        cachedCacheBuster = value
        return value
    }
}

// MARK: - Macro names

/// OpenRTB 2.6 §4.4 and OpenRTB 3.0 substitution macros.
enum OpenRTBMacro: String, CaseIterable {
    case auctionID = "AUCTION_ID", auctionBidID = "AUCTION_BID_ID", auctionImpID = "AUCTION_IMP_ID", auctionSeatID = "AUCTION_SEAT_ID"
    case auctionAdID = "AUCTION_AD_ID", auctionPrice = "AUCTION_PRICE", auctionCurrency = "AUCTION_CURRENCY", auctionMBR = "AUCTION_MBR"
    case auctionLoss = "AUCTION_LOSS", auctionMinToWin = "AUCTION_MIN_TO_WIN", auctionMultiplier = "AUCTION_MULTIPLIER"
    case auctionImpTimestamp = "AUCTION_IMP_TS", auctionDiscountPercent = "AUCTION_DISCOUNT_PCT", auctionDiscountCPM = "AUCTION_DISCOUNT_CPM"
    case openRTBID = "OPENRTB_ID", openRTBBidID = "OPENRTB_BID_ID", openRTBItemID = "OPENRTB_ITEM_ID", openRTBItemQuantity = "OPENRTB_ITEM_QTY"
    case openRTBSeatID = "OPENRTB_SEAT_ID", openRTBMediaID = "OPENRTB_MEDIA_ID", openRTBPrice = "OPENRTB_PRICE"
    case openRTBCurrency = "OPENRTB_CURRENCY", openRTBMBR = "OPENRTB_MBR", openRTBLoss = "OPENRTB_LOSS", openRTBMinToWin = "OPENRTB_MIN_TO_WIN"

    var isPrice: Bool { self == .auctionPrice || self == .openRTBPrice }
}

/// VAST 4.x macros (VAST 4.1 §6.2 and 4.2). Values the player does not model come from `MacroContext.custom["[NAME]"]`
/// (request-derived) or are `-1`.
enum VASTMacro: String, CaseIterable {
    // Generic
    case timestamp = "TIMESTAMP", cacheBusting = "CACHEBUSTING"
    // Ad break
    case adCount = "ADCOUNT", transactionID = "TRANSACTIONID", placementType = "PLACEMENTTYPE", breakMaxDuration = "BREAKMAXDURATION"
    case breakMaxAds = "BREAKMAXADS", breakMinDuration = "BREAKMINDURATION", breakMaxAdLength = "BREAKMAXADLENGTH"
    case breakMinAdLength = "BREAKMINADLENGTH", breakPosition = "BREAKPOSITION", adPlayhead = "ADPLAYHEAD", adServingID = "ADSERVINGID"
    case assetURI = "ASSETURI", blockedAdCategories = "BLOCKEDADCATEGORIES", adCategories = "ADCATEGORIES", adType = "ADTYPE"
    case contentPlayhead = "CONTENTPLAYHEAD", mediaPlayhead = "MEDIAPLAYHEAD", podSequence = "PODSEQUENCE"
    case universalAdID = "UNIVERSALADID", contentID = "CONTENTID", contentURI = "CONTENTURI"
    // Client
    case ifa = "IFA", ifaType = "IFATYPE", clientUA = "CLIENTUA", serverUA = "SERVERUA", deviceUA = "DEVICEUA", serverSide = "SERVERSIDE"
    case deviceIP = "DEVICEIP", latLong = "LATLONG", domain = "DOMAIN", pageURL = "PAGEURL", appBundle = "APPBUNDLE", storeID = "STOREID"
    case storeURL = "STOREURL", vastVersions = "VASTVERSIONS", apiFrameworks = "APIFRAMEWORKS", verificationVendors = "VERIFICATIONVENDORS"
    case omidPartner = "OMIDPARTNER", mediaMime = "MEDIAMIME", playerCapabilities = "PLAYERCAPABILITIES", clickType = "CLICKTYPE"
    case playerState = "PLAYERSTATE", inventoryState = "INVENTORYSTATE", playerSize = "PLAYERSIZE", clickPosition = "CLICKPOS"
    case limitAdTracking = "LIMITADTRACKING", regulations = "REGULATIONS", gdprConsent = "GDPRCONSENT"
    // Errors and verification
    case errorCode = "ERRORCODE", reason = "REASON"
}

// MARK: - Encoding helpers

enum MacroEncoding {
    /// VAST 4.1 §6.1: the value is unknown or not available to the player.
    static let unknownVASTValue = "-1"

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    /// RFC 3986 percent-encoding of every byte except the unreserved set `A–Z a–z 0–9 - . _ ~`.
    static func percentEncode(_ value: String) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isUnreserved(byte) {
                output.append(byte)
            } else {
                output.append(UInt8(ascii: "%"))
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"): true
        default: false
        }
    }

    /// RFC 4648 §5 base64url without padding.
    static func base64URL(_ value: String) -> String {
        var encoded = Data(value.utf8).base64EncodedString()
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return String(encoded.map { character -> Character in
            switch character {
            case "+": "-"
            case "/": "_"
            default: character
            }
        })
    }

    /// Shortest round-trip decimal (`2` not `2.0`); `nil` for NaN / infinity.
    static func decimal(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    /// Milliseconds since the epoch.
    static func unixMilliseconds(_ date: Date) -> String? {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard milliseconds.isFinite, abs(milliseconds) < 9e15 else { return nil }
        return String(Int64(milliseconds))
    }

    /// `HH:MM:SS.mmm` (VAST 4.1 §6.2 `[ADPLAYHEAD]`); `nil` when negative, non-finite or 100 hours or longer.
    static func playhead(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, seconds < 360_000 else { return nil }
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        guard hours < 100 else { return nil }
        let minutes = totalMilliseconds / 60_000 % 60
        let wholeSeconds = totalMilliseconds / 1000 % 60
        let milliseconds = totalMilliseconds % 1000
        return pad(hours, 2) + ":" + pad(minutes, 2) + ":" + pad(wholeSeconds, 2) + "." + pad(milliseconds, 3)
    }

    /// ISO 8601 with milliseconds and the zone (`2016-01-17T08:15:07.127-05:00`, `…Z` for UTC), VAST 4.1 `[TIMESTAMP]`.
    static func iso8601(_ date: Date, timeZone: TimeZone) -> String? {
        let totalMilliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard totalMilliseconds.isFinite, abs(totalMilliseconds) < 2.5e14 else { return nil } // ± ~9,900 years
        let wholeSeconds = (totalMilliseconds / 1000).rounded(.down)
        let milliseconds = Int(totalMilliseconds - wholeSeconds * 1000)
        let instant = Date(timeIntervalSince1970: wholeSeconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute,
              let second = parts.second, (0...9999).contains(year) else { return nil }
        let offset = timeZone.secondsFromGMT(for: instant)
        let zone: String
        if offset == 0 {
            zone = "Z"
        } else {
            let magnitude = abs(offset) / 60
            zone = (offset < 0 ? "-" : "+") + pad(magnitude / 60, 2) + ":" + pad(magnitude % 60, 2)
        }
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T" + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
            + "." + pad(milliseconds, 3) + zone
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
