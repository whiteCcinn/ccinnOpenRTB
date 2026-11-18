import AVFoundation
import Foundation
import os

/// One track to write: its writer input and its items (video frames, audio chunks) in presentation order.
struct TrackFeed {
    let input: AVAssetWriterInput
    let itemCount: Int
    /// Appends item `index` to `input`. Called on the session's queue, in order, only while the input is ready.
    let appendItem: (_ index: Int) throws -> Void
}

/// Drives one AVAssetWriter to a finished file: AVAssetWriter pulls each track (`requestMediaDataWhenReady`), which is
/// how AVFoundation expects a non-real-time source to be written, and each input is marked finished as soon as
/// its last item has been appended.
///
/// Marking inputs finished promptly is what keeps writing from deadlocking. To keep its interleaving pattern,
/// AVAssetWriter holds back an input that is ahead of the others and waits for every input that is not yet finished:
/// "Clients that are monitoring each input's readyForMoreMediaData value must call markAsFinished on an input when they
/// are done appending buffers to it. This is necessary to prevent other inputs from stalling, as they may otherwise
/// wait forever for that input's media data" (AVAssetWriterInput.h). If one track runs out of items but its input is
/// left open, the other input stops being ready once it has buffered as far as the writer allows, and nothing moves.
///
/// Generation can't hang. If no item is appended for `stallTimeout`, writing is cancelled. The cancellation runs on the
/// session's queue, because `cancelWriting` must not run while an append is in progress. If the queue doesn't
/// respond within another `stallTimeout`, the session is abandoned. In both cases `run()` throws "the writer stalled".
final class MovieWriteSession: @unchecked Sendable {
    // `@unchecked Sendable`: `feeds`, `appended`, `finished` and, once `run()` has started it, the writer are only used on
    // `queue`. The waiting thread shares nothing with the queue but `shared` (a lock) and `done` (a semaphore). `run()`
    // reads the writer and `feeds` before it starts writing, which happens before anything is queued.
    private let writer: AVAssetWriter
    private let feeds: [TrackFeed]
    private let stallTimeout: Duration
    private let queue = DispatchQueue(label: "io.github.whiteccinn.ccinnopenrtb.sample-movie", qos: .userInitiated)
    private var appended: [Int]
    private var finished: [Bool]
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let done = DispatchSemaphore(value: 0)

    private struct Shared {
        var hasRun = false
        var lastProgress = ContinuousClock.now
        /// Set once writing must stop (an outcome is known or a stall was detected): no more appends after this.
        var isStopping = false
        var outcome: Result<Void, any Error>?
    }

    init(writer: AVAssetWriter, feeds: [TrackFeed], stallTimeout: TimeInterval) {
        self.writer = writer
        self.feeds = feeds
        // Clamped to [0, 1 day] (non-finite values included), so the Duration arithmetic below cannot trap.
        self.stallTimeout = .seconds(stallTimeout.isFinite ? min(max(0, stallTimeout), 86_400) : 86_400)
        appended = Array(repeating: 0, count: feeds.count)
        finished = Array(repeating: false, count: feeds.count)
    }

