import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// A system clock step during a ride must not move any duration, and must move both Live Activity
/// anchors by exactly the step — once.
///
/// **On negative controls.** A `.stepped` instant puts its whole divergence in the wall half, and
/// no duration reads the wall half, so the duration fixtures below would stay green against
/// `.coherent` instants too. That is structural, not sloppiness: what those fixtures catch is a
/// production regression back to wall subtraction. Policing the fixture generator is
/// `steppedInstantsActuallyCarryAStep`'s job, and pinning that the defect is real is
/// `theOldWallClockExpressionWouldHaveLostTheStop`'s. The anchor fixtures are wall-sensitive by
/// construction and need no control.
@MainActor
@Suite struct RideClockStepTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func startedRecorder() -> RideRecorder {
        let r = RideRecorder()
        r.start(at: .coherent(t0))
        return r
    }

    // MARK: negative controls

    @Test func steppedInstantsActuallyCarryAStep() {
        let plain = RideInstant.coherent(t0.addingTimeInterval(100))
        let stepped = RideInstant.stepped(t0.addingTimeInterval(100), by: -40)
        #expect(stepped.monotonicSeconds == plain.monotonicSeconds)
        #expect(stepped.date.timeIntervalSince(plain.date) == -40)
    }

    @Test func theOldWallClockExpressionWouldHaveLostTheStop() {
        let pauseAt = RideInstant.coherent(t0.addingTimeInterval(600))
        let readAt = RideInstant.stepped(t0.addingTimeInterval(610), by: -40)
        #expect(max(0, readAt.date.timeIntervalSince(pauseAt.date)) == 0)
        #expect(readAt.monotonicSeconds - pauseAt.monotonicSeconds == 10)
    }

    // MARK: durations

    @Test func aBackwardStepMidStopDoesNotMoveEitherNumber() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        let stepped = RideInstant.stepped(t0.addingTimeInterval(640), by: -40)
        #expect(r.currentPauseSeconds(asOf: stepped) == 40)
        #expect(r.elapsedSeconds(asOf: stepped) == 640)
        #expect(RideDuration.activeSeconds(elapsed: .measured(r.elapsedSeconds(asOf: stepped)),
                                           pausedSeconds: r.pausedSeconds(asOf: stepped)) == 600)
    }

    /// The durably wrong case today: the `max(0,)` clamp stops crediting the stop entirely, so the
    /// ride banks a café stop as riding.
    @Test func aBackwardStepLongerThanTheStopKeepsTheWholeStop() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .stepped(t0.addingTimeInterval(610), by: -40))
        #expect(r.pausedSeconds(asOf: .stepped(t0.addingTimeInterval(700), by: -40)) == 10)
    }

    @Test func aForwardStepMidStopDoesNotMoveEitherNumber() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        let stepped = RideInstant.stepped(t0.addingTimeInterval(640), by: 40)
        #expect(r.currentPauseSeconds(asOf: stepped) == 40)
        #expect(r.elapsedSeconds(asOf: stepped) == 640)
    }

    @Test func aStepSpanningAPauseAndAResumeCreditsTheRealStop() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .stepped(t0.addingTimeInterval(900), by: -40))
        #expect(r.pausedSeconds(asOf: .stepped(t0.addingTimeInterval(1_200), by: -40)) == 300)
    }

    // MARK: what gets persisted

    /// The shape spec revision 1 missed: a ride with no pause at all calls no pause-path code, so
    /// a fix that only corrected the pause path would leave this wrong.
    @Test func anUnpausedRideWithAStepPersistsTheMonotonicDuration() throws {
        let r = startedRecorder()
        let ride = r.end(at: .stepped(t0.addingTimeInterval(3_600), by: 40))
        let d = try #require(ride.duration)
        #expect(d.elapsedSeconds == 3_600)
        #expect(d.activeSeconds == 3_600)
        #expect(ride.startedAt == t0, "the start stamp the rider saw is never rewritten")
        #expect(ride.endedAt == t0.addingTimeInterval(3_600))
    }

    @Test func aPausedRideWithAStepPersistsBothDurations() throws {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .coherent(t0.addingTimeInterval(900)))
        let ride = r.end(at: .stepped(t0.addingTimeInterval(3_600), by: -40))
        let d = try #require(ride.duration)
        #expect(d.elapsedSeconds == 3_600)
        #expect(d.activeSeconds == 3_300)
        #expect(ride.startedAt == t0)
    }

    /// `checkpoint(at:)` keeps both of its stamps raw — a checkpoint row reports no duration at
    /// all, so there is nothing there to correct, and `checkpointedAt` is rendered copy
    /// ("Recording stops at 2:14 PM"). Spec D3.
    @Test func aCheckpointKeepsBothStampsOnTheWallClock() {
        let r = startedRecorder()
        let at = RideInstant.stepped(t0.addingTimeInterval(600), by: -40)
        r.pause(at: at)
        let row = r.checkpoint(at: at)
        #expect(row.startedAt == t0)
        #expect(row.endedAt == at.date)
        #expect(row.checkpointedAt == at.date)
        #expect(row.duration == nil)
    }

    // MARK: the anchors

    @Test func alignAbsorbsAStepIntoTheAnchorStampsOnly() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(600), by: -40))
        #expect(r.startedAt == t0, "the stored stamp never moves")
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-40))
    }

    @Test func alignIsIdempotent() {
        let r = startedRecorder()
        for i in 0..<3 {
            r.align(at: .stepped(t0.addingTimeInterval(600 + Double(i)), by: -40))
        }
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-40))
    }

    @Test func alignIgnoresDivergenceUnderTheThreshold() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(600), by: 1.9))
        #expect(r.anchorStartedAt == t0)
    }

    @Test func aStopOpenedBeforeAStepMovesWithIt() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.align(at: .stepped(t0.addingTimeInterval(640), by: -40))
        #expect(r.anchorPausedSince == t0.addingTimeInterval(560))
    }

    /// The defect the plan gate found in spec revision 2: `wallOffset` corrects a stamp taken on
    /// the *old* clock, and a stop opened after the step is already on the new one. Correcting it
    /// anyway opens the Lock Screen's stop timer at 0:40 — or, on a forward step, 40 s in the
    /// future, counting down.
    @Test func aStopOpenedAfterAStepIsNotCorrectedAgain() {
        for step in [-40.0, 40.0] {
            let r = startedRecorder()
            r.align(at: .stepped(t0.addingTimeInterval(300), by: step))
            let tap = RideInstant.stepped(t0.addingTimeInterval(600), by: step)
            r.pause(at: tap)
            #expect(r.anchorPausedSince == tap.date,
                    "the stop timer opens at zero, step \(step)")
        }
    }

    @Test func aSecondStepMovesAStopOpenedAfterTheFirst() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(300), by: -40))
        let tap = RideInstant.stepped(t0.addingTimeInterval(600), by: -40)
        r.pause(at: tap)
        r.align(at: .stepped(t0.addingTimeInterval(700), by: -70))
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-70))
        #expect(r.anchorPausedSince == tap.date.addingTimeInterval(-30))
    }

    // MARK: active time frozen at the pause
    // These three carry the arithmetic that used to live in RideActiveClockTests'
    // `pausedCarriesStopInstantAndFrozenActive`, `pausedAfterAnEarlierStop` and
    // `frozenActiveClampedAtZero`. It moved here with the code (spec D5).

    @Test func activeSecondsAtPauseIsActiveTimeAtTheTap() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        #expect(r.activeSecondsAtPause == 600)
    }

    @Test func aSecondStopFreezesActiveTimeNetOfTheFirst() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .coherent(t0.addingTimeInterval(660)))
        r.pause(at: .coherent(t0.addingTimeInterval(900)))
        #expect(r.activeSecondsAtPause == 840)
    }

    /// Ending while paused clears both halves of the stop. `closePause` clears `pausedSince` and
    /// its monotonic partner; leaving the frozen active time behind would hand a consumer that
    /// reads both — as the Live Activity's paused payload does — half a pair.
    @Test func endingAPausedRideClearsBothHalvesOfTheStop() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.end(at: .coherent(t0.addingTimeInterval(900)))
        #expect(r.activeSecondsAtPause == nil)
        #expect(r.pausedSince == nil)
    }

    @Test func activeSecondsAtPauseDoesNotMoveDuringTheStopAndClearsOnResume() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.align(at: .coherent(t0.addingTimeInterval(1_200)))
        #expect(r.activeSecondsAtPause == 600)
        r.resume(at: .coherent(t0.addingTimeInterval(1_200)))
        #expect(r.activeSecondsAtPause == nil)
    }
}
