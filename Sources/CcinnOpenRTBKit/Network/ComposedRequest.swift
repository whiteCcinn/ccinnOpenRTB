import Foundation
import Observation
import RTBKit

/// What a composed request is for: its Network category and its default trigger and source.
public enum ComposedPurpose: String, Sendable, Hashable, Codable {
    /// A bid request from the Client tab, or from a Prebid.js adapter on the Prebid page.
    case bidRequest
    /// A cookie-sync run from the Sync tab.
    case userSync

    public var category: TrackerCategory {
        switch self {
        case .bidRequest: .bidRequest
        case .userSync: .userSync
        }
    }

    var defaultTrigger: String { self == .bidRequest ? "bid request" : "user sync" }
    var defaultSource: String { self == .bidRequest ? "client" : "sync" }
}

/// The cookie jar of a Sync run, as a browser on `context`'s page would use it: read before every hop, filled from every
/// response. In memory only; never the Mac's cookies. Shared by the runs of one Sync tab, so a second run sees what the
/// first one stored.
@MainActor
@Observable
public final class CookieSession: Hashable {
    public private(set) var jar: CookieJar
    public var context: CookieContext

    public init(jar: CookieJar = CookieJar(), context: CookieContext) {
        self.jar = jar
        self.context = context
    }

    public func clear() { jar.removeAll() }

    func selection(for url: URL, now: Date) -> CookieSelection {
        jar.cookies(for: url, context: context, now: now)
    }

    func receive(_ lines: [String], from url: URL, now: Date) -> [CookieDecision] {
        jar.receive(lines, from: url, context: context, now: now)
    }

    public nonisolated static func == (lhs: CookieSession, rhs: CookieSession) -> Bool { lhs === rhs }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Which redirects a load follows by itself (`RedirectRule` decides how each hop is sent).
public enum RedirectPolicy: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Every redirect, across origins too (at most `NetworkMonitor.maxRedirects`, loops refused), as `curl -L` does:
    /// `Authorization`, `Proxy-Authorization` and `Cookie` stay behind on a hop to another origin.
    case all
    /// Within the request's origin (scheme, host and port); a redirect anywhere else is the answer.
    case sameOrigin
    /// None: the first 3xx is the answer.
    case none

    public var id: String { rawValue }
}

/// A request the user composed and sends on purpose (the Client tab): typically an OpenRTB bid request POSTed to an
/// endpoint. `NetworkMonitor.send(_:userAgent:)` records and sends it as a `.bidRequest` entry.
public struct ComposedRequest: Sendable, Hashable {
    public var url: String
    /// Sent uppercased; blank means POST.
    public var method: String
    /// The user's headers. They replace the monitor's own (`Accept`, `User-Agent`, `Accept-Language`) whatever their case.
    public var headers: [String: String]
    /// Sent for every method but GET and HEAD.
    public var body: Data?
    /// Which redirects are followed; by default only those within the origin, so nothing typed goes elsewhere unasked.
    public var redirects: RedirectPolicy
    public var purpose: ComposedPurpose
    /// A Sync run's jar: its cookies replace any `Cookie` header, and every hop's `Set-Cookie`s go into it.
    public var cookies: CookieSession?
    public var trigger: String
    public var source: String

    public init(url: String, method: String = "POST", headers: [String: String] = [:], body: Data? = nil, redirects: RedirectPolicy = .sameOrigin,
                purpose: ComposedPurpose = .bidRequest, cookies: CookieSession? = nil, trigger: String? = nil, source: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.redirects = redirects
        self.purpose = purpose
        self.cookies = cookies
        self.trigger = trigger ?? purpose.defaultTrigger
        self.source = source ?? purpose.defaultSource
    }

    /// The method on the wire.
    public var wireMethod: String {
        let verb = method.trimmingCharacters(in: .whitespaces).uppercased()
        return verb.isEmpty ? "POST" : verb
    }

