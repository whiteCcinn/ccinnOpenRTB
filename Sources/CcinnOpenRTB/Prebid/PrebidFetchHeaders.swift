import Foundation
import RTBKit

/// The headers a browser adds to a request the Prebid page makes, which page scripts cannot set themselves: `Origin`,
/// `Referer` (the default policy, `strict-origin-when-cross-origin`), `Sec-Fetch-Site/Mode/Dest` and, for Chrome, its
/// User-Agent Client Hints. Bidders read them (domain checks, fraud filters, `device.sua`); without them a request does
/// not look like it came from a page. Pure.
enum PrebidFetchHeaders {
    /// The Fetch standard's forbidden request header names: a page cannot set them (the browser's win).
    private static let forbidden: Set<String> = ["accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
                                                 "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive",
                                                 "origin", "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via"]

    static func isForbidden(_ name: String) -> Bool {
        let name = name.lowercased()
        return forbidden.contains(name) || name.hasPrefix("proxy-") || name.hasPrefix("sec-")
    }

    /// `pageHeaders` (what the page's script asked for) without the forbidden names, plus the browser's own. `mode` is the
    /// request's (`cors`, `no-cors`, `same-origin`); `clientHints` go to https only, as Chrome sends them.
    static func headers(for url: URL, method: String, mode: String, page: URL, pageHeaders: [String: String],
                        clientHints: [String: String] = [:]) -> [String: String] {
        var headers = pageHeaders.filter { !isForbidden($0.key) }
        let sameOrigin = origin(of: url) == origin(of: page)
        let method = method.uppercased()
        // A cross-origin CORS request carries Origin, and so does every request that is not a GET or HEAD.
        if let origin = origin(of: page), (!sameOrigin && mode == "cors") || (method != "GET" && method != "HEAD") { headers["Origin"] = origin }
        if let referer = referer(for: url, page: page) { headers["Referer"] = referer }
        headers["Sec-Fetch-Site"] = sameOrigin ? "same-origin" : (CookieSite(url: url) == CookieSite(url: page) && CookieSite(url: page) != nil ? "same-site" : "cross-site")
        headers["Sec-Fetch-Mode"] = mode
        headers["Sec-Fetch-Dest"] = "empty"
        if url.scheme?.lowercased() == "https" { headers.merge(clientHints) { _, hint in hint } }
        return headers
    }

    /// `strict-origin-when-cross-origin`: the full page URL (no fragment, no credentials) within the origin, the page's
    /// origin across origins, nothing from https to http.
    static func referer(for url: URL, page: URL) -> String? {
        guard let pageOrigin = origin(of: page) else { return nil }
        if page.scheme?.lowercased() == "https" && url.scheme?.lowercased() != "https" { return nil }
        guard origin(of: url) == pageOrigin else { return pageOrigin + "/" }
        guard var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return pageOrigin + "/" }
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? pageOrigin + "/"
    }

    /// `https://news.example` (the port only when it is not the scheme's default).
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        return "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(port)"
    }
}
