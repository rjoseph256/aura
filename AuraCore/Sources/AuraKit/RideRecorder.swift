import Foundation
import Observation
import AuraCore

/// Accumulates a live ride from incoming TrackPoints and recomputes stats as it goes.
/// Observable so SwiftUI views update on each new sample.
@Observable
@MainActor
public final class RideRecorder {
    /// The recorder's lifecycle. A pause is a state of a *running* ride, not a stop — see
    /// `isRecording` below.
    public enum State: Sendable, Equatable { case idle, recording, paused }

    public private(set) var state: State = .idle

    /// **True while paused.** This is not a recorder-internal flag: it is the app's notion of
    /// "a ride is in progress", and five call sites read it that way (spec D6) — `finish()`'s
    /// guard (End would discard a paused ride), the coordinator's ticker guard (a `return`,
    /// so the ticker would never come back), `start()`'s re-entry guard (a re-entrant start
    /// wipes the track), and both HUDs' `router.isRideActive` mirror, which is the only thing
    /// stopping a deep link from tearing the HUD down into `cancel()` — which does not save.
    /// Use `isPaused` for the paused reading.
    public var isRecording: Bool { state != .idle }
    public var isPaused: Bool { state == .paused }

    /// The instant the stop in progress began as it was *stamped*, or nil while recording.
    ///
    /// The stored stamp, never rewritten by a clock correction — the same rule `startedAt`
    /// follows. `anchorPausedSince` is what the Live Activity's paused clock counts up from:
    /// the OS renders that anchor against its own wall clock inside the widget process, so it
    /// needs the stamp expressed on the *current* system clock (ROH-130 D2).
    public var pausedSince: Date? { pauseStartedAt }

    /// The ride so far, split at pauses: a pause closes the current segment and a resume
    /// opens the next one, so two points in different segments were never adjacent.
    public private(set) var segments: [RideSegment] = []
    public private(set) var stats: RideStats = .zero
    public private(set) var startedAt: Date?
    /// Identity of the ride being recorded, fixed at `start(at:)`. The mid-pause checkpoint
    /// and the ride `end(at:)` returns share it, so the store updates one row rather than
    /// accumulating a copy per pause.
    public private(set) var rideID = UUID()
    /// Smoothed live speed for the HUD dial — current speed, not the ride average.
    public private(set) var currentSpeedMetersPerSecond: Double = 0

    private let kind: Ride.Kind
    // Untracked state for the live-speed pipeline; the published value above is what
    // SwiftUI observes.
    private var smoother = SpeedSmoother()
    private var lastPoint: TrackPoint?

    /// Paused time from stops that have already ended, measured monotonically. The stop in
    /// progress is added by `pausedSeconds(asOf:)`; nothing else may read this.
    private var closedPausedSeconds: TimeInterval = 0
    /// When the stop in progress began, on the wall clock.
    ///
    /// Stamped once per stop and never rewritten, like `startedAt`. These two are what gets
    /// persisted and what History shows, and a rider reads a ride's start time as its identity —
    /// so a clock correction moves the *durations*, which are measured elsewhere, and leaves these
    /// alone (ROH-130 D2).
    ///
    /// On the caller's clock, never the track's. `TrackPoint.timestamp` is a third clock: a
    /// replayed fixture carries the stamps it was recorded with, and a real ride's last accepted
    /// fix can be minutes stale through a tunnel, which would retroactively reclassify those
    /// minutes as paused the instant the rider taps. A deliberate departure from spec D6.
    private var pauseStartedAt: Date?
    /// The monotonic partner of each stamp above. Written and cleared in the same statement as its
    /// partner. **Every duration this type reports is a difference of these**, so no duration can
    /// move when civil time does.
    private var startMonotonic: TimeInterval?
    private var pauseStartMonotonic: TimeInterval?
    /// The value `wallOffset` had when `pauseStartedAt` was stamped.
    ///
    /// **This is what stops a step being applied twice.** `wallOffset` converts a stamp taken on
    /// the *old* clock onto the current one. `startedAt` always qualifies, because `start()` zeroes
    /// the offset. A stop opened *after* a step does not: its stamp is already on the corrected
    /// clock. Correcting it anyway opened the Lock Screen's stop timer at 0:40, or — on a forward
    /// step — 40 s in the future counting down, which is worse than the bug being fixed.
    private var pauseStartWallOffset: TimeInterval?
    /// Active time frozen at the instant of the pause.
    ///
    /// Not recomputed per tick. The Live Activity's paused payload carries it, and
    /// `RideActivityPushPolicy` skips a push only when the whole payload is unchanged — so a value
    /// that moved by a rounding error every tick would push every 4 s for the length of a café
    /// stop instead of once a minute (ROH-130 D5).
    public private(set) var activeSecondsAtPause: TimeInterval?
    /// What to add to a wall stamp taken when the offset was zero to express it on the *current*
    /// system clock.
    ///
    /// Consumed only by `anchorStartedAt` and `anchorPausedSince`, which the Live Activity's two
    /// anchors are built from. The OS renders those anchors against its own wall clock inside the
    /// widget process, so without this a step would leave the Lock Screen off by the step for the
    /// rest of the ride while the cockpit stayed right. Nothing persisted depends on it.
    private var wallOffset: TimeInterval = 0

