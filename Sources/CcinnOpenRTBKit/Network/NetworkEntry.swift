import Foundation
import RTBKit

// Network contracts (design D9). Owner: kit-network. The app and the renderers only use this API.

/// Whether trackers are recorded only (simulated) or sent (real).
public enum TrackingMode: String, Sendable, Hashable, Codable {
    case simulated, real
}

/// What happened to a request.
public enum NetworkEntryState: Sendable, Hashable {
    /// A tracker in Simulated mode: recorded, never sent.
    case simulated
    /// Stopped before it was sent: a creative request by the Simulated-mode sandbox, remote content by Offline.
    case blocked
    case pending
    case completed(status: Int)
    case failed(String)
}

/// How a request was carried out (or why it was not): the Network window's "mode" column and HAR `_ccinn.delivery`.
public enum NetworkDelivery: String, Sendable, Hashable, Codable, CaseIterable {
    /// Recorded only: a Simulated-mode tracker, or a navigation kept inside the simulator.
    case simulated
    /// Sent over the network by the monitor.
    case network
    /// Stopped by the Simulated-mode sandbox (the HTML creative's own network).
    case blocked
    /// Served without the network: a `data:` URL or built-in sample media.
    case local
    /// Loaded by the renderer itself: allowed creative loads, injected script trackers. (Remote AVPlayer media is fetched
    /// by the monitor: `network`.)
    case renderer
    /// Opened in the default browser (Real-mode click-through with "Open click-throughs in browser" on).
    case browser
    /// Remote content recorded and not sent because the session is Offline.
    case offline

    /// Short label for badges.
    public var label: String {
        switch self {
        case .simulated: "Simulated"
        case .network: "Sent"
        case .blocked: "Blocked"
        case .local: "Local"
        case .renderer: "Renderer"
        case .browser: "Browser"
        case .offline: "Offline"
        }
    }
}

/// One row of the network monitor.
public struct NetworkEntry: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var parentID: UUID?
    /// Monotonic per session, in creation order.
    public var sequence: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var category: TrackerCategory
    public var trigger: String
    public var source: String
    public var template: String
    public var url: String
    public var method: String
    public var state: NetworkEntryState
    public var replacedMacros: [String]
    public var unknownMacros: [String]
    public var isScript: Bool
    /// The request headers: as sent over the wire when `requestHeadersAsSent`, otherwise the ones the request was (or
    /// would have been) sent with, before the HTTP stack added its own.
    public var requestHeaders: [String: String]
    /// `requestHeaders` are the headers that went over the wire (reported by the transport).
    public var requestHeadersAsSent: Bool
    public var responseHeaders: [String: String]
    public var responseBytes: Int?
    public var mimeType: String?
    /// For redirect hops: the `Location` that produced the child entry.
    public var redirectLocation: String?
    /// How the request was carried out.
    public var delivery: NetworkDelivery
    /// The session's tracking mode when the request was recorded.
    public var sessionMode: TrackingMode
    /// A short human note: "local sample", "injected by renderer", "body truncated at 1 MiB", …
    public var note: String?
    /// Transport timing breakdown, when the transport reported one (HAR `timings`).
    public var timings: HTTPTimings?
    /// The size of the request body, when the request has one (a composed POST); the body itself is kept by the monitor
    /// (`NetworkMonitor.requestBody(for:)`) up to its preview limit.
    public var requestBodyBytes: Int?
    /// A request made with a cookie session (a Sync run): the cookies sent and withheld, and what became of each
    /// `Set-Cookie` it received.
    public var cookies: NetworkCookies?

    public init(id: UUID = UUID(), parentID: UUID? = nil, sequence: Int, startedAt: Date = Date(), finishedAt: Date? = nil,
                category: TrackerCategory, trigger: String, source: String, template: String, url: String, method: String = "GET",
                state: NetworkEntryState, replacedMacros: [String] = [], unknownMacros: [String] = [], isScript: Bool = false,
                requestHeaders: [String: String] = [:], responseHeaders: [String: String] = [:], responseBytes: Int? = nil,
                mimeType: String? = nil, redirectLocation: String? = nil, delivery: NetworkDelivery = .simulated,
                sessionMode: TrackingMode = .simulated, note: String? = nil, timings: HTTPTimings? = nil, requestHeadersAsSent: Bool = false,
                requestBodyBytes: Int? = nil) {
        self.id = id
        self.parentID = parentID
        self.sequence = sequence
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.category = category
        self.trigger = trigger
        self.source = source
        self.template = template
        self.url = url
        self.method = method
        self.state = state
        self.replacedMacros = replacedMacros
        self.unknownMacros = unknownMacros
        self.isScript = isScript
        self.requestHeaders = requestHeaders
        self.requestHeadersAsSent = requestHeadersAsSent
        self.responseHeaders = responseHeaders
        self.responseBytes = responseBytes
        self.mimeType = mimeType
        self.redirectLocation = redirectLocation
        self.delivery = delivery
        self.sessionMode = sessionMode
        self.note = note
        self.timings = timings
        self.requestBodyBytes = requestBodyBytes
    }

    /// Seconds from start to finish; `nil` while pending or for entries that never ran.
    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    /// The HTTP status, when a response arrived.
    public var status: Int? {
        if case let .completed(status) = state, status > 0 { return status }
        return nil
    }

    /// Whether the entry is a redirect hop of another entry.
    public var isRedirectHop: Bool { redirectLocation != nil }

    /// Case-insensitive response header lookup.
    public func responseHeader(_ name: String) -> String? {
        HTTPHeaders.value(name, in: responseHeaders)
    }
}

/// The cookies of one hop made with a cookie session.
public struct NetworkCookies: Sendable, Hashable {
    public var sent: [StoredCookie]
    public var withheld: [WithheldCookie]
    /// One per `Set-Cookie` line received.
    public var decisions: [CookieDecision]

    public init(sent: [StoredCookie] = [], withheld: [WithheldCookie] = [], decisions: [CookieDecision] = []) {
        self.sent = sent
        self.withheld = withheld
        self.decisions = decisions
    }
}

/// Header helpers shared by the transport, the monitor and the exporters.
public enum HTTPHeaders {
    public static func value(_ name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }

    /// `base` with `overrides` applied: an override replaces a base header of the same name in any case, so the result
    /// never holds two spellings of one header (URLSession would pick one of them at random).
    public static func merged(_ base: [String: String], overriddenBy overrides: [String: String]) -> [String: String] {
        guard !overrides.isEmpty else { return base }
        var merged = removing(overrides.keys, from: base)
        for (name, value) in overrides { merged[name] = value }
        return merged
    }

    /// `headers` without the ones named in `names`, compared case-insensitively.
    public static func removing(_ names: some Sequence<String>, from headers: [String: String]) -> [String: String] {
        let lowered = Set(names.map { $0.lowercased() })
        guard !lowered.isEmpty else { return headers }
        return headers.filter { !lowered.contains($0.key.lowercased()) }
    }

    /// Headers in a stable order (by name) for display and export.
    public static func sorted(_ headers: [String: String]) -> [(name: String, value: String)] {
        headers.map { (name: $0.key, value: $0.value) }
            .sorted { $0.name.lowercased() == $1.name.lowercased() ? $0.name < $1.name : $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The standard reason phrase ("Not Found"); empty for unknown codes.
    public static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 410: "Gone"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }

    /// The MIME type of a `Content-Type` value, without parameters.
    public static func mimeType(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        let type = contentType.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return type.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The `charset` parameter of a `Content-Type` value.
    public static func charset(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "charset" {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            }
        }
        return nil
    }
}
