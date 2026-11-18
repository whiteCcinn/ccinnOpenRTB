import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// End-to-end acceptance on the real kit, the real session and the real renderer models, for every built-in sample
/// (decisions.md, "Network relationships"; design D9). Test copies of the samples point every host at a loopback server,
/// so "nothing is sent" is measured on a socket, not inferred from the monitor's own bookkeeping.
///
/// Set `CCINN_ACCEPTANCE_DUMP=<dir>` to also write each sample's network entries there (evidence for reviews).
@MainActor
@Suite("Acceptance: every sample, end to end", .serialized)
struct SampleAcceptanceTests {
    nonisolated static let sampleIDs = SampleLibrary.all.map(\.id)

    /// What a sample does when rendered in Simulated mode.
    private static func expectedPhase(_ sample: Sample) -> String {
        switch sample.id {
        case "ortb26-no-bid": "noBid"
        case "ortb25-nurl-markup": "needsRealMode"
        default: "ready"
        }
    }

    private static func name(of phase: RenderPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .preparing: "preparing"
        case .ready: "ready"
        case .noBid: "noBid"
        case .needsRealMode: "needsRealMode"
        case .failed: "failed"
        case .lost: "lost"
        }
    }

    private static func dump(_ entries: [NetworkEntry], sampleID: String, suffix: String) {
        guard let directory = ProcessInfo.processInfo.environment["CCINN_ACCEPTANCE_DUMP"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = entries.map(\.dumpLine).joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: folder.appendingPathComponent("\(sampleID)-\(suffix).txt"))
    }

    // MARK: Simulated mode: relationships, lifecycle order, zero traffic

    /// Every sample, Simulated mode, the full lifecycle through the real renderer models: no connection reaches the
    /// loopback server, every tracker is recorded as simulated, and the entries follow the relationship rules.
    @Test(arguments: sampleIDs)
    func simulatedModeFollowsTheRulesAndSendsNothing(sampleID: String) async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let sample = try SampleCopies.pointing(try #require(SampleLibrary.sample(id: sampleID)), at: "http://127.0.0.1:\(port)")
        let harness = AcceptanceSession(transport: URLSessionTransport())
        try await harness.render(sample)
        #expect(Self.name(of: harness.session.phase) == Self.expectedPhase(sample), "\(harness.session.phase)")

        let driver = LifecycleDriver(harness)
        defer { driver.teardown() }
        let played = try await driver.run()
        #expect(played == (Self.expectedPhase(sample) == "ready"))
        // Anything the creative or a tracker tried to send would have connected by now.
        try await Task.sleep(for: .milliseconds(500))
        await harness.monitor.waitUntilIdle()

        let entries = harness.monitor.liveEntries
        Self.dump(entries, sampleID: sampleID, suffix: "simulated")
        let listing = entries.map(\.dumpLine).joined(separator: "\n")
        #expect(server.connectionCount == 0, "Simulated mode connected \(server.connectionCount)×: \(server.requests.map(\.target))")
        #expect(entries.allSatisfy { $0.delivery != .network }, "sent by the monitor:\n\(listing)")
        let trackers = entries.filter { $0.category.isTracker }
        #expect(trackers.allSatisfy { $0.state == .simulated && $0.delivery == .simulated }, "\(listing)")
        let creative = entries.filter { $0.category == .creative }
        #expect(creative.allSatisfy { $0.state == .blocked || ["ccinn-sample", "data"].contains(URLText.scheme($0.url) ?? "") },
                "the creative's own network is blocked (built-in sample images are served locally):\n\(listing)")
        #expect(!creative.contains { $0.url.contains("${") }, "the exchange substitutes OpenRTB macros in adm:\n\(listing)")

        guard played, let prepared = harness.session.prepared else { return }
        let audit = NetworkAudit(entries: entries, candidate: prepared.candidate, vast: prepared.vast, markupRequestID: prepared.markupEntryID)
        let violations = audit.all(driver.actions)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))\n\(listing)")
        #expect(entries.contains { $0.category == .billing } == (prepared.candidate.billingURL != nil && !sampleID.contains("vpaid")),
                "billing fires on .rendered, and a VAST ad that never plays never renders")
        if case .vast = prepared.candidate.markup, !sampleID.contains("vpaid") {
            for event in ["start", "firstQuartile", "midpoint", "thirdQuartile", "complete"] {
                #expect(entries.contains { $0.trigger.hasPrefix("VAST \(event)") }, "no \(event) tracker:\n\(listing)")
            }
        }
        // `[ADPLAYHEAD]` is the playhead the tracker fired at (progress offsets: at or just past the offset).
        for entry in entries where entry.trigger.hasPrefix("VAST progress") && entry.template.contains("[ADPLAYHEAD]") {
            let playhead = entry.url.range(of: #"\d{2}%3A\d{2}%3A\d{2}\.\d{3}"#, options: .regularExpression).map { String(entry.url[$0]) }
            #expect(playhead != nil, "[ADPLAYHEAD] is HH:MM:SS.mmm: \(entry.url)")
            if let offset = entry.trigger.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression).map({ String(entry.trigger[$0]) }) {
                #expect(playhead.map { $0.replacingOccurrences(of: "%3A", with: ":") >= offset } == true, "\(entry.dumpLine)")
            }
        }
    }

    /// VPAID-only VAST is never executed: error 901 for the ad, no billing and no impression.
    @Test func vpaidOnlyReports901AndNeverRenders() async throws {
        let harness = AcceptanceSession(transport: CountingTransport())
        try await harness.render(try #require(SampleLibrary.sample(id: "ortb26-vast30-vpaid-only")))
        let driver = LifecycleDriver(harness)
        defer { driver.teardown() }
        _ = try await driver.run()
        let entries = harness.monitor.liveEntries
        let errors = entries.filter { $0.category == .error }
        #expect(errors.count == 1 && errors.allSatisfy { $0.url.contains("code=901") }, "\(entries.map(\.dumpLine))")
        #expect(!entries.contains { $0.category == .billing || $0.category == .impression })
    }
}
