import Foundation

/// Why a fetch through the monitor produced no data.
public enum NetworkMonitorError: Error, Sendable, Equatable, LocalizedError {
    /// A tracker-category fetch in Simulated mode: recorded as `entryID`, nothing sent.
    case notSentInSimulatedMode(entryID: UUID)
    /// Navigation and creative requests are recorded, never fetched by the monitor.
    case notFetchable(entryID: UUID)
    /// Remote content while the session is Offline: recorded as `entryID`, nothing sent.
    case offline(entryID: UUID)
    /// Stopped while in flight (a switch to Simulated mode for trackers, Offline for everything); the reason says why.
    case cancelled(String)
    case invalidURL(String)
    case unsupportedScheme(String)
    case httpStatus(Int, entryID: UUID)
    case tooLarge(limit: Int)
    case timedOut(seconds: Double)
    case tooManyRedirects(limit: Int)
    case redirectLoop(String)
    case redirectNotFollowed(String)
    case sampleUnavailable(String)
    case transport(String)
    /// The log was cleared while the request was in flight.
    case cleared

    public var errorDescription: String? {
        switch self {
        case .notSentInSimulatedMode: "Not sent: trackers are only recorded in Simulated mode."
        case .notFetchable: "Navigation and creative requests are not fetched by the monitor."
        case .offline: "Offline: content requests are recorded, not sent. Only data: URLs and built-in samples load."
        case let .cancelled(reason): "Cancelled: \(reason)"
        case let .invalidURL(url): "Invalid URL: \(url.prefix(200))"
        case let .unsupportedScheme(scheme): "Unsupported URL scheme “\(scheme.prefix(40))”."
        case let .httpStatus(status, _): "The server answered with status \(status)."
        case let .tooLarge(limit): "The response is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary))."
        case let .timedOut(seconds): "Timed out after \(seconds.formatted()) s."
        case let .tooManyRedirects(limit): "Too many redirects (limit \(limit))."
        case let .redirectLoop(url): "Redirect loop: \(url.prefix(200)) was already requested."
        case let .redirectNotFollowed(target): "Redirect not followed: \(target.prefix(200))"
        case let .sampleUnavailable(reason): "Sample media unavailable: \(reason)"
        case let .transport(message): message
        case .cleared: "The network log was cleared."
        }
    }
}

/// The monitor's time source; injectable for deterministic tests.
public protocol NetworkClock: Sendable {
    func now() -> Date
}

public struct SystemNetworkClock: NetworkClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Bodies kept for the details preview, curl and HAR export (one store for responses, one for request bodies): at most
/// `maxBodyBytes` per entry and `totalBudget` overall, oldest dropped first.
struct BodyStore: Sendable {
    let maxBodyBytes: Int
    let totalBudget: Int
    private var bodies: [UUID: Data] = [:]
    private var order: [UUID] = []
    private var head = 0
    private(set) var totalBytes = 0

    init(maxBodyBytes: Int = 512 * 1024, totalBudget: Int = 32 << 20) {
        self.maxBodyBytes = maxBodyBytes
        self.totalBudget = max(maxBodyBytes, totalBudget)
    }

    func body(for id: UUID) -> Data? { bodies[id] }

    func bodies(for ids: some Sequence<UUID>) -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        for id in ids { if let body = bodies[id] { result[id] = body } }
        return result
    }

    mutating func store(_ data: Data, for id: UUID) {
        guard data.count <= maxBodyBytes else { return }
        if let previous = bodies[id] { totalBytes -= previous.count } else { order.append(id) }
        bodies[id] = data
        totalBytes += data.count
        while totalBytes > totalBudget, head < order.count {
            let oldest = order[head]
            head += 1
            if let removed = bodies.removeValue(forKey: oldest) { totalBytes -= removed.count }
        }
        if head > 1024, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }

    mutating func removeAll() {
        bodies.removeAll()
        order.removeAll()
        head = 0
        totalBytes = 0
    }
}
