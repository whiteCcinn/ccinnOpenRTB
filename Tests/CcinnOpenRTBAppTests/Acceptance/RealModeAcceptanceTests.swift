import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// Real mode against a loopback echo server, for every sample with an ad: the session's confirmation flow, then every
/// tracker arrives exactly once, with the device's User-Agent and its macros expanded as the specs define them, and a
/// redirecting billing notice is recorded as a child entry (design D9; tracking spec, "Real mode").
@MainActor
@Suite("Acceptance: Real mode against a loopback echo server", .serialized)
struct RealModeAcceptanceTests {
    nonisolated static let sampleIDs = SampleLibrary.all.map(\.id).filter { $0 != "ortb26-no-bid" }

    /// What each macro in a sample template expands to (OpenRTB 2.6 §4.4, OpenRTB 3.0 / AdCOM, VAST 4.2 §6), as a regular
    /// expression over the percent-encoded value.
    private static let macroPatterns: [String: String] = [
        "${AUCTION_PRICE}": #"[0-9]+(\.[0-9]+)?"#, "${OPENRTB_PRICE}": #"[0-9]+(\.[0-9]+)?"#,
        "${AUCTION_ID}": "ccinn-req-[A-Za-z0-9-]+", "${OPENRTB_ID}": "ccinn-req-[A-Za-z0-9-]+",
        "${AUCTION_BID_ID}": "ccinn-resp-[A-Za-z0-9-]+", "${OPENRTB_BID_ID}": "ccinn-resp-[A-Za-z0-9-]+",
        "${AUCTION_IMP_ID}": "1", "${OPENRTB_ITEM_ID}": "1", "${AUCTION_SEAT_ID}": "ccinn-dsp",
        "${AUCTION_CURRENCY}": "USD", "${OPENRTB_CURRENCY}": "USD", "${OPENRTB_MEDIA_ID}": "[A-Za-z0-9-]+",
        "${AUCTION_MIN_TO_WIN}": #"[0-9]*(\.[0-9]+)?"#, "${OPENRTB_MIN_TO_WIN}": #"[0-9]*(\.[0-9]+)?"#,
        "${AUCTION_LOSS}": "[0-9]+", "${OPENRTB_LOSS}": "[0-9]+",
        "${CUSTOM_CLICKTOKEN}": "[A-Za-z0-9]+",
        "[CACHEBUSTING]": "[0-9]{8}",
        // ISO 8601 with milliseconds and the offset, percent-encoded (VAST 4.2 §6.2.1).
        "[TIMESTAMP]": #"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}%3A[0-9]{2}%3A[0-9]{2}\.[0-9]{3}(Z|%2B[0-9]{2}%3A[0-9]{2}|-[0-9]{2}%3A[0-9]{2})"#,
        "[ADPLAYHEAD]": #"[0-9]{2}%3A[0-9]{2}%3A[0-9]{2}\.[0-9]{3}"#,
        "[ERRORCODE]": "[1-9][0-9]{2}",
        "[REASON]": "[0-9]+",
        "[PODSEQUENCE]": "[1-9][0-9]*",
    ]

    /// `template` as a pattern its expansion must match: literal text escaped, each macro replaced by its value pattern.
    static func expansionPattern(for template: String) throws -> NSRegularExpression {
        let token = try NSRegularExpression(pattern: #"\$\{[A-Z0-9_]+(:[A-Za-z0-9]+)?\}|\[[A-Z][A-Z0-9_]*\]"#)
        var pattern = "^"
        var cursor = template.startIndex
        for match in token.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template) else { continue }
            pattern += NSRegularExpression.escapedPattern(for: String(template[cursor..<range.lowerBound]))
            let name = String(template[range])
            pattern += "(" + (macroPatterns[name] ?? "UNEXPECTED-MACRO-\(name)") + ")"
            cursor = range.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(for: String(template[cursor...])) + "$"
        return try NSRegularExpression(pattern: pattern)
    }

