import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// Simulated mode sends nothing, measured on a socket with the real views: every sample (hosts pointed at a loopback
/// server) is rendered by the app's own `AdSlotView` — WebKit creatives, AVPlayer playback, image loads, companions — then
/// every Fire-menu event of the ad and the loss notice are fired. Not one connection may reach the server.
@MainActor
@Suite("Acceptance: Simulated mode, real renderers, zero traffic", .serialized)
struct RenderedSampleZeroTrafficTests {
    nonisolated static let sampleIDs = SampleLibrary.all.map(\.id)

    @Test(arguments: sampleIDs)
    func nothingLeavesTheMachine(sampleID: String) async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let sample = try SampleCopies.pointing(#require(SampleLibrary.sample(id: sampleID)), at: "http://127.0.0.1:\(port)")
        let harness = AcceptanceSession(transport: URLSessionTransport())
        try await harness.render(sample)
        var window: WindowHarness?
        defer { window?.close() }
        if harness.session.renderRequest != nil {
            let size = harness.session.adSize
            window = WindowHarness(AdSlotView(session: harness.session, size: size), size: size)
            // The renderer's own path: the creative loads, the image decodes, or the player reaches its first frame.
            let started = await Wait.until(timeout: .seconds(30)) {
                harness.session.hasFired(.rendered) || harness.monitor.liveEntries.contains { $0.category == .error }
            }
            #expect(started, "\(harness.session.phase): \(harness.monitor.liveEntries.map(\.dumpLine))")
            try await Task.sleep(for: .seconds(1))
            // The renderers' own order: a companion is viewed only after its ad's impression (never before billing).
            let entries = harness.monitor.liveEntries
            if let companion = entries.first(where: { $0.trigger.hasPrefix("VAST companion creativeView") }) {
                let billing = entries.first { $0.category == .billing }?.sequence ?? .max
                let impression = entries.first { $0.category == .impression }?.sequence ?? .max
                #expect(billing < companion.sequence && impression < companion.sequence, "\(entries.map(\.dumpLine))")
            }
            // Every event the Fire menu offers for this ad, then the loss notice.
            for action in FireActions.sections(for: harness.session.prepared).flatMap(\.actions) {
                harness.session.fireManually(action.event)
            }
        }
        harness.session.lose(.lostToHigherBid)
        try await Task.sleep(for: .milliseconds(500))
        await harness.monitor.waitUntilIdle()

        let entries = harness.monitor.liveEntries
        #expect(server.connectionCount == 0, "Simulated mode connected: \(server.requests.map(\.target))\n\(entries.map(\.dumpLine))")
        #expect(entries.allSatisfy { $0.delivery != .network }, "\(entries.map(\.dumpLine))")
        #expect(entries.filter(\.category.isTracker).allSatisfy { $0.state == .simulated }, "\(entries.map(\.dumpLine))")
        if harness.session.prepared?.candidate.lossURL != nil || SampleLibrary.sample(id: sampleID)?.response.contains("lurl") == true {
            #expect(entries.contains { $0.category == .loss && $0.state == .simulated }, "the loss notice is recorded, not sent")
        }
    }
}
