import Foundation
import Observation
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
    /// A creative request stopped by the simulated-mode sandbox.
    case blocked
    case pending
    case completed(status: Int)
    case failed(String)
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
    public var requestHeaders: [String: String]
    public var responseHeaders: [String: String]
    public var responseBytes: Int?
    public var mimeType: String?
    /// For redirect hops: the `Location` that produced the child entry.
    public var redirectLocation: String?

    public init(id: UUID = UUID(), parentID: UUID? = nil, sequence: Int, startedAt: Date = Date(), finishedAt: Date? = nil,
                category: TrackerCategory, trigger: String, source: String, template: String, url: String, method: String = "GET",
                state: NetworkEntryState, replacedMacros: [String] = [], unknownMacros: [String] = [], isScript: Bool = false,
                requestHeaders: [String: String] = [:], responseHeaders: [String: String] = [:], responseBytes: Int? = nil,
                mimeType: String? = nil, redirectLocation: String? = nil) {
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
        self.responseHeaders = responseHeaders
        self.responseBytes = responseBytes
        self.mimeType = mimeType
        self.redirectLocation = redirectLocation
    }
}

/// The session's network: dispatches trackers by mode, fetches content, records creative requests, and keeps the
/// ordered, related entries the Network window shows.
@MainActor
@Observable
public final class NetworkMonitor {
    public private(set) var entries: [NetworkEntry] = []
    public var mode: TrackingMode = .simulated
    /// Simulated mode: let the HTML creative load from the network for this session.
    public var allowCreativeNetwork = false

    public init() {}

    /// Records a tracker; sends it in Real mode (with `userAgent`). Returns the entry id.
    @discardableResult
    public func dispatch(_ request: TrackerRequest, userAgent: String) -> UUID {
        append(NetworkEntry(id: request.id, parentID: request.parentID, sequence: entries.count + 1, category: request.category,
                            trigger: request.trigger, source: request.source, template: request.template, url: request.url,
                            state: .simulated, replacedMacros: request.replacedMacros, unknownMacros: request.unknownMacros,
                            isScript: request.isScript))
        return request.id
    }

    /// Fetches content needed to render (VAST wrappers, media, images, win-notice markup) in both modes.
    public func fetchContent(_ url: String, category: TrackerCategory = .content, trigger: String, source: String, parentID: UUID?,
                             userAgent: String) async throws -> (data: Data, entryID: UUID) {
        throw URLError(.unsupportedURL)
    }

    /// Records a request the HTML creative made (or tried to make).
    @discardableResult
    public func recordCreativeRequest(url: String, kind: String, blocked: Bool, parentID: UUID?) -> UUID {
        let id = UUID()
        append(NetworkEntry(id: id, parentID: parentID, sequence: entries.count + 1, category: .creative, trigger: kind, source: "creative",
                            template: url, url: url, state: blocked ? .blocked : .pending))
        return id
    }

    /// Records a click-through navigation (never followed inside the simulator).
    @discardableResult
    public func recordNavigation(url: String, trigger: String, source: String, parentID: UUID?) -> UUID {
        let id = UUID()
        append(NetworkEntry(id: id, parentID: parentID, sequence: entries.count + 1, category: .navigation, trigger: trigger, source: source,
                            template: url, url: url, state: .simulated))
        return id
    }

    public func clear() {
        entries.removeAll()
    }

    /// HAR 1.2 export of the current entries.
    public func harData() -> Data {
        Data("{}".utf8)
    }

    private func append(_ entry: NetworkEntry) {
        entries.append(entry)
    }
}
