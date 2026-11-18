import AVFoundation
import Foundation
import os
import UniformTypeIdentifiers

/// The `AVAssetResourceLoaderDelegate` of one remote media URL: AVFoundation opens `url` (a private scheme, unique to this
/// loader) and asks this loader for every byte; the loader asks the monitor. Owned by the kit; the player attaches it to
/// its asset (`attach(to:)`) and keeps it while it plays (AVFoundation holds its delegate weakly).
///
/// - Content information and data requests map to HTTP `Range` requests of at most `chunkBytes` each, answered as they
///   arrive (`respond(with:)`), so playback starts before a large file is complete.
/// - A server that ignores `Range` (200) is read whole once (at most `NetworkMonitor.maxContentBytes`) and served from
///   memory. A playlist comes back rewritten (see `MediaRouter`) and is fetched again for every request: a live
///   playlist changes between AVFoundation's reloads.
/// - `didCancel` cancels that request's fetch (and its transport task); `invalidate` (the render ended, the log was
///   cleared) fails everything in flight and every later request.
public final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// Every loader's scheme starts with this, followed by a random token.
    public static let schemePrefix = "ccinn-media-"

    /// What the player opens.
    public let url: URL
    /// The media's real URL (for display).
    public let remoteURL: URL
    let queue: DispatchQueue
    private let chunkBytes: Int
    /// Fetches a byte range (`nil`: the whole resource) through the monitor, at most the given number of bytes.
    let fetch: @Sendable (ByteRange?, Int) async -> Result<MediaPart, NetworkMonitorError>
    // All mutable state lives behind this lock (hence `@unchecked Sendable`); AVAssetResourceLoadingRequest objects are
    // only touched on `queue`.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    private struct State {
        var resource: Resource?
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        var invalidation: NetworkMonitorError?
    }

    /// What the loader learned about the media from a response.
    enum Resource: Sendable {
        /// Served by the origin in byte ranges.
        case ranged(type: String, length: Int64)
        /// The whole body of a server without ranges, served from memory.
        case whole(type: String, data: Data)
        /// An HLS playlist, rewritten; never kept (a live playlist changes).
        case playlist(Data)

        var isKept: Bool {
            if case .playlist = self { false } else { true }
        }
    }

    init(remoteURL: URL, chunkBytes: Int, fetch: @escaping @Sendable (ByteRange?, Int) async -> Result<MediaPart, NetworkMonitorError>) {
        self.remoteURL = remoteURL
        self.chunkBytes = max(1, chunkBytes)
        self.fetch = fetch
        let token = MediaRouter.makeToken()
        let name = MediaRouter.safeName(remoteURL)
        url = URL(string: "\(Self.schemePrefix)\(token)://media/\(name)") ?? URL(fileURLWithPath: "/dev/null")
        queue = DispatchQueue(label: "io.github.whiteccinn.ccinnopenrtb.media-loader")
        super.init()
    }

    /// Makes this loader answer `asset`'s requests.
    public func attach(to asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    /// Fails every request in flight and every later one with `error`.
    func invalidate(_ error: NetworkMonitorError) {
        let tasks = state.withLockUnchecked { state -> [Task<Void, Never>] in
            state.invalidation = error
            defer { state.tasks.removeAll() }
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
    }

    deinit {
        let tasks = state.withLockUnchecked { Array($0.tasks.values) }
        for task in tasks { task.cancel() }
    }

    // MARK: AVAssetResourceLoaderDelegate (called on `queue`)

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.absoluteString == url.absoluteString else { return false }
        let request = LoadingRequest(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        state.withLockUnchecked { state in
            // Created under the lock: the task removes itself only after this insertion.
            state.tasks[key] = Task.detached { [weak self] in
                guard let self else { return }
                await self.serve(request, key: key)
            }
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        state.withLockUnchecked { $0.tasks.removeValue(forKey: key) }?.cancel()
    }

    // MARK: Serving

    private func serve(_ request: LoadingRequest, key: ObjectIdentifier) async {
        do {
            try await respond(to: request)
            await onQueue { request.finish(nil) }
        } catch {
            let invalidation = state.withLockUnchecked { $0.invalidation }
            let failure = invalidation ?? error as? NetworkMonitorError ?? NetworkMonitorError.monitorErrorForLoader(error)
            await onQueue { request.finish(failure) }
        }
        state.withLockUnchecked { _ = $0.tasks.removeValue(forKey: key) }
    }

    private func respond(to request: LoadingRequest) async throws {
        if let invalidation = state.withLockUnchecked({ $0.invalidation }) { throw invalidation }
        let wanted = await onQueue { request.wanted }
        var resource = state.withLockUnchecked { $0.resource }
        var first: MediaPart?
        if resource == nil {
            // First contact: exactly the range asked for (at most a chunk), read whole if the server ignores ranges.
            let upper = wanted.offset + min(wanted.length ?? Int64(chunkBytes), Int64(chunkBytes)) - 1
            let part = try await fetchPart(.from(wanted.offset, through: max(wanted.offset, upper)), maxBodyBytes: NetworkMonitor.maxContentBytes)
            let learned = try Self.resource(from: part, offset: wanted.offset, url: remoteURL)
            if learned.isKept { state.withLockUnchecked { $0.resource = $0.resource ?? learned } }
            resource = learned
            if case .ranged = learned { first = part }
        }
        guard let resource else { throw NetworkMonitorError.transport("The media could not be described") }
        if wanted.wantsInformation { await onQueue { request.describe(resource) } }
        guard wanted.wantsData else { return }

        switch resource {
        case let .whole(_, data), let .playlist(data):
            let start = Int(clamping: wanted.offset)
            let end = wanted.length.map { min(data.count, start + Int(clamping: $0)) } ?? data.count
            if start < end {
                let slice = data.subdata(in: start..<end)
                await onQueue { request.respond(slice) }
            }
        case let .ranged(_, length):
            let end = wanted.length.map { min(length, wanted.offset + $0) } ?? length
            var current = wanted.offset
            if let first, let range = first.contentRange, range.start == current {
                let usable = first.body.prefix(Int(clamping: max(0, end - current)))
                if !usable.isEmpty { await onQueue { request.respond(usable) } }
                current += Int64(usable.count)
            }
            while current < end {
                try Task.checkCancellation()
                let upper = min(end, current + Int64(chunkBytes)) - 1
                let part = try await fetchPart(.from(current, through: upper), maxBodyBytes: chunkBytes)
                guard part.status == 206, let range = part.contentRange, range.start == current, !part.body.isEmpty, !part.truncated else {
                    throw NetworkMonitorError.transport("The server did not answer the byte range \(current)-\(upper)")
                }
                let usable = part.body.prefix(Int(clamping: end - current))
                await onQueue { request.respond(usable) }
                current += Int64(usable.count)
            }
        }
    }

    private func fetchPart(_ range: ByteRange, maxBodyBytes: Int) async throws -> MediaPart {
        try Task.checkCancellation()
        if let invalidation = state.withLockUnchecked({ $0.invalidation }) { throw invalidation }
        let result = await fetch(range, maxBodyBytes)
        try Task.checkCancellation()
        return try result.get()
    }

    /// What the first response says about the media.
    static func resource(from part: MediaPart, offset: Int64, url: URL) throws -> Resource {
        if part.isPlaylist { return .playlist(part.body) }
        let type = uniformType(mimeType: part.mimeType, url: url)
        switch part.status {
        case 206:
            guard let range = part.contentRange, range.start == offset else {
                throw NetworkMonitorError.transport("The server answered a byte range without a valid Content-Range")
            }
            if let total = range.total { return .ranged(type: type, length: total) }
            throw NetworkMonitorError.transport("The server did not say how long the media is")
        case 200..<300:
            guard !part.truncated else { throw NetworkMonitorError.tooLarge(limit: NetworkMonitor.maxContentBytes) }
            return .whole(type: type, data: part.body)
        default:
            throw NetworkMonitorError.transport("The media request answered \(part.status)")
        }
    }

    /// The uniform type AVFoundation needs: from the MIME type, else the URL's extension, else MPEG-4.
    static func uniformType(mimeType: String?, url: URL) -> String {
        let generic: Set<String> = [UTType.data.identifier, "com.apple.macbinary-archive"]
        if let mimeType, let type = UTType(mimeType: mimeType), !type.isDynamic, !generic.contains(type.identifier) { return type.identifier }
        if let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic, !generic.contains(type.identifier) { return type.identifier }
        return UTType.mpeg4Movie.identifier
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// An `AVAssetResourceLoadingRequest`, carried between the loader's queue and its tasks; it is only touched on the
/// loader's queue.
private final class LoadingRequest: @unchecked Sendable {
    struct Wanted: Sendable {
        var wantsInformation: Bool
        var wantsData: Bool
        var offset: Int64
        /// `nil`: to the end.
        var length: Int64?
    }

    private let request: AVAssetResourceLoadingRequest

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    var wanted: Wanted {
        let data = request.dataRequest
        let offset = max(0, data?.requestedOffset ?? 0)
        let length: Int64? = if let data, !data.requestsAllDataToEndOfResource { Int64(max(0, data.requestedLength)) } else { nil }
        return Wanted(wantsInformation: request.contentInformationRequest != nil, wantsData: data != nil, offset: offset,
                      length: data == nil ? 2 : length)
    }

    func describe(_ resource: MediaResourceLoader.Resource) {
        guard let information = request.contentInformationRequest, !request.isCancelled, !request.isFinished else { return }
        switch resource {
        case let .ranged(type, length):
            information.contentType = type
            information.contentLength = length
        case let .whole(type, data):
            information.contentType = type
            information.contentLength = Int64(data.count)
        case let .playlist(data):
            information.contentType = UTType.m3uPlaylist.identifier
            information.contentLength = Int64(data.count)
        }
        information.isByteRangeAccessSupported = true
    }

    func respond(_ data: Data) {
        guard !request.isCancelled, !request.isFinished else { return }
        request.dataRequest?.respond(with: data)
    }

    func finish(_ error: NetworkMonitorError?) {
        guard !request.isCancelled, !request.isFinished else { return }
        if let error {
            request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable,
                                                userInfo: [NSLocalizedDescriptionKey: error.errorDescription ?? "The media could not be loaded"]))
        } else {
            request.finishLoading()
        }
    }
}

extension NetworkMonitorError {
    /// Any error of a loader task as a monitor error.
    static func monitorErrorForLoader(_ error: any Error) -> NetworkMonitorError {
        error is CancellationError ? .cancelled("the player cancelled the request") : .transport(error.localizedDescription)
    }
}
