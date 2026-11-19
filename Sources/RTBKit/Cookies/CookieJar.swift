import Foundation

/// `SameSite` as written; `unspecified` is read by the policy (Chrome: Lax; WebKit and Firefox: None).
public enum SameSite: String, Sendable, Hashable, Codable {
    case strict, lax, none, unspecified
}

/// What a browser does with third-party cookies (a subresource request — a sync pixel or iframe and its redirects —
/// whose site is not the page's).
public enum CookiePolicy: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Allowed when `SameSite=None; Secure`; a cookie without `SameSite` is Lax ("Lax by default"). `Partitioned`
    /// cookies (CHIPS) are kept per top-level site. Chrome.
    case allowThirdParty
    /// Never stored or sent. WebKit: Safari and in-app web views (`WKWebView`) — every iPhone and iPad.
    case blockThirdParty
    /// Stored and sent, but kept per top-level site; cookies set first party are not visible. Firefox Total Cookie
    /// Protection.
    case partitioned

    public var id: String { rawValue }
}

/// The page a request is made from, and the browser's policy.
public struct CookieContext: Sendable, Hashable {
    public var topLevelSite: CookieSite
    public var policy: CookiePolicy

    public init(topLevelSite: CookieSite, policy: CookiePolicy) {
        self.topLevelSite = topLevelSite
        self.policy = policy
    }
}

/// A cookie in the jar.
public struct StoredCookie: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var value: String
    /// Lowercased, without a leading dot.
    public var domain: String
    /// Set without `Domain`: sent to this exact host only.
    public var hostOnly: Bool
    public var path: String
    /// `nil` for a session cookie.
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: SameSite
    /// The top-level site it is kept for (partitioned); `nil` when unpartitioned.
    public var partitionSite: CookieSite?
    public var created: Date

    public init(name: String, value: String, domain: String, hostOnly: Bool, path: String, expires: Date?, secure: Bool, httpOnly: Bool,
                sameSite: SameSite, partitionSite: CookieSite?, created: Date) {
        self.name = name
        self.value = value
        self.domain = domain
        self.hostOnly = hostOnly
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
        self.partitionSite = partitionSite
        self.created = created
    }

    /// rfc6265bis §5.7: name, domain, host-only flag and path (and the partition): a host-only and a Domain cookie of
    /// one name are two cookies.
    public var id: String { [partitionSite?.description ?? "", domain, hostOnly ? "host" : "domain", path, name].joined(separator: "|") }

    func isExpired(at now: Date) -> Bool { expires.map { $0 <= now } ?? false }
}

/// Why a `Set-Cookie` was not stored.
public enum CookieRejection: Sendable, Hashable {
    case malformed
    /// Name and value longer than 4096 bytes.
    case tooLarge
    case secureFromInsecureOrigin
    case sameSiteNoneWithoutSecure
    case partitionedWithoutSecure
    /// `__Secure-` / `__Host-` requirements not met.
    case prefix(String)
    case publicSuffix(String)
    case domainMismatch(String)
    case thirdPartyBlocked
    /// Lax or Strict (written, or Lax by default) from a cross-site subresource response.
    case sameSiteCrossSite(SameSite)
    /// A cookie from http may not replace a Secure cookie of the same name (rfc6265bis §5.7).
    case overlaysSecureCookie
}

/// What happened to one `Set-Cookie` line.
public enum CookieDecision: Sendable, Hashable {
    case stored(StoredCookie)
    case replaced(StoredCookie)
    /// Expired on arrival: the cookie of this name, domain, host-only flag and path is removed.
    case deleted(name: String)
    /// Expired on arrival, with no such cookie to remove.
    case expiredOnArrival(name: String)
    case rejected(name: String, reason: CookieRejection)
}

/// Why a matching cookie was not sent.
public enum CookieWithheld: Sendable, Hashable {
    case thirdPartyBlocked
    case sameSite(SameSite)
    case secureOnly
    /// Kept for another top-level site, or (partitioned policy) set first party.
    case partitionedElsewhere
}

public struct WithheldCookie: Sendable, Hashable {
    public var cookie: StoredCookie
    public var reason: CookieWithheld
}