    /// Why this request cannot go on the wire, or `nil`. HTTP/1.1 writes the method and header names verbatim: one that is
    /// not a token (a space, CR or LF) would split into another request, a value with CR, LF or NUL into another header.
    /// `CONNECT`, `TRACE` and `TRACK` are refused, as browsers refuse them (RFC 9110 §9.3.6, §9.3.8).
    public var syntaxProblem: String? {
        let verb = wireMethod
        guard HTTPSyntax.isToken(verb) else { return "The method “\(verb.prefix(40))” is not an HTTP token." }
        guard !HTTPSyntax.forbiddenMethods.contains(verb) else { return "The method \(verb) is not allowed." }
        for (name, value) in headers {
            guard HTTPSyntax.isToken(name) else { return "The header name “\(name.prefix(40))” is not an HTTP token." }
            guard HTTPSyntax.isFieldValue(value) else { return "The value of \(name.prefix(40)) has a line break or a NUL." }
        }
        return nil
    }

    /// The body on the wire: none for GET and HEAD, which have no defined body semantics (RFC 9110 §9.3.1).
    public var wireBody: Data? {
        RedirectRule.carriesBody(wireMethod) ? body : nil
    }
}

/// Why a composed request's chain ended on a redirect.
public enum RedirectStop: Sendable, Hashable, CustomStringConvertible {
    /// The request's setting did not follow it: `.none`, or `.sameOrigin` with a target on another origin. Following all
    /// redirects would continue the chain.
    case notFollowed(RedirectPolicy, location: String)
    /// The next request was already made (same method and URL).
    case loop(String)
    case tooManyRedirects(limit: Int)
    case invalidLocation(String)
    /// The target is not http(s) (an app link, `data:` …).
    case unsupportedScheme(String)

    /// Whether following every redirect would take the chain further.
    public var canBeFollowed: Bool {
        if case .notFollowed = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case let .notFollowed(.sameOrigin, location): "Redirect to another origin not followed: \(location.prefix(300))"
        case let .notFollowed(_, location): "Redirect not followed (Redirects: don’t follow): \(location.prefix(300))"
        case let .loop(url): "Redirect loop: \(url.prefix(300)) was already requested"
        case let .tooManyRedirects(limit): "Too many redirects (limit \(limit))"
        case let .invalidLocation(location): "Invalid Location: \(location.prefix(300))"
        case let .unsupportedScheme(url): "Redirect not followed: \(url.prefix(300)) is not an http(s) URL"
        }
    }
}

/// One request of a composed request's chain: the request itself, then each redirect hop, as recorded.
public struct ComposedHop: Sendable, Hashable {
    public var entryID: UUID
    public var method: String
    public var url: String
    /// The status it was answered with; `nil` when it was not sent or failed.
    public var status: Int?
    /// The `Location` it was redirected to.
    public var location: String?
    /// The body it carried; `nil` for none.
    public var bodyBytes: Int?
    public var duration: TimeInterval?
    /// What changed on the way (method, body, headers left behind, a downgrade to http) or why it was not sent.
    public var note: String?
    public var wasSent: Bool
    /// Why it failed or was not sent.
    public var failure: String?
    /// The cookies of a hop made with a cookie session.
    public var cookies: NetworkCookies?

    public init(entryID: UUID, method: String, url: String, status: Int?, location: String?, bodyBytes: Int?, duration: TimeInterval?,
                note: String?, wasSent: Bool, failure: String?, cookies: NetworkCookies? = nil) {
        self.entryID = entryID
        self.method = method
        self.url = url
        self.status = status
        self.location = location
        self.bodyBytes = bodyBytes
        self.duration = duration
        self.note = note
        self.wasSent = wasSent
        self.failure = failure
        self.cookies = cookies
    }
}

/// What came back for a composed request: the final response, whatever its status.
public struct ComposedResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// The URL that answered (after redirects).
    public var url: URL
    /// The request's root entry.
    public var entryID: UUID
    /// The entry of the hop that answered (`entryID` unless redirected).
    public var responseEntryID: UUID
    /// From the request's start to the final response, in seconds.
    public var duration: TimeInterval
    /// The answering hop's phases, when the transport reported them.
    public var timings: HTTPTimings?
    /// Every request of the chain in order: the request itself, each redirect hop, and a hop that was not sent.
    public var chain: [ComposedHop]
    /// Why the chain ended on a redirect (not followed by the setting, a loop, too many hops); `nil` when it was answered.
    public var redirectStop: RedirectStop?

    public init(status: Int, headers: [String: String], body: Data, url: URL, entryID: UUID, responseEntryID: UUID, duration: TimeInterval,
                timings: HTTPTimings?, chain: [ComposedHop] = [], redirectStop: RedirectStop? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
        self.entryID = entryID
        self.responseEntryID = responseEntryID
        self.duration = duration
        self.timings = timings
        self.chain = chain
        self.redirectStop = redirectStop
    }
}

