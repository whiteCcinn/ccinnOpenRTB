import Foundation

/// What `NetworkMonitor.prepareMedia` hands the player.
public struct PreparedMedia: Sendable {
    /// What the player opens; `nil` when the media could not be prepared (see `failure`).
    public var playableURL: URL?
    /// The media's entry in the monitor.
    public var entryID: UUID
    /// Why there is no `playableURL`.
    public var failure: NetworkMonitorError?
    /// For remote media: the loader the player must attach to its `AVURLAsset` (`resourceLoader.attach(to:)`) and keep
    /// while it plays (AVFoundation holds it weakly). `playableURL` then uses a private scheme only this loader answers.
    /// `nil` for local files (`ccinn-sample:`, `data:`), which open as they are.
    public var resourceLoader: MediaResourceLoader?

    public init(playableURL: URL? = nil, entryID: UUID, failure: NetworkMonitorError? = nil, resourceLoader: MediaResourceLoader? = nil) {
        self.playableURL = playableURL
        self.entryID = entryID
        self.failure = failure
        self.resourceLoader = resourceLoader
    }
}