/// The cookies for one request.
public struct CookieSelection: Sendable, Hashable {
    /// The `Cookie` header; `nil` when nothing is sent.
    public var header: String?
    public var sent: [StoredCookie]
    /// Cookies that match the URL but are not sent, with why.
    public var withheld: [WithheldCookie]
}

/// An in-memory cookie jar that decides as a browser would (RFC 6265 and rfc6265bis: `SameSite`, `Secure`, prefixes,
/// `Partitioned`) under a `CookiePolicy`. A value type: pure, deterministic, tested without a network.
public struct CookieJar: Sendable, Hashable {
    public static let maxCookies = 3_000
    /// Chrome's limit (rfc6265bis §5.7 eviction): one partner cannot crowd out the others.
    public static let maxCookiesPerDomain = 180
    public static let maxNameValueBytes = 4_096
    /// rfc6265bis §5.6.1: an expiry further than 400 days is cut to 400 days.
    public static let maxLifetime: TimeInterval = 400 * 86_400

    public private(set) var cookies: [StoredCookie] = []

    public init(cookies: [StoredCookie] = []) {
        self.cookies = cookies
    }

    public mutating func removeAll() { cookies.removeAll() }

    // MARK: Receiving

    /// Applies the `Set-Cookie` lines of a response from `url`, made from `context`'s page.
    public mutating func receive(_ setCookieLines: [String], from url: URL, context: CookieContext, now: Date) -> [CookieDecision] {
        cookies.removeAll { $0.isExpired(at: now) }
        return setCookieLines.map { receive($0, from: url, context: context, now: now) }
    }

    private mutating func receive(_ line: String, from url: URL, context: CookieContext, now: Date) -> CookieDecision {
        guard let parsed = ParsedSetCookie(line) else { return .rejected(name: "", reason: .malformed) }
        let name = parsed.name
        guard let host = url.host?.lowercased(), let requestSite = CookieSite(url: url) else { return .rejected(name: name, reason: .malformed) }
        let isSecureOrigin = url.scheme?.lowercased() == "https" || host == "localhost" || host == "127.0.0.1"
        if parsed.name.utf8.count + parsed.value.utf8.count > Self.maxNameValueBytes { return .rejected(name: name, reason: .tooLarge) }
        if parsed.secure, !isSecureOrigin { return .rejected(name: name, reason: .secureFromInsecureOrigin) }
        if parsed.partitioned, !parsed.secure { return .rejected(name: name, reason: .partitionedWithoutSecure) }
        if parsed.sameSite == .none, !parsed.secure { return .rejected(name: name, reason: .sameSiteNoneWithoutSecure) }
        if name.hasPrefix("__Secure-"), !parsed.secure { return .rejected(name: name, reason: .prefix("__Secure-")) }
        if name.hasPrefix("__Host-"), !parsed.secure || parsed.domain != nil || parsed.path != "/" { return .rejected(name: name, reason: .prefix("__Host-")) }

        var domain = host
        var hostOnly = true
        if let attribute = parsed.domain {
            if CookieSite.isPublicSuffix(attribute) {
                guard attribute == host else { return .rejected(name: name, reason: .publicSuffix(attribute)) }
            } else {
                guard Self.domainMatches(host: host, domain: attribute) else { return .rejected(name: name, reason: .domainMismatch(attribute)) }
                domain = attribute
                hostOnly = false
            }
        }

        let path = parsed.path ?? Self.defaultPath(of: url)
        if !parsed.secure, !isSecureOrigin, cookies.contains(where: { stored in
            stored.secure && stored.name == name && (Self.domainMatches(host: stored.domain, domain: domain) || Self.domainMatches(host: domain, domain: stored.domain))
                && Self.pathMatches(path, stored.path)
        }) {
            return .rejected(name: name, reason: .overlaysSecureCookie)
        }

        let crossSite = requestSite != context.topLevelSite
        var partitionSite: CookieSite?
        if crossSite {
            if context.policy == .blockThirdParty { return .rejected(name: name, reason: .thirdPartyBlocked) }
            // rfc6265bis §5.7: Lax / Strict from a cross-site response is ignored, partitioned or not; only Chrome reads a
            // missing SameSite as Lax.
            let effective = parsed.sameSite == .unspecified && context.policy == .allowThirdParty ? SameSite.lax : parsed.sameSite
            if effective == .lax || effective == .strict { return .rejected(name: name, reason: .sameSiteCrossSite(effective)) }
            if context.policy == .partitioned || parsed.partitioned { partitionSite = context.topLevelSite }
        } else if parsed.partitioned {
            partitionSite = context.topLevelSite
        }

        var cookie = StoredCookie(name: name, value: parsed.value, domain: domain, hostOnly: hostOnly, path: path,
                                  expires: parsed.expires(at: now), secure: parsed.secure, httpOnly: parsed.httpOnly, sameSite: parsed.sameSite,
                                  partitionSite: partitionSite, created: now)
        let existing = cookies.firstIndex { $0.id == cookie.id }
        if cookie.isExpired(at: now) {
            guard let existing else { return .expiredOnArrival(name: name) }
            cookies.remove(at: existing)
            return .deleted(name: name)
        }
        if let existing {
            cookie.created = cookies[existing].created
            cookies[existing] = cookie
            return .replaced(cookie)
        }
        cookies.append(cookie)
        // The domain's oldest go first, then the jar's.
        let sameDomain = cookies.indices.filter { cookies[$0].domain == domain }
        if sameDomain.count > Self.maxCookiesPerDomain { cookies.remove(at: sameDomain[0]) }
        if cookies.count > Self.maxCookies { cookies.removeFirst(cookies.count - Self.maxCookies) }
        return .stored(cookie)
    }

