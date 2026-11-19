import AVFoundation
import CcinnOpenRTBKit
import Foundation
import os
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// The real `AVPlayer` engine on the offline AAC sample (15 s), muted. The engine does not depend on the media type, and the
/// audio sample keeps these tests off the H.264 hardware that kit-network's sample-media writer test uses in a parallel
/// process. Timing assertions are generous: the observer runs at 10 Hz, and a busy machine can delay it.
@MainActor
@Suite("AVPlayer engine (AVFoundation)", .serialized)
struct AVPlaybackEngineTests {
    @MainActor
    final class Recorder {
        private(set) var events: [PlaybackEngineEvent] = []

        func attach(_ engine: AVPlaybackEngine) {
            engine.onEvent = { [weak self] event in self?.events.append(event) }
        }

        var readyDuration: Double? {
            for case let .ready(duration) in events { return duration }
            return nil
        }

        var isReady: Bool { events.contains { if case .ready = $0 { true } else { false } } }

        var lastTick: Double? {
            events.reversed().lazy.compactMap { if case let .tick(time) = $0 { time } else { nil } }.first
        }

        var failure: String? {
            for case let .failed(message) in events { return message }
            return nil
        }
    }

    private func sampleFile() async throws -> URL {
        try await SampleMedia.shared.fileURL(for: SampleURL.audio)
    }

    @Test func readyWithTheMediaDurationThenTicksAndStopIsSilent() async throws {
        let engine = AVPlaybackEngine()
        let recorder = Recorder()
        recorder.attach(engine)
        engine.setMuted(true)
        engine.load(try await sampleFile())
        #expect(await Wait.until(timeout: .seconds(20)) { recorder.isReady }, "\(recorder.events)")
        let duration = try #require(recorder.readyDuration)
        #expect(abs(duration - 15) < 0.2)
        // AVPlayer may report time 0 once the item is ready; the playhead must not move before play.
        #expect((recorder.lastTick ?? 0) < 0.05, "no progress before play")
        engine.play()
        #expect(await Wait.until(timeout: .seconds(10)) { (recorder.lastTick ?? 0) >= 0.5 }, "\(recorder.events.suffix(5))")
        engine.pause()
        // Ticks made before the pause may still be on their way (a loaded CI runner delivers them late): read the paused
        // position once they have settled. A playhead that kept moving never settles, and fails below anyway.
        var paused = recorder.lastTick ?? 0
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(300))
            let latest = recorder.lastTick ?? 0
            if latest == paused { break }
            paused = latest
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect((recorder.lastTick ?? 0) - paused < 0.05, "the playhead stands still while paused")
        engine.stop()
        let count = recorder.events.count
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.events.count == count, "nothing is delivered after stop")
        #expect(engine.avPlayer?.currentItem == nil)
    }

    @Test func replacingTheMediaDropsTheEventsOfTheOldOne() async throws {
        let engine = AVPlaybackEngine()
        let recorder = Recorder()
        recorder.attach(engine)
        engine.setMuted(true)
        let file = try await sampleFile()
        engine.load(file)
        engine.load(file)
        #expect(await Wait.until(timeout: .seconds(20)) { recorder.isReady })
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.events.filter { if case .ready = $0 { true } else { false } }.count == 1, "one ready, for the current item")
        engine.stop()
    }

    /// Remote media: the engine opens the private URL with the kit's resource loader, so the monitor fetches every byte
    /// (with the device's agent, in byte ranges) and AVFoundation never reaches the origin.
    @Test func remoteMediaPlaysThroughTheMonitor() async throws {
        let transport = RangedFileTransport(data: try Data(contentsOf: try await sampleFile()), contentType: "audio/mp4")
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let agent = RendererFixtures.phone.userAgent
        let prepared = await monitor.prepareMedia("https://cdn.example/ad.m4a", trigger: "media file", source: "VAST", parentID: nil,
                                                  userAgent: agent)
        let url = try #require(prepared.playableURL)
        #expect(url.scheme != "https")
        let engine = AVPlaybackEngine()
        let recorder = Recorder()
        recorder.attach(engine)
        engine.setMuted(true)
        engine.load(url, resourceLoader: prepared.resourceLoader)
        #expect(await Wait.until(timeout: .seconds(20)) { recorder.isReady }, "\(recorder.events)")
        #expect(abs((recorder.readyDuration ?? 0) - 15) < 0.2)
        engine.stop()

        let requests = transport.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.url.absoluteString == "https://cdn.example/ad.m4a" && $0.headers["User-Agent"] == agent })
        #expect(requests.allSatisfy { $0.headers["Range"]?.hasPrefix("bytes=") == true })
        #expect(monitor.liveEntries.contains { $0.parentID == prepared.entryID && $0.status == 206 })
    }

    /// The player model hands the engine the loader `prepareMedia` made for remote media.
    @Test func thePlayerModelPassesTheResourceLoaderToTheEngine() async throws {
        let host = RecordingHost()
        let engine = LoaderRecordingEngine()
        let ad = RendererFixtures.linearAd(duration: 15, media: [VASTMediaFile(url: "https://cdn.example/ad.mp4", type: "video/mp4")])
        let configuration = VASTPlayerConfiguration(request: RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, placement: .inFeed),
                                                    role: .ad(audioOnly: false), playerSize: CGSize(width: 358, height: 201))
        let model = VASTPlayerModel(vast: ResolvedVAST(ads: [ad]), configuration: configuration, host: host, engine: engine,
                                    chooseMedia: { files, _, _, _ in files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia) })
        defer { model.teardown() }
        model.start()
        #expect(await Wait.until(timeout: .seconds(10)) { !engine.loads.isEmpty })
        let load = try #require(engine.loads.first)
        #expect(load.loader?.url == load.url)
        #expect(load.loader?.remoteURL.absoluteString == "https://cdn.example/ad.mp4")
    }

    @Test func aMissingFileFails() async throws {
        let engine = AVPlaybackEngine()
        let recorder = Recorder()
        recorder.attach(engine)
        engine.load(FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-missing-\(UUID().uuidString).mp4"))
        #expect(await Wait.until(timeout: .seconds(20)) { recorder.failure != nil }, "\(recorder.events)")
        #expect(!recorder.isReady)
        engine.stop()
    }

    /// The player model on the real engine: the decisions.md order up to the first quartile (3.75 s of 15 s). In-feed with
    /// `audioOnly: false`, so it starts muted.
    @Test func thePlayerModelReportsTheVASTOrderOnRealPlayback() async throws {
        let host = RecordingHost()
        let ad = RendererFixtures.linearAd(duration: 15, media: [VASTMediaFile(url: SampleURL.audio, type: "audio/mp4")])
        var configuration = VASTPlayerConfiguration(request: RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, placement: .inFeed),
                                                    role: .ad(audioOnly: false), playerSize: CGSize(width: 358, height: 201))
        configuration.readyTimeout = .seconds(30)
        #expect(configuration.startsMuted, "in-feed: muted, so the test is silent")
        let model = VASTPlayerModel(vast: ResolvedVAST(ads: [ad]), configuration: configuration, host: host, engine: AVPlaybackEngine(),
                                    chooseMedia: { files, _, _, _ in files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia) })
        defer { model.teardown() }
        model.start()
        let reached = await Wait.until(timeout: .seconds(30)) { host.videoEvents(adIndex: 0).contains(.firstQuartile) }
        #expect(reached, "\(host.events)")
        #expect(Array(host.events.prefix(5)) == [.video(.loaded, adIndex: 0), .rendered, .video(.creativeView, adIndex: 0),
                                                 .video(.start, adIndex: 0), .video(.firstQuartile, adIndex: 0)])
        #expect(host.statuses.contains { $0.isPlaying && $0.isMuted && $0.duration.map { abs($0 - 15) < 0.2 } == true })
        let local = host.monitor.liveEntries.first { $0.url == SampleURL.audio }
        #expect(local?.delivery == .local, "the sample is served locally, nothing leaves the machine")
    }
}

