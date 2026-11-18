import Foundation

/// What `NetworkMonitor.prepareMedia` hands the player.
public struct PreparedMedia: Sendable {
    /// What the player opens; `nil` when the media could not be prepared (see `failure`).
    public var playableURL: URL?
    /// The media's entry in the monitor.
    public var entryID: UUID
    /// Why there is no `playableURL`.
    public var failure: NetworkMonitorError?

    public init(playableURL: URL? = nil, entryID: UUID, failure: NetworkMonitorError? = nil) {
        self.playableURL = playableURL
        self.entryID = entryID
        self.failure = failure
    }
}
