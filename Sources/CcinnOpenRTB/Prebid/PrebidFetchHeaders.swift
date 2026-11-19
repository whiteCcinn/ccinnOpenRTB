import Foundation
import RTBKit

/// The headers a browser adds to a request the Prebid page makes, which page scripts cannot set themselves: `Origin`,
/// `Referer` (the default policy, `strict-origin-when-cross-origin`) and `Sec-Fetch-Site/Mode/Dest`. Bidders read them
/// (domain checks, fraud filters); without them a request does not look like it came from a page. Pure.
enum PrebidFetchHeaders {
    /// Headers a page cannot set (the Fetch standard's forbidden names this covers): the browser's win.
    private static let browserOwned: Set<String> = ["origin", "referer", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "cookie", "host",
                                                     "content-length", "connection"]

    /// `pageHeaders` (what the page's script asked for) without the browser-owned names, plus the browser's own.
    static func headers(for url: URL, method: String, kind: String, page: URL, pageHeaders: [String: String]) -> [String: String] {
        var headers = pageHeaders.filter { !browserOwned.contains($0.key.lowercased()) && !$0.key.lowercased().hasPrefix("proxy-") }
        let sameOrigin = origin(of: url) == origin(of: page)
        let method = method.uppercased()
        // Every CORS request carries Origin; a same-origin one only when it is not a GET or HEAD.
        if let origin = origin(of: page), !sameOrigin || (method != "GET" && method != "HEAD") { headers["Origin"] = origin }
        if let referer = referer(for: url, page: page) { headers["Referer"] = referer }
        headers["Sec-Fetch-Site"] = sameOrigin ? "same-origin" : (CookieSite(url: url) == CookieSite(url: page) && CookieSite(url: page) != nil ? "same-site" : "cross-site")
        headers["Sec-Fetch-Mode"] = kind == "beacon" ? "no-cors" : "cors"
        headers["Sec-Fetch-Dest"] = "empty"
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
