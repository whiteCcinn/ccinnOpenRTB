import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

/// The monitor over the real transport against a loopback server: what is recorded is what went over the wire.
@MainActor
@Suite("Network on the wire", .serialized)
struct NetworkWireTests {
    private func lowercased(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
    }

    @Test func recordedRequestHeadersAreTheHeadersOnTheWire() async throws {
        let server = try LoopbackHTTPServer { request in
            request.path == "/imp" ? .redirect(to: "/pixel") : .text("<VAST version=\"4.2\"/>", type: "application/xml")
        }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.mode = .real
        _ = try await monitor.fetchContent("http://127.0.0.1:\(port)/vast", trigger: "VAST tag", source: "VAST", parentID: nil, userAgent: deviceUA)
        monitor.dispatch(tracker(.impression, "http://127.0.0.1:\(port)/imp"), userAgent: deviceUA)
        await monitor.waitUntilIdle()

        let entries = monitor.liveEntries
        #expect(entries.count == 3, "content, tracker, redirect hop")
        #expect(server.requests.count == 3)
        for (entry, request) in zip(entries, server.requests) {
            #expect(entry.requestHeadersAsSent, "\(entry.url)")
            #expect(lowercased(entry.requestHeaders) == request.headers, "\(entry.url): recorded \(entry.requestHeaders), wire \(request.headers)")
            let curl = CurlCommand.make(for: entry)
            for (name, value) in entry.requestHeaders { #expect(curl.contains(CurlCommand.quote("\(name): \(value)"))) }
        }
        let har = try #require(try JSONSerialization.jsonObject(with: monitor.harData()) as? [String: Any])
        let harEntries = try #require((har["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        for (harEntry, request) in zip(harEntries, server.requests) {
            let headers = try #require((harEntry["request"] as? [String: Any])?["headers"] as? [[String: String]])
            #expect(Dictionary(headers.map { (($0["name"] ?? "").lowercased(), $0["value"] ?? "") }) { first, _ in first } == request.headers)
            #expect((harEntry["_ccinn"] as? [String: Any])?["requestHeadersAsSent"] as? Bool == true)
        }
        // Explicit, from the monitor (the simulated device's language), not CFNetwork's guess from the Mac's locale.
        #expect(server.requests.allSatisfy { $0.header("Accept-Language") == NetworkMonitor.defaultAcceptLanguage })
        #expect(server.requests.allSatisfy { $0.header("User-Agent") == deviceUA })
    }

    @Test func theMonitorsLanguageIsSentAndRecorded() async throws {
        let server = try LoopbackHTTPServer { _ in .text("ok") }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.acceptLanguage = "de-DE,de;q=0.9"
        _ = try await monitor.fetchContent("http://127.0.0.1:\(port)/x", trigger: "image", source: "Native", parentID: nil, userAgent: deviceUA)
        #expect(server.requests.first?.header("Accept-Language") == "de-DE,de;q=0.9")
        #expect(monitor.liveEntries.first.flatMap { HTTPHeaders.value("Accept-Language", in: $0.requestHeaders) } == "de-DE,de;q=0.9")
    }

    /// A Simulated-mode tracker never ran: its headers are the ones it would have sent, and say so.
    @Test func headersOfARequestNeverSentAreMarkedPlanned() {
        let monitor = NetworkMonitor(transport: FailingTransport(), publishInterval: .zero)
        let id = monitor.dispatch(tracker(.impression, "https://t.example/imp"), userAgent: deviceUA)
        let entry = monitor.entry(id: id)
        #expect(entry?.requestHeadersAsSent == false)
    }

    // MARK: Offline

