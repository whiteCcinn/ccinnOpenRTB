import Foundation

/// The media entry a player's requests hang under, and the headers they are sent with.
struct MediaContext: Sendable, Hashable {
    var entryID: UUID
    var source: String
    var trigger: String
    var userAgent: String
}

/// One request a player's media needs, as the monitor sends it.
struct MediaPartRequest: Sendable {
    var url: URL
    var range: ByteRange?
    var parentID: UUID?
    var trigger: String
    var source: String
    var userAgent: String
    var maxBodyBytes: Int
}

/// What a media request produced, ready for the player: a playlist is already rewritten.
struct MediaPart: Sendable {
    var status: Int
    var mimeType: String?
    var body: Data
    var contentRange: ContentRange?
    var isPlaylist: Bool
    var truncated: Bool
}

/// Routes a player's remote media through the monitor (one router per monitor).
///
/// AVFoundation offers two ways in, and the router uses both, so the player never talks to an origin:
/// - The media URL itself becomes a private-scheme URL answered by a `MediaResourceLoader` (content information and
///   byte ranges, mapped to HTTP `Range`). A playlist it loads is rewritten.
/// - Every URI inside a playlist (variant playlists, segments, keys, init sections) is rewritten to the
///   `MediaLoopbackProxy` on 127.0.0.1, because AVFoundation refuses HLS media segments as data from a resource loader
///   (CoreMedia error -12881, "custom url not redirect") and a redirect would let it fetch the origin itself. Playlists
///   the proxy serves are rewritten in turn.
///
/// Both ask the monitor (`fetchMediaPart`), so every request passes the dispatch policy (Offline included), goes out
/// with the device's headers through the ephemeral transport, and is recorded under the request that delivered the
/// document naming it (the media entry, or the playlist). `invalidate()` (the render ended, or the log was cleared)
/// stops every loader and route made so far.
@MainActor
final class MediaRouter {
    nonisolated static let mediaNote = "AVPlayer media: every request the player needs is sent by the monitor and recorded below"
    nonisolated static let endedReason = "the render ended"
    /// At most this many playlist URIs are routed per render; more get a dead route.
    static let maxResources = 50_000

    struct Resource {
        var url: URL
        var kind: HLSPlaylist.Kind
        /// The request that delivered the playlist naming it.
        var parentID: UUID
        var media: MediaContext
    }

