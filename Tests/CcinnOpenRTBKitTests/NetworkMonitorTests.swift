import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

@Suite("Dispatch policy")
struct DispatchPolicyTests {
    @Test(arguments: TrackerCategory.allCases)
    func simulatedModeNeverIssuesAPermitForATracker(category: TrackerCategory) {
        for isScript in [false, true] {
            let permit = DispatchPolicy.permit(for: category, isScript: isScript, mode: .simulated)
            if category.isTracker {
                #expect(permit == nil, "\(category) must not be sendable in Simulated mode")
            }
        }
    }

    @Test func realModeSendsTrackersAndScriptsGoToTheRenderer() {
        #expect(DispatchPolicy.permit(for: .impression, isScript: false, mode: .real) != nil)
        #expect(DispatchPolicy.action(for: .impression, isScript: true, mode: .real) == .renderer(note: DispatchPolicy.scriptRealNote))
        #expect(DispatchPolicy.permit(for: .impression, isScript: true, mode: .real) == nil)
    }

    /// Offline = Simulated tracking + offline content: no permit for any remote request, whatever the mode says; local
    /// content (`data:`, `ccinn-sample:`) is still served.
    @Test(arguments: TrackerCategory.allCases, [TrackingMode.simulated, .real])
    func offlineIssuesNoPermitForARemoteRequest(category: TrackerCategory, mode: TrackingMode) {
        for isScript in [false, true] {
            #expect(DispatchPolicy.permit(for: category, isScript: isScript, mode: mode, offline: true) == nil, "\(category) \(mode)")
            if category.isTracker {
                let action = DispatchPolicy.action(for: category, isScript: isScript, mode: mode, offline: true)
                #expect(action == .record(.simulated, .simulated, note: isScript ? DispatchPolicy.scriptSimulatedNote : DispatchPolicy.simulatedNote))
            }
        }
        #expect(DispatchPolicy.action(for: .content, isScript: false, mode: mode, offline: true)
            == .record(.blocked, .offline, note: DispatchPolicy.offlineNote))
        let local = DispatchPolicy.action(for: .content, isScript: false, mode: mode, offline: true, destination: .local)
        #expect({ if case .send = local { true } else { false } }(), "\(local)")
        #expect(DispatchPolicy.permit(for: .content, isScript: false, mode: mode, offline: true, destination: .local) != nil)
    }

    @Test func destinationsAreLocalOnlyForDataAndSampleURLs() {
        #expect(DispatchPolicy.Destination(url: "data:text/xml,<VAST/>") == .local)
        #expect(DispatchPolicy.Destination(url: "CCINN-SAMPLE://image/icon.png") == .local)
        #expect(DispatchPolicy.Destination(url: "https://cdn.example/a.mp4") == .remote)
        #expect(DispatchPolicy.Destination(url: "//cdn.example/a.mp4") == .remote)
        #expect(DispatchPolicy.Destination(url: "ftp://cdn.example/a.mp4") == .remote)
    }

    @Test(arguments: [TrackingMode.simulated, .real])
    func contentIsAlwaysFetchedNavigationAndCreativeNever(mode: TrackingMode) {
        #expect(DispatchPolicy.permit(for: .content, isScript: false, mode: mode) != nil)
        #expect(DispatchPolicy.permit(for: .navigation, isScript: false, mode: mode) == nil)
        #expect(DispatchPolicy.permit(for: .creative, isScript: false, mode: mode) == nil)
    }
}

@MainActor
@Suite("Network monitor: Simulated mode")
struct SimulatedModeTests {
    /// Spec "Simulated mode sends nothing": nurl, burl and impression trackers appear as simulated and nothing is sent.
    @Test func simulatedModeRecordsAndSendsNothing() async throws {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        let win = monitor.dispatch(tracker(.win, "https://dsp.example/win?p=1.23"), userAgent: deviceUA)
        monitor.dispatch(tracker(.billing, "https://dsp.example/bill"), userAgent: deviceUA)
        monitor.dispatch(tracker(.impression, "https://dsp.example/imp"), userAgent: deviceUA)
        await monitor.waitUntilIdle()

        #expect(transport.callCount == 0)
        #expect(monitor.entries.map(\.sequence) == [1, 2, 3])
        #expect(monitor.entries.map(\.category) == [.win, .billing, .impression])
        #expect(monitor.entries.allSatisfy { $0.state == .simulated && $0.delivery == .simulated && $0.sessionMode == .simulated })
        #expect(monitor.entries.first?.id == win)
        #expect(monitor.entries.allSatisfy { $0.requestHeaders.isEmpty })
    }

