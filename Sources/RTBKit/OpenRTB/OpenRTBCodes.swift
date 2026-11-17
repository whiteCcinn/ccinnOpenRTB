import Foundation

/// Names for OpenRTB enumerations the UI shows (OpenRTB 3.0 lists, which OpenRTB 2.6 references).
public enum OpenRTBCodes {
    /// "No-Bid Reason Codes" (`nbr`).
    public static func noBidReasonName(_ code: Int) -> String {
        if let name = noBidReasons[code] { return name }
        return code >= 500 ? "Exchange-specific (\(code))" : "Unknown no-bid reason (\(code))"
    }

    /// "Loss Reason Codes" (`${AUCTION_LOSS}`).
    public static func lossReasonName(_ code: Int) -> String {
        if let name = lossReasons[code] { return name }
        return code >= 500 ? "Exchange-specific (\(code))" : "Unknown loss reason (\(code))"
    }

    /// Every loss reason the spec defines, for pickers.
    public static var lossReasonCodes: [Int] { lossReasons.keys.sorted() }

    private static let noBidReasons: [Int: String] = [
        0: "Unknown Error", 1: "Technical Error", 2: "Invalid Request", 3: "Known Web Crawler", 4: "Suspected Non-Human Traffic",
        5: "Cloud, Data Center, or Proxy IP", 6: "Unsupported Device", 7: "Blocked Publisher or Site", 8: "Unmatched User",
        9: "Daily User Cap Met", 10: "Daily Domain Cap Met", 11: "Ads.txt Authorization Unavailable", 12: "Ads.txt Authorization Violation",
        13: "Ads.cert Authentication Unavailable", 14: "Ads.cert Authentication Violation", 15: "Insufficient Auction Time",
        16: "Incomplete SupplyChain", 17: "Blocked SupplyChain Node",
    ]

    private static let lossReasons: [Int: String] = [
        0: "Bid Won", 1: "Internal Error", 2: "Impression Opportunity Expired", 3: "Invalid Bid Response", 4: "Invalid Deal ID",
        5: "Invalid Auction ID", 6: "Invalid Advertiser Domain", 7: "Missing Markup", 8: "Missing Creative ID", 9: "Missing Bid Price",
        10: "Missing Minimum Creative Approval Data", 100: "Bid was Below Auction Floor", 101: "Bid was Below Deal Floor",
        102: "Lost to Higher Bid", 103: "Lost to a Bid for a Deal", 104: "Buyer Seat Blocked", 200: "Creative Filtered - General",
        201: "Creative Filtered - Pending Processing by Exchange", 202: "Creative Filtered - Disapproved by Exchange",
        203: "Creative Filtered - Size Not Allowed", 204: "Creative Filtered - Incorrect Creative Format",
        205: "Creative Filtered - Advertiser Exclusions", 206: "Creative Filtered - App Store ID Exclusions",
        207: "Creative Filtered - Not Secure", 208: "Creative Filtered - Language Exclusions", 209: "Creative Filtered - Category Exclusions",
        210: "Creative Filtered - Creative Attribute Exclusions", 211: "Creative Filtered - Ad Type Exclusions",
        212: "Creative Filtered - Animation Too Long", 213: "Creative Filtered - Not Allowed in Deal",
        214: "Creative Filtered - Invalid SKAdNetwork", 215: "Creative Filtered - App Bundle Exclusions",
    ]
}

/// ISO 4217 active alphabetic currency codes (plus the precious-metal and fund codes exchanges may quote).
enum CurrencyCodes {
    static func isISO4217(_ code: String) -> Bool {
        all.contains(code)
    }

    static let all: Set<String> = [
        "AED", "AFN", "ALL", "AMD", "ANG", "AOA", "ARS", "AUD", "AWG", "AZN", "BAM", "BBD", "BDT", "BGN", "BHD", "BIF", "BMD", "BND",
        "BOB", "BOV", "BRL", "BSD", "BTN", "BWP", "BYN", "BZD", "CAD", "CDF", "CHE", "CHF", "CHW", "CLF", "CLP", "CNY", "COP", "COU",
        "CRC", "CUC", "CUP", "CVE", "CZK", "DJF", "DKK", "DOP", "DZD", "EGP", "ERN", "ETB", "EUR", "FJD", "FKP", "GBP", "GEL", "GHS",
        "GIP", "GMD", "GNF", "GTQ", "GYD", "HKD", "HNL", "HTG", "HUF", "IDR", "ILS", "INR", "IQD", "IRR", "ISK", "JMD", "JOD",
        "JPY", "KES", "KGS", "KHR", "KMF", "KPW", "KRW", "KWD", "KYD", "KZT", "LAK", "LBP", "LKR", "LRD", "LSL", "LYD", "MAD", "MDL",
        "MGA", "MKD", "MMK", "MNT", "MOP", "MRU", "MUR", "MVR", "MWK", "MXN", "MXV", "MYR", "MZN", "NAD", "NGN", "NIO", "NOK", "NPR",
        "NZD", "OMR", "PAB", "PEN", "PGK", "PHP", "PKR", "PLN", "PYG", "QAR", "RON", "RSD", "RUB", "RWF", "SAR", "SBD", "SCR", "SDG",
        "SEK", "SGD", "SHP", "SLE", "SLL", "SOS", "SRD", "SSP", "STN", "SVC", "SYP", "SZL", "THB", "TJS", "TMT", "TND", "TOP", "TRY",
        "TTD", "TWD", "TZS", "UAH", "UGX", "USD", "USN", "UYI", "UYU", "UYW", "UZS", "VED", "VES", "VND", "VUV", "WST", "XAF", "XAG",
        "XAU", "XBA", "XBB", "XBC", "XBD", "XCD", "XCG", "XDR", "XOF", "XPD", "XPF", "XPT", "XSU", "XTS", "XUA", "YER", "ZAR", "ZMW",
        "ZWG", "ZWL",
    ]
}

/// `major.minor` comparison for declared versions (`"2.5"`, `"1"`, `"1.2"`).
struct SpecVersion: Comparable {
    var major: Int
    var minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, first.count <= 4, let major = Int(first) else { return nil }
        var minor = 0
        if parts.count > 1 {
            guard parts[1].count <= 4, let value = Int(parts[1]) else { return nil }
            minor = value
        }
        self.major = major
        self.minor = minor
    }

    static func < (lhs: SpecVersion, rhs: SpecVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