    /// Writes every track and finishes the file. Blocks until then, so call it off the Swift concurrency pool.
    ///
    /// AVFoundation raises an Objective-C exception (a crash) when writing starts twice, when an input is asked for
    /// data twice, or when an input is not attached to the writer. So a session runs once, on a writer that has not
    /// started, and each track needs an input of its own on that writer; anything else throws.
    func run() throws {
        let isFirstRun = shared.withLock { state in
            defer { state.hasRun = true }
            return !state.hasRun
        }
        guard isFirstRun else { throw SampleMediaError.generationFailed("the session has already run") }
        guard writer.status == .unknown else { throw SampleMediaError.generationFailed("the writer has already been used") }
        let inputs = feeds.map { ObjectIdentifier($0.input) }
        guard Set(inputs).count == inputs.count, feeds.allSatisfy({ feed in writer.inputs.contains { $0 === feed.input } }) else {
            throw SampleMediaError.generationFailed("each track needs its own input on the writer")
        }
        guard writer.startWriting() else { throw failure(otherwise: "the writer did not start") }
        writer.startSession(atSourceTime: .zero)
        touch()
        let interval = min(0.25, max(0.01, stallTimeout / .seconds(4)))
        // A writer can fail while no input asks for data; check its status on the queue rather than wait for a stall.
        let failureCheck = DispatchSource.makeTimerSource(queue: queue)
        failureCheck.schedule(deadline: .now() + interval, repeating: interval)
        failureCheck.setEventHandler { [weak self] in self?.checkForFailure() }
        failureCheck.activate()
        defer { failureCheck.cancel() }
        queue.async { self.start() }

        var stopRequested = false
        while done.wait(timeout: .now() + interval) == .timedOut {
            let idle = shared.withLock { ContinuousClock.now - $0.lastProgress }
            if idle > stallTimeout * 2 {
                complete(.failure(SampleMediaError.generationFailed("the writer stalled")))  // the queue itself is stuck
            } else if idle > stallTimeout, !stopRequested {
                stopRequested = true
                shared.withLock { $0.isStopping = true }
                queue.async { self.stop() }
            }
        }
        try (shared.withLock { $0.outcome } ?? .failure(SampleMediaError.generationFailed("the writer stalled"))).get()
    }

    // MARK: On `queue`

    private func start() {
        for track in feeds.indices {
            if feeds[track].itemCount > 0 {
                feeds[track].input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pump(track) }
            } else {
                finish(track)
            }
        }
        finishWritingIfDone()
    }

    /// Appends the track's next items while its input is ready, and marks the input finished right after its last one.
    private func pump(_ track: Int) {
        let feed = feeds[track]
        while appended[track] < feed.itemCount, !isStopping, feed.input.isReadyForMoreMediaData {
            do {
                try feed.appendItem(appended[track])
            } catch {
                fail(error)
                return
            }
            appended[track] += 1
            touch()
        }
        if appended[track] == feed.itemCount {
            finish(track)
            finishWritingIfDone()
        }
    }

    private func finish(_ track: Int) {
        guard !finished[track], !isStopping, writer.status == .writing else { return }
        finished[track] = true
        feeds[track].input.markAsFinished()
    }

    private func finishWritingIfDone() {
        guard finished.allSatisfy({ $0 }), !isStopping, writer.status == .writing else { return }
        shared.withLock { $0.isStopping = true }  // every input is finished; nothing is appended any more
        touch()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            queue.async { self.writerFinished() }
        }
    }

    private func writerFinished() {
        if writer.status == .completed {
            complete(.success(()))
        } else {
            complete(.failure(failure(otherwise: "the writer did not finish")))
        }
    }

    private func checkForFailure() {
        if writer.status == .failed { complete(.failure(failure(otherwise: "the writer failed"))) }
    }

    /// An append failed: cancel the other tracks too (and delete the partial file) unless the writer already failed.
    private func fail(_ error: any Error) {
        let reported = writer.status == .failed ? failure(otherwise: "the writer failed") : error
        writer.cancelWriting()
        complete(.failure(reported))
    }

    /// The writer made no progress for `stallTimeout`. Runs on the queue, so it never overlaps an append.
    private func stop() {
        switch writer.status {
        case .completed:
            complete(.success(()))
        case .failed:
            complete(.failure(failure(otherwise: "the writer failed")))
        default:
            writer.cancelWriting()
            complete(.failure(SampleMediaError.generationFailed("the writer stalled")))
        }
    }

    // MARK: Shared

    private var isStopping: Bool { shared.withLock { $0.isStopping } }

    private func touch() {
        shared.withLock { $0.lastProgress = .now }
    }

    /// Records the first outcome only, stops further appends and wakes `run()`.
    private func complete(_ result: Result<Void, any Error>) {
        let isFirst = shared.withLock { state in
            guard state.outcome == nil else { return false }
            state.outcome = result
            state.isStopping = true
            return true
        }
        if isFirst { done.signal() }
    }

    private func failure(otherwise reason: String) -> SampleMediaError {
        .generationFailed(writer.error?.localizedDescription ?? reason)
    }
}
