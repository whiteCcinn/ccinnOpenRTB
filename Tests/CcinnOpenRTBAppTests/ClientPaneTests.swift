import AppKit
import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

private let endpoint = "https://ssp.example/openrtb2/auction"
private let bidRequest = """
{"id":"req-1","imp":[{"id":"1","video":{"w":640,"h":360,"mimes":["video/mp4"]},"instl":1,"rwdd":1}],"app":{"bundle":"com.example.game"},"device":{"ua":"x","ifa":"00000000-0000-0000-0000-000000000000"}}
"""
private let bidResponse = """
{"id":"req-1","cur":"USD","seatbid":[{"seat":"dsp","bid":[{"id":"b1","impid":"1","price":2.5,"mtype":2,"burl":"https://bill.dsp.example/b?p=${AUCTION_PRICE}","adm":"<VAST version=\\"4.2\\"><Ad id=\\"a\\"><InLine><AdSystem>DSP</AdSystem><AdTitle>Rewarded</AdTitle><Impression><![CDATA[https://imp.dsp.example/i]]></Impression><Creatives><Creative><Linear skipoffset=\\"00:00:05\\"><Duration>00:00:15</Duration><MediaFiles><MediaFile delivery=\\"progressive\\" type=\\"video/mp4\\" width=\\"1280\\" height=\\"720\\"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>"}]}]}
"""

/// The Client tab drawn in a window: every phase renders (smoke), and with `CCINN_CLIENT_SNAPSHOTS=<dir>` the tab next
/// to the device after a real send is written as a PNG, for looking at it.
@MainActor
@Suite("Client pane", .serialized)
struct ClientPaneTests {
    @MainActor
    private struct Fixture {
        let transport = ScriptedTransport()
        let session: AdSession
        let client: ClientModel
        let directory = TemporaryDirectory()

        init() {
            let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
            session = AdSession(services: .live, monitor: monitor, parseDebounce: .zero)
            client = ClientModel(target: session, library: SavedRequestLibrary(store: SavedRequestStore(directory: directory.url)),
                                 now: { Date(timeIntervalSince1970: 1_795_000_000) })
            client.request = ClientRequest(url: endpoint, body: bidRequest)
            client.name = "Rewarded video · SSP staging"
        }
    }

    private func show(_ fixture: Fixture, size: CGSize = CGSize(width: 560, height: 760)) -> WindowHarness {
        WindowHarness(ClientPane(client: fixture.client, session: fixture.session), size: size)
    }

    @Test func everyPhaseDraws() async throws {
        let fixture = Fixture()
        defer { fixture.directory.cleanUp() }
        let harness = show(fixture)
        defer { harness.close() }
        try await Task.sleep(for: .milliseconds(100))

        fixture.transport.answer(endpoint, .init(body: bidResponse, delay: .milliseconds(150)))
        let sending = fixture.client.send()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.client.isSending)
        await sending?.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.client.phase == .received)

        fixture.client.request.url = "ftp://nowhere"
        fixture.client.send()
        try await Task.sleep(for: .milliseconds(100))
        guard case .failed = fixture.client.phase else {
            Issue.record("expected a failure, got \(fixture.client.phase)")
            return
        }
        fixture.client.newRequest()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.hosting.fittingSize.width > 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CCINN_CLIENT_SNAPSHOTS"] != nil))
    func snapshotNextToTheDevice() async throws {
        let fixture = Fixture()
        defer { fixture.directory.cleanUp() }
        fixture.transport.answer(endpoint, .init(headers: ["Content-Type": "application/json; charset=utf-8", "X-Request-Id": "8f1c2e"],
                                                 body: bidResponse))
        let size = CGSize(width: 1400, height: 860)
        let harness = WindowHarness(HSplitView {
            SimulatorPane(session: fixture.session).frame(width: 820)
            ClientPane(client: fixture.client, session: fixture.session)
        }
        .background(Color(nsColor: .windowBackgroundColor)), size: size)
        // A borderless offscreen window has no background of its own: give it the app's look, in light mode.
        harness.window.appearance = NSAppearance(named: .aqua)
        defer { harness.close() }

        await fixture.client.send()?.value
        _ = await fixture.client.save()
        for _ in 0..<300 where fixture.session.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .seconds(2))

        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CCINN_CLIENT_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = harness.hosting
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("client-tab.png"))
        #expect(fixture.session.placement == .rewarded)
    }
}
