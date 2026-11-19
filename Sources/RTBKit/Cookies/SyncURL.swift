import Foundation

/// Consent values a cookie-sync URL carries (IAB TCF v2 "URL-based services" and GPP URL macros).
public struct SyncConsent: Sendable, Hashable, Codable {
    /// `${GDPR}`: 1, 0, or empty when unknown.
    public var gdprApplies: Bool?
    /// `${GDPR_CONSENT_<gvlid>}`: the TC string.
    public var tcString: String?
    /// `${US_PRIVACY}`.
    public var usPrivacy: String?
    /// `${GPP_STRING_<id>}`.
    public var gppString: String?
    /// `${GPP_SID}`, comma-separated.
    public var gppSectionIDs: [Int]
    /// `${ADDTL_CONSENT}` (Google Additional Consent).
    public var addtlConsent: String?

    public init(gdprApplies: Bool? = nil, tcString: String? = nil, usPrivacy: String? = nil, gppString: String? = nil, gppSectionIDs: [Int] = [],
                addtlConsent: String? = nil) {
        self.gdprApplies = gdprApplies
        self.tcString = tcString
        self.usPrivacy = usPrivacy
        self.gppString = gppString
        self.gppSectionIDs = gppSectionIDs
        self.addtlConsent = addtlConsent
    }
}

/// The parts of a cookie-sync URL that decide a match: consent macros to fill, placeholders a partner left
/// unsubstituted, and the ids and partners passed along. Pure.
public enum SyncURL {
    public struct Parameter: Sendable, Hashable {
        public var name: String
        public var value: String
    }

    public struct Mapping: Sendable, Hashable {
        /// User ids passed in the query (`uid`, `buyeruid`, `user_id` …).
        public var ids: [Parameter]
        /// Who the id belongs to (`bidder`, `partner`, `dsp` …).
        public var partners: [Parameter]
    }

    /// Fills the IAB consent macros of `url` with `consent`, URL-encoded (a value not known is empty; `${GDPR}` is 1, 0 or
    /// empty). Other `${…}` macros are left as they are and listed as unknown.
    public static func expandConsentMacros(in url: String, consent: SyncConsent) -> (url: String, replaced: [String], unknown: [String]) {
        var output = ""
        var replaced: [String] = []
        var unknown: [String] = []
        var rest = url[...]
        while let open = rest.range(of: "${") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let token = String(rest[open.lowerBound...close])
            let name = String(rest[open.upperBound..<close])
            if let value = value(of: name, consent: consent) {
                output += encode(value)
                replaced.append(token)
            } else {
                output += token
                unknown.append(token)
            }
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        return (output, replaced, unknown)
    }

    private static func value(of name: String, consent: SyncConsent) -> String? {
        switch name {
        case "GDPR": consent.gdprApplies.map { $0 ? "1" : "0" } ?? ""
        case "GDPR_PD": ""
        case "ADDTL_CONSENT": consent.addtlConsent ?? ""
        case "US_PRIVACY": consent.usPrivacy ?? ""
        case "GPP_SID": consent.gppSectionIDs.map(String.init).joined(separator: ",")
        default:
            if hasNumericSuffix(name, prefix: "GDPR_CONSENT_") { consent.tcString ?? "" }
            else if hasNumericSuffix(name, prefix: "GPP_STRING_") { consent.gppString ?? "" }
            else { nil }
        }
    }

    private static func hasNumericSuffix(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && name.count > prefix.count && name.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded.
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Placeholders a partner left in a URL instead of a value — `$UID`, `${UID}`, `[UID]`, `{uid}`, `{{UID}}` — read
    /// after percent-decoding, in order of appearance.
    public static func leftoverPlaceholders(in url: String) -> [String] {
        let text = url.removingPercentEncoding ?? url
        let range = NSRange(text.startIndex..., in: text)
        return placeholderPattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static let placeholderPattern: NSRegularExpression = {
        // Ordered so the longer forms win: ${X} before $X, {{x}} before {x}.
        let pattern = #"\$\{[A-Za-z0-9_]+\}|\{\{[A-Za-z0-9_]+\}\}|\$[A-Z][A-Z0-9_]*|\[[A-Z][A-Z0-9_]*\]|\{[A-Za-z0-9_]+\}"#
        do { return try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("invalid placeholder pattern") }
    }()

    /// The user ids and partners in `url`'s query.
    public static func mappingParameters(in url: String) -> Mapping {
        let items = URLComponents(string: url)?.queryItems ?? []
        var ids: [Parameter] = []
        var partners: [Parameter] = []
        for item in items {
            guard let value = item.value, !value.isEmpty else { continue }
            let key = item.name.lowercased()
            if partnerKeys.contains(key) {
                partners.append(Parameter(name: item.name, value: value))
            } else if idKeys.contains(key) || key.hasSuffix("_uid") || key.hasSuffix("userid") {
                ids.append(Parameter(name: item.name, value: value))
            }
        }
        return Mapping(ids: ids, partners: partners)
    }

    static let idKeys: Set<String> = ["uid", "buyeruid", "buyer_uid", "user_id", "userid", "puid", "partneruid", "partner_uid", "external_uid",
                                      "dspuid", "dsp_uid", "google_gid", "google_hm", "xuid", "tuid", "id5id", "pubcid"]
    static let partnerKeys: Set<String> = ["bidder", "bidder_code", "partner", "partner_id", "partnerid", "dsp", "network", "ssp", "source"]
}
