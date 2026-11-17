import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// The host members with default implementations must be protocol requirements: a renderer only ever sees
/// `any AdRenderingHost`, and an extension-only member would be statically dispatched to the default.
@MainActor
@Suite("Renderer contract")
struct RendererContractTests {
    private static let device = DeviceProfile(id: "p", name: "Phone", family: .iPhone, screenWidth: 393, screenHeight: 852, scale: 3,
                                              os: "iOS", osVersion: "18", make: "Apple", model: "iPhone", userAgent: "UA",
                                              openRTBDeviceType: 4)

    private final class MinimalHost: AdRenderingHost {
        let monitor = NetworkMonitor()
        let device = RendererContractTests.device
        func report(_ event: AdLifecycleEvent) {}
        func navigate(to url: String, trigger: String, source: String) {}
        func fetchContent(_ url: String, trigger: String, source: String) async throws -> Data { Data() }
    }

    /// Conforms directly, like `AdSession` (a subclass could not replace a witness its superclass took from the extension).
    private final class SessionLikeHost: AdRenderingHost {
        let monitor = NetworkMonitor()
        let device = RendererContractTests.device
        private(set) var scriptTrackers: [ScriptTracker] = []
        func enqueue(_ tracker: ScriptTracker) { scriptTrackers.append(tracker) }
        func report(_ event: AdLifecycleEvent) {}
        func navigate(to url: String, trigger: String, source: String) {}
        func fetchContent(_ url: String, trigger: String, source: String) async throws -> Data { Data() }
    }

    @Test func scriptTrackersDefaultToNone() {
        let host: any AdRenderingHost = MinimalHost()
        #expect(host.scriptTrackers.isEmpty)
    }

    @Test func scriptTrackersAreDynamicallyDispatched() {
        let session = SessionLikeHost()
        let tracker = ScriptTracker(entryID: UUID(), request: TrackerRequest(category: .impression, trigger: "rendered", source: "Native",
                                                                              template: "https://t.example/js", url: "https://t.example/js",
                                                                              isScript: true))
        session.enqueue(tracker)
        let host: any AdRenderingHost = session
        #expect(host.scriptTrackers == [tracker])
    }
}
