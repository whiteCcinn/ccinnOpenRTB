import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

/// A transport that must never be reached from these UI-level tests.
private struct UnreachableTransport: HTTPTransport {
    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        Issue.record("unexpected request to \(request.url)")
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
@Suite("Network registry")
struct NetworkRegistryTests {
    private func monitor() -> NetworkMonitor {
        NetworkMonitor(transport: UnreachableTransport(), publishInterval: .zero)
    }

    @Test func theMostRecentlyFocusedWindowWins() {
        let registry = NetworkRegistry()
        let first = monitor()
        let second = monitor()
        #expect(registry.activeMonitor == nil)
        registry.activate(first)
        registry.activate(second)
        #expect(registry.activeMonitor === second)
        registry.activate(first)
        #expect(registry.activeMonitor === first)
        #expect(registry.registered.map(ObjectIdentifier.init) == [ObjectIdentifier(first), ObjectIdentifier(second)])
    }

    @Test func closingTheActiveWindowFallsBackToThePreviousOne() {
        let registry = NetworkRegistry()
        let first = monitor()
        let second = monitor()
        registry.activate(first)
        registry.activate(second)
        registry.unregister(second)
        #expect(registry.activeMonitor === first)
        registry.unregister(first)
        #expect(registry.activeMonitor == nil)
        #expect(registry.registered.isEmpty)
    }

    @Test func monitorsAreNotKeptAliveByTheHistory() {
        let registry = NetworkRegistry()
        weak var released: NetworkMonitor?
        do {
            let transient = monitor()
            released = transient
            registry.activate(transient)
            registry.activate(monitor())
        }
        // Only the active monitor is held strongly; the earlier one is gone.
        #expect(released == nil)
        #expect(registry.registered.count == 1)
    }
}

@Suite("Macro highlighting")
struct MacroHighlighterTests {
    @Test func templateMacrosAreColouredByOutcome() {
        let entry = NetworkEntry(sequence: 1, category: .error, trigger: "error", source: "VAST",
                                 template: "https://t.example/e?c=[ERRORCODE]&p=${AUCTION_PRICE}&x=[FOO]",
                                 url: "https://t.example/e?c=405&p=1.2&x=[FOO]", state: .simulated,
                                 replacedMacros: ["[ERRORCODE]", "${AUCTION_PRICE}"], unknownMacros: ["[FOO]"])
        let template = MacroHighlighter.template(entry)
        let colored = template.runs.filter { $0.foregroundColor != nil }.map { String(template[$0.range].characters) }
        #expect(colored == ["[ERRORCODE]", "${AUCTION_PRICE}", "[FOO]"])
        let expanded = MacroHighlighter.expanded(entry)
        let leftover = expanded.runs.filter { $0.foregroundColor != nil }.map { String(expanded[$0.range].characters) }
        #expect(leftover == ["[FOO]"])
    }

    @Test func hugeURLsAreBounded() {
        let long = "https://t.example/?" + String(repeating: "a", count: 100_000)
        #expect(MacroHighlighter.highlight(long) { _ in .red }.characters.count < 20_010)
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test func offsetsAndDurationsNeverTrap() {
        #expect(Format.offset(1.2345) == "+1,235" || Format.offset(1.2345) == "+1235")
        #expect(Format.offset(.infinity) == "—")
        #expect(Format.offset(1e300).hasPrefix("+"))
        #expect(Format.duration(seconds: nil) == "—")
        #expect(Format.duration(milliseconds: .nan) == "—")
        #expect(Format.duration(milliseconds: 1e300).hasSuffix("s"))
        #expect(Format.bytes(nil) == "—")
    }

    @Test func statusTextFollowsTheState() {
        func entry(_ state: NetworkEntryState) -> NetworkEntry {
            NetworkEntry(sequence: 1, category: .impression, trigger: "t", source: "s", template: "u", url: "u", state: state)
        }
        #expect(Theme.statusText(for: entry(.completed(status: 302))) == "302")
        #expect(Theme.statusText(for: entry(.completed(status: 0))) == "loaded")
        #expect(Theme.statusText(for: entry(.blocked)) == "blocked")
        #expect(Theme.statusText(for: entry(.failed("x"))) == "failed")
    }
}

@MainActor
@Suite("Demo session")
struct NetworkDemoTests {
    /// The demo used for screenshots exercises every delivery kind without touching the network.
    @Test func demoCoversTheWindowAndStaysOffline() async {
        let monitor = NetworkMonitor(transport: DemoTransport(), samples: StubSamples(), publishInterval: .zero)
        await NetworkDemo.populate(monitor)
        let deliveries = Set(monitor.entries.map(\.delivery))
        #expect(deliveries.isSuperset(of: [.simulated, .network, .blocked, .local]))
        #expect(monitor.entries.contains { $0.isRedirectHop })
        #expect(monitor.entries.contains { $0.category == .navigation })
        #expect(monitor.mode == .simulated)
        let tree = NetworkTree.build(monitor.entries)
        #expect(tree.count < monitor.entries.count)
    }