    /// Below this, a wall/monotonic disagreement is NTP slewing rather than a clock set, and
    /// correcting it would move the Live Activity anchor continuously — defeating the push dedupe
    /// the discreteness exists to protect.
    private static let clockStepThreshold: TimeInterval = 2

    public init(kind: Ride.Kind = .freeRide) { self.kind = kind }

    /// Every recorded point in order. **O(n) and allocating on every access** — bind to a
    /// `let`, never read from a SwiftUI `body`.
    public var flattenedPoints: [TrackPoint] { segments.flatMap(\.points) }

    public func start(at instant: RideInstant) {
        segments = [RideSegment(points: [])]
        stats = .zero
        startedAt = instant.date
        startMonotonic = instant.monotonicSeconds
        rideID = UUID()
        state = .recording
        smoother.reset()
        currentSpeedMetersPerSecond = 0
        lastPoint = nil
        closedPausedSeconds = 0
        pauseStartedAt = nil
        pauseStartMonotonic = nil
        pauseStartWallOffset = nil
        activeSecondsAtPause = nil
        wallOffset = 0
    }

    public func record(_ point: TrackPoint) {
        guard state == .recording, !segments.isEmpty else { return }
        segments[segments.count - 1].points.append(point)
        stats = RideStatsCalculator.stats(segments: segments)
        // Doppler speed when present, else position-delta from the previous fix; fed to
        // the smoother at the GPS timestamp (NOT wall-clock) so sim/GPX replay is
        // deterministic.
        let instant = InstantaneousSpeed.between(previous: lastPoint, current: point)
        currentSpeedMetersPerSecond = smoother.add(instant, at: point.timestamp)
        lastPoint = point
    }

    /// Close the current segment and stop recording, without ending the ride. Idempotent: a
    /// second pause leaves the stop in progress alone rather than restamping it.
    public func pause(at instant: RideInstant) {
        guard state == .recording else { return }
        // Before the stamp, so a stop opened right after a step records the *corrected* offset as
        // its own and is not corrected a second time.
        align(at: instant)
        state = .paused
        // `SpeedSmoother` has no time decay and `currentSpeedMetersPerSecond` is written only in
        // `record()`, so without this a rider who pauses at 25 km/h leaves 25 on the cockpit's
        // largest numeral for the whole stop — and reads `.moving` to the crew (spec D6/D7).
        currentSpeedMetersPerSecond = 0
        activeSecondsAtPause = RideDuration.activeSeconds(
            elapsed: .measured(elapsedSeconds(asOf: instant)),
            pausedSeconds: pausedSeconds(asOf: instant))
        pauseStartedAt = instant.date
        pauseStartMonotonic = instant.monotonicSeconds
        pauseStartWallOffset = wallOffset
    }

    /// Open a new segment and start recording again.
    ///
    /// `lastPoint` and the smoother are reset so the first post-resume fix has no predecessor
    /// to position-delta against: a short stop plus a displaced reacquisition fix — which the
    /// coarser paused location tier makes likely — would otherwise read as hundreds of m/s on
    /// the dial (spec D6).
    public func resume(at instant: RideInstant) {
        guard state == .paused else { return }
        align(at: instant)
        closePause(at: instant)
        state = .recording
        segments.append(RideSegment(points: []))
        smoother.reset()
        lastPoint = nil
        currentSpeedMetersPerSecond = 0
        activeSecondsAtPause = nil
    }

    /// Wall-clock time since the ride started, measured monotonically. Includes time spent paused;
    /// `RideDuration.activeSeconds` is what subtracts that.
    public func elapsedSeconds(asOf instant: RideInstant) -> TimeInterval {
        guard let startMonotonic else { return 0 }
        return max(0, instant.monotonicSeconds - startMonotonic)
    }

    /// Total paused time as of `instant`, including the stop in progress. The live active clock is
    /// `elapsed - pausedSeconds`, so this has to grow *while* the rider is stopped.
    public func pausedSeconds(asOf instant: RideInstant) -> TimeInterval {
        closedPausedSeconds + currentPauseSeconds(asOf: instant)
    }

    /// The stop **in progress** only, or zero when recording — the number the cockpit's chip
    /// shows. `pausedSeconds(asOf:)` is the ride's running total across every stop.
    ///
    /// The `max(0,)` cannot fire on a monotonic input. It stays because it costs nothing; the
    /// coordinator's non-decreasing clamp, which *could* wedge a displayed number, does not.
    public func currentPauseSeconds(asOf instant: RideInstant) -> TimeInterval {
        guard let pauseStartMonotonic else { return 0 }
        return max(0, instant.monotonicSeconds - pauseStartMonotonic)
    }

