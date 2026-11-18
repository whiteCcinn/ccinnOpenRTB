import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import CcinnOpenRTBKit

@Suite("Sample URLs")
struct SampleURLTests {
    @Test func canonicalAndAliasNamesResolve() {
        #expect(SampleURL.parse(SampleURL.video) == .video)
        #expect(SampleURL.parse(SampleURL.audio) == .audio)
        #expect(SampleURL.parse("ccinn-sample://media/sample-video.mp4") == .video)
        #expect(SampleURL.parse("CCINN-SAMPLE://media/anything.MOV?t=1#x") == .video)
        #expect(SampleURL.parse("ccinn-sample://media/sample-audio.m4a") == .audio)
        #expect(SampleURL.parse("ccinn-sample://media/tone.mp3") == .audio)
    }

    @Test func namedAndSizedImagesResolve() throws {
        guard case let .image(main)? = SampleURL.parse("ccinn-sample://image/main.png") else {
            Issue.record("main.png must resolve")
            return
        }
        #expect((main.width, main.height) == (1200, 627))
        guard case let .image(sized)? = SampleURL.parse(SampleURL.image("728x90")) else {
            Issue.record("728x90.png must resolve")
            return
        }
        #expect((sized.width, sized.height) == (728, 90))
        for (name, size) in SampleImageSpec.named {
            let spec = try #require(SampleImageSpec(name: name))
            #expect((spec.width, spec.height) == (size.width, size.height))
        }
    }

    @Test(arguments: ["ccinn-sample://image/unknown.png", "ccinn-sample://image/0x50.png", "ccinn-sample://image/99999x1.png",
                      "ccinn-sample://media/clip.webm", "ccinn-sample://other/x.png", "ccinn-sample://image/", "ccinn-sample://",
                      "https://media/sample-15s.mp4", "ccinn-sample://image/../../etc/passwd", "ccinn-sample://image/a/b.png"])
    func rejectsUnknownSamples(url: String) {
        #expect(SampleURL.parse(url) == nil)
    }
}

@Suite("Sample media generation")
struct SampleMediaGenerationTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-samples-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func imagesAreDeterministicPNGsOfTheRequestedSize() throws {
        for (name, size) in SampleImageSpec.named.sorted(by: { $0.key < $1.key }) {
            let spec = try #require(SampleImageSpec(name: name))
            let first = try #require(SampleImageRenderer.png(spec))
            let second = try #require(SampleImageRenderer.png(spec))
            #expect(first == second, "\(name) must render identically")
            #expect(Array(first.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let source = try #require(CGImageSourceCreateWithData(first as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect((image.width, image.height) == (size.width, size.height))
        }
    }

    @Test func concurrentRequestsShareOneFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = SampleMedia(directory: directory)
        let spec = try #require(SampleImageSpec(name: "companion"))
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<12 { group.addTask { try await media.fileURL(for: .image(spec)) } }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(urls).count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["image-companion.png"], "no temporary files are left behind")
        let data = try await media.data(for: .image(spec))
        #expect(data == SampleImageRenderer.png(spec))
        await #expect(throws: SampleMediaError.self) { _ = try await media.fileURL(for: "ccinn-sample://image/nope.png") }
    }

    @Test func videoIsFifteenSecondsOf720pH264WithAudio() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = SampleMedia(directory: directory)
        let file = try await media.fileURL(for: "ccinn-sample://media/sample-15s.mp4")
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 15) < 0.1)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size == CGSize(width: 1280, height: 720))
        let formats = try await video.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        // Idempotent: a second request returns the same file without regenerating it.
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let again = try await media.fileURL(for: .video)
        #expect(again == file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
    }

    /// Several app processes can generate the same files at the same moment; independent `SampleMedia` instances share
    /// nothing but the directory, like processes. Every request succeeds, one file per asset remains, and no
    /// temporary file is left behind.
    @Test(.timeLimit(.minutes(2)))
    func instancesSharingADirectoryEachGetTheSameFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instances = (0..<4).map { _ in SampleMedia(directory: directory) }
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for media in instances {
                group.addTask { try await media.fileURL(for: .video) }
                group.addTask { try await media.fileURL(for: .audio) }
            }
            return try await group.reduce(into: Set<URL>()) { $0.insert($1) }
        }
        #expect(urls == [directory.appendingPathComponent("sample-15s.mp4"), directory.appendingPathComponent("sample-15s.m4a")])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == ["sample-15s.m4a", "sample-15s.mp4"], "no temporary files are left behind")
    }

    /// A process that crashes while generating leaves its workspace behind. Creating a `SampleMedia` removes those that
    /// are over an hour old (no generation runs that long), including the files older builds wrote next to the samples,
    /// and nothing else: a workspace another process is using right now, or a sample however old, stays.
    @Test func staleWorkspacesAreSweptWhenCreated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let twoHoursAgo = Date().addingTimeInterval(-2 * 3_600)

        func make(_ name: String, isDirectory: Bool, modified: Date? = nil) throws {
            let url = directory.appendingPathComponent(name)
            if isDirectory {
                try manager.createDirectory(at: url, withIntermediateDirectories: false)
                try Data("partial".utf8).write(to: url.appendingPathComponent("sample-15s.mp4"))
            } else {
                try Data("partial".utf8).write(to: url)
            }
            if let modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        try make(".tmp-\(UUID().uuidString)", isDirectory: true, modified: twoHoursAgo)  // crashed generation
        try make(".tmp-\(UUID().uuidString)-sample-15s.mp4", isDirectory: false, modified: twoHoursAgo)  // older builds
        try make(".tmp-\(UUID().uuidString)-sample-15s.mp4.sb-f10320fd-AbCdEf", isDirectory: false, modified: twoHoursAgo)
        let fresh = ".tmp-\(UUID().uuidString)"
        try make(fresh, isDirectory: true)  // another process is generating right now
        try make("sample-15s.m4a", isDirectory: false, modified: twoHoursAgo)  // a generated sample
        try make("tmp-notes", isDirectory: false, modified: twoHoursAgo)  // not a workspace

        let media = SampleMedia(directory: directory)
        await media.startupSweep.value
        let left = try manager.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == [fresh, "sample-15s.m4a", "tmp-notes"].sorted())
    }

    @Test func audioIsFifteenSecondsOfAAC() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await SampleMedia(directory: directory).fileURL(for: .audio)
        #expect(file.pathExtension == "m4a")
        let asset = AVURLAsset(url: file)
        #expect(abs(try await asset.load(.duration).seconds - 15) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kAudioFormatMPEG4AAC)
        #expect(try await asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test func toneStaysInRange() {
        let samples = (0..<(SampleMovieWriter.sampleRate * 2)).map(SampleMovieWriter.toneSample)
        #expect(samples.contains { $0 != 0 })
        #expect(samples.allSatisfy { $0 > Int16.min })
    }
}
