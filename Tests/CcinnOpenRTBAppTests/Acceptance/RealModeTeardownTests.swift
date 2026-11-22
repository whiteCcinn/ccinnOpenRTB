import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// Safety review: a Real-mode script tracker kept reaching the network after the switch back to Simulated (7 loopback
/// hits in 4 s: its hidden web view runs up to 15 s plus a 2 s linger). Switching mode, rendering again or resetting
/// tears every Real-mode web view down at once: not one more hit.
@MainActor
@Suite("Real mode ends at once", .serialized)
struct RealModeTeardownTests {
    /// A jstracker that beats every 100 ms and never finishes loading (an image the server holds): otherwise its web view
    /// ends by itself 2 s after the load (the linger), and the test could not tell a teardown from that.
    private static func response(port: UInt16) -> String {
        let beacon = #"<img src="http://127.0.0.1:\#(port)/hold/pixel"><script>setInterval(function () { new Image().src = 'http://127.0.0.1:\#(port)/beat?' + Date.now(); }, 100);</script>"#
        let native = """
        {"native":{"ver":"1.2","assets":[{"id":1,"title":{"text":"Beat"}}],"link":{"url":"https://adv.example/"},
          "jstracker":\(JSONValue.string(beacon).serialized())}}
        """
        let adm = JSONValue.string(native).serialized()
        return """
        {"id": "req-1", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "impid": "1", "price": 1, "mtype": 4, "adm": \(adm)}]}]}
        """
    }

    private func beatingSession() async throws -> (AcceptanceSession, EchoServer, WindowHarness) {
        let server = try EchoServer()
        let port = try #require(await server.start())
        let harness = AcceptanceSession(transport: URLSessionTransport())
        await harness.session.load(Sample(id: "beat", title: "beat", group: "test", response: Self.response(port: port)), render: false)
        try harness.confirmRealMode()
        harness.session.render()
        await harness.waitUntilSettled()
        let size = harness.session.adSize
        let window = WindowHarness(AdSlotView(session: harness.session, size: size), size: size)
        let beating = await Wait.until(timeout: .seconds(20)) { server.requests.filter { $0.target.hasPrefix("/beat") }.count >= 3 }
        #expect(beating, "the Real-mode jstracker runs: \(server.requests.map(\.target))")
        return (harness, server, window)
    }

    /// The page stopped: no beacon was *made* after the change. Each beacon carries the page's `Date.now()`, so a beacon
    /// made before teardown that lands late (on a loaded 3-core CI runner one arrived after more than 1 s) is told apart
    /// from a page still running, which would make about 20 in the last 2 s of the window. Teardown happens in the
    /// change's turn on the UI side; the web content process acts on it over IPC, which a starved runner has delayed by
    /// just over 1 s, so beacons made within 2 s of the change are allowed.
    private func expectSilence(_ server: EchoServer, after change: String) async throws {
        let changedAt = Date().timeIntervalSince1970 * 1000
        try await Task.sleep(for: .milliseconds(4000))
        let made = beaconTimes(server)
        let afterTeardown = made.filter { $0 > changedAt + 2000 }
        #expect(afterTeardown.isEmpty, "\(change): \(afterTeardown.count) beacons made more than 2 s after the change (\(made.count) in all)")
        #expect(!made.isEmpty, "\(change): the beacons carry the page's clock")
    }

    /// The script tracker's own page, hidden (not in any window), is judged in two parts.
    ///
    /// - The app's part, exactly: the tracker is torn down in the change's own turn, before anything is awaited — its
    ///   entry already carries the teardown's outcome.
    /// - WebKit's part, loosely: WebKit runs a hidden web view's content process at background priority (its timers tick
    ///   once a second: CI's late beacons were 1000 ms apart), so on a starved 3-core runner it acted on the teardown
    ///   2–4 s late, while the visible creative and companion stop within `expectSilence`'s 2 s. The page must still be
    ///   silent long before the regression this guards, a tracker running to its 15 s timeout plus the 2 s linger.
    private func expectTrackerStopped(_ harness: AcceptanceSession, _ server: EchoServer, after change: String,
                                      _ perform: () -> Void) async throws {
        let trackers = harness.monitor.liveEntries.filter(\.isScript).map(\.id)
        try #require(!trackers.isEmpty, "the jstracker has an entry")
        #expect(trackers.allSatisfy { harness.monitor.entry(id: $0)?.state == .pending }, "the jstracker is still loading (its pixel is held)")

        let changedAt = Date().timeIntervalSince1970 * 1000
        perform()
        for id in trackers {
            #expect(harness.monitor.entry(id: id)?.state == .failed(ScriptTrackerInjector.removedBeforeLoad),
                    "\(change): the tracker is torn down in the change's own turn")
        }

