import AVFoundation
import Foundation
import Testing
@testable import CcinnOpenRTBKit

/// The writer is synchronous (it waits for AVAssetWriter), so tests run it on a dispatch queue, as `SampleMedia` does,
/// rather than blocking a thread of the Swift concurrency pool.
private func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
}

private func temporaryFile(_ fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-movie-\(UUID().uuidString).\(fileExtension)")
}

/// Whether `file` is gone, now or within `limit` (a cancellation that runs on the writer's queue deletes it a little later).
private func fileDisappears(_ file: URL, within limit: Duration = .seconds(10)) async throws -> Bool {
    let deadline = ContinuousClock.now + limit
    while FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    return !FileManager.default.fileExists(atPath: file.path)
}

private func seconds(of mediaType: AVMediaType, in file: URL) async throws -> Double? {
    guard let track = try await AVURLAsset(url: file).loadTracks(withMediaType: mediaType).first else { return nil }
    return try await track.load(.timeRange).duration.seconds
}

@Suite("Sample movie writer")
struct SampleMovieWriterTests {
    /// Regression for "the writer stalled". AVAssetWriter holds back an input that runs ahead of the others to keep its
    /// interleaving pattern, and an input whose samples have run out but that is not marked finished is waited for
    /// forever. The writer must mark each input finished as soon as its last sample is appended; tracks of different
    /// lengths make the old writer (which marked both inputs finished only at the very end) deadlock every time.
    @Test(arguments: [
        SampleMovieWriter.Tracks(videoFrames: 90, audioSamples: 44_100),  // audio runs out first (3 s video, 1 s audio)
        SampleMovieWriter.Tracks(videoFrames: 30, audioSamples: 396_900),  // video runs out first (1 s video, 9 s audio)
    ])
    func aTrackThatEndsFirstDoesNotStallTheOther(tracks: SampleMovieWriter.Tracks) async throws {
        let file = temporaryFile("mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try await offThePool { try SampleMovieWriter.write(tracks, to: file, fileType: .mp4, stallTimeout: 5) }
        let video = try #require(try await seconds(of: .video, in: file))
        let audio = try #require(try await seconds(of: .audio, in: file))
        #expect(abs(video - Double(tracks.videoFrames) / Double(SampleMovieWriter.framesPerSecond)) < 0.1)
        #expect(abs(audio - Double(tracks.audioSamples) / Double(SampleMovieWriter.sampleRate)) < 0.1)
    }

    /// A writer that makes no progress is cancelled (between appends, never during one) and the generation fails
    /// with "the writer stalled" instead of hanging; cancelling deletes the partial file.
    @Test func aWriterWithoutProgressIsCancelledWithinTheStallTimeout() async throws {
        let file = temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        let started = ContinuousClock.now
        await #expect(throws: SampleMediaError.generationFailed("the writer stalled")) {
            try await offThePool {
                let writer = try AVAssetWriter(outputURL: file, fileType: .m4a)
                let audio = try SampleMovieWriter.audioFeed(samples: SampleMovieWriter.sampleRate, writer: writer)
                // Every chunk takes longer than the stall timeout to produce, but less than twice as long, so the
                // queue keeps responding and the session is cancelled, never abandoned.
                let slow = TrackFeed(input: audio.input, itemCount: audio.itemCount) { index in
                    Thread.sleep(forTimeInterval: 1.6)
                    try audio.appendItem(index)
                }
                try MovieWriteSession(writer: writer, feeds: [slow], stallTimeout: 1).run()
            }
        }
        // Cancelled when the first slow chunk returns (1.6 s), or the second if the watchdog woke late.
        #expect(ContinuousClock.now - started < .seconds(5))
        // On a loaded machine the first chunk can start so late that the session is abandoned first; the queued
        // cancellation then runs right after that chunk, so allow it a moment.
        #expect(try await fileDisappears(file), "cancelling deleted the partial file")
    }

