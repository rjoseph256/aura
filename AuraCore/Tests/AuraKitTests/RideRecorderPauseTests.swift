import Testing
import Foundation
@testable import AuraKit
@testable import AuraCore

/// The recorder half of spec D6: the idle/recording/paused state machine, what `isRecording`
/// means while paused, the GPS-clock pause accounting, and the two live-speed defects a pause
/// would otherwise introduce (a pinned hero, a phantom post-resume spike).
@MainActor
struct RideRecorderPauseTests {
    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    private func pt(_ lat: Double, _ t: TimeInterval, speed: Double? = nil) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80.0),
                   elevation: nil, timestamp: at(t), speedMetersPerSecond: speed)
    }

    // MARK: State machine

    /// The load-bearing decision of this pass: `isRecording` is the app's "a ride is in
    /// progress", not a recorder-internal flag. Five call sites break in five different
    /// directions if a pause clears it (spec D6).
    @Test func pausedRideStillReadsAsRecording() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.pause(at: at(10))
        #expect(r.isRecording)
        #expect(r.isPaused)
    }

    @Test func recordDropsPointsWhilePaused() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.pause(at: at(10))
        r.record(pt(40.001, 20))
        r.record(pt(40.002, 30))
        #expect(r.flattenedPoints.count == 1)
        #expect(r.segments.count == 1)
    }

    @Test func resumeOpensANewSegment() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.pause(at: at(10))
        r.resume(at: at(60))
        r.record(pt(40.001, 60))
        #expect(r.segments.count == 2)
        #expect(r.segments[0].points.count == 1)
        #expect(r.segments[1].points.count == 1)
    }

    @Test func pauseBeforeStartIsANoOp() {
        let r = RideRecorder()
        r.pause(at: at(0))
        #expect(r.isRecording == false)
        #expect(r.isPaused == false)
    }

    @Test func resumeWithoutAPauseIsANoOp() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.resume(at: at(10))
        #expect(r.segments.count == 1, "a stray resume must not open a phantom segment")
    }

    @Test func pauseIsIdempotent() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 10))
        r.pause(at: at(10))
        r.pause(at: at(40))
        r.resume(at: at(70))
        // The second pause must not restamp the open interval: 70 - 10, not 70 - 40.
        #expect(r.pausedSeconds(asOf: at(70)) == 60)
    }

    @Test func restartClearsPauseState() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.pause(at: at(10))
        r.start(at: at(100))
        #expect(r.isPaused == false)
        #expect(r.pausedSeconds(asOf: at(200)) == 0)
        #expect(r.segments.count == 1)
    }

    // MARK: Live speed

    /// `SpeedSmoother` has no time decay and `currentSpeedMetersPerSecond` is written only
    /// inside `record()`, so without an explicit zero a rider who pauses at 25 km/h leaves 25
    /// on the largest numeral in the cockpit for the whole stop — and reads `.moving` to the
    /// crew, whose motion classifier falls back to this value (spec D6/D7).
    @Test func pauseZeroesTheLiveSpeed() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0, speed: 7))
        r.record(pt(40.001, 1, speed: 7))
        #expect(r.currentSpeedMetersPerSecond > 0)
        r.pause(at: at(2))
        #expect(r.currentSpeedMetersPerSecond == 0)
    }

    /// The first fix after a resume must not be position-deltaed against the last fix before
    /// the pause. A short stop plus a displaced reacquisition fix — exactly what the coarser
    /// paused location tier makes likely — would otherwise read as hundreds of m/s on the dial.
    @Test func resumeDoesNotDeltaTheFirstFixAcrossTheGap() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.record(pt(40.001, 10))
        r.pause(at: at(10))
        r.resume(at: at(12))
        // ~1.1 km from the pre-pause fix, 2 s after it on the GPS clock.
        r.record(pt(40.011, 12))
        #expect(r.currentSpeedMetersPerSecond == 0,
                "a resumed segment's first fix has no predecessor to delta against")
    }

    // MARK: Paused accounting

    /// Paused time is measured between the pause and the resume, on the clock the taps arrive
    /// on — which is the clock `startedAt`/`endedAt` and therefore active time are measured on.
    @Test func pausedSecondsMeasuresTheStopItself() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.record(pt(40.001, 10))
        r.pause(at: at(10))
        r.resume(at: at(310))
        r.record(pt(40.002, 310))
        let ride = r.end(at: at(400))
        #expect(ride.pausedSeconds == 300)
    }

    @Test func pausedSecondsSumsAcrossTwoStops() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.pause(at: at(0))
        r.resume(at: at(30))
        r.record(pt(40.001, 30))
        r.pause(at: at(30))
        r.resume(at: at(100))
        r.record(pt(40.002, 100))
        #expect(r.pausedSeconds(asOf: at(100)) == 100)
    }

    /// The point timestamps are a *different clock* from the taps: a replayed fixture carries
    /// the stamps it was recorded with (`golden-ride-paused.gpx` is stamped 2026-07-22) while
    /// the taps arrive at `Date()`. Stamping pause intervals from the track would report the
    /// age of the fixture — years — as paused time, and clamp the active clock to zero for the
    /// rest of the ride. Paused time must not read the track at all.
    @Test func trackTimestampsFromAnotherEpochDoNotPoisonPausedTime() {
        let r = RideRecorder()
        let epoch: TimeInterval = 1_800_000_000     // the "fixture" clock, decades off
        r.start(at: at(0))
        r.record(pt(40.000, epoch))
        r.record(pt(40.001, epoch + 10))
        r.pause(at: at(60))
        r.resume(at: at(90))
        r.record(pt(40.002, epoch + 20))
        let ride = r.end(at: at(120))
        #expect(ride.pausedSeconds == 30)
    }

    /// A fix that arrives stamped *before* the pause began — a cached CoreLocation reading on
    /// reacquisition — must not erase the stop the rider actually took.
    @Test func aStaleFixAfterResumeDoesNotEraseThePause() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 100))
        r.pause(at: at(100))
        r.resume(at: at(700))
        r.record(pt(40.001, 95))    // stamped 5 s before the pause started
        #expect(r.pausedSeconds(asOf: at(700)) == 600)
    }

    /// A pause → resume → pause with no fix in between is two real stops with a moment of
    /// riding between them; both are counted.
    @Test func pauseResumePauseWithNoFixCountsBothStops() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 10))
        r.pause(at: at(10))
        r.resume(at: at(20))
        r.pause(at: at(30))
        r.record(pt(40.001, 40))   // dropped: still paused
        r.resume(at: at(50))
        r.record(pt(40.002, 50))
        #expect(r.pausedSeconds(asOf: at(50)) == 30, "10 → 20 and 30 → 50")
        #expect(r.flattenedPoints.count == 2)
    }

    /// Interior empty segments are legal (spec D6) and the segment-aware stats must survive
    /// them without reaching `points[0]`.
    @Test func interiorEmptySegmentsAreLegalAndDoNotCrashStats() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.pause(at: at(1))          // before the first fix: segment 0 stays empty
        r.resume(at: at(2))
        r.pause(at: at(3))          // segment 1 never gets a point either
        r.resume(at: at(4))
        r.record(pt(40.000, 4))
        r.record(pt(40.001, 14))
        #expect(r.segments.count == 3)
        #expect(r.segments[0].points.isEmpty)
        #expect(r.segments[1].points.isEmpty)
        #expect(r.stats.distanceMeters > 0)
    }

    // MARK: The live clock

    /// The active clock has to fall behind the wall clock *while* the rider is stopped, not
    /// only once the interval closes — the ticker reads this every 0.5 s (spec D5/D6).
    @Test func livePausedSecondsGrowsWhilePaused() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 10))
        r.pause(at: at(10))
        #expect(r.pausedSeconds(asOf: at(40)) == 30)
        #expect(r.pausedSeconds(asOf: at(70)) == 60)
    }

    @Test func livePausedSecondsStopsGrowingAtTheResume() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 10))
        r.pause(at: at(10))
        r.resume(at: at(40))
        #expect(r.pausedSeconds(asOf: at(100)) == 30)
    }

    /// The headline clock is `elapsed - pausedSeconds`, so any jump in paused time is a jump in
    /// the number the rider is watching. It must never move backwards, and it must not step at
    /// the tap, the resume, or the first fix afterwards. Sampled densely across all three.
    @Test func theActiveClockIsMonotonicAcrossAPauseAndResume() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 3))     // last fix is 7 s stale by the time the rider taps
        r.pause(at: at(10))
        var previous = -Double.infinity
        for tick in stride(from: 0.0, through: 60.0, by: 0.5) {
            if tick == 30 { r.resume(at: at(30)) }
            if tick == 45 { r.record(pt(40.001, 45)) }
            let active = at(tick).timeIntervalSince(at(0)) - r.pausedSeconds(asOf: at(tick))
            #expect(active >= previous, "active time went backwards at t=\(tick)")
            previous = active
        }
        #expect(previous == 40, "60 s of ride, 20 s of it paused")
    }

    // MARK: end()

    /// Without closing the open interval, every ride ended while paused over-reports active
    /// time by the length of the tail (spec D6).
    @Test func endWhilePausedClosesTheOpenInterval() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 10))
        r.pause(at: at(10))
        let ride = r.end(at: at(310))
        #expect(ride.pausedSeconds == 300)
        #expect(r.isRecording == false)
        #expect(r.isPaused == false)
    }

    @Test func endWhilePausedDropsTheTrailingEmptySegment() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.record(pt(40.001, 10))
        r.pause(at: at(10))
        r.resume(at: at(70))        // opens an empty segment nothing ever fills
        let ride = r.end(at: at(80))
        #expect(ride.segments.count == 1)
    }

    @Test func anUnpausedRideReportsZeroPausedSeconds() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.record(pt(40.001, 10))
        let ride = r.end(at: at(20))
        #expect(ride.pausedSeconds == 0)
    }

    // MARK: Checkpoint identity

    /// The mid-pause checkpoint and the finished ride are the same ride, so the store updates
    /// one row instead of leaving a duplicate behind (spec D7's pause-boundary flush).
    @Test func theCheckpointCarriesTheIdTheFinishedRideWillHave() {
        let r = RideRecorder()
        r.start(at: at(0))
        r.record(pt(40.000, 0))
        r.record(pt(40.001, 10))
        r.pause(at: at(10))
        let checkpoint = r.checkpoint(at: at(10))
        r.resume(at: at(70))
        r.record(pt(40.002, 70))
        let ride = r.end(at: at(80))
        #expect(checkpoint.id == ride.id)
        // Ends at the pause, because no surface in this app reads `endedAt` — a nil-ended row
        // renders as a finished ride anyway, so it may as well describe the ride that was
        // actually recorded. See `checkpoint(at:)`.
        #expect(checkpoint.endedAt == at(10))
        #expect(checkpoint.segments.count == 1)
        #expect(checkpoint.stats?.distanceMeters ?? 0 > 0, "the checkpoint carries the ride so far")
    }
}
