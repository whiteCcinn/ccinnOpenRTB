import Foundation

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
    public var trigger: String
    public var source: String

    public init(url: String, method: String = "POST", headers: [String: String] = [:], body: Data? = nil, trigger: String = "bid request",
                source: String = "client") {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.trigger = trigger
        self.source = source
    }

    /// The method on the wire.
    public var wireMethod: String {
        let verb = method.trimmingCharacters(in: .whitespaces).uppercased()
        return verb.isEmpty ? "POST" : verb
    }

    /// The body on the wire: none for GET and HEAD, which have no defined body semantics (RFC 9110 §9.3.1).
    public var wireBody: Data? {
        RedirectRule.carriesBody(wireMethod) ? body : nil
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

    public init(status: Int, headers: [String: String], body: Data, url: URL, entryID: UUID, responseEntryID: UUID, duration: TimeInterval,
                timings: HTTPTimings?) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
        self.entryID = entryID
        self.responseEntryID = responseEntryID
        self.duration = duration
        self.timings = timings
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
        return next
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