/// How a request changes when it is redirected (RFC 9110 §15.4; Fetch §4.4 "HTTP-redirect fetch"). Pure.
enum RedirectRule {
    /// Headers that describe the body: dropped with it.
    static let bodyHeaders = ["Content-Type", "Content-Length", "Content-Encoding", "Content-Language", "Content-Location"]
    /// Credentials the user may have set by hand: never carried to another origin.
    static let credentialHeaders = ["Authorization", "Proxy-Authorization", "Cookie"]

    struct Hop: Sendable, Hashable {
        var method: String
        var body: Data?
        /// The extra headers (the user's, or `Range`), on top of the monitor's own.
        var headers: [String: String]
    }

    static func carriesBody(_ method: String) -> Bool {
        let verb = method.uppercased()
        return verb != "GET" && verb != "HEAD"
    }

    /// The next hop of `hop`, redirected with `status` from `origin` to `target`:
    /// - 303 (unless GET or HEAD), and 301 / 302 after a POST, continue as a GET without the body or its headers;
    /// - 307 and 308 (and 301 / 302 of any other method) repeat the method and the body;
    /// - a hop to another origin (scheme, host, port) loses the credential headers.
    static func next(after hop: Hop, status: Int, from origin: URL, to target: URL) -> Hop {
        var next = hop
        let verb = hop.method.uppercased()
        let becomesGET = (status == 303 && verb != "GET" && verb != "HEAD") || ((status == 301 || status == 302) && verb == "POST")
        if becomesGET {
            next.method = "GET"
            next.body = nil
            next.headers = HTTPHeaders.removing(bodyHeaders, from: next.headers)
        }
        if !sameOrigin(origin, target) {
            next.headers = HTTPHeaders.removing(credentialHeaders, from: next.headers)
        }
        // strict-origin-when-cross-origin: no Referer on a downgrade to http.
        if origin.scheme?.lowercased() == "https", target.scheme?.lowercased() == "http" {
            next.headers = HTTPHeaders.removing(["Referer"], from: next.headers)
        }
        return next
    }

    /// What changed from `hop` to `next` on a redirect with `status` from `origin` to `target`, for the hop's record:
    /// a method change and the body left behind, the body sent again, credentials left at the origin, a downgrade to http.
    static func changes(from hop: Hop, to next: Hop, status: Int, from origin: URL, to target: URL) -> [String] {
        var notes: [String] = []
        if next.method != hop.method {
            notes.append("\(hop.method) → \(next.method) (\(status))" + (hop.body == nil ? "" : ": the body was not sent again"))
        } else if next.body != nil {
            notes.append("\(next.method) and its body sent again (\(status))")
        }
        let kept = Set(next.headers.keys.map { $0.lowercased() })
        let left = credentialHeaders.filter { name in
            hop.headers.keys.contains { $0.lowercased() == name.lowercased() } && !kept.contains(name.lowercased())
        }
        if !left.isEmpty { notes.append("Not carried to another origin: " + left.joined(separator: ", ")) }
        if origin.scheme?.lowercased() == "https", target.scheme?.lowercased() == "http" {
            notes.append("Downgraded to http: sent unencrypted")
        }
        return notes
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftScheme = lhs.scheme?.lowercased()
        let rightScheme = rhs.scheme?.lowercased()
        return leftScheme == rightScheme
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs, scheme: leftScheme) == effectivePort(rhs, scheme: rightScheme)
    }

    private static func effectivePort(_ url: URL, scheme: String?) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// HTTP syntax the gate checks before anything is sent.
public enum HTTPSyntax {
    /// Methods no request may use (browsers refuse them too).
    public static let forbiddenMethods: Set<String> = ["CONNECT", "TRACE", "TRACK"]

    /// RFC 9110 §5.6.2 `token`: one or more of ALPHA, DIGIT and ``!#$%&'*+-.^_`|~``.
    public static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": true
            case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~": true
            default: false
            }
        }
    }

    /// A field value without CR, LF or NUL (checked on Unicode scalars: `"\r\n"` is one `Character`).
    public static func isFieldValue(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\u{0}" }
    }
}
