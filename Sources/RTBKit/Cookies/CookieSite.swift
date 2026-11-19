import Foundation

/// A site for cookie decisions: scheme plus registrable domain ("schemeful same-site"). The registrable domain is the
/// last two labels, or three under a known multi-label public suffix (`co.uk` …): an approximation of the Public Suffix
/// List that covers ad-tech domains; IP addresses and `localhost` are their own site.
public struct CookieSite: Hashable, Sendable, Codable, CustomStringConvertible {
    public let scheme: String
    public let registrableDomain: String

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        self.scheme = scheme
        registrableDomain = Self.registrableDomain(of: host)
    }

    public var description: String { "\(scheme)://\(registrableDomain)" }

    public static func registrableDomain(of host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if isIPAddress(host) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return multiLabelSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    /// A domain a cookie may not be scoped to: a top-level domain (any single label but `localhost`) or a known
    /// multi-label suffix.
    public static func isPublicSuffix(_ domain: String) -> Bool {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if domain.isEmpty { return true }
        if !domain.contains(".") { return domain != "localhost" }
        return multiLabelSuffixes.contains(domain)
    }

    static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || (!host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") })
    }

    /// Multi-label public suffixes common in ad tech (Public Suffix List excerpt).
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp", "or.jp",
        "com.cn", "net.cn", "org.cn", "com.hk", "com.tw", "co.kr", "or.kr", "co.in", "com.sg", "com.my", "co.id", "co.th", "com.vn",
        "com.ph", "com.br", "com.ar", "com.mx", "com.co", "co.za", "com.tr", "com.ua", "co.il", "com.sa", "com.eg",
        "github.io", "herokuapp.com", "appspot.com", "cloudfront.net", "azurewebsites.net", "blogspot.com", "vercel.app", "netlify.app",
    ]
}
