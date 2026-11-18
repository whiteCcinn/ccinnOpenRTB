import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// Safety review 5 and the lead's single-gate invariant: every byte that reaches the network goes through the monitor's
/// dispatch policy and is recorded — the media player's byte ranges and redirects included. Every sample, its hosts and its
/// built-in content (media, images, VAST tags) served from a loopback server, is rendered in Simulated mode by the app's
/// own views (WebKit, AVPlayer, image loads), with every Fire event and the loss notice. Each request the server saw must
/// be a recorded, sent entry: one it saw that no entry records went around the gate.
@MainActor
@Suite("Acceptance: one gate to the network", .serialized)
struct SingleGateAcceptanceTests {
    nonisolated static let sampleIDs = SampleLibrary.all.map(\.id)

    @Test(arguments: sampleIDs)
    func everyRequestOnTheWireIsARecordedEntry(sampleID: String) async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let sample = try SampleCopies.remoteContent(try #require(SampleLibrary.sample(id: sampleID)), at: base)
        let harness = AcceptanceSession(transport: URLSessionTransport())
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
        let sent = entries.filter { $0.delivery == .network && $0.url.hasPrefix(base) }
        // Recorded sends per target (path and query), against what the wire saw.
        var recorded: [String: Int] = [:]
        for entry in sent { recorded[String(entry.url.dropFirst(base.count)), default: 0] += 1 }
        var seen: [String: Int] = [:]
        for request in server.requests { seen[request.target, default: 0] += 1 }
        for (target, count) in seen {
            #expect(count <= recorded[target] ?? 0,
                    "\(sampleID): \(count)× \(target) on the wire, \(recorded[target] ?? 0) recorded\n\(entries.map(\.dumpLine).joined(separator: "\n"))")
        }
        #expect(server.connectionCount == server.requests.count, "one request per connection: nothing half-sent")
        // Not vacuous: what the session records as sent reaches this server (media, images, tags of the sample).
        if !sent.isEmpty { #expect(!server.requests.isEmpty, "\(sampleID): recorded sends never reached the server") }
        if sampleID == "ortb30-video" || sampleID.contains("vast4") {
            #expect(server.requests.contains { $0.target.hasPrefix("/sample/media/") }, "\(sampleID): the player's media went through the gate")
        }
        // Simulated mode: no tracker among them.
        #expect(sent.allSatisfy { !$0.category.isTracker }, "\(sent.map(\.dumpLine))")
    }
}
