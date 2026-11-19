import Foundation

/// The browser's cross-origin rules for the Prebid page's requests, as the Fetch standard words them: which requests
/// need a preflight, what a preflight and a response must answer for the page to read them, which response headers the
/// page sees, and mixed content. A bidder whose endpoint gets these wrong loses its bids in Safari; here the bid is
/// lost the same way, and the Log says why. Pure.
enum PrebidCORS {
    /// The request's credentials mode (`fetch`'s `credentials`; XHR's `withCredentials` is `include`).
    enum Credentials: String, Sendable {
        case omit
        case sameOrigin = "same-origin"
        case include

        init(page value: String?) {
            self = Credentials(rawValue: value ?? "") ?? .sameOrigin
        }
    }

    /// GET, HEAD and POST need no preflight (Fetch: CORS-safelisted methods).
    static let safelistedMethods: Set<String> = ["GET", "HEAD", "POST"]
    private static let safelistedContentTypes: Set<String> = ["application/x-www-form-urlencoded", "multipart/form-data", "text/plain"]
    private static let safelistedResponseHeaders: Set<String> = ["cache-control", "content-language", "content-length", "content-type", "expires",
                                                                 "last-modified", "pragma"]

    /// Fetch's CORS-safelisted request header: `Accept`, `Accept-Language`, `Content-Language` or a simple `Content-Type`,
    /// at most 128 bytes, without the bytes a browser treats as unsafe.
    static func isSafelisted(name: String, value: String) -> Bool {
        guard value.utf8.count <= 128 else { return false }
        let unsafeBytes: Set<UInt8> = [0x22, 0x28, 0x29, 0x3A, 0x3C, 0x3E, 0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x7B, 0x7D, 0x7F]
        let hasUnsafeByte = value.utf8.contains { ($0 < 0x20 && $0 != 0x09) || unsafeBytes.contains($0) }
        switch name.lowercased() {
        case "accept":
            return !hasUnsafeByte
        case "accept-language", "content-language":
            return value.unicodeScalars.allSatisfy { $0.properties.isAlphabetic && $0.isASCII || "0123456789 *,-.;=".unicodeScalars.contains($0) }
        case "content-type":
            let essence = value.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            return !hasUnsafeByte && safelistedContentTypes.contains(essence)
        default:
            return false
        }
    }

    /// The names (lowercased, sorted, once) of the headers that are not safelisted: what a preflight must allow.
    static func unsafeHeaderNames(_ headers: [String: String]) -> [String] {
        Set(headers.filter { !isSafelisted(name: $0.key, value: $0.value) }.map { $0.key.lowercased() }).sorted()
    }

    static func needsPreflight(method: String, headers: [String: String]) -> Bool {
        !safelistedMethods.contains(method.uppercased()) || !unsafeHeaderNames(headers).isEmpty
    }

    /// The preflight's own headers (the browser adds Origin, Referer, `Sec-Fetch-*` and its User-Agent).
    static func preflightHeaders(method: String, unsafeNames: [String]) -> [String: String] {
        var headers = ["Accept": "*/*", "Access-Control-Request-Method": method.uppercased()]
        if !unsafeNames.isEmpty { headers["Access-Control-Request-Headers"] = unsafeNames.joined(separator: ",") }
        return headers
    }

    /// Why the page may not read a cross-origin response (`nil`: it may).
    static func responseProblem(headers: [String: String], origin: String, credentials: Credentials) -> String? {
        guard let allowed = value("Access-Control-Allow-Origin", in: headers) else {
            return "no Access-Control-Allow-Origin header: the browser does not let \(origin) read the response"
        }
        if allowed == "*" {
            return credentials == .include
                ? "Access-Control-Allow-Origin is * on a request with credentials (withCredentials): the browser requires \(origin) itself"
                : nil
        }
        guard allowed == origin else { return "Access-Control-Allow-Origin is “\(allowed.prefix(120))”, not \(origin)" }
        if credentials == .include && value("Access-Control-Allow-Credentials", in: headers) != "true" {
            return "a request with credentials (withCredentials) needs Access-Control-Allow-Credentials: true"
        }
        return nil
    }

    /// Why a preflight refuses the request (`nil`: the request may go).
    static func preflightProblem(status: Int, headers: [String: String], origin: String, method: String, unsafeNames: [String],
                                 credentials: Credentials) -> String? {
        guard (200...299).contains(status) else { return "the preflight (OPTIONS) answered \(status), not a 2xx" }
        if let problem = responseProblem(headers: headers, origin: origin, credentials: credentials) { return "the preflight: " + problem }
        let wildcard = credentials != .include
        let methods = list("Access-Control-Allow-Methods", in: headers)
        let verb = method.uppercased()
        if !safelistedMethods.contains(verb) && !methods.contains(verb) && !(wildcard && methods.contains("*")) {
            return "the preflight does not allow the method \(verb) (Access-Control-Allow-Methods)"
        }
        let allowedHeaders = Set(list("Access-Control-Allow-Headers", in: headers).map { $0.lowercased() })
        let refused = unsafeNames.filter { name in
            !allowedHeaders.contains(name) && !(wildcard && allowedHeaders.contains("*") && name != "authorization")
        }
        if !refused.isEmpty { return "the preflight does not allow the header(s) \(refused.joined(separator: ", ")) (Access-Control-Allow-Headers)" }
        return nil
    }

    /// The response headers the page can read: all but `Set-Cookie` from its own origin; across origins the safelisted
    /// ones and those in `Access-Control-Expose-Headers` (`*`: all, unless the request had credentials).
    static func exposedHeaders(_ headers: [String: String], crossOrigin: Bool, credentials: Credentials) -> [String: String] {
        let readable = headers.filter { !["set-cookie", "set-cookie2"].contains($0.key.lowercased()) }
        guard crossOrigin else { return readable }
        let exposed = Set(list("Access-Control-Expose-Headers", in: headers).map { $0.lowercased() })
        if exposed.contains("*") && credentials != .include { return readable }
        return readable.filter { safelistedResponseHeaders.contains($0.key.lowercased()) || exposed.contains($0.key.lowercased()) }
    }

    /// An https page's request to http, which WebKit blocks — except to the Mac itself (`localhost`, loopback addresses),
    /// a potentially trustworthy origin.
    static func isMixedContent(_ url: URL, page: URL) -> Bool {
        guard page.scheme?.lowercased() == "https", url.scheme?.lowercased() == "http" else { return false }
        return !isLoopback(url.host ?? "")
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { part in UInt8(part).map { String($0) == part } ?? false }
    }

    private static func value(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.trimmingCharacters(in: .whitespaces)
    }

    private static func list(_ name: String, in headers: [String: String]) -> [String] {
        (value(name, in: headers) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
