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
    private static func response(port: UInt16) -> String {
        let beacon = #"<script>setInterval(function () { new Image().src = 'http://127.0.0.1:\#(port)/beat?' + Date.now(); }, 100);</script>"#
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

    private func expectSilence(_ server: EchoServer, after change: String) async throws {
        // Teardown happens in the same turn as the change; allow one SwiftUI update for the view tree.
        try await Task.sleep(for: .milliseconds(200))
        let settled = server.requests.count
        try await Task.sleep(for: .milliseconds(1500))
        #expect(server.requests.count == settled, "\(change): \(server.requests.count - settled) more hits after the change")
    }

    @Test func switchingToSimulatedStopsEveryRealModeWebView() async throws {
        let (harness, server, window) = try await beatingSession()
        defer {
            window.close()
            server.stop()
        }
        harness.session.useSimulatedMode()
        try await expectSilence(server, after: "Simulated")
    }

    @Test func resettingStopsEveryRealModeWebView() async throws {
        let (harness, server, window) = try await beatingSession()
        defer {
            window.close()
            server.stop()
        }
        harness.session.reset()
        try await expectSilence(server, after: "Reset")
    }
}
