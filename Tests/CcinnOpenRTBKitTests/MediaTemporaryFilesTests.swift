import Foundation
import Testing
@testable import CcinnOpenRTBKit

/// `data:` media becomes a temporary file for the player; those files never outlive the render that made them.
@MainActor
@Suite("Media temporary files")
struct MediaTemporaryFilesTests {
    private static let dataVideo = "data:video/mp4;base64,AAAAIGZ0eXBpc29t"

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-media-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func monitor(_ directory: URL) -> NetworkMonitor {
        NetworkMonitor(transport: FailingTransport(), samples: FakeSamples(), publishInterval: .zero,
                       mediaFiles: MediaTemporaryFiles(directory: directory))
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func dataMediaFilesAreDeletedWhenTheRenderEndsOrTheLogIsCleared() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(directory)
        let first = try #require(await monitor.prepareMedia(Self.dataVideo, trigger: "media", source: "VAST", parentID: nil, userAgent: deviceUA)
            .playableURL)
        #expect(first.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(first.lastPathComponent.hasPrefix(MediaTemporaryFiles.filePrefix))
        #expect(FileManager.default.fileExists(atPath: first.path))
        monitor.endRender()
        #expect(!FileManager.default.fileExists(atPath: first.path))

        let second = try #require(await monitor.prepareMedia(Self.dataVideo, trigger: "media", source: "VAST", parentID: nil, userAgent: deviceUA)
            .playableURL)
        #expect(FileManager.default.fileExists(atPath: second.path))
        monitor.clear()
        #expect(files(in: directory).isEmpty)
    }

    @Test func atMostEightFilesAreKeptEvenWithoutARenderEnd() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = monitor(directory)
        var made: [URL] = []
        for _ in 0..<10 {
            let prepared = await monitor.prepareMedia(Self.dataVideo, trigger: "media", source: "VAST", parentID: nil, userAgent: deviceUA)
            made.append(try #require(prepared.playableURL))
        }
        #expect(MediaTemporaryFiles.maxFiles == 8)
        #expect(files(in: directory) == made.suffix(8).map(\.lastPathComponent).sorted())
    }

    @Test func releasingTheStoreDeletesItsFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: MediaTemporaryFiles? = MediaTemporaryFiles(directory: directory)
        let file = try #require(try await store?.write(Data("x".utf8), mimeType: "video/mp4"))
        #expect(file.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: file.path))
        store = nil
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// A process that quits or crashes mid-render leaves its files: each new store removes those over an hour old, and
    /// nothing else (another window's file in use, files that are not ours).
    @Test func staleFilesAreSweptWhenAStoreIsCreated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        func make(_ name: String, modified: Date?) throws {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            if let modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3_600)
        try make("ccinn-media-\(UUID().uuidString).mp4", modified: twoHoursAgo)
        let fresh = "ccinn-media-\(UUID().uuidString).m4a"
        try make(fresh, modified: nil)
        try make("notes.txt", modified: twoHoursAgo)

        let store = MediaTemporaryFiles(directory: directory)
        await store.startupSweep.value
        #expect(files(in: directory) == [fresh, "notes.txt"].sorted())
    }
}
