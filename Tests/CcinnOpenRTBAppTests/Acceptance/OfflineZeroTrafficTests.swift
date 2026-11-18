import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// Safety review: Offline loads nothing — measured on a socket with the real views. Every sample, its hosts AND its
/// built-in content (media, images, VAST tags) served from a loopback server, is rendered Offline by the app's own
/// `AdSlotView`, every Fire-menu event and the loss notice are fired: not one connection. The blocked content is recorded
/// (`offline`), so the run proves something was there to block.
@MainActor
@Suite("Acceptance: Offline, real renderers, zero connections", .serialized)
struct OfflineZeroTrafficTests {
    nonisolated static let sampleIDs = SampleLibrary.all.map(\.id)

    @Test(arguments: sampleIDs)
    func offlineConnectsToNothing(sampleID: String) async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let original = try #require(SampleLibrary.sample(id: sampleID))
        let sample = try SampleCopies.remoteContent(original, at: "http://127.0.0.1:\(port)")
        let harness = AcceptanceSession(transport: URLSessionTransport())
        harness.session.choose(.offline)
        try await harness.render(sample)
        var window: WindowHarness?
        defer { window?.close() }
        if harness.session.renderRequest != nil {
            let size = harness.session.adSize
            window = WindowHarness(AdSlotView(session: harness.session, size: size), size: size)
            try await Task.sleep(for: .seconds(2))
            for action in FireActions.sections(for: harness.session.prepared).flatMap(\.actions) {
                harness.session.fireManually(action.event)
            }
        }
        harness.session.lose(.lostToHigherBid)
        try await Task.sleep(for: .milliseconds(500))
        await harness.monitor.waitUntilIdle()

        let entries = harness.monitor.liveEntries
        #expect(server.connectionCount == 0, "Offline connected: \(server.requests.map(\.target))\n\(entries.map(\.dumpLine))")
        #expect(entries.allSatisfy { $0.delivery != .network }, "\(entries.map(\.dumpLine))")
        if original.response.contains(SampleURL.scheme + "://") {
            // Content the session fetches is recorded Offline; an HTML creative's own loads are blocked by its sandbox.
            #expect(entries.contains { $0.delivery == .offline || $0.delivery == .blocked },
                    "the sample's content was there to block: \(entries.map(\.dumpLine))")
        }
    }

    /// The control: the same rewritten sample in Simulated mode does reach the server for its content, so the Offline
    /// run above measured real content requests.
    @Test func simulatedModeFetchesTheSameContent() async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let original = try #require(SampleLibrary.sample(id: "ortb30-video"))
        #expect(original.response.contains(SampleURL.scheme + "://"))
        let harness = AcceptanceSession(transport: URLSessionTransport())
        try await harness.render(try SampleCopies.remoteContent(original, at: "http://127.0.0.1:\(port)"))
        let size = harness.session.adSize
        let window = WindowHarness(AdSlotView(session: harness.session, size: size), size: size)
        defer { window.close() }
        #expect(await Wait.until(timeout: .seconds(10)) { server.connectionCount > 0 }, "\(original.id): \(harness.monitor.liveEntries.map(\.dumpLine))")
        #expect(await Wait.until(timeout: .seconds(10)) { server.requests.contains { $0.target.hasPrefix("/sample/") } },
                "\(server.requests.map(\.target))")
    }
}
