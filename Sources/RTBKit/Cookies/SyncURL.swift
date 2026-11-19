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
        /// Id parameters carrying a "no id" sentinel (`uid=0`, `undefined` …): the partner had no cookie or the user opted out.
        public var sentinels: [Parameter]
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

    /// The placeholders of `url` itself: its path and the query values that are not URLs. A URL passed as a parameter
    /// (`redir=https://ssp.example/setuid?uid=$UID`) is the next party's template, where a placeholder belongs.
    public static func ownPlaceholders(in url: String) -> [String] {
        let parts = split(url)
        var found = leftoverPlaceholders(in: parts.path)
        for item in parts.query {
            // `getuid?<url>` (no "="): the whole query is the nested URL.
            if !looksLikeURL(item.name) { found += leftoverPlaceholders(in: item.name) }
            if !looksLikeURL(item.value) { found += leftoverPlaceholders(in: item.value) }
        }
        return found
    }

    /// A URL, or one still percent-encoded once more (`https%3A%2F%2F…`).
    static func looksLikeURL(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["http://", "https://", "//", "http%3a", "https%3a"].contains { lowered.hasPrefix($0) }
    }

    /// A placeholder for a user id (`$UID`, `${BUYER_ID}`, `{{.UID}}`) rather than for consent or a URL: left
    /// unsubstituted, it loses the match.
    public static func isIDPlaceholder(_ placeholder: String) -> Bool {
        let name = placeholder.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.contains("UID") || name.contains("USER") || name.contains("BUYER") || name == "ID" || name.hasSuffix("_ID")
    }

    /// The path and the percent-decoded query pairs of `url`, read leniently: sync URLs carry characters `URLComponents`
    /// refuses (`${GDPR}`, `{uid}`).
    static func split(_ url: String) -> (path: String, query: [Parameter]) {
        let withoutFragment = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        let halves = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var path = String(halves.first ?? "")
        if let scheme = path.range(of: "://") {
            let afterScheme = path[scheme.upperBound...]
            path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        guard halves.count == 2 else { return (path, []) }
        let query = halves[1].split(separator: "&").map { pair -> Parameter in
            let sides = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode: (Substring) -> String = { part in
                let plus = part.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            return Parameter(name: decode(sides[0]), value: sides.count > 1 ? decode(sides[1]) : "")
        }
        return (path, query)
    }

    private static let placeholderPattern: NSRegularExpression = {
        // Ordered so the longer forms win: ${X} before $X, {{x}} (and Go templates {{.X}}) before {x}.
        let pattern = #"\$\{[A-Za-z0-9_]+\}|\{\{\s*\.?[A-Za-z0-9_.]+\s*\}\}|\$[A-Z][A-Z0-9_]*|\[[A-Z][A-Z0-9_]*\]|\{[A-Za-z0-9_]+\}"#
        do { return try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("invalid placeholder pattern") }
    }()

    /// The user ids and partners in `url`'s query.
    public static func mappingParameters(in url: String) -> Mapping {
        var ids: [Parameter] = []
        var partners: [Parameter] = []
        var sentinels: [Parameter] = []
        for item in split(url).query {
            let value = item.value
            guard !value.isEmpty else { continue }
            let key = item.name.lowercased()
            if partnerKeys.contains(key) {
                partners.append(Parameter(name: item.name, value: value))
            } else if idKeys.contains(key) || key.hasSuffix("_uid") || key.hasSuffix("puid") || key.hasSuffix("userid") {
                // An unsubstituted placeholder is no id: the partner did not fill it in.
                guard leftoverPlaceholders(in: value).isEmpty else { continue }
                if sentinelValues.contains(value.lowercased()) {
                    sentinels.append(Parameter(name: item.name, value: value))
                } else {
                    ids.append(Parameter(name: item.name, value: value))
                }
            }
        }
        return Mapping(ids: ids, partners: partners, sentinels: sentinels)
    }

    static let idKeys: Set<String> = ["uid", "buyeruid", "buyer_uid", "user_id", "userid", "puid", "partneruid", "partner_uid", "external_uid",
                                      "dspuid", "dsp_uid", "google_gid", "google_hm", "xuid", "tuid", "id5id", "pubcid"]
    /// What partners send instead of an id when they have none (AppNexus: `uid=0`).
    static let sentinelValues: Set<String> = ["0", "-1", "null", "undefined", "nil", "none", "false", "unknown", "00000000-0000-0000-0000-000000000000"]
    static let partnerKeys: Set<String> = ["bidder", "bidder_code", "partner", "partner_id", "partnerid", "dsp", "network", "ssp", "source"]
}