    /// Note how far the system clock has drifted from this ride's monotonic timeline, and absorb a
    /// genuine step into `wallOffset`.
    ///
    /// An explicit call, never a side effect of a getter: making a read mutate would put the
    /// correctness of `checkpoint(at:)` at the mercy of argument evaluation order. Called once per
    /// ticker tick from `RideSessionCoordinator.refreshElapsed`, and at each pause boundary.
    ///
    /// Idempotent — after an update, `expected` recomputes against the new offset and `delta` is
    /// zero, so a step is corrected once rather than compounded per tick. That is also what stops
    /// slew from flapping the anchor: a correction resets the divergence, so the next one has to
    /// re-accumulate the whole threshold.
    public func align(at instant: RideInstant) {
        guard let startedAt else { return }
        let expected = startedAt.addingTimeInterval(wallOffset + elapsedSeconds(asOf: instant))
        let delta = instant.date.timeIntervalSince(expected)
        if abs(delta) > Self.clockStepThreshold { wallOffset += delta }
    }

    /// The ride's start expressed on the *current* system clock, for the Live Activity's running
    /// anchor. Not what gets persisted — see `startedAt`.
    public var anchorStartedAt: Date? { startedAt?.addingTimeInterval(wallOffset) }

    /// The open stop's start on the current system clock, for the Live Activity's paused clock.
    /// Only the offset accrued *since the stop opened* applies; see `pauseStartWallOffset`.
    public var anchorPausedSince: Date? {
        guard let pauseStartedAt, let pauseStartWallOffset else { return nil }
        return pauseStartedAt.addingTimeInterval(wallOffset - pauseStartWallOffset)
    }

    /// Bank the stop in progress. `max(0,)` guards a caller whose clock ran backwards (an NTP
    /// correction mid-stop); it can only ever drop a stop, never invent one.
    private func closePause(at instant: RideInstant) {
        guard let pauseStartMonotonic else { return }
        closedPausedSeconds += max(0, instant.monotonicSeconds - pauseStartMonotonic)
        pauseStartedAt = nil
        self.pauseStartMonotonic = nil
        pauseStartWallOffset = nil
    }

    /// The ride so far, for the pause-boundary flush (spec D7). Carries `rideID`, so the store
    /// updates the same row the finished ride will write rather than accumulating a copy per
    /// pause.
    ///
    /// `endedAt` is the pause instant, **not nil**. Nil would be the more literal encoding of
    /// "not ended", but it costs the row its elapsed and active time, and it cannot tell a
    /// second synced device that this ride is being recorded right now rather than abandoned.
    /// `checkpointedAt` carries that instead (ROH-107, spec D1), and it additionally records
    /// what the recording covers — a rider who resumed and was killed later while riding has a
    /// row whose track stops well before they did.
    ///
    /// Both stamps stay on the wall clock, unlike `end(at:)`. A checkpoint row writes `endedAt`
    /// and `checkpointedAt` to the same instant and `RideDuration` disqualifies it on exactly that
    /// equality, so it reports no duration for a monotonic correction to fix — and
    /// `checkpointedAt` is rendered copy ("Recording stops at 2:14 PM", and again in the warning
    /// before an all-devices delete). Spec D3.
    public func checkpoint(at instant: RideInstant, destinationName: String? = nil) -> Ride {
        Ride(id: rideID, kind: kind, startedAt: startedAt ?? instant.date, endedAt: instant.date,
             segments: normalizedSegments, stats: stats,
             pausedSeconds: pausedSeconds(asOf: instant), checkpointedAt: instant.date,
             destinationName: destinationName,
             routeId: nil, destinationPlaceId: nil)
    }

    @discardableResult
    public func end(at instant: RideInstant, destinationName: String? = nil) -> Ride {
        // Bank a stop still in progress, or every ride ended while paused over-reports active time
        // by the length of the tail (spec D6).
        closePause(at: instant)
        let paused = closedPausedSeconds
        let start = startedAt ?? instant.date
        // Derived, not `instant.date`: `endedAt - startedAt` is this ride's elapsed time, and a
        // wall pair spanning a clock step is not (ROH-130 D3). After a backward step this sits
        // slightly ahead of the current wall clock; nothing renders `endedAt`, and the alternative
        // is a wrong duration on the number the summary leads with.
        let ended = start.addingTimeInterval(elapsedSeconds(asOf: instant))
        state = .idle
        return Ride(id: rideID, kind: kind, startedAt: start, endedAt: ended,
                    segments: normalizedSegments, stats: stats, pausedSeconds: paused,
                    checkpointedAt: nil,
                    destinationName: destinationName, routeId: nil, destinationPlaceId: nil)
    }

    /// `segments` with trailing empties dropped, so "no points" has one encoding — zero
    /// segments — matching `Ride(track: [])` and the persisted round trip. INTERIOR empties
    /// are legal and must survive (spec D6); only the tail goes.
    ///
    /// Deliberately not written back to `self.segments`: normalizing here would mutate live
    /// state as a side effect of producing a return value. This does mean `recorder.segments`
    /// and the returned ride's can disagree after a no-fix ride — harmless, since the HUD that
    /// reads the recorder is torn down by then.
    private var normalizedSegments: [RideSegment] {
        var closed = segments
        while let last = closed.last, last.points.isEmpty { closed.removeLast() }
        return closed
    }
}