    /// Every remote content request a render makes, plus trackers of every kind.
    private func requestEverything(_ monitor: NetworkMonitor, base: String) async -> [Result<Data, any Error>] {
        var results: [Result<Data, any Error>] = []
        func fetch(_ path: String, _ category: TrackerCategory = .content, trigger: String) async {
            do {
                results.append(.success(try await monitor.fetchContent(base + path, category: category, trigger: trigger, source: "bid 0.0",
                                                                       parentID: nil, userAgent: deviceUA).data))
            } catch {
                results.append(.failure(error))
            }
        }
        await fetch("/vast", trigger: "VAST tag")
        await fetch("/image.png", trigger: "image")
        await fetch("/assets.json", trigger: "assetsurl")
        await fetch("/curl", trigger: "markup (curl)")
        await fetch("/nurl", .win, trigger: "win (markup)")
        let source = VASTSource.url(base + "/tag")
        _ = await VASTResolver(fetcher: MonitorVASTFetcher(monitor: monitor, userAgent: deviceUA, resolving: source)).resolve(source)
        let media = await monitor.prepareMedia(base + "/ad.mp4", trigger: "media file", source: "VAST", parentID: nil, userAgent: deviceUA)
        results.append(media.playableURL == nil ? .failure(media.failure ?? NetworkMonitorError.cleared) : .success(Data()))
        monitor.dispatch(tracker(.impression, base + "/imp"), userAgent: deviceUA)
        monitor.dispatch(tracker(.event, base + "/script.js", isScript: true), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        return results
    }

    @Test func offlineSendsNothingAndSaysSo() async throws {
        let server = try LoopbackHTTPServer { _ in .text("<VAST version=\"4.2\"/>", type: "application/xml") }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.offline = true
        let results = await requestEverything(monitor, base: "http://127.0.0.1:\(port)")

        try await Task.sleep(for: .milliseconds(200))
        #expect(server.connectionCount == 0, "\(server.paths)")
        #expect(results.allSatisfy { if case .failure = $0 { true } else { false } })
        for case let .failure(error) in results {
            switch error as? NetworkMonitorError {
            case .offline?, .notSentInSimulatedMode?: break
            default: Issue.record("unexpected \(error)")
            }
        }
        let entries = monitor.liveEntries
        let content = entries.filter { $0.category == .content }
        #expect(content.count == 6, "VAST tag, image, assetsurl, curl markup, resolved tag, media")
        #expect(content.allSatisfy { $0.delivery == .offline && $0.state == .blocked && $0.note == DispatchPolicy.offlineNote })
        #expect(content.allSatisfy { $0.requestHeaders.isEmpty == false && !$0.requestHeadersAsSent })
        let trackers = entries.filter(\.category.isTracker)
        #expect(trackers.count == 3, "nurl markup, impression, script")
        #expect(trackers.allSatisfy { $0.delivery == .simulated && $0.state == .simulated })
    }

    /// The control: Simulated (not Offline) still fetches content, and still sends no tracker.
    @Test func simulatedModeStillFetchesContent() async throws {
        let server = try LoopbackHTTPServer { _ in .text("<VAST version=\"4.2\"/>", type: "application/xml") }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        _ = await requestEverything(monitor, base: "http://127.0.0.1:\(port)")
        #expect(Set(server.paths).isSuperset(of: ["/vast", "/image.png", "/assets.json", "/curl", "/tag"]), "\(server.paths)")
        #expect(!server.paths.contains("/imp") && !server.paths.contains("/nurl") && !server.paths.contains("/script.js"))
        #expect(monitor.liveEntries.allSatisfy { $0.delivery != .offline })
    }

    @Test func offlineStillServesLocalContent() async throws {
        let monitor = NetworkMonitor(transport: FailingTransport(), samples: FakeSamples(), publishInterval: .zero)
        monitor.offline = true
        let data = try await monitor.fetchContent("data:text/xml,%3CVAST%2F%3E", trigger: "VAST tag", source: "VAST", parentID: nil,
                                                  userAgent: deviceUA)
        #expect(String(decoding: data.data, as: UTF8.self) == "<VAST/>")
        let image = try await monitor.fetchContent(SampleURL.image("icon"), trigger: "image", source: "Native", parentID: nil, userAgent: deviceUA)
        #expect(!image.data.isEmpty)
        let media = await monitor.prepareMedia(SampleURL.video, trigger: "media file", source: "VAST", parentID: nil, userAgent: deviceUA)
        #expect(media.playableURL?.isFileURL == true)
        #expect(monitor.liveEntries.allSatisfy { $0.delivery == .local })
    }

    /// Offline is Simulated tracking plus offline content: it forces Simulated mode and closes the creative's own
    /// network; choosing Real leaves Offline.
    @Test func offlineImpliesSimulatedModeAndRealLeavesIt() {
        let monitor = NetworkMonitor(transport: FailingTransport(), publishInterval: .zero)
        monitor.mode = .real
        monitor.allowCreativeNetwork = true
        monitor.offline = true
        #expect(monitor.mode == .simulated)
        #expect(!monitor.allowCreativeNetwork)
        monitor.allowCreativeNetwork = true
        #expect(!monitor.allowCreativeNetwork, "the creative's own network stays closed while Offline")
        monitor.mode = .real
        #expect(!monitor.offline)
        #expect(monitor.allowCreativeNetwork, "the opt-in is remembered")
    }

    // MARK: Cancelling in-flight requests

    /// A slow server: `/slow` answers 302 → `/next` only after `delay`; everything else at once.
    private func slowServer(delay: Duration = .milliseconds(800)) throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer { request in
            switch request.path {
            case "/slow": LoopbackHTTPServer.Response(status: 302, headers: ["Location": "/next"], delay: delay)
            case "/slow-content": LoopbackHTTPServer.Response(status: 200, headers: ["Content-Type": "application/xml"], body: Data("<VAST/>".utf8),
                                                              delay: delay)
            default: .text("ok")
            }
        }
    }

