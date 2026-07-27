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

    /// Paused time from stops that have already ended. The stop in progress is added by
    /// `pausedSeconds(asOf:)`; nothing else may read this.
    private var closedPausedSeconds: TimeInterval = 0
    /// When the stop in progress began, or nil if the rider is riding.
    ///
    /// **On the caller's clock — the same one `startedAt` and `endedAt` are on — never the
    /// track's.** Active time is `endedAt - startedAt - pausedSeconds`, so paused time has to
    /// be commensurate with those two or the subtraction is meaningless. `TrackPoint.timestamp`
    /// is a different clock: a replayed fixture carries the stamps it was recorded with, so
    /// measuring a stop against the track would report the fixture's age as paused time; and a
    /// real ride's last accepted fix can be minutes stale through a tunnel, which would
    /// retroactively reclassify those minutes as paused the instant the rider taps.
    ///
    /// This is a deliberate departure from spec D6, which specified the GPS clock. The gap
    /// between two segments is still derivable from the segments themselves when something
    /// needs it; what it cannot be is the number the rider's clock is computed from.
    private var pauseStartedAt: Date?

    public init(kind: Ride.Kind = .freeRide) { self.kind = kind }

    /// Every recorded point in order. **O(n) and allocating on every access** — bind to a
    /// `let`, never read from a SwiftUI `body`.
    public var flattenedPoints: [TrackPoint] { segments.flatMap(\.points) }

    public func start(at date: Date) {
        segments = [RideSegment(points: [])]
        stats = .zero
        startedAt = date
        rideID = UUID()
        state = .recording
        smoother.reset()
        currentSpeedMetersPerSecond = 0
        lastPoint = nil
        closedPausedSeconds = 0
        pauseStartedAt = nil
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
    public func pause(at date: Date) {
        guard state == .recording else { return }
        state = .paused
        // `SpeedSmoother` has no time decay and `currentSpeedMetersPerSecond` is written only
        // in `record()`, so without this a rider who pauses at 25 km/h leaves 25 on the
        // cockpit's largest numeral for the whole stop — and reads `.moving` to the crew,
        // whose motion classifier falls back to this value (spec D6/D7).
        currentSpeedMetersPerSecond = 0
        pauseStartedAt = date
    }

    /// Open a new segment and start recording again.
    ///
    /// `lastPoint` and the smoother are reset so the first post-resume fix has no predecessor
    /// to position-delta against: a short stop plus a displaced reacquisition fix — which the
    /// coarser paused location tier makes likely — would otherwise read as hundreds of m/s on
    /// the dial (spec D6).
    public func resume(at date: Date) {
        guard state == .paused else { return }
        closePause(at: date)
        state = .recording
        segments.append(RideSegment(points: []))
        smoother.reset()
        lastPoint = nil
        currentSpeedMetersPerSecond = 0
    }

    /// Total paused time as of `now`, including the stop in progress. The live active clock is
    /// `elapsed - pausedSeconds(asOf:)`, so this has to grow *while* the rider is stopped, and
    /// it must be continuous at both ends of the stop — it is the largest numeral on the
    /// cockpit, and a number that jumps backwards there is worse than one that is slightly off.
    public func pausedSeconds(asOf now: Date) -> TimeInterval {
        guard let start = pauseStartedAt else { return closedPausedSeconds }
        return closedPausedSeconds + max(0, now.timeIntervalSince(start))
    }

    /// Bank the stop in progress. `max(0,)` guards a caller whose clock ran backwards (an NTP
    /// correction mid-stop); it can only ever drop a stop, never invent one.
    private func closePause(at date: Date) {
        guard let start = pauseStartedAt else { return }
        closedPausedSeconds += max(0, date.timeIntervalSince(start))
        pauseStartedAt = nil
    }

    /// The ride so far, for the pause-boundary flush (spec D7). Carries `rideID`, so the store
    /// updates the same row the finished ride will write rather than accumulating a copy per
    /// pause.
    ///
    /// `endedAt` is the pause instant, **not nil**, even though the ride has not ended. Nil
    /// would be the more truthful encoding, but no surface in this app reads
    /// `RideSummary.endedAt` — History, the last-ride card, the widget snapshot and the weekly
    /// ring all render from the denormalized stats — so a nil-ended row is displayed as a
    /// finished ride regardless. Given that, a row that says "a ride that ended when you
    /// stopped" describes what was actually recorded, while a nil would be an unfinished-ride
    /// claim that nothing in the app is equipped to make. Spec D5 assumes a statless treatment
    /// for nil `endedAt` that does not exist; building it belongs with the pass that owns the
    /// summary.
    public func checkpoint(at date: Date, destinationName: String? = nil) -> Ride {
        Ride(id: rideID, kind: kind, startedAt: startedAt ?? date, endedAt: date,
             segments: normalizedSegments, stats: stats,
             pausedSeconds: pausedSeconds(asOf: date), destinationName: destinationName,
             routeId: nil, destinationPlaceId: nil)
    }

    @discardableResult
    public func end(at date: Date, destinationName: String? = nil) -> Ride {
        // Bank a stop still in progress, or every ride ended while paused over-reports active
        // time by the length of the tail (spec D6).
        closePause(at: date)
        let paused = closedPausedSeconds
        state = .idle
        return Ride(id: rideID, kind: kind, startedAt: startedAt ?? date, endedAt: date,
                    segments: normalizedSegments, stats: stats, pausedSeconds: paused,
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
