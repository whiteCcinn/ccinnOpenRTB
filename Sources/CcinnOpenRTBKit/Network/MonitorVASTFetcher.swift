import Foundation
import RTBKit

/// `VASTFetcher` that loads every wrapper / tag through the network monitor, so each fetch is a `content` entry linked to
/// the fetch that asked for it (`parentRequestID`), forming the wrapper chain in the Network window. `data:` and
/// `ccinn-sample://` URLs are served locally and still recorded.
///
/// Labels: the first hop of a `.url` source is the VAST tag (`tagTrigger`); every hop a Wrapper's `VASTAdTagURI`
/// produced is a wrapper (`trigger`, `wrapperTrigger` by default). The resolver asks for both with the same parent (the
/// tag of a `.url` source, and the first wrapper of inline `.xml`), so the fetcher tells them apart by the source it
/// resolves: pass it as `resolving`. Without it, every hop keeps the wrapper label.
public struct MonitorVASTFetcher: VASTFetcher {
    public static let tagTrigger = "VAST tag"
    public static let wrapperTrigger = "VAST wrapper"

    public let monitor: NetworkMonitor
    public let userAgent: String
    public let source: String
    /// The label of wrapper hops.
    public let trigger: String
    /// The label of the top-level tag fetch.
    public let tagTrigger: String
    /// Parent for the first fetch (the resolver passes `nil` for it): e.g. the win-notice markup entry.
    public let rootParentID: UUID?
    /// The VAST source is a tag URL: its first hop (asked for with the resolution's own parent) is the tag.
    public let resolvesTagURL: Bool

    public init(monitor: NetworkMonitor, userAgent: String, source: String = "VAST", trigger: String = MonitorVASTFetcher.wrapperTrigger,
                tagTrigger: String = MonitorVASTFetcher.tagTrigger, rootParentID: UUID? = nil, resolving vastSource: VASTSource? = nil) {
        self.monitor = monitor
        self.userAgent = userAgent
        self.source = source
        self.trigger = trigger
        self.tagTrigger = tagTrigger
        self.rootParentID = rootParentID
        resolvesTagURL = if case .url = vastSource { true } else { false }
    }

    /// The label of a fetch. A wrapper hop always names its parent hop (an entry this fetcher created), never the
    /// resolution's own parent, so in a tag-URL resolution the fetch with that parent is the tag.
    public func label(parentRequestID: UUID?) -> String {
        resolvesTagURL && (parentRequestID == nil || parentRequestID == rootParentID) ? tagTrigger : trigger
    }

    public func fetchVAST(_ url: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?) {
        try await fetchVAST(url, template: url, parentRequestID: parentRequestID)
    }

    /// The resolver's call: `url` is sent (the player's VAST macros expanded), `template` is the URI as written; the entry
    /// shows both.
    public func fetchVAST(_ url: String, template: String, parentRequestID: UUID?) async throws -> (body: String, requestID: UUID?) {
        let monitor = monitor
        let (data, entryID) = try await monitor.fetchContent(url, category: .content, trigger: label(parentRequestID: parentRequestID),
                                                             source: source, parentID: parentRequestID ?? rootParentID, userAgent: userAgent,
                                                             template: template)
        // The root entry's Content-Type describes the body only when it was not redirected.
        let root = await monitor.entry(id: entryID)
        let contentType = root.flatMap { (200..<300).contains($0.status ?? 0) ? $0.responseHeader("Content-Type") : nil }
        return (TextDecoding.string(from: data, charset: HTTPHeaders.charset(fromContentType: contentType)), entryID)
    }
}