    private static func target(_ url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    /// Native markup delivered by the win notice (a test copy of the Native 1.2 sample whose `adm` moves into a `data:`
    /// nurl): its impression, event and click trackers and its navigations hang under the win notice that delivered it,
    /// while the bid response's own billing notice stays a root (decisions.md, "Network relationships").
    @Test func nativeMarkupFromTheWinNoticeHangsUnderIt() async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        var sample = try SampleCopies.pointing(#require(SampleLibrary.sample(id: "ortb26-native12-eventtrackers")), at: base)
        var response = try #require(try JSONSerialization.jsonObject(with: Data(sample.response.utf8)) as? [String: Any])
        var seatbids = try #require(response["seatbid"] as? [[String: Any]])
        var bids = try #require(seatbids[0]["bid"] as? [[String: Any]])
        let adm = try #require(bids[0]["adm"] as? String)
        bids[0]["adm"] = nil
        bids[0]["nurl"] = "data:application/json;base64," + Data(adm.utf8).base64EncodedString()
        seatbids[0]["bid"] = bids
        response["seatbid"] = seatbids
        sample.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)

        let harness = AcceptanceSession(transport: URLSessionTransport())
        try await harness.render(sample)
        guard case .needsRealMode = harness.session.phase else {
            Issue.record("Simulated mode does not fetch the win notice: \(harness.session.phase)")
            return
        }
        try harness.confirmRealMode()
        await harness.waitUntilSettled()
        #expect(harness.session.phase == .ready, "\(harness.session.phase)")
        let driver = LifecycleDriver(harness)
        defer { driver.teardown() }
        #expect(try await driver.run())
        let entries = harness.monitor.liveEntries
        let listing = entries.map(\.dumpLine).joined(separator: "\n")
        let prepared = try #require(harness.session.prepared)
        // The Simulated render recorded the win notice without sending it; the Real render fetched the markup with it.
        let wins = entries.filter { $0.category == .win }
        #expect(wins.count == 2 && wins.first?.delivery == .simulated && wins.last?.delivery == .local, "\(listing)")
        let win = try #require(wins.last, "\(listing)")
        #expect(prepared.markupEntryID == win.id && prepared.markupFromWinNotice)
        #expect(!entries.contains { $0.category == .win && $0.sequence > win.sequence }, "the win notice that delivered the markup is not sent again")
        for entry in entries where [.impression, .viewability, .click, .navigation].contains(entry.category) {
            #expect(entry.parentID == win.id, "\(entry.dumpLine)\n\(listing)")
        }
        #expect(entries.filter { $0.category == .billing }.allSatisfy { $0.parentID == nil }, "\(listing)")
        let audit = NetworkAudit(entries: entries, candidate: prepared.candidate, vast: nil, markupRequestID: win.id)
        #expect(audit.all(driver.actions).isEmpty, "\(audit.all(driver.actions))\n\(listing)")
    }

    @Test(arguments: sampleIDs)
    func everyTrackerArrivesOnceWithItsMacrosExpanded(sampleID: String) async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        var sample = try SampleCopies.pointing(try #require(SampleLibrary.sample(id: sampleID)), at: base)
        // The billing notice redirects once: the hop must be recorded as its child.
        for path in ["/rtb/bill", "/ortb30/bill"] {
            sample.response = sample.response.replacingOccurrences(of: base + path, with: base + "/redirect" + path)
        }

        let harness = AcceptanceSession(transport: URLSessionTransport())
        harness.session.device = try #require(DeviceCatalog.device(id: AcceptanceSession.deviceID(for: sample)))
        await harness.session.load(sample, render: false)
        // The confirmation lists the bid's tracker hosts before anything is sent; cancelling keeps Simulated mode.
        harness.session.requestRealMode()
        #expect(harness.session.realModeConfirmation?.summary.hosts.map(\.name).contains { $0.hasPrefix("127.0.0.1") } == true,
                "\(String(describing: harness.session.realModeConfirmation?.summary))")
        harness.session.cancelRealMode()
        #expect(harness.session.mode == .simulated)
        try harness.confirmRealMode()
        #expect(server.connectionCount == 0, "confirming sends nothing by itself")

