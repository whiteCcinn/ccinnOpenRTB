import AppKit
import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// Official Prebid.js from jsDelivr and a real adapter, over the network: run with `CCINN_PREBID_LIVE=<directory>` (the
/// snapshot goes there). Never in CI: it depends on jsDelivr, npm and AppNexus's public test placement.
@MainActor
@Suite("Prebid: live", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CCINN_PREBID_LIVE"] != nil))
struct PrebidLiveTests {
    @Test func theDefaultVersionRunsAnAppNexusAuctionAndTheBidRenders() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CCINN_PREBID_LIVE"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = TemporaryDirectory()
        defer { cache.cleanUp() }
        let session = AdSession()
        let library = PrebidLibrary(cacheDirectory: cache.url, monitor: { session.monitor },
                                    userAgent: { SyncBrowser.default(for: session.device).userAgent(for: session.device) })
        let prebid = PrebidModel(target: session, library: library)
        let harness = WindowHarness(HSplitView {
            SimulatorPane(session: session).frame(width: 760)
            PrebidPane(prebid: prebid, openSyncTab: {})
        }
        .background { PrebidWebView(host: prebid.host).frame(width: 1, height: 1).opacity(0) }
        .background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 1360, height: 860))
        harness.window.appearance = NSAppearance(named: .aqua)
        defer { harness.close() }

        prebid.start()
        #expect(await Wait.until(timeout: .seconds(60)) { !prebid.catalog.isEmpty && prebid.phase == .idle }, "\(prebid.phase)")
        let version = try #require(prebid.defaultVersion)
        #expect(prebid.setup.version == version)
        #expect(prebid.catalog["appnexus"] != nil && prebid.catalog.count > 100, "\(prebid.catalog.count) bidders")

        prebid.runAuction()
        let ended = await Wait.until(timeout: .seconds(40)) { prebid.phase != .running }
        #expect(ended && prebid.phase == .done, "\(prebid.phase)\n\(prebid.timeline.map { "\($0.type) \($0.summary)" }.joined(separator: "\n"))\n\(prebid.warnings)")
        #expect(prebid.loadedVersion?.contains(version) == true, "\(prebid.loadedVersion ?? "nil")")
        let hits = session.monitor.entries.filter { $0.category == .bidRequest }.map(\.url)
        #expect(hits.contains { $0.contains("adnxs.com") }, "\(hits)")
        print("Prebid.js \(version): \(prebid.bids.count) bid(s); timeline:\n" + prebid.timeline.map { "  +\($0.at) \($0.type) \($0.summary)" }.joined(separator: "\n"))
        print("syncs: \(prebid.syncs)\nwarnings: \(prebid.warnings)")
        for entry in session.monitor.entries where entry.category == .bidRequest {
            let sent = session.monitor.requestBody(for: entry.id).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let received = session.monitor.responseBody(for: entry.id).map { String(decoding: $0, as: UTF8.self) } ?? ""
            print("» \(entry.method) \(entry.url)\n  headers: \(entry.requestHeaders)\n  body: \(sent.prefix(3_000))\n  ← \(received.prefix(1_500))")
        }

        if let bid = prebid.bids.first {
            await prebid.render(bid)
            for _ in 0..<500 where session.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
            #expect(session.parsed.candidates.first?.seat == bid.bidderCode)
        }
        try await Task.sleep(for: .seconds(2))
        let view = harness.hosting
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("prebid-tab.png"))
    }
}
