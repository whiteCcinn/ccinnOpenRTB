import CoreGraphics
import Foundation
import RTBKit

/// One editable macro value (`${KEY}` custom macro, or a bracketed request-derived VAST value such as `[DOMAIN]`).
struct MacroEntry: Identifiable, Hashable, Sendable {
    var id = UUID()
    var key: String
    var value: String
}

/// The Macros panel: values the simulator substitutes into tracker URLs (design D4), plus the auction options.
struct MacroSettings: Equatable, Sendable {
    /// Fixed `[TIMESTAMP]` in deterministic mode: 2026-01-01T00:00:00Z.
    static let deterministicTimestamp = Date(timeIntervalSince1970: 1_767_225_600)
    static let deterministicCacheBuster = "12345678"
    static let deterministicTransactionID = "00000000-0000-4000-8000-000000000000"

    /// Empty: the bid price.
    var clearingPrice = ""
    /// Opaque encrypted price, substituted verbatim for `${AUCTION_PRICE}` when set.
    var encryptedPrice = ""
    /// Empty: the bid request id, else the response id.
    var auctionID = ""
    /// Empty: the bid's seat.
    var seatID = ""
    /// `${AUCTION_MIN_TO_WIN}`; empty: not set.
    var minimumToWin = ""
    /// `${AUCTION_LOSS}` and the Lose control.
    var lossReason = LossReason.lostToHigherBid
    /// `${KEY}` macros; they override the bid's own `bid.macro` values with the same key.
    var customMacros: [MacroEntry] = []
    /// Bracketed VAST values a real request would supply.
    var requestValues: [MacroEntry] = MacroSettings.defaultRequestValues
    /// The exchange sends the win notice (`nurl`) when the ad wins.
    var exchangeSendsWinNotice = true
    /// Fixed `[TIMESTAMP]`, `[CACHEBUSTING]` and `[TRANSACTIONID]`, so two runs produce identical URLs.
    var deterministic = false

    static let defaultRequestValues: [MacroEntry] = [
        MacroEntry(key: "[APPBUNDLE]", value: "com.example.newsreader"),
        MacroEntry(key: "[DOMAIN]", value: "news.example.com"),
        MacroEntry(key: "[PAGEURL]", value: "https://news.example.com/world/article-42"),
        MacroEntry(key: "[IFA]", value: "6D92078A-8246-4BA4-AE5B-76104861E7DC"),
        MacroEntry(key: "[IFATYPE]", value: "idfa"),
        MacroEntry(key: "[LIMITADTRACKING]", value: "0"),
    ]

    /// VAST 4.1/4.2 §6.2 macros of type `Array<T>` (and the `number,number` pairs `[LATLONG]`, `[PLAYERSIZE]`, `[CLICKPOS]`):
    /// a panel value is split at commas into `MacroContext.customLists`, so the expander percent-encodes each item and
    /// keeps the commas literal (§6.1). `[REGULATIONS]` has no default: it is `Array<string>` (`gdpr`, `coppa`, …) and
    /// stays unknown unless the request or the user supplies it.
    static let listMacroKeys: Set<String> = [
        "[ADCATEGORIES]", "[APIFRAMEWORKS]", "[BLOCKEDADCATEGORIES]", "[CLICKPOS]", "[EXTENSIONS]", "[INVENTORYSTATE]", "[LATLONG]",
        "[MEDIAMIME]", "[PLAYERCAPABILITIES]", "[PLAYERSIZE]", "[PLAYERSTATE]", "[REGULATIONS]", "[UNIVERSALADID]", "[VASTVERSIONS]",
        "[VERIFICATIONVENDORS]",
    ]