    /// When the writing queue itself stops responding (a call into AVFoundation never returns), the caller still gets
    /// "the writer stalled" after twice the stall timeout; the cancellation runs once the queue is free again.
    @Test func aWriterWhoseQueueIsBlockedIsAbandoned() async throws {
        let file = temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        let release = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        await #expect(throws: SampleMediaError.generationFailed("the writer stalled")) {
            try await offThePool {
                let writer = try AVAssetWriter(outputURL: file, fileType: .m4a)
                let audio = try SampleMovieWriter.audioFeed(samples: SampleMovieWriter.sampleRate, writer: writer)
                let blocked = TrackFeed(input: audio.input, itemCount: audio.itemCount) { index in
                    release.wait()
                    try audio.appendItem(index)
                }
                try MovieWriteSession(writer: writer, feeds: [blocked], stallTimeout: 0.5).run()
            }
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(1) && elapsed < .seconds(3))
        release.signal()
        // The queued cancellation runs as soon as the blocked append returns, and deletes the partial file.
        #expect(try await fileDisappears(file))
    }

    /// AVFoundation raises an Objective-C exception (a crash, not an error) when writing starts twice, when an input is
    /// asked for data twice, or when it belongs to another writer. A session that cannot run throws instead.
    @Test func aSessionRunsOnce() async throws {
        let file = temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        let errors = try await offThePool { () -> [SampleMediaError?] in
            let writer = try AVAssetWriter(outputURL: file, fileType: .m4a)
            let feed = try SampleMovieWriter.audioFeed(samples: 4_410, writer: writer)
            let session = MovieWriteSession(writer: writer, feeds: [feed], stallTimeout: 5)
            try session.run()
            // The same session again, then a new session on the writer that has already written its file.
            return [session, MovieWriteSession(writer: writer, feeds: [feed], stallTimeout: 5)].map { session in
                do { try session.run() } catch let error as SampleMediaError {
                    return error
                } catch {
                    return nil
                }
                return nil
            }
        }
        #expect(errors == [.generationFailed("the session has already run"), .generationFailed("the writer has already been used")])
    }

    /// The same input listed twice would be asked for data twice; an input of another writer can't be asked at all.
    @Test func aSessionNeedsOneInputOfItsOwnWriterPerTrack() async throws {
        let file = temporaryFile("m4a")
        let other = temporaryFile("m4a")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: other)
        }
        let errors = try await offThePool { () -> [SampleMediaError?] in
            let writer = try AVAssetWriter(outputURL: file, fileType: .m4a)
            let own = try SampleMovieWriter.audioFeed(samples: 4_410, writer: writer)
            let foreign = try SampleMovieWriter.audioFeed(samples: 4_410, writer: try AVAssetWriter(outputURL: other, fileType: .m4a))
            return [[own, own], [foreign]].map { feeds in
                do { try MovieWriteSession(writer: writer, feeds: feeds, stallTimeout: 5).run() } catch let error as SampleMediaError {
                    return error
                } catch {
                    return nil
                }
                return nil
            }
        }
        #expect(errors == [.generationFailed("each track needs its own input on the writer"),
                           .generationFailed("each track needs its own input on the writer")])
    }

    /// Stress: concurrent encodes of every shape, bounded in time. The stall showed on a loaded machine, with other
    /// processes encoding at the same moment. With equal track lengths the old writer stalled only when the last video
    /// frames did not fit in what the writer buffers ahead of the open audio input, so the canonical video catches it
    /// only some of the time (2 of 3 runs at load average 22, 0 of 4 at 15); the tracks that end at different times
    /// catch it every time, so they carry the regression and one canonical video and audio cover the real assets.
    /// Kept small for CI runners with few cores. Each encode has a short stall timeout and the test a time limit, so a
    /// regression fails in seconds instead of hanging CI.
    @Test(.timeLimit(.minutes(2)))
    func concurrentEncodesAllComplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-movie-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shapes: [SampleMovieWriter.Tracks] = [.video, .audio]
            + Array(repeating: SampleMovieWriter.Tracks(videoFrames: 90, audioSamples: 44_100), count: 2)
            + Array(repeating: SampleMovieWriter.Tracks(videoFrames: 30, audioSamples: 396_900), count: 2)
        let written = try await withThrowingTaskGroup(of: (SampleMovieWriter.Tracks, URL).self) { group in
            for (index, tracks) in shapes.enumerated() {
                let file = directory.appendingPathComponent("job-\(index).\(tracks.videoFrames > 0 ? "mp4" : "m4a")")
                group.addTask {
                    try await offThePool {
                        try SampleMovieWriter.write(tracks, to: file, fileType: tracks.videoFrames > 0 ? .mp4 : .m4a, stallTimeout: 15)
                    }
                    return (tracks, file)
                }
            }
            return try await group.reduce(into: [(SampleMovieWriter.Tracks, URL)]()) { $0.append($1) }
        }
        #expect(written.count == shapes.count)
        for (tracks, file) in written {
            let audio = try #require(try await seconds(of: .audio, in: file))
            #expect(abs(audio - Double(tracks.audioSamples) / Double(SampleMovieWriter.sampleRate)) < 0.1)
            let video = try await seconds(of: .video, in: file)
            if tracks.videoFrames > 0 {
                let video = try #require(video)
                #expect(abs(video - Double(tracks.videoFrames) / Double(SampleMovieWriter.framesPerSecond)) < 0.1)
            } else {
                #expect(video == nil)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == shapes.count, "no temporary files")
    }
}