        harness.session.render()
        await harness.waitUntilSettled()
        #expect(harness.session.phase == .ready, "\(harness.session.phase)")
        let driver = LifecycleDriver(harness)
        defer { driver.teardown() }
        #expect(try await driver.run())
        // Real-mode script trackers (Native jstracker, eventtrackers / AdCOM events with method 2) run in hidden web views.
        let injector = ScriptTrackerInjector(host: harness.session.rendererHost)
        defer { injector.teardown() }
        let scripts = harness.session.scriptTrackers
        injector.inject(scripts)
        let scriptsFinished = await Wait.until(timeout: .seconds(20)) {
            scripts.allSatisfy { harness.monitor.entry(id: $0.entryID).map { $0.state != .pending } ?? false }
        }
        #expect(scriptsFinished)
        try await Task.sleep(for: .milliseconds(500))
        await harness.monitor.waitUntilIdle()

        let entries = harness.monitor.liveEntries
        let listing = entries.map(\.dumpLine).joined(separator: "\n")
        // Every request the session made to the server, and nothing else, arrived — each exactly once. A script tracker's
        // entry is its injection; the load it makes is its child (one row per request on the wire).
        let made = entries.filter { ($0.delivery == .network || $0.delivery == .renderer) && !$0.isScript && $0.url.hasPrefix(base) }
            .compactMap { Self.target($0.url) }
        for script in entries where script.isScript && script.url.hasPrefix(base) {
            let loads = entries.filter { $0.parentID == script.id && $0.url == script.url }
            #expect(loads.count == 1 && loads.allSatisfy { $0.state == .completed(status: 200) }, "\(script.dumpLine)\n\(listing)")
        }
        let received = server.requests.map(\.target)
        #expect(made.sorted() == received.sorted(), "made:\n\(made.sorted().joined(separator: "\n"))\nreceived:\n\(received.sorted().joined(separator: "\n"))")
        #expect(server.connectionCount == received.count)

        let prepared = try #require(harness.session.prepared)
        let trackers = entries.filter { $0.category.isTracker && !$0.isScript && $0.redirectLocation == nil && $0.url.hasPrefix(base) }
        #expect(!trackers.isEmpty)
        for tracker in trackers {
            #expect(tracker.delivery == .network, "\(tracker.dumpLine)")
            #expect(tracker.unknownMacros.isEmpty, "\(tracker.dumpLine): unknown \(tracker.unknownMacros)")
            let pattern = try Self.expansionPattern(for: tracker.template)
            #expect(pattern.firstMatch(in: tracker.url, range: NSRange(tracker.url.startIndex..., in: tracker.url)) != nil,
                    "\(tracker.template)\n→ \(tracker.url)")
            if tracker.template.contains("price=${AUCTION_PRICE}") || tracker.template.contains("price=${OPENRTB_PRICE}") {
                let price = URLComponents(string: tracker.url)?.queryItems?.first { $0.name == "price" }?.value.flatMap(Double.init)
                #expect(price == prepared.candidate.price, "the clearing price defaults to the bid price: \(tracker.url)")
            }
            if let request = server.requests.first(where: { Self.target(tracker.url) == $0.target }) {
                #expect(request.headers["user-agent"] == harness.session.device.userAgent, "trackers carry the device's User-Agent")
            }
        }
        if sampleID.contains("vpaid") {
            #expect(trackers.contains { $0.category == .error && $0.url.contains("code=901") }, "\(listing)")
        }

        let audit = NetworkAudit(entries: entries, candidate: prepared.candidate, vast: prepared.vast, markupRequestID: prepared.markupEntryID)
        let violations = audit.all(driver.actions)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))\n\(listing)")

        // The redirecting billing notice: the root answered 302, the hop is its child and completed.
        if let billing = entries.first(where: { $0.category == .billing && $0.redirectLocation == nil }) {
            #expect(billing.state == .completed(status: 302), "\(billing.dumpLine)")
            let hops = entries.filter { $0.parentID == billing.id }
            #expect(hops.count == 1 && hops.allSatisfy { $0.redirectLocation?.hasPrefix("/landed/") == true && $0.state == .completed(status: 200) },
                    "\(listing)")
        }
    }
}
