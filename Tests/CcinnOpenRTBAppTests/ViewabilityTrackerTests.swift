import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("MRC viewability")
struct ViewabilityTrackerTests {
    @Test func nothingCountsBeforeTheAdRenders() {
        var tracker = ViewabilityTracker(rule: .display)
        #expect(tracker.update(fraction: 1, at: 0).isEmpty)
        #expect(tracker.advance(to: 5).isEmpty)
        #expect(tracker.nextDeadline == nil)
    }

    @Test func displayFiresMRC50AndMRC100AfterOneSecond() {
        var tracker = ViewabilityTracker(rule: .display)
        #expect(tracker.update(fraction: 1, at: 0).isEmpty)
        #expect(tracker.didRender(at: 10).isEmpty)
        #expect(tracker.nextDeadline == 11)
        #expect(tracker.advance(to: 10.99).isEmpty)
        #expect(tracker.advance(to: 11) == [.mrc50, .mrc100])
        // Once per render.
        #expect(tracker.advance(to: 20).isEmpty)
        #expect(tracker.update(fraction: 0, at: 21).isEmpty)
        #expect(tracker.update(fraction: 1, at: 22).isEmpty)
        #expect(tracker.advance(to: 30).isEmpty)
        #expect(tracker.nextDeadline == nil)
    }

    @Test func halfVisibleFiresOnlyMRC50() {
        var tracker = ViewabilityTracker(rule: .display)
        _ = tracker.didRender(at: 0)
        _ = tracker.update(fraction: 0.5, at: 0)
        #expect(tracker.advance(to: 1) == [.mrc50])
        #expect(tracker.nextDeadline == nil)
        // Becoming fully visible later starts the 100% timer.
        #expect(tracker.update(fraction: 1, at: 3).isEmpty)
        #expect(tracker.advance(to: 4) == [.mrc100])
    }

    @Test func dippingBelowTheThresholdRestartsTheTimer() {
        var tracker = ViewabilityTracker(rule: .display)
        _ = tracker.didRender(at: 0)
        _ = tracker.update(fraction: 0.6, at: 0)
        #expect(tracker.update(fraction: 0.4, at: 0.9).isEmpty)
        #expect(tracker.update(fraction: 0.6, at: 1.0).isEmpty)
        #expect(tracker.advance(to: 1.95).isEmpty)
        #expect(tracker.advance(to: 2.0) == [.mrc50])
    }

    @Test func aDeadlineThatPassedBeforeAnUpdateStillFires() {
        var tracker = ViewabilityTracker(rule: .display)
        _ = tracker.didRender(at: 0)
        _ = tracker.update(fraction: 0.7, at: 0)
        // No timer tick happened; the update at 1.5 s first settles the elapsed second.
        #expect(tracker.update(fraction: 0, at: 1.5) == [.mrc50])
    }

    @Test func videoNeedsTwoContinuousSecondsOfPlayback() {
        var tracker = ViewabilityTracker(rule: .video)
        _ = tracker.didRender(at: 0)
        _ = tracker.update(fraction: 1, at: 0)
        // Visible but not playing: nothing.
        #expect(tracker.advance(to: 5).isEmpty)
        #expect(tracker.setPlaying(true, at: 5).isEmpty)
        #expect(tracker.nextDeadline == 7)
        // A pause breaks continuity.
        #expect(tracker.setPlaying(false, at: 6.5).isEmpty)
        #expect(tracker.setPlaying(true, at: 7).isEmpty)
        #expect(tracker.advance(to: 8.9).isEmpty)
        #expect(tracker.advance(to: 9) == [.video50])
        // Display levels never fire for video.
        #expect(tracker.advance(to: 60).isEmpty)
    }

    @Test func videoBelowFiftyPercentDoesNotCount() {
        var tracker = ViewabilityTracker(rule: .video)
        _ = tracker.didRender(at: 0)
        _ = tracker.setPlaying(true, at: 0)
        _ = tracker.update(fraction: 0.49, at: 0)
        #expect(tracker.advance(to: 10).isEmpty)
        #expect(!tracker.hasMetVideoStandard)
    }

    @Test func noRuleNeverFires() {
        var tracker = ViewabilityTracker(rule: .none)
        _ = tracker.didRender(at: 0)
        _ = tracker.update(fraction: 1, at: 0)
        _ = tracker.setPlaying(true, at: 0)
        #expect(tracker.advance(to: 100).isEmpty)
        #expect(tracker.nextDeadline == nil)
    }

    @Test func progressReportsTheRunningTimer() {
        var tracker = ViewabilityTracker(rule: .display)
        _ = tracker.didRender(at: 0)
        _ = tracker.update(fraction: 1, at: 0)
        #expect(tracker.progress(of: .mrc50, at: 0.5) == 0.5)
        #expect(tracker.progress(of: .mrc50, at: 3) == 1)
        _ = tracker.advance(to: 1)
        #expect(tracker.progress(of: .mrc50, at: 3) == 1)
        #expect(tracker.progress(of: .video50, at: 3) == 0)
    }
}