/// Records what the player model asks the engine to load.
@MainActor
private final class LoaderRecordingEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var avPlayer: AVPlayer? { nil }
    private(set) var loads: [(url: URL, loader: MediaResourceLoader?)] = []

    func load(_ url: URL) { load(url, resourceLoader: nil) }
    func load(_ url: URL, resourceLoader: MediaResourceLoader?) { loads.append((url, resourceLoader)) }
    func play() {}
    func pause() {}
    func setMuted(_ muted: Bool) {}
    func stop() {}
}

/// Serves one file to the monitor in byte ranges (`Range: bytes=a-b` / `bytes=a-`), recording each request.
private final class RangedFileTransport: HTTPTransport {
    let data: Data
    let contentType: String
    private let seen = OSAllocatedUnfairLock(initialState: [HTTPRequest]())

    init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    var requests: [HTTPRequest] { seen.withLock { $0 } }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        seen.withLock { $0.append(request) }
        guard let range = request.headers["Range"], range.hasPrefix("bytes=") else {
            return HTTPResponse(status: 200, headers: ["Content-Type": contentType], body: data.prefix(request.maxBodyBytes),
                                truncated: data.count > request.maxBodyBytes)
        }
        let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        let start = bounds.first.flatMap { Int($0) } ?? 0
        let end = min(bounds.count > 1 ? Int(bounds[1]) ?? data.count - 1 : data.count - 1, data.count - 1)
        guard start <= end else { return HTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(data.count)"]) }
        return HTTPResponse(status: 206, headers: ["Content-Type": contentType, "Content-Range": "bytes \(start)-\(end)/\(data.count)"],
                            body: data.subdata(in: start..<(end + 1)))
    }
}