    @Test(arguments: TrackerCategory.allCases.filter(\.isTracker))
    func everyTrackerCategoryIsOnlyRecorded(category: TrackerCategory) async throws {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        monitor.dispatch(tracker(category, "https://t.example/\(category.rawValue)"), userAgent: deviceUA)
        monitor.dispatch(tracker(category, "https://t.example/js", isScript: true), userAgent: deviceUA)
        await #expect(throws: NetworkMonitorError.self) {
            _ = try await monitor.fetchContent("https://t.example/markup", category: category, trigger: "win", source: "bid",
                                               parentID: nil, userAgent: deviceUA)
        }
        await monitor.waitUntilIdle()
        #expect(transport.callCount == 0)
        #expect(monitor.entries.count == 3)
        #expect(monitor.entries.allSatisfy { $0.state == .simulated })
    }

    /// Win-notice markup in Simulated mode: recorded, not sent, and the caller learns why.
    @Test func trackerCategoryFetchThrowsInSimulatedMode() async throws {
        let monitor = makeMonitor(transport: FailingTransport())
        do {
            _ = try await monitor.fetchContent("https://dsp.example/win", category: .win, trigger: "win", source: "bid 0.0", parentID: nil,
                                               userAgent: deviceUA)
            Issue.record("expected a throw")
        } catch let NetworkMonitorError.notSentInSimulatedMode(entryID) {
            #expect(monitor.entry(id: entryID)?.state == .simulated)
        }
    }

    @Test func scriptTrackersAreRecordedWithANote() {
        let monitor = makeMonitor(transport: FailingTransport())
        let id = monitor.dispatch(tracker(.impression, "https://v.example/tag.js", isScript: true), userAgent: deviceUA)
        let entry = monitor.entry(id: id)
        #expect(entry?.isScript == true)
        #expect(entry?.state == .simulated)
        #expect(entry?.note == DispatchPolicy.scriptSimulatedNote)
    }

    /// Switching to Simulated after dispatch but before the request goes out: the tracker is not sent.
    @Test func switchingToSimulatedBeforeTheFirstHopSendsNothing() async {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.impression, "https://t.example/imp"), userAgent: deviceUA)
        monitor.mode = .simulated
        await monitor.waitUntilIdle()
        #expect(transport.callCount == 0)
        #expect(monitor.entry(id: id)?.state == .simulated)
        #expect(monitor.entry(id: id)?.note == "Not sent: switched to Simulated mode")
    }

    /// Switching to Simulated while a redirect chain runs: the hop in flight is cancelled (even if its 302 still
    /// arrives) and the next hop is neither sent nor recorded.
    @Test func switchingToSimulatedMidChainStopsTheNextHop() async {
        let transport = FakeTransport()
        let monitor = makeMonitor(transport: transport)
        transport.respond("https://t.example/imp", status: 302, headers: ["Location": "https://hop.example/next"]) { monitor.mode = .simulated }
        transport.respond("https://hop.example/next", body: "never")
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.impression, "https://t.example/imp"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        #expect(transport.requestedURLs == ["https://t.example/imp"])
        #expect(monitor.entries.count == 1)
        #expect(monitor.entry(id: id)?.state == .failed("Cancelled: \(NetworkMonitor.simulatedCancellation)"))
    }

    @Test func contentIsStillFetchedInSimulatedMode() async throws {
        let transport = FakeTransport()
        transport.respond("https://cdn.example/vast.xml", headers: ["Content-Type": "application/xml"], body: "<VAST/>")
        let monitor = makeMonitor(transport: transport)
        let (data, id) = try await monitor.fetchContent("https://cdn.example/vast.xml", trigger: "VAST wrapper", source: "bid 0.0",
                                                         parentID: nil, userAgent: deviceUA)
        #expect(String(decoding: data, as: UTF8.self) == "<VAST/>")
        #expect(monitor.entry(id: id)?.delivery == .network)
        #expect(monitor.entry(id: id)?.state == .completed(status: 200))
    }
}