    // MARK: Sending

    /// The cookies a request to `url` from `context`'s page carries, and the matching ones it does not, with why.
    public func cookies(for url: URL, context: CookieContext, now: Date) -> CookieSelection {
        guard let host = url.host?.lowercased(), let requestSite = CookieSite(url: url) else {
            return CookieSelection(header: nil, sent: [], withheld: [])
        }
        let isSecure = url.scheme?.lowercased() == "https" || host == "localhost" || host == "127.0.0.1"
        let path = Self.rawPath(of: url)
        let crossSite = requestSite != context.topLevelSite
        var sent: [StoredCookie] = []
        var withheld: [WithheldCookie] = []
        for cookie in cookies where !cookie.isExpired(at: now) {
            let domainOK = cookie.hostOnly ? host == cookie.domain : Self.domainMatches(host: host, domain: cookie.domain)
            guard domainOK, Self.pathMatches(path, cookie.path) else { continue }
            if let reason = Self.reasonToWithhold(cookie, isSecure: isSecure, crossSite: crossSite, context: context) {
                withheld.append(WithheldCookie(cookie: cookie, reason: reason))
            } else {
                sent.append(cookie)
            }
        }
        // RFC 6265 §5.4: longer paths first, then earlier creation, then the order they were stored in (deterministic).
        sent = sent.enumerated().sorted { lhs, rhs in
            if lhs.element.path.count != rhs.element.path.count { return lhs.element.path.count > rhs.element.path.count }
            if lhs.element.created != rhs.element.created { return lhs.element.created < rhs.element.created }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let header = sent.isEmpty ? nil : sent.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return CookieSelection(header: header, sent: sent, withheld: withheld)
    }

    private static func reasonToWithhold(_ cookie: StoredCookie, isSecure: Bool, crossSite: Bool, context: CookieContext) -> CookieWithheld? {
        if cookie.secure, !isSecure { return .secureOnly }
        if let partition = cookie.partitionSite {
            if partition != context.topLevelSite { return .partitionedElsewhere }
        } else if crossSite {
            switch context.policy {
            case .blockThirdParty: return .thirdPartyBlocked
            case .partitioned: return .partitionedElsewhere
            case .allowThirdParty: break
            }
        }
        guard crossSite else { return nil }
        // Chrome reads a missing SameSite as Lax; WebKit and Firefox as None.
        let effective = cookie.sameSite == .unspecified && context.policy == .allowThirdParty ? SameSite.lax : cookie.sameSite
        return effective == .lax || effective == .strict ? .sameSite(effective) : nil
    }

    // MARK: Matching (RFC 6265 §5.1.3, §5.1.4)

    static func domainMatches(host: String, domain: String) -> Bool {
        host == domain || (host.hasSuffix("." + domain) && !CookieSite.isIPAddress(host))
    }

    static func pathMatches(_ requestPath: String, _ cookiePath: String) -> Bool {
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")
    }

    /// The request's uri-path as written (percent-encoded, trailing slash kept); "/" when empty.
    static func rawPath(of url: URL) -> String {
        let path = url.path(percentEncoded: true)
        return path.isEmpty ? "/" : path
    }

    /// The directory of the request path (RFC 6265 §5.1.4 default-path), from the raw path: `/sync/` gives `/sync`.
    static func defaultPath(of url: URL) -> String {
        let path = rawPath(of: url)
        guard path.hasPrefix("/"), let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}

/// One `Set-Cookie` line, read leniently (RFC 6265 §5.2).
struct ParsedSetCookie {
    var name: String
    var value: String
    var domain: String?
    var path: String?
    var maxAge: Int?
    var expiresDate: Date?
    var secure = false
    var httpOnly = false
    var sameSite = SameSite.unspecified
    var partitioned = false

    init?(_ line: String) {
        // rfc6265bis §5.6 step 1: a control character (but tab) ignores the whole line.
        guard !line.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 0x09) || $0.value == 0x7F }) else { return nil }
        let parts = line.split(separator: ";", omittingEmptySubsequences: false)
        guard let pair = parts.first, let equals = pair.firstIndex(of: "=") else { return nil }
        name = pair[..<equals].trimmingCharacters(in: .whitespaces)
        value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        for attribute in parts.dropFirst() {
            let split = attribute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = split[0].trimmingCharacters(in: .whitespaces).lowercased()
            let argument = split.count > 1 ? split[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "domain":
                let domain = argument.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !domain.isEmpty { self.domain = domain }
            case "path":
                path = argument.hasPrefix("/") ? argument : nil
            case "max-age":
                // RFC 6265 §5.2.2: an optional "-" and digits; anything else ("+10") is ignored. Overflow is "very long".
                let digits = argument.hasPrefix("-") ? argument.dropFirst() : Substring(argument)
                if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    maxAge = Int(argument) ?? (argument.hasPrefix("-") ? Int.min : Int.max)
                }
            case "expires":
                if let date = CookieDate.parse(argument) { expiresDate = date }
            case "secure":
                secure = true
            case "httponly":
                httpOnly = true
            case "samesite":
                sameSite = SameSite(rawValue: argument.lowercased()) ?? .unspecified
            case "partitioned":
                partitioned = true
            default:
                continue
            }
        }
    }

    /// `Max-Age` wins over `Expires`; a non-positive `Max-Age` expires it at once; at most 400 days ahead.
    func expires(at now: Date) -> Date? {
        let latest = now.addingTimeInterval(CookieJar.maxLifetime)
        if let maxAge { return maxAge <= 0 ? .distantPast : min(now.addingTimeInterval(TimeInterval(min(maxAge, Int(CookieJar.maxLifetime)))), latest) }
        return expiresDate.map { min($0, latest) }
    }
}

/// `Set-Cookie` lines out of one header value that joined several with commas (as `HTTPURLResponse.allHeaderFields`
/// does). A comma starts a new line only when what follows reads as `name=` and it is not inside an `Expires` date.
public enum SetCookieLines {
    public static func split(_ joined: String) -> [String] {
        var lines: [String] = []
        for piece in joined.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if let last = lines.last, !startsCookie(trimmed) || endsInsideExpires(last) {
                lines[lines.count - 1] = last + "," + piece
            } else if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func startsCookie(_ text: String) -> Bool {
        guard let equals = text.firstIndex(of: "=") else { return false }
        let name = text[..<equals]
        return !name.isEmpty && !name.contains(where: { $0 == ";" || $0 == " " || $0 == "\t" })
    }

    /// `…; Expires=Wed` — the comma after a weekday belongs to the date.
    private static func endsInsideExpires(_ text: String) -> Bool {
        guard let range = text.range(of: "expires=", options: [.caseInsensitive, .backwards]) else { return false }
        let tail = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return !tail.isEmpty && tail.count <= 9 && tail.allSatisfy(\.isLetter)
    }
}
