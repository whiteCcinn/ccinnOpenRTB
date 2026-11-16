import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("VAST playback tracker")
struct VASTPlaybackTrackerTests {
    /// Plays from `from` to `to` in `step` increments and collects every event.
    private func play(_ tracker: inout VASTPlaybackTracker, from: Double, to: Double, step: Double = 0.1) -> [VASTEvent] {
        var events: [VASTEvent] = []
        var playhead = from
        while playhead <= to + 1e-9 {
            events += tracker.advance(to: playhead)
            playhead += step
        }
        return events
    }

    @Test func fullPlaybackFiresEveryEventOnceInOrder() {
        var tracker = VASTPlaybackTracker(duration: 10)
        var events = tracker.loaded()
        events += play(&tracker, from: 0, to: 10)
        events += tracker.complete()
        #expect(events == [.loaded, .creativeView, .start, .firstQuartile, .midpoint, .thirdQuartile, .complete])
        // Nothing fires twice.
        #expect(tracker.loaded().isEmpty)
        #expect(tracker.complete().isEmpty)
        #expect(play(&tracker, from: 9, to: 10).isEmpty)
    }

    @Test func startWaitsForTheFirstFrame() {
        var tracker = VASTPlaybackTracker(duration: 10)
        #expect(tracker.advance(to: 0).isEmpty)
        #expect(tracker.advance(to: 0.05) == [.creativeView, .start])
        #expect(tracker.advance(to: 0.1).isEmpty)
    }

    @Test func progressOffsetsFireOnceInTimeOrderMixedWithQuartiles() {
        var tracker = VASTPlaybackTracker(duration: 20, progressOffsets: [.seconds(12), .percent(10), .seconds(3), .seconds(3)])
        let events = play(&tracker, from: 0, to: 20, step: 0.25)
        #expect(events == [.creativeView, .start, .progress(.percent(10)), .progress(.seconds(3)), .firstQuartile, .midpoint,
                           .progress(.seconds(12)), .thirdQuartile])
    }

    @Test func percentOffsetsWaitForTheDuration() {
        var tracker = VASTPlaybackTracker(duration: nil, progressOffsets: [.percent(50), .seconds(1)])
        #expect(tracker.advance(to: 0.5) == [.creativeView, .start])
        #expect(tracker.advance(to: 1.5) == [.progress(.seconds(1))])
        // Quartiles and percent offsets are unknown until the media reports its duration.
        #expect(tracker.advance(to: 6).isEmpty)
        // At the same instant a quartile precedes a progress offset.
        #expect(tracker.setDuration(10) == [.firstQuartile, .midpoint, .progress(.percent(50))])
        #expect(tracker.advance(to: 8) == [.thirdQuartile])
    }

    @Test func seekingBackwardsFiresRewindButNeverRefiresQuartiles() {
        var tracker = VASTPlaybackTracker(duration: 8)
        var events = play(&tracker, from: 0, to: 5)
        #expect(events.last == .midpoint)
        events = tracker.advance(to: 1)
        #expect(events == [.rewind])
        events = play(&tracker, from: 1.1, to: 5.5)
        #expect(events.isEmpty)
        events = play(&tracker, from: 5.6, to: 6.5)
        #expect(events == [.thirdQuartile])
    }

    @Test func smallJitterBackwardsIsNotARewind() {
        var tracker = VASTPlaybackTracker(duration: 10)
        _ = play(&tracker, from: 0, to: 3)
        #expect(tracker.advance(to: 2.8).isEmpty)
    }

    @Test func forwardJumpFiresAllCrossedQuartilesInOrder() {
        var tracker = VASTPlaybackTracker(duration: 10)
        _ = tracker.advance(to: 0.1)
        #expect(tracker.advance(to: 8) == [.firstQuartile, .midpoint, .thirdQuartile])
    }

    @Test func pauseAndResumePairUp() {
        var tracker = VASTPlaybackTracker(duration: 10)
        #expect(tracker.pause().isEmpty, "no pause before start")
        _ = tracker.advance(to: 1)
        #expect(tracker.pause() == [.pause])
        #expect(tracker.pause().isEmpty, "already paused")
        #expect(tracker.resume() == [.resume])
        #expect(tracker.resume().isEmpty, "not paused")
        #expect(tracker.pause() == [.pause])
        #expect(tracker.resume() == [.resume])
    }

    @Test func muteTogglesFireOnChangeOnly() {
        var tracker = VASTPlaybackTracker(duration: 10, muted: true)
        #expect(tracker.setMuted(true).isEmpty)
        #expect(tracker.setMuted(false) == [.unmute])
        #expect(tracker.setMuted(false).isEmpty)
        #expect(tracker.setMuted(true) == [.mute])
    }

    @Test func skipEndsTheAdWithoutComplete() {
        // Spec scenario: skipoffset 5 s, skipped at 6 s of a 20 s ad.
        var tracker = VASTPlaybackTracker(duration: 20)
        var events = play(&tracker, from: 0, to: 6)
        events += tracker.skip()
        events += tracker.complete()
        events += play(&tracker, from: 6, to: 20)
        events += tracker.pause()
        events += tracker.close()
        #expect(events == [.creativeView, .start, .firstQuartile, .skip])
        #expect(tracker.isFinished)
    }

    @Test func shortMediaCompletesWithEveryMissingQuartile() {
        // A 0.3 s clip can end between two observer ticks.
        var tracker = VASTPlaybackTracker(duration: 0.3, progressOffsets: [.seconds(0.2), .seconds(5)])
        var events = tracker.advance(to: 0)
        events += tracker.complete()
        #expect(events == [.creativeView, .start, .firstQuartile, .midpoint, .progress(.seconds(0.2)), .thirdQuartile, .complete])
    }

    @Test func closeBeforeCompleteIsCloseLinearAfterCompleteIsNothing() {
        var early = VASTPlaybackTracker(duration: 10)
        _ = early.advance(to: 2)
        #expect(early.close() == [.closeLinear])
        #expect(early.close().isEmpty)
        #expect(early.advance(to: 9).isEmpty)

        var late = VASTPlaybackTracker(duration: 1)
        _ = late.advance(to: 0.5)
        _ = late.complete()
        #expect(late.close().isEmpty)
    }

    @Test func replayAfterCompleteIsARewindOnly() {
        var tracker = VASTPlaybackTracker(duration: 4)
        _ = play(&tracker, from: 0, to: 4)
        _ = tracker.complete()
        #expect(tracker.advance(to: 0) == [.rewind])
        #expect(play(&tracker, from: 0.1, to: 4).isEmpty)
        #expect(tracker.complete().isEmpty)
    }

    @Test func pauseAtTheEndIsNotReported() {
        var tracker = VASTPlaybackTracker(duration: 2)
        _ = play(&tracker, from: 0, to: 2)
        _ = tracker.complete()
        #expect(tracker.pause().isEmpty)
    }

    @Test func invalidInputsAreIgnored() {
        var tracker = VASTPlaybackTracker(duration: -5, progressOffsets: [.seconds(-1), .percent(150)])
        #expect(tracker.advance(to: .nan).isEmpty)
        #expect(tracker.advance(to: -1).isEmpty)
        #expect(tracker.setDuration(.infinity).isEmpty)
        #expect(tracker.advance(to: 1) == [.creativeView, .start])
        #expect(tracker.setDuration(4) == [.firstQuartile])
        // -1 s and 150 % are never reachable; they fire neither during playback nor at complete.
        #expect(tracker.complete() == [.midpoint, .thirdQuartile, .complete])
    }
}