@MainActor
@Suite("Network monitor: Real mode")
struct RealModeTests {
    @Test func sendsWithTheDeviceUserAgentAndRecordsTheExchange() async throws {
        let clock = ManualClock()
        let transport = FakeTransport(clock: clock, latency: 0.04)
        transport.respond("https://dsp.example/imp?x=1", headers: ["Content-Type": "image/gif", "Server": "edge"], body: "GIF89a")
        let monitor = makeMonitor(transport: transport, clock: clock)
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.impression, "https://dsp.example/imp?x=1"), userAgent: deviceUA)
        #expect(monitor.entry(id: id)?.state == .pending)
        await monitor.waitUntilIdle()

        #expect(transport.requests.first?.headers["User-Agent"] == deviceUA)
        let entry = try #require(monitor.entry(id: id))
        #expect(entry.state == .completed(status: 200))
        #expect(entry.delivery == .network)
        #expect(entry.sessionMode == .real)
        #expect(entry.requestHeaders["User-Agent"] == deviceUA)
        #expect(entry.responseHeader("server") == "edge")
        #expect(entry.responseBytes == 6)
        #expect(entry.mimeType == "image/gif")
        #expect(abs((entry.duration ?? 0) - 0.04) < 0.000_1)
        #expect(entry.timings != nil)
        #expect(monitor.responseBody(for: id) == Data("GIF89a".utf8))
    }

    /// Redirects are never auto-followed: each hop is a child entry with the `Location` that produced it.
    @Test func redirectsAreRecordedHopByHop() async throws {
        let transport = FakeTransport()
        transport.redirect("https://a.example/click", to: "https://b.example/r?id=7")
        transport.redirect("https://b.example/r?id=7", to: "/landing", status: 301)
        transport.respond("https://b.example/landing", body: "ok")
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        let root = monitor.dispatch(tracker(.click, "https://a.example/click"), userAgent: deviceUA)
        await monitor.waitUntilIdle()

        #expect(transport.requestedURLs == ["https://a.example/click", "https://b.example/r?id=7", "https://b.example/landing"])
        let entries = monitor.entries
        #expect(entries.count == 3)
        #expect(entries[0].id == root)
        #expect(entries[0].state == .completed(status: 302))
        #expect(entries[1].parentID == root)
        #expect(entries[1].redirectLocation == "https://b.example/r?id=7")
        #expect(entries[1].state == .completed(status: 301))
        #expect(entries[2].parentID == root)
        #expect(entries[2].redirectLocation == "/landing")
        #expect(entries[2].url == "https://b.example/landing")
        #expect(entries[2].state == .completed(status: 200))
        #expect(entries.map(\.category) == [.click, .click, .click])
        #expect(transport.requests.allSatisfy { $0.headers["User-Agent"] == deviceUA })
    }

    @Test func redirectLoopsStop() async {
        let transport = FakeTransport()
        transport.redirect("https://a.example/1", to: "https://b.example/2")
        transport.redirect("https://b.example/2", to: "https://a.example/1")
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        monitor.dispatch(tracker(.impression, "https://a.example/1"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        #expect(transport.requests.count == 2)
        guard case let .failed(message)? = monitor.entries.last?.state else {
            Issue.record("the loop hop must be recorded as failed")
            return
        }
        #expect(message.contains("loop"))
    }

    @Test func atMostTenRedirectsAreFollowed() async {
        let transport = FakeTransport()
        for index in 0...11 { transport.redirect("https://r.example/\(index)", to: "https://r.example/\(index + 1)") }
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        monitor.dispatch(tracker(.impression, "https://r.example/0"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        #expect(transport.requests.count == NetworkMonitor.maxRedirects + 1)
        #expect(monitor.entries.count == NetworkMonitor.maxRedirects + 2)
        #expect(monitor.entries.last?.state == .failed(NetworkMonitorError.tooManyRedirects(limit: 10).errorDescription ?? ""))
    }

    @Test func nonHTTPRedirectTargetsAreRecordedNotFollowed() async {
        let transport = FakeTransport()
        transport.redirect("https://t.example/click", to: "itms-apps://apps.apple.com/app/id1")
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        monitor.dispatch(tracker(.click, "https://t.example/click"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        #expect(transport.requests.count == 1)
        #expect(monitor.entries.last?.url == "itms-apps://apps.apple.com/app/id1")
        #expect(monitor.entries.last?.delivery == .simulated)
    }

    @Test func largeTrackerBodiesAreTruncatedNotFailed() async throws {
        let transport = FakeTransport()
        transport.respond("https://t.example/big", data: Data(count: NetworkMonitor.maxTrackerBodyBytes + 10))
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.impression, "https://t.example/big"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        let entry = try #require(monitor.entry(id: id))
        #expect(entry.state == .completed(status: 200))
        #expect(entry.responseBytes == NetworkMonitor.maxTrackerBodyBytes)
        #expect(entry.note?.contains("truncated") == true)
    }

    @Test func timeoutsFailTheEntry() async throws {
        let transport = FakeTransport()
        transport.respond("https://slow.example/imp", body: "late", delay: .seconds(30))
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        monitor.requestTimeout = 0.1
        let id = monitor.dispatch(tracker(.impression, "https://slow.example/imp"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        guard case let .failed(message)? = monitor.entry(id: id)?.state else {
            Issue.record("expected a timeout failure")
            return
        }
        #expect(message.contains("Timed out"))
    }

    @Test func transportErrorsFailTheEntry() async {
        let monitor = makeMonitor(transport: FakeTransport())
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.loss, "https://unknown.example/loss"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        if case .failed? = monitor.entry(id: id)?.state {} else { Issue.record("expected failure") }
        #expect(monitor.entry(id: id)?.finishedAt != nil)
    }

    @Test func realModeScriptTrackersAreLeftToTheRenderer() {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        let id = monitor.dispatch(tracker(.impression, "https://v.example/tag.js", isScript: true), userAgent: deviceUA)
        #expect(monitor.entry(id: id)?.delivery == .renderer)
        #expect(monitor.entry(id: id)?.note == "Injected by renderer")
        #expect(monitor.entry(id: id)?.state == .pending)
        monitor.finishRendererLoad(id, status: 200)
        #expect(monitor.entry(id: id)?.state == .completed(status: 200))
        #expect(transport.callCount == 0)
    }

    @Test func rendererReportsOnlyApplyToRendererLoads() async {
        let monitor = makeMonitor(transport: FailingTransport())
        let simulated = monitor.dispatch(tracker(.impression, "https://t.example/imp"), userAgent: deviceUA)
        monitor.finishRendererLoad(simulated, status: 200)
        #expect(monitor.entry(id: simulated)?.state == .simulated)

        let blocked = monitor.recordCreativeRequest(url: "https://c.example/a.js", kind: "script", blocked: true, parentID: nil)
        monitor.finishRendererLoad(blocked, status: 200)
        #expect(monitor.entry(id: blocked)?.state == .blocked)

        let allowed = monitor.recordCreativeRequest(url: "https://c.example/b.png", kind: "img", blocked: false, parentID: nil)
        #expect(monitor.entry(id: allowed)?.delivery == .renderer)
        monitor.finishRendererLoad(allowed, error: "404")
        monitor.finishRendererLoad(allowed, status: 200)
        #expect(monitor.entry(id: allowed)?.state == .failed("404"))
    }
}

@MainActor
@Suite("Network monitor: content, media and records")
struct ContentTests {
    @Test func dataURLsAreDecodedLocally() async throws {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        let (data, id) = try await monitor.fetchContent("data:text/xml;base64,PFZBU1QvPg==", trigger: "VAST wrapper", source: "bid",
                                                         parentID: nil, userAgent: deviceUA)
        #expect(String(decoding: data, as: UTF8.self) == "<VAST/>")
        let entry = try #require(monitor.entry(id: id))
        #expect(entry.delivery == .local)
        #expect(entry.mimeType == "text/xml")
        #expect(entry.note == "data: URL decoded locally")
        #expect(transport.callCount == 0)
    }

    @Test func sampleURLsAreServedLocally() async throws {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        let (data, id) = try await monitor.fetchContent("ccinn-sample://image/companion.png", trigger: "companion", source: "VAST",
                                                         parentID: nil, userAgent: deviceUA)
        #expect(String(decoding: data, as: UTF8.self) == "sample:image-companion.png")
        #expect(monitor.entry(id: id)?.note?.contains("Local sample") == true)
        #expect(monitor.entry(id: id)?.mimeType == "image/png")
        #expect(transport.callCount == 0)
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "ftp://x.example/a", "not a url"])
    func unsupportedSchemesAreRefused(url: String) async {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        await #expect(throws: NetworkMonitorError.self) {
            _ = try await monitor.fetchContent(url, trigger: "image", source: "native", parentID: nil, userAgent: deviceUA)
        }
        #expect(transport.callCount == 0)
        if case .failed? = monitor.entries.last?.state {} else { Issue.record("expected a failed entry") }
    }

    @Test func contentErrorsThrowWithTheStatus() async {
        let transport = FakeTransport()
        transport.respond("https://cdn.example/missing.xml", status: 404, body: "nope")
        let monitor = makeMonitor(transport: transport)
        await #expect(throws: NetworkMonitorError.self) {
            _ = try await monitor.fetchContent("https://cdn.example/missing.xml", trigger: "VAST wrapper", source: "bid", parentID: nil,
                                               userAgent: deviceUA)
        }
        #expect(monitor.entries.last?.state == .completed(status: 404))
    }

    @Test func contentFollowsRedirectsAndReturnsTheFinalBody() async throws {
        let transport = FakeTransport()
        transport.redirect("https://ad.example/tag", to: "https://cdn.example/vast.xml")
        transport.respond("https://cdn.example/vast.xml", body: "<VAST version=\"4.2\"/>")
        let monitor = makeMonitor(transport: transport)
        let (data, id) = try await monitor.fetchContent("https://ad.example/tag", trigger: "VAST wrapper", source: "bid", parentID: nil,
                                                         userAgent: deviceUA)
        #expect(String(decoding: data, as: UTF8.self) == "<VAST version=\"4.2\"/>")
        #expect(monitor.entries.count == 2)
        #expect(monitor.entries[1].parentID == id)
    }

    @Test func oversizedContentFails() async {
        let transport = FakeTransport()
        transport.respond("https://cdn.example/huge.png", data: Data(count: NetworkMonitor.maxContentBytes + 1))
        let monitor = makeMonitor(transport: transport)
        await #expect(throws: NetworkMonitorError.tooLarge(limit: NetworkMonitor.maxContentBytes)) {
            _ = try await monitor.fetchContent("https://cdn.example/huge.png", trigger: "image", source: "native", parentID: nil,
                                               userAgent: deviceUA)
        }
    }

    @Test func prepareMediaResolvesSamplesDataAndRemoteURLs() async throws {
        let monitor = makeMonitor(transport: FailingTransport())
        let sample = await monitor.prepareMedia(SampleURL.video, trigger: "media", source: "VAST", parentID: nil, userAgent: deviceUA)
        #expect(sample.playableURL?.lastPathComponent == "sample-15s.mp4")
        #expect(monitor.entry(id: sample.entryID)?.delivery == .local)

        let data = await monitor.prepareMedia("data:video/mp4;base64,AAAA", trigger: "media", source: "VAST", parentID: nil, userAgent: deviceUA)
        let file = try #require(data.playableURL)
        #expect(file.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: file)

        let remote = await monitor.prepareMedia("https://cdn.example/ad.mp4", trigger: "media", source: "VAST", parentID: nil, userAgent: deviceUA)
        #expect(remote.playableURL?.absoluteString == "https://cdn.example/ad.mp4")
        #expect(monitor.entry(id: remote.entryID)?.state == .pending)
        monitor.finishRendererLoad(remote.entryID, responseBytes: 1234, mimeType: "video/mp4")
        #expect(monitor.entry(id: remote.entryID)?.state == .completed(status: 0))
        #expect(monitor.entry(id: remote.entryID)?.responseBytes == 1234)
    }

    @Test func navigationIsRecordedNeverFollowed() {
        let monitor = makeMonitor(transport: FailingTransport())
        let click = monitor.dispatch(tracker(.click, "https://t.example/click"), userAgent: deviceUA)
        let navigation = monitor.recordNavigation(url: "https://advertiser.example", trigger: "click-through", source: "VAST", parentID: click)
        #expect(monitor.entry(id: navigation)?.category == .navigation)
        #expect(monitor.entry(id: navigation)?.parentID == click)
        #expect(monitor.entry(id: navigation)?.state == .simulated)
        let opened = monitor.recordNavigation(url: "https://advertiser.example", trigger: "click-through", source: "VAST", parentID: click,
                                              openedInBrowser: true)
        #expect(monitor.entry(id: opened)?.delivery == .browser)
    }
}

@MainActor
@Suite("Network monitor: log")
struct MonitorLogTests {
    @Test func publishingIsCoalesced() async throws {
        let monitor = NetworkMonitor(transport: FailingTransport(), clock: ManualClock(), samples: FakeSamples(),
                                     publishInterval: .milliseconds(50))
        for index in 0..<200 { monitor.dispatch(tracker(.event, "https://t.example/\(index)"), userAgent: deviceUA) }
        #expect(monitor.entries.isEmpty, "a burst is not published entry by entry")
        #expect(monitor.liveEntries.count == 200)
        monitor.flush()
        #expect(monitor.entries.count == 200)

        monitor.dispatch(tracker(.event, "https://t.example/late"), userAgent: deviceUA)
        #expect(monitor.entries.count == 200)
        try await Task.sleep(for: .milliseconds(300))
        #expect(monitor.entries.count == 201)
    }

    @Test func capacityDropsTheOldestAndOrphansBecomeRoots() {
        let monitor = makeMonitor(transport: FailingTransport(), capacity: 5)
        let parent = monitor.dispatch(tracker(.win, "https://t.example/win"), userAgent: deviceUA)
        for index in 0..<4 { monitor.dispatch(tracker(.event, "https://t.example/\(index)", parentID: parent), userAgent: deviceUA) }
        monitor.dispatch(tracker(.event, "https://t.example/last"), userAgent: deviceUA)
        #expect(monitor.entries.count == 5)
        #expect(monitor.entries.map(\.sequence) == [2, 3, 4, 5, 6])
        #expect(monitor.entry(id: parent) == nil)
        #expect(monitor.entries.allSatisfy { $0.parentID == nil })
    }

    @Test func duplicateIDsGetANewOne() {
        let monitor = makeMonitor(transport: FailingTransport())
        let request = tracker(.impression, "https://t.example/imp")
        let first = monitor.dispatch(request, userAgent: deviceUA)
        let second = monitor.dispatch(request, userAgent: deviceUA)
        #expect(first == request.id)
        #expect(second != first)
        #expect(Set(monitor.entries.map(\.id)).count == 2)
    }

    @Test func clearRestartsTheSequenceAndDropsLateResults() async {
        let transport = FakeTransport()
        transport.respond("https://slow.example/imp", body: "x", delay: .milliseconds(100))
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real
        monitor.dispatch(tracker(.impression, "https://slow.example/imp"), userAgent: deviceUA)
        monitor.clear()
        #expect(monitor.entries.isEmpty)
        let id = monitor.dispatch(tracker(.loss, "https://t.example/loss"), userAgent: deviceUA)
        await monitor.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(monitor.entries.first?.sequence == 1)
        #expect(monitor.entries.first?.id == id)
        #expect(monitor.entries.count == 1)
    }

    /// Spec "Ordering": a VAST ad played to completion in Simulated mode records its events in order.
    @Test func vastEventsKeepTheirOrder() {
        let monitor = makeMonitor(transport: FailingTransport())
        let events = ["impression", "creativeView", "start", "firstQuartile", "midpoint", "thirdQuartile", "complete"]
        for event in events {
            monitor.dispatch(tracker(event == "impression" ? .impression : .event, "https://t.example/\(event)", trigger: event),
                             userAgent: deviceUA)
        }
        #expect(monitor.entries.map(\.trigger) == events)
        #expect(monitor.entries.map(\.sequence) == Array(1...7))
    }
}
