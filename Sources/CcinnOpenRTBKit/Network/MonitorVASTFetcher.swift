import Foundation
import RTBKit

/// `VASTFetcher` that loads every wrapper / tag through the network monitor, so each fetch is a `content` entry linked to
/// the fetch that asked for it (`parentRequestID`), forming the wrapper chain in the Network window. `data:` and
/// `ccinn-sample://` URLs are served locally and still recorded.
public struct MonitorVASTFetcher: VASTFetcher {
    public let monitor: NetworkMonitor
    public let userAgent: String
    public let source: String
    public let trigger: String
    /// Parent for the first fetch (the resolver passes `nil` for it): e.g. the win-notice markup entry.
    public let rootParentID: UUID?

    public init(monitor: NetworkMonitor, userAgent: String, source: String = "VAST", trigger: String = "VAST wrapper",
                rootParentID: UUID? = nil) {
        self.monitor = monitor
        self.userAgent = userAgent
        self.source = source
        self.trigger = trigger
        self.rootParentID = rootParentID
    }

    public func fetchVAST(_ url: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?) {
        let monitor = monitor
        let (data, entryID) = try await monitor.fetchContent(url, category: .content, trigger: trigger, source: source,
                                                             parentID: parentRequestID ?? rootParentID, userAgent: userAgent)
        // The root entry's Content-Type describes the body only when it was not redirected.
        let root = await monitor.entry(id: entryID)
        let contentType = root.flatMap { (200..<300).contains($0.status ?? 0) ? $0.responseHeader("Content-Type") : nil }
        return (TextDecoding.string(from: data, charset: HTTPHeaders.charset(fromContentType: contentType)), entryID)
    }
}
