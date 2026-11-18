import Foundation
import Testing
@testable import CcinnOpenRTBKit

/// The test double owns its temporary directory: it disappears with the last reference, so no test leaves one behind.
@Suite("Test support: fake samples")
struct FakeSamplesTests {
    @Test func theDirectoryIsRemovedWithTheFakeSamples() async throws {
        var samples: FakeSamples? = FakeSamples()
        let directory = try #require(samples).directory
        let file = try await #require(samples).fileURL(for: .video)
        #expect(FileManager.default.fileExists(atPath: file.path))
        samples = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// `makeMonitor` is how most network tests get fake samples; the directory goes away with the monitor.
    @MainActor
    @Test func theDirectoryIsRemovedWithTheMonitorThatUsesIt() async throws {
        var monitor: NetworkMonitor? = makeMonitor(transport: FailingTransport())
        let sample = try #require(await monitor?.prepareMedia(SampleURL.video, trigger: "media", source: "VAST", parentID: nil,
                                                                userAgent: deviceUA))
        let directory = try #require(sample.playableURL).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: directory.path))
        monitor = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
