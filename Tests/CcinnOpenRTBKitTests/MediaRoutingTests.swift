import AVFoundation
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

/// AVFoundation plays remote media only through the monitor: every byte, redirect and HLS sub-request is fetched by the
/// monitor's transport after the dispatch policy allowed it, recorded under the media entry, with the simulated device's
/// headers, ephemeral (no cookies). The servers are on loopback; AVFoundation never talks to them.
@MainActor
@Suite("Media routing (AVFoundation)", .serialized)
struct MediaRoutingTests {
    private func monitor() -> NetworkMonitor {
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.mediaChunkBytes = 64 * 1024
        return monitor
    }

    private func sampleAudio() async throws -> Data {
        try Data(contentsOf: try await SampleMedia.shared.fileURL(for: .audio))
    }

    private func descendants(of id: UUID, in entries: [NetworkEntry]) -> [NetworkEntry] {
        var parents: Set<UUID> = [id]
        var found: [NetworkEntry] = []
        for entry in entries.sorted(by: { $0.sequence < $1.sequence }) {
            if let parent = entry.parentID, parents.contains(parent) {
                found.append(entry)
                parents.insert(entry.id)
            }
        }
        return found
    }

    /// (a) Progressive media: content information plus byte ranges, mapped to HTTP `Range`, sent with the simulated
    /// device's headers and no cookie, even after the server set one. In Simulated mode: media is content.
    @Test func progressiveMediaIsFetchedByTheMonitorInRanges() async throws {
        let file = try await sampleAudio()
        let server = try LoopbackHTTPServer { request in
            .file(file, type: "audio/mp4", for: request, headers: ["Set-Cookie": "uid=\(UUID().uuidString); Path=/; Max-Age=3600"])
        }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = monitor()
        #expect(monitor.mode == .simulated)
        let url = "http://127.0.0.1:\(port)/ad.m4a"
        let prepared = await monitor.prepareMedia(url, trigger: "media file", source: "VAST › MediaFile", parentID: nil, userAgent: deviceUA)
        let playable = try #require(prepared.playableURL)
        let loader = try #require(prepared.resourceLoader)
        #expect(playable.scheme?.hasPrefix(MediaResourceLoader.schemePrefix) == true)
        #expect(!playable.absoluteString.contains("127.0.0.1"), "AVFoundation never sees the origin")

        let asset = AVURLAsset(url: playable)
        loader.attach(to: asset)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 15) < 0.2)
        _ = try await asset.loadTracks(withMediaType: .audio)
        asset.cancelLoading()
        await monitor.waitUntilIdle()

        let requests = server.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.header("User-Agent") == deviceUA }, "\(requests.map { $0.header("User-Agent") ?? "" })")
        #expect(requests.allSatisfy { $0.header("Cookie") == nil }, "no cookie comes back")
        #expect(requests.allSatisfy { $0.header("Accept-Language") == NetworkMonitor.defaultAcceptLanguage })
        #expect(requests.allSatisfy { $0.header("Range")?.hasPrefix("bytes=") == true }, "every request is a byte range")

        let entries = monitor.liveEntries
        let media = try #require(monitor.entry(id: prepared.entryID))
        #expect(media.url == url)
        let parts = entries.filter { $0.parentID == media.id }
        // Every request on the wire is a child entry; the ones answered are 206 with the headers that were sent.
        // (AVFoundation cancels what it no longer needs, so a request may end before its answer.)
        #expect(parts.allSatisfy { $0.delivery == .network && $0.category == .content && $0.state != .pending })
        let answered = parts.filter { $0.status != nil }
        #expect(!answered.isEmpty && answered.count <= requests.count)
        #expect(answered.allSatisfy { $0.status == 206 && $0.requestHeadersAsSent })
        #expect(Set(requests.compactMap { $0.header("Range") }).isSubset(of: Set(parts.compactMap { HTTPHeaders.value("Range", in: $0.requestHeaders) })))
    }

    /// (b) A 302 from the media URL to another origin is followed by the monitor and recorded; the player never sees it.
    @Test func aRedirectToAnotherOriginIsFollowedAndRecorded() async throws {
        let file = try await sampleAudio()
        let target = try LoopbackHTTPServer { request in .file(file, type: "audio/mp4", for: request) }
        let targetPort = try await target.start()
        defer { target.stop() }
        let origin = try LoopbackHTTPServer { _ in .redirect(to: "http://127.0.0.1:\(targetPort)/cdn/ad.m4a") }
        let originPort = try await origin.start()
        defer { origin.stop() }

        let monitor = monitor()
        let prepared = await monitor.prepareMedia("http://127.0.0.1:\(originPort)/ad.m4a", trigger: "media file", source: "VAST", parentID: nil,
                                                  userAgent: deviceUA)
        let asset = AVURLAsset(url: try #require(prepared.playableURL))
        try #require(prepared.resourceLoader).attach(to: asset)
        #expect(abs(try await asset.load(.duration).seconds - 15) < 0.2)
        asset.cancelLoading()
        await monitor.waitUntilIdle()

        #expect(!origin.requests.isEmpty)
        #expect(!target.requests.isEmpty)
        #expect((origin.requests + target.requests).allSatisfy { $0.header("User-Agent") == deviceUA && $0.header("Cookie") == nil })
        let tree = descendants(of: prepared.entryID, in: monitor.liveEntries)
        let hops = tree.filter(\.isRedirectHop)
        #expect(!hops.isEmpty)
        #expect(hops.allSatisfy { URLText.host($0.url) == "127.0.0.1" && $0.url.contains(":\(targetPort)/cdn/ad.m4a") })
        #expect(hops.contains { $0.status == 206 })
        // Requests AVFoundation cancelled once it had what it needed may have ended before their answer.
        let requests = tree.filter { !$0.isRedirectHop }
        #expect(requests.allSatisfy { $0.parentID == prepared.entryID && $0.state != .pending })
        #expect(requests.filter { $0.status != nil }.allSatisfy { $0.status == 302 })
        #expect(hops.allSatisfy { hop in requests.contains { $0.id == hop.parentID } })
    }

    /// (c) HLS: the master on one origin, the variant, its init section and segments on another. Each is fetched by the
    /// monitor and hangs under the request that delivered the playlist naming it.
    @Test(.timeLimit(.minutes(1)))
    func hlsPlaylistsAndSegmentsFromTwoOriginsAreAllRecorded() async throws {
        let fixture = try HLSFixture.make()
        let segments = try LoopbackHTTPServer { request in
            switch request.path {
            case "/v/variant.m3u8": .text(fixture.mediaPlaylist, type: "application/vnd.apple.mpegurl", headers: ["Set-Cookie": "s=1"])
            case "/v/init.mp4": .file(fixture.initSection, type: "video/mp4", for: request)
            default:
                if let index = Int(request.path.dropFirst("/v/seg".count).prefix { $0.isNumber }), fixture.segments.indices.contains(index) {
                    .file(fixture.segments[index].data, type: "video/iso.segment", for: request)
                } else {
                    .text("not found", status: 404)
                }
            }
        }
        let segmentsPort = try await segments.start()
        defer { segments.stop() }
        let master = try LoopbackHTTPServer { _ in
            .text(HLSFixture.masterPlaylist(variant: "http://127.0.0.1:\(segmentsPort)/v/variant.m3u8"), type: "application/vnd.apple.mpegurl")
        }
        let masterPort = try await master.start()
        defer { master.stop() }

        let monitor = monitor()
        let prepared = await monitor.prepareMedia("http://127.0.0.1:\(masterPort)/master.m3u8", trigger: "media file", source: "VAST",
                                                  parentID: nil, userAgent: deviceUA)
        let asset = AVURLAsset(url: try #require(prepared.playableURL))
        try #require(prepared.resourceLoader).attach(to: asset)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        player.play()
        defer { player.pause() }
        let played = await eventually {
            (player.currentItem?.status == .readyToPlay && segments.paths.contains("/v/seg1.m4s")) || player.currentItem?.status == .failed
        }
        #expect(played, "\(segments.paths)")
        #expect(player.currentItem?.status == .readyToPlay, "\(String(describing: player.currentItem?.error))")
        player.replaceCurrentItem(with: nil)
        await monitor.waitUntilIdle()

        let everyRequest = master.requests + segments.requests
        #expect(everyRequest.allSatisfy { $0.header("User-Agent") == deviceUA }, "AVFoundation's own agent never reaches an origin")
        #expect(everyRequest.allSatisfy { $0.header("Cookie") == nil && $0.header("X-Playback-Session-Id") == nil })

        let entries = monitor.liveEntries
        let masterEntries = entries.filter { $0.url.hasSuffix("/master.m3u8") && $0.parentID == prepared.entryID }
        #expect(!masterEntries.isEmpty)
        let masterIDs = Set(masterEntries.map(\.id))
        let variantEntries = entries.filter { $0.url.hasSuffix("/v/variant.m3u8") }
        #expect(!variantEntries.isEmpty)
        #expect(variantEntries.allSatisfy { $0.parentID.map(masterIDs.contains) == true && $0.trigger == "HLS playlist" })
        #expect(variantEntries.allSatisfy { URLText.host($0.url) == "127.0.0.1" && $0.url.contains(":\(segmentsPort)/") })
        let variantIDs = Set(variantEntries.map(\.id))
        let sectionEntries = entries.filter { $0.url.hasSuffix("/v/init.mp4") || $0.url.contains("/v/seg") }
        #expect(sectionEntries.contains { $0.trigger == "HLS init section" })
        #expect(sectionEntries.contains { $0.trigger == "HLS segment" })
        #expect(sectionEntries.allSatisfy { $0.parentID.map(variantIDs.contains) == true && $0.state != .pending })
        #expect(sectionEntries.filter { $0.status != nil }.allSatisfy { $0.status == 200 })
        let tree = descendants(of: prepared.entryID, in: entries)
        #expect(Set(tree.map(\.id)).isSuperset(of: variantIDs.union(sectionEntries.map(\.id))))
        // Every request on the wire is recorded; a recorded request that got an answer was on the wire.
        let recordedPaths = Set(tree.compactMap { URL(string: $0.url)?.path })
        #expect(Set(everyRequest.map(\.path)).isSubset(of: recordedPaths), "\(everyRequest.map(\.path)) vs \(recordedPaths)")
        #expect(tree.filter { $0.status != nil }.count <= everyRequest.count)
    }

    /// (d) Offline: a player that already has its URL gets nothing; nothing connects.
    @Test func offlineStopsMediaThatWasAlreadyPrepared() async throws {
        let file = try await sampleAudio()
        let server = try LoopbackHTTPServer { request in .file(file, type: "audio/mp4", for: request) }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = monitor()
        let prepared = await monitor.prepareMedia("http://127.0.0.1:\(port)/ad.m4a", trigger: "media file", source: "VAST", parentID: nil,
                                                  userAgent: deviceUA)
        monitor.offline = true
        let asset = AVURLAsset(url: try #require(prepared.playableURL))
        try #require(prepared.resourceLoader).attach(to: asset)
        await #expect(throws: (any Error).self) { _ = try await asset.load(.duration) }
        #expect(server.connectionCount == 0)
        let parts = monitor.liveEntries.filter { $0.parentID == prepared.entryID }
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.delivery == .offline })
    }

    /// The render ended: the loader of its media serves nothing more.
    @Test func endingTheRenderStopsItsMedia() async throws {
        let file = try await sampleAudio()
        let server = try LoopbackHTTPServer { request in .file(file, type: "audio/mp4", for: request) }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = monitor()
        let prepared = await monitor.prepareMedia("http://127.0.0.1:\(port)/ad.m4a", trigger: "media file", source: "VAST", parentID: nil,
                                                  userAgent: deviceUA)
        monitor.endRender()
        let asset = AVURLAsset(url: try #require(prepared.playableURL))
        try #require(prepared.resourceLoader).attach(to: asset)
        await #expect(throws: (any Error).self) { _ = try await asset.load(.duration) }
        #expect(server.connectionCount == 0)
    }
}