    private func waitForRequest(_ server: LoopbackHTTPServer, _ path: String) async -> Bool {
        for _ in 0..<400 {
            if server.paths.contains(path) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func leavingRealModeCancelsEveryTrackerInFlight() async throws {
        let server = try slowServer()
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.impression, "http://127.0.0.1:\(port)/slow"), userAgent: deviceUA)
        #expect(await waitForRequest(server, "/slow"))

        monitor.mode = .simulated
        // At once: the entry is finished as cancelled, and nothing is in flight any more.
        #expect(monitor.entry(id: id)?.state == .failed("Cancelled: switched to Simulated mode"))
        #expect(monitor.entry(id: id)?.finishedAt != nil)
        #expect(monitor.inFlightCount == 0)
        await monitor.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(server.paths == ["/slow"], "no redirect hop after the switch")
        #expect(monitor.liveEntries.count == 1, "no hop recorded")
        #expect(monitor.entry(id: id)?.state == .failed("Cancelled: switched to Simulated mode"))
    }

    @Test func cancelInFlightTrackersUsesTheGivenReason() async throws {
        let server = try slowServer()
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.billing, "http://127.0.0.1:\(port)/slow"), userAgent: deviceUA)
        #expect(await waitForRequest(server, "/slow"))
        monitor.cancelInFlightTrackers(reason: "a new render started")
        #expect(monitor.entry(id: id)?.state == .failed("Cancelled: a new render started"))
        #expect(monitor.mode == .real, "the mode is unchanged")
        await monitor.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(server.paths == ["/slow"])
    }

    /// Content is needed to render: a mode switch does not touch it (only Offline does).
    @Test func contentInFlightSurvivesTheModeSwitch() async throws {
        let server = try slowServer(delay: .milliseconds(300))
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.mode = .real
        let fetch = Task { try await monitor.fetchContent("http://127.0.0.1:\(port)/slow-content", trigger: "VAST tag", source: "VAST",
                                                          parentID: nil, userAgent: deviceUA) }
        #expect(await waitForRequest(server, "/slow-content"))
        monitor.mode = .simulated
        let result = try await fetch.value
        #expect(String(decoding: result.data, as: UTF8.self) == "<VAST/>")
        #expect(monitor.entry(id: result.entryID)?.status == 200)
    }

    @Test func goingOfflineCancelsContentInFlight() async throws {
        let server = try slowServer()
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        let fetch = Task { try await monitor.fetchContent("http://127.0.0.1:\(port)/slow-content", trigger: "VAST tag", source: "VAST",
                                                          parentID: nil, userAgent: deviceUA) }
        #expect(await waitForRequest(server, "/slow-content"))
        monitor.offline = true
        await #expect(throws: NetworkMonitorError.cancelled(NetworkMonitor.offlineCancellation)) { _ = try await fetch.value }
        let entry = try #require(monitor.liveEntries.first)
        #expect(entry.state == .failed("Cancelled: \(NetworkMonitor.offlineCancellation)"))
    }
}