    private struct StubSamples: SampleMediaProviding {
        func fileURL(for asset: SampleAsset) async throws -> URL {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(asset.fileName)")
            try Data("x".utf8).write(to: file)
            return file
        }
    }
}

@Suite("Network presentation")
struct NetworkPresentationTests {
    private func entry(_ category: TrackerCategory, delivery: NetworkDelivery = .network, state: NetworkEntryState = .completed(status: 200),
                       headers: [String: String] = ["User-Agent": "UA"], asSent: Bool = false) -> NetworkEntry {
        NetworkEntry(sequence: 1, category: category, trigger: "t", source: "s", template: "https://x/", url: "https://x/", state: state,
                     requestHeaders: headers, delivery: delivery, requestHeadersAsSent: asSent)
    }

    /// Content is fetched to render the ad (in both modes): it carries its own badge, never one that looks like a tracker's.
    @Test func contentHasItsOwnBadgeTrackersKeepTheirCategory() {
        let content = NetworkPresentation.categoryBadge(for: entry(.content))
        #expect(content.text == "CONTENT")
        #expect(content.isContent)
        for category in TrackerCategory.allCases where category != .content {
            let badge = NetworkPresentation.categoryBadge(for: entry(category))
            #expect(!badge.isContent)
            #expect(badge.text != "CONTENT")
        }
    }

    @Test func theSessionStateNamesOffline() {
        #expect(NetworkPresentation.session(mode: .simulated, offline: false).title == "Simulated")
        #expect(NetworkPresentation.session(mode: .real, offline: false).title == "Real")
        let offline = NetworkPresentation.session(mode: .simulated, offline: true)
        #expect(offline.title == "Offline")
        #expect(offline.subtitle.contains("not sent"))
        #expect(offline.systemImage == Theme.icon(for: .offline))
    }

    @Test func headersSayWhetherTheyWentOverTheWire() {
        #expect(NetworkPresentation.requestHeadersTitle(for: entry(.content, asSent: true)) == "Request Headers (as sent)")
        #expect(NetworkPresentation.requestHeadersTitle(for: entry(.impression, delivery: .simulated, state: .simulated))
            == "Request Headers (not sent)")
        #expect(NetworkPresentation.requestHeadersTitle(for: entry(.content, delivery: .offline, state: .blocked)) == "Request Headers (not sent)")
        #expect(NetworkPresentation.requestHeadersTitle(for: entry(.content, state: .pending)) == "Request Headers (to be sent)")
        #expect(NetworkPresentation.requestHeadersTitle(for: entry(.content, state: .failed("refused"))) == "Request Headers (planned)")
    }

    /// Offline requests are a mode of their own: listed in the Mode filter, and the filter finds them.
    @Test func offlineIsFilterable() {
        #expect(NetworkDelivery.allCases.contains(.offline))
        #expect(NetworkDelivery.offline.label == "Offline")
        let entries = [entry(.content, delivery: .offline, state: .blocked), entry(.content), entry(.impression, delivery: .simulated, state: .simulated)]
        let filter = NetworkFilter(deliveries: [.offline])
        #expect(filter.apply(entries).map(\.delivery) == [.offline])
    }
}