        try await Task.sleep(for: .milliseconds(8000))
        let made = beaconTimes(server).map { Int($0 - changedAt) }
        let late = made.filter { $0 > 6000 }
        #expect(late.isEmpty, "\(change): the hidden tracker page still made beacons \(late) ms after the change (last: \(made.suffix(12)))")
        #expect(!made.isEmpty, "\(change): the beacons carry the page's clock")
    }

    @Test func switchingToSimulatedStopsEveryRealModeWebView() async throws {
        let (harness, server, window) = try await beatingSession()
        defer {
            window.close()
            server.stop()
        }
        try await expectTrackerStopped(harness, server, after: "Simulated") { harness.session.useSimulatedMode() }
    }

    /// The HTML creative itself loads freely in Real mode; leaving Real (to Simulated or Offline) closes its network at once.
    @Test(arguments: ["simulated", "offline"])
    func leavingRealStopsTheHTMLCreativesOwnLoads(_ change: String) async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let adm = JSONValue.string(#"<script>setInterval(function () { new Image().src = 'http://127.0.0.1:\#(port)/creative?' + Date.now(); }, 100);</script>"#).serialized()
        let response = """
        {"id": "req-1", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "impid": "1", "price": 1, "mtype": 1, "w": 320, "h": 50, "adm": \(adm)}]}]}
        """
        let harness = AcceptanceSession(transport: URLSessionTransport())
        await harness.session.load(Sample(id: "creative", title: "creative", group: "test", response: response), render: false)
        try harness.confirmRealMode()
        harness.session.render()
        await harness.waitUntilSettled()
        let size = harness.session.adSize
        let window = WindowHarness(AdSlotView(session: harness.session, size: size), size: size)
        defer { window.close() }
        let loading = await Wait.until(timeout: .seconds(20)) { server.requests.filter { $0.target.hasPrefix("/creative") }.count >= 3 }
        #expect(loading, "the Real-mode creative loads: \(server.requests.map(\.target))")
        harness.session.choose(change == "offline" ? .offline : .simulated)
        try await expectSilence(server, after: change)
    }

    /// Safety review B1 (on 0864bf9): an HTML VAST companion created in Real mode (its sandbox off) kept beaconing after
    /// the switch to Simulated or Offline. It reloads with the sandbox on as soon as the mode leaves Real, like the HTML ad.
    @Test(arguments: ["simulated", "offline"])
    func leavingRealStopsAnHTMLCompanionsOwnLoads(_ change: String) async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let beacon = "<script>setInterval(function () { new Image().src = 'http://127.0.0.1:\(port)/companion?' + Date.now(); }, 100);</script>"
        let vast = """
        <VAST version="3.0"><Ad id="1"><InLine><AdSystem>x</AdSystem><AdTitle>t</AdTitle><Impression>https://imp.example/i</Impression>
        <Creatives><Creative><Linear><Duration>00:00:15</Duration><MediaFiles>
        <MediaFile type="video/mp4" delivery="progressive" width="1280" height="720">ccinn-sample://media/sample-15s.mp4</MediaFile></MediaFiles></Linear></Creative>
        <Creative><CompanionAds><Companion width="300" height="250"><HTMLResource><![CDATA[\(beacon)]]></HTMLResource></Companion></CompanionAds></Creative>
        </Creatives></InLine></Ad></VAST>
        """
        let adm = JSONValue.string(vast).serialized()
        let response = """
        {"id": "req-1", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "impid": "1", "price": 1, "mtype": 2, "adm": \(adm)}]}]}
        """
        let harness = AcceptanceSession(transport: URLSessionTransport())
        await harness.session.load(Sample(id: "companion", title: "companion", group: "test", response: response), render: false)
        try harness.confirmRealMode()
        harness.session.render()
        await harness.waitUntilSettled()
        let size = harness.session.adSize
        let window = WindowHarness(AdSlotView(session: harness.session, size: size), size: size)
        defer { window.close() }
        let beating = await Wait.until(timeout: .seconds(25)) { server.requests.filter { $0.target.hasPrefix("/companion") }.count >= 3 }
        #expect(beating, "the Real-mode companion loads: \(server.requests.map(\.target))")
        harness.session.choose(change == "offline" ? .offline : .simulated)
        try await expectSilence(server, after: change)
    }

    /// When each beacon was made, by the page's own clock (`?<Date.now()>`).
    private func beaconTimes(_ server: EchoServer) -> [Double] {
        server.requests.compactMap { request -> Double? in
            guard let mark = request.target.firstIndex(of: "?") else { return nil }
            return Double(request.target[request.target.index(after: mark)...])
        }
    }

    @Test func resettingStopsEveryRealModeWebView() async throws {
        let (harness, server, window) = try await beatingSession()
        defer {
            window.close()
            server.stop()
        }
        try await expectTrackerStopped(harness, server, after: "Reset") { harness.session.reset() }
    }
}
