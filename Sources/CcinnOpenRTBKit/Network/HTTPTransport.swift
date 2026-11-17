import Foundation

/// One HTTP request, exactly as the monitor wants it sent (one hop: redirects are never followed by a transport).
public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    /// Total time allowed for this hop, in seconds.
    public var timeout: TimeInterval
    /// The transport stops reading the body after this many bytes and reports `truncated`.
    public var maxBodyBytes: Int

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], timeout: TimeInterval = 15, maxBodyBytes: Int) {
        self.url = url
        self.method = method
        self.headers = headers
        self.timeout = timeout
        self.maxBodyBytes = max(0, maxBodyBytes)
    }
}

/// Phase durations of one exchange in milliseconds (HAR `timings`); `nil` = not applicable / unknown.
public struct HTTPTimings: Sendable, Hashable, Codable {
    public var blocked: Double?
    public var dns: Double?
    public var connect: Double?
    public var ssl: Double?
    public var send: Double
    public var wait: Double
    public var receive: Double

    public init(blocked: Double? = nil, dns: Double? = nil, connect: Double? = nil, ssl: Double? = nil, send: Double = 0, wait: Double = 0,
                receive: Double = 0) {
        self.blocked = blocked.map(Self.clamped)
        self.dns = dns.map(Self.clamped)
        self.connect = connect.map(Self.clamped)
        self.ssl = ssl.map(Self.clamped)
        self.send = Self.clamped(send)
        self.wait = Self.clamped(wait)
        self.receive = Self.clamped(receive)
    }

    /// The sum HAR calls `time` (`ssl` is part of `connect`, so it is not added again).
    public var total: Double {
        (blocked ?? 0) + (dns ?? 0) + (connect ?? 0) + send + wait + receive
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// What came back for one hop.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    /// At most `HTTPRequest.maxBodyBytes`.
    public var body: Data
    /// The body was longer than `maxBodyBytes`; reading stopped there.
    public var truncated: Bool
    public var timings: HTTPTimings?

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), truncated: Bool = false, timings: HTTPTimings? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.truncated = truncated
        self.timings = timings
    }

    public var mimeType: String? { HTTPHeaders.mimeType(fromContentType: HTTPHeaders.value("Content-Type", in: headers)) }
    public var location: String? { HTTPHeaders.value("Location", in: headers) }
}

/// Sends single HTTP requests. Implementations MUST NOT follow redirects: a 3xx comes back as the response, and the
/// monitor records and follows it itself (design D9). Injectable so tests never touch the network.
public protocol HTTPTransport: Sendable {
    func perform(_ request: HTTPRequest) async throws -> HTTPResponse
}