    private weak var monitor: NetworkMonitor?
    private var generation = 0
    private var loaders: [WeakLoader] = []
    private var proxy: MediaLoopbackProxy?
    private var proxyStart: Task<UInt16, any Error>?
    /// Changes with every invalidation, so earlier proxy URLs are unknown.
    private var routeToken = MediaRouter.makeToken()
    private var resources: [String: Resource] = [:]
    private var resourceIDs: [URL: String] = [:]
    private var nextResourceID = 0

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
    }

    /// The loader for one remote media URL.
    func makeLoader(for url: URL, media: MediaContext) -> MediaResourceLoader {
        loaders.removeAll { $0.loader == nil }
        let generation = generation
        let chunkBytes = monitor?.mediaChunkBytes ?? NetworkMonitor.defaultMediaChunkBytes
        let loader = MediaResourceLoader(remoteURL: url, chunkBytes: chunkBytes) { [weak self] range, maxBodyBytes in
            guard let self else { return .failure(.cancelled(Self.endedReason)) }
            return await self.fetchForLoader(url: url, range: range, maxBodyBytes: maxBodyBytes, media: media, generation: generation)
        }
        loaders.append(WeakLoader(loader: loader))
        return loader
    }

    /// Stops every loader and proxy route made so far; their requests in flight are cancelled.
    func invalidate() {
        generation &+= 1
        let error = NetworkMonitorError.cancelled(Self.endedReason)
        for entry in loaders { entry.loader?.invalidate(error) }
        loaders.removeAll()
        routeToken = Self.makeToken()
        resources.removeAll()
        resourceIDs.removeAll()
        proxy?.cancelAll()
    }

    // MARK: Fetching

    private func fetchForLoader(url: URL, range: ByteRange?, maxBodyBytes: Int, media: MediaContext,
                                generation: Int) async -> Result<MediaPart, NetworkMonitorError> {
        let label = range.map { " › " + Self.label(of: $0) } ?? ""
        let request = MediaPartRequest(url: url, range: range, parentID: media.entryID, trigger: media.trigger, source: media.source + label,
                                       userAgent: media.userAgent, maxBodyBytes: maxBodyBytes)
        return await fetch(request, media: media, generation: generation)
    }

    /// Sends `request` through the monitor; a playlist comes back whole and rewritten.
    private func fetch(_ request: MediaPartRequest, media: MediaContext, generation: Int) async -> Result<MediaPart, NetworkMonitorError> {
        guard generation == self.generation, let monitor else { return .failure(.cancelled(Self.endedReason)) }
        let (entryID, result) = await monitor.fetchMediaPart(request)
        guard generation == self.generation else { return .failure(.cancelled(Self.endedReason)) }
        guard case var .success(response) = result else { return result.map { _ in Self.emptyPart } }
        var mimeType = HTTPHeaders.mimeType(fromContentType: HTTPHeaders.value("Content-Type", in: response.headers))
        let contentRange = ContentRange(header: HTTPHeaders.value("Content-Range", in: response.headers))
        // Only a body that starts at offset 0 can be recognised by its signature; a declared playlist type always counts.
        let startsAtZero = response.status != 206 || contentRange?.start == 0
        guard HLSPlaylist.isPlaylist(startsAtZero ? response.body : Data(), mimeType: mimeType) else {
            return .success(MediaPart(status: response.status, mimeType: mimeType, body: response.body, contentRange: contentRange,
                                      isPlaylist: false, truncated: response.truncated))
        }
        let complete = response.status != 206 || contentRange.map { $0.start == 0 && $0.total == $0.end + 1 } == true
        if request.range != nil, !complete || response.truncated {
            // Part of a playlist is no playlist: fetch it whole.
            var whole = request
            whole.range = nil
            whole.maxBodyBytes = NetworkMonitor.maxContentBytes
            let (_, wholeResult) = await monitor.fetchMediaPart(whole)
            guard generation == self.generation else { return .failure(.cancelled(Self.endedReason)) }
            guard case let .success(fetched) = wholeResult else { return wholeResult.map { _ in Self.emptyPart } }
            response = fetched
            mimeType = HTTPHeaders.mimeType(fromContentType: HTTPHeaders.value("Content-Type", in: fetched.headers)) ?? mimeType
        }
        guard !response.truncated else { return .failure(.tooLarge(limit: NetworkMonitor.maxContentBytes)) }
        monitor.relabel(entryID, trigger: HLSPlaylist.Kind.playlist.label)
        let port: UInt16
        do {
            port = try await proxyPort()
        } catch {
            return .failure(.transport("The local media proxy could not start: \(error.localizedDescription)"))
        }
        guard generation == self.generation else { return .failure(.cancelled(Self.endedReason)) }
        let text = String(decoding: response.body, as: UTF8.self)
        let rewritten = HLSPlaylist.rewrite(text, base: response.url ?? request.url, unresolved: deadRoute(port)) { reference in
            route(reference, parentID: entryID, media: media, port: port)
        }
        return .success(MediaPart(status: 200, mimeType: mimeType ?? "application/vnd.apple.mpegurl", body: Data(rewritten.utf8),
                                  contentRange: nil, isPlaylist: true, truncated: false))
    }

    private static let emptyPart = MediaPart(status: 0, mimeType: nil, body: Data(), contentRange: nil, isPlaylist: false, truncated: false)

    // MARK: Proxy routes

    /// The proxy URL for a playlist URI (the same URI keeps its route, and its first parent).
    private func route(_ reference: HLSPlaylist.Reference, parentID: UUID, media: MediaContext, port: UInt16) -> String {
        let id: String
        if let existing = resourceIDs[reference.url] {
            id = existing
        } else {
            guard resources.count < Self.maxResources else { return deadRoute(port) }
            nextResourceID += 1
            id = String(nextResourceID)
            resources[id] = Resource(url: reference.url, kind: reference.kind, parentID: parentID, media: media)
            resourceIDs[reference.url] = id
        }
        return "http://127.0.0.1:\(port)/\(routeToken)/\(id)/\(Self.safeName(reference.url))"
    }

    private func deadRoute(_ port: UInt16) -> String {
        "http://127.0.0.1:\(port)/\(routeToken)/0/unavailable"
    }

    private func proxyPort() async throws -> UInt16 {
        if let proxyStart { return try await proxyStart.value }
        let proxy = try MediaLoopbackProxy { [weak self] request in
            guard let self else { return .status(404) }
            return await self.serve(request)
        }
        let start = Task { try await proxy.start() }
        self.proxy = proxy
        proxyStart = start
        do {
            return try await start.value
        } catch {
            if proxyStart == start {
                self.proxy = nil
                proxyStart = nil
            }
            throw error
        }
    }

    /// Answers one proxy request: a known route is fetched through the monitor.
    private func serve(_ request: MediaLoopbackProxy.Request) async -> MediaLoopbackProxy.Response {
        guard request.method == "GET" || request.method == "HEAD" else { return .status(405) }
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2, segments[0] == routeToken, let resource = resources[String(segments[1])] else { return .status(404) }
        let part = MediaPartRequest(url: resource.url, range: request.range, parentID: resource.parentID, trigger: resource.kind.label,
                                    source: resource.media.source + " › " + resource.kind.label, userAgent: resource.media.userAgent,
                                    maxBodyBytes: NetworkMonitor.maxContentBytes)
        switch await fetch(part, media: resource.media, generation: generation) {
        case let .success(fetched):
            guard !fetched.truncated else { return .status(502) }
            var headers = ["Content-Type": fetched.mimeType ?? "application/octet-stream", "Cache-Control": "no-store"]
            if fetched.status == 206, let range = fetched.contentRange {
                headers["Content-Range"] = range.header
                headers["Accept-Ranges"] = "bytes"
            }
            return MediaLoopbackProxy.Response(status: fetched.status, headers: headers, body: fetched.body)
        case let .failure(error):
            switch error {
            case let .httpStatus(status, _): return .status(status)
            case .offline, .notFetchable: return .status(403)
            default: return .status(502)
            }
        }
    }

    // MARK: Helpers

    nonisolated static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The last path component, reduced to safe characters (players look at the extension).
    nonisolated static func safeName(_ url: URL) -> String {
        let name = url.lastPathComponent.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        let text = String(String.UnicodeScalarView(name.prefix(80)))
        return text.isEmpty || text == "." || text == ".." ? "resource" : text
    }

    nonisolated static func label(of range: ByteRange) -> String {
        switch range.form {
        case let .from(start, end?): "bytes \(start)-\(end)"
        case let .from(start, nil): "bytes \(start)-"
        case let .suffix(length): "last \(length) bytes"
        }
    }
}

private struct WeakLoader {
    weak var loader: MediaResourceLoader?
}