    /// Parses a price typed with either decimal separator; `nil` when empty or not a finite, non-negative number.
    static func price(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// The macro context for one tracker batch: `MacroContext.simulatorDefaults` (the bid, the pasted request, the
    /// response ids, the device and the player size), then the panel (`overlay`).
    /// - Parameters:
    ///   - transactionID: `[TRANSACTIONID]` of the current render when the request has none.
    ///   - playhead: `[ADPLAYHEAD]` of the ad the event belongs to.
    func context(candidate: AdCandidate, input: ParsedInput, device: DeviceProfile, playerSize: CGSize, transactionID: String,
                 playhead: Double? = nil) -> MacroContext {
        func defaults(_ request: BidRequestSummary?) -> MacroContext {
            MacroContext.simulatorDefaults(candidate: candidate, request: request, device: device, playerWidth: Self.points(playerSize.width),
                                           playerHeight: Self.points(playerSize.height), responseID: input.responseID,
                                           responseBidID: input.bidResponseID)
        }
        let base = defaults(input.request)
        return overlay(on: base, withoutRequest: input.request == nil ? base : defaults(nil), candidate: candidate,
                       transactionID: transactionID, playhead: playhead)
    }

    /// The panel over the kit's defaults (pure).
    ///
    /// - Request values (`[DOMAIN]`, `[BLOCKEDADCATEGORIES]`, …): the pasted request wins; otherwise the panel's value
    ///   replaces the simulator's own default (one `withoutRequest` has too, such as the player's `[VASTVERSIONS]`). List
    ///   macros (`listMacroKeys`) go to `customLists`, one item per comma; scalars to `custom`.
    /// - `[TRANSACTIONID]` is the request's `source.tid`, else one per render (fixed in deterministic mode).
    /// - `${KEY}` macros override the bid's own `bid.macro` values.
    /// - Auction fields: a typed value replaces the default; an empty (or unreadable) field keeps it — including
    ///   `${AUCTION_MBR}`, which is clearing price ÷ bid price only when a clearing price is typed.
    /// - Parameters:
    ///   - base: `simulatorDefaults` with the pasted request.
    ///   - withoutRequest: `simulatorDefaults` without it: a value that differs (or exists only in `base`) came from the
    ///     request.
    func overlay(on base: MacroContext, withoutRequest: MacroContext, candidate: AdCandidate, transactionID: String,
                 playhead: Double? = nil) -> MacroContext {
        var context = base
        func suppliedByRequest(_ key: String) -> Bool {
            base.custom[key] != withoutRequest.custom[key] || base.customLists[key] != withoutRequest.customLists[key]
        }
        for entry in requestValues {
            let trimmed = entry.key.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !entry.value.isEmpty else { continue }
            let key = Self.bracketedKey(trimmed)
            guard !suppliedByRequest(key) else { continue }
            if Self.listMacroKeys.contains(key) {
                let items = Self.listItems(entry.value)
                guard !items.isEmpty else { continue }
                context.customLists[key] = items
                context.custom[key] = nil
            } else {
                context.custom[key] = entry.value
                context.customLists[key] = nil
            }
        }
        if context.custom["[TRANSACTIONID]"]?.isEmpty ?? true {
            context.custom["[TRANSACTIONID]"] = deterministic ? Self.deterministicTransactionID : transactionID
        }
        for entry in customMacros {
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            context.custom[Self.plainKey(key)] = entry.value
        }

        let clearing = Self.price(clearingPrice)
        let encrypted = encryptedPrice.trimmingCharacters(in: .whitespaces)
        let auction = auctionID.trimmingCharacters(in: .whitespaces)
        let seat = seatID.trimmingCharacters(in: .whitespaces)
        if !auction.isEmpty { context.auctionID = auction }
        if !seat.isEmpty { context.seatID = seat }
        if let clearing { context.price = clearing }
        if !encrypted.isEmpty { context.encryptedPrice = encrypted }
        context.marketBidRatio = clearing.flatMap { clearing in candidate.price > 0 ? clearing / candidate.price : nil } ?? base.marketBidRatio
        context.lossReason = lossReason.code
        context.minimumToWin = Self.price(minimumToWin) ?? base.minimumToWin
        context.adPlayhead = playhead ?? base.adPlayhead
        if deterministic {
            context.timestamp = Self.deterministicTimestamp
            context.cacheBuster = Self.deterministicCacheBuster
        }
        return context
    }

    /// `" IAB25 , IAB26,,"` → `["IAB25", "IAB26"]`.
    static func listItems(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `${KEY}` / `KEY` → `KEY`.
    static func plainKey(_ key: String) -> String {
        if key.hasPrefix("${"), key.hasSuffix("}"), key.count > 3 { return String(key.dropFirst(2).dropLast()) }
        return key
    }

    /// `DOMAIN` / `[DOMAIN]` → `[DOMAIN]`.
    static func bracketedKey(_ key: String) -> String {
        key.hasPrefix("[") && key.hasSuffix("]") ? key : "[\(key)]"
    }

    private static func points(_ value: CGFloat) -> Int? {
        guard value.isFinite, value > 0, value < CGFloat(Int32.max) else { return nil }
        return Int(value.rounded())
    }
}

/// OpenRTB loss reason codes (OpenRTB 2.5 §5.25 / AdCOM "Loss Reason Codes").
struct LossReason: Hashable, Identifiable, Sendable {
    let code: Int
    let title: String
    var id: Int { code }

    static let lostToHigherBid = LossReason(code: 102, title: "Lost to higher bid")

    static let all: [LossReason] = [
        LossReason(code: 1, title: "Internal error"),
        LossReason(code: 2, title: "Impression opportunity expired"),
        LossReason(code: 3, title: "Invalid bid response"),
        LossReason(code: 4, title: "Invalid deal ID"),
        LossReason(code: 5, title: "Invalid auction ID"),
        LossReason(code: 6, title: "Invalid advertiser domain"),
        LossReason(code: 7, title: "Missing markup"),
        LossReason(code: 8, title: "Missing creative ID"),
        LossReason(code: 9, title: "Missing bid price"),
        LossReason(code: 10, title: "Missing minimum creative approval data"),
        LossReason(code: 100, title: "Bid below auction floor"),
        LossReason(code: 101, title: "Bid below deal floor"),
        lostToHigherBid,
        LossReason(code: 103, title: "Lost to a bid for a PMP deal"),
        LossReason(code: 104, title: "Buyer seat blocked"),
        LossReason(code: 200, title: "Creative filtered – reason unknown"),
        LossReason(code: 201, title: "Creative filtered – pending processing"),
        LossReason(code: 202, title: "Creative filtered – disapproved"),
        LossReason(code: 203, title: "Creative filtered – size not allowed"),
        LossReason(code: 204, title: "Creative filtered – incorrect format"),
        LossReason(code: 205, title: "Creative filtered – advertiser exclusions"),
        LossReason(code: 206, title: "Creative filtered – app store ID exclusions"),
        LossReason(code: 207, title: "Creative filtered – not secure"),
        LossReason(code: 208, title: "Creative filtered – language exclusions"),
        LossReason(code: 209, title: "Creative filtered – category exclusions"),
        LossReason(code: 210, title: "Creative filtered – creative attribute exclusions"),
        LossReason(code: 211, title: "Creative filtered – ad type exclusions"),
        LossReason(code: 212, title: "Creative filtered – animation too long"),
        LossReason(code: 213, title: "Creative filtered – not allowed in PMP deal"),
    ]

    static func reason(code: Int) -> LossReason {
        all.first { $0.code == code } ?? LossReason(code: code, title: "Exchange-specific")
    }
}

extension VASTErrorCode {
    /// The VAST 4.2 name of the code.
    var title: String {
        switch self {
        case .xmlParsing: "XML parsing error"
        case .schemaValidation: "VAST schema validation error"
        case .unsupportedVersion: "VAST version not supported"
        case .traffickingError: "Trafficking error"
        case .unexpectedLinearity: "Unexpected linearity"
        case .unexpectedDuration: "Unexpected duration"
        case .unexpectedSize: "Unexpected size"
        case .adCategoryRequired: "Ad category required"
        case .blockedAdCategory: "Category blocked by a wrapper"
        case .adBreakShortened: "Ad break shortened"
        case .wrapperError: "General wrapper error"
        case .wrapperTimeout: "Wrapper timeout"
        case .wrapperLimit: "Wrapper limit reached"
        case .noAdsAfterWrapper: "No ads after wrapper"
        case .inlineResponseTimeout: "InLine response timeout"
        case .linearError: "General linear error"
        case .fileNotFound: "Media file not found"
        case .mediaTimeout: "Media file timeout"
        case .noSupportedMedia: "No supported media file"
        case .mediaDisplayProblem: "Problem displaying media file"
        case .mezzanineRequired: "Mezzanine required"
        case .mezzanineDownloading: "Mezzanine downloading"
        case .conditionalAdRejected: "Conditional ad rejected"
        case .interactiveCreativeError: "Interactive creative error"
        case .codeResourceError: "Verification code resource error"
        case .nonLinearError: "General non-linear error"
        case .nonLinearDimensions: "Non-linear ad too large"
        case .nonLinearResourceUnavailable: "Non-linear resource not fetched"
        case .nonLinearResourceUnsupported: "No supported non-linear resource"
        case .companionError: "General companion error"
        case .companionDimensions: "Companion does not fit"
        case .requiredCompanionUnavailable: "Required companion not displayed"
        case .companionResourceUnavailable: "Companion resource not fetched"
        case .companionResourceUnsupported: "No supported companion resource"
        case .undefinedError: "Undefined error"
        case .vpaidError: "VPAID error"
        }
    }
}
