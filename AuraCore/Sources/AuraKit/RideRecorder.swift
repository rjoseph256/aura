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

    /// Paused time from intervals that have already closed. The in-flight interval is added
    /// by `pausedSeconds(asOf:)`; nothing else may read this.
    private var closedPausedSeconds: TimeInterval = 0
    /// Start of the pause interval currently being measured. Set at `pause(at:)` and cleared
    /// when the interval closes — at the first fix after a resume, or at `end(at:)`.
    private var openPauseStart: Date?
    /// The `resume(at:)` that is still waiting for its first fix. While it is set the paused
    /// total stops growing: the rider is riding again, there is just no GPS stamp yet to
    /// close the interval with.
    private var pendingResume: Date?
    /// Timestamp of the most recent recorded fix, kept across resumes. Distinct from
    /// `lastPoint`, which the speed pipeline resets at every resume; this one is the GPS clock
    /// that pause intervals are stamped against.
    private var lastPointTimestamp: Date?

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
        openPauseStart = nil
        pendingResume = nil
        lastPointTimestamp = nil
    }

    public func record(_ point: TrackPoint) {
        guard state == .recording, !segments.isEmpty else { return }
        // The first fix of a resumed segment closes the pause interval on the GPS clock, so
        // `pausedSeconds` stays reconcilable with the gap between the two segments and
        // survives accelerated replay (spec D6). `max(0,)` absorbs a stale first fix.
        if let start = openPauseStart {
            closedPausedSeconds += max(0, point.timestamp.timeIntervalSince(start))
            openPauseStart = nil
            pendingResume = nil
        }
        segments[segments.count - 1].points.append(point)
        stats = RideStatsCalculator.stats(segments: segments)
        // Doppler speed when present, else position-delta from the previous fix; fed to
        // the smoother at the GPS timestamp (NOT wall-clock) so sim/GPX replay is
        // deterministic.
        let instant = InstantaneousSpeed.between(previous: lastPoint, current: point)
        currentSpeedMetersPerSecond = smoother.add(instant, at: point.timestamp)
        lastPoint = point
        lastPointTimestamp = point.timestamp
    }

    /// Close the current segment and stop recording, without ending the ride.
    ///
    /// The interval is stamped from the most recent fix rather than from `date`, because
    /// paused time is measured on the same clock as the points (spec D6); `date` is used only
    /// before the first fix, when there is no GPS clock yet. A pause that arrives while an
    /// interval is already open (a resume that never got a fix) leaves that interval alone —
    /// nothing was ridden in between, so it never really closed.
    public func pause(at date: Date) {
        guard state == .recording else { return }
        state = .paused
        // `SpeedSmoother` has no time decay and `currentSpeedMetersPerSecond` is written only
        // in `record()`, so without this a rider who pauses at 25 km/h leaves 25 on the
        // cockpit's largest numeral for the whole stop — and reads `.moving` to the crew,
        // whose motion classifier falls back to this value (spec D6/D7).
        currentSpeedMetersPerSecond = 0
        pendingResume = nil
        if openPauseStart == nil { openPauseStart = lastPointTimestamp ?? date }
    }

    /// Open a new segment and start recording again.
    ///
    /// `lastPoint` and the smoother are reset so the first post-resume fix has no predecessor
    /// to position-delta against: a short stop plus a displaced reacquisition fix — which the
    /// coarser paused location tier makes likely — would otherwise read as hundreds of m/s on
    /// the dial (spec D6).
    public func resume(at date: Date) {
        guard state == .paused else { return }
        state = .recording
        segments.append(RideSegment(points: []))
        smoother.reset()
        lastPoint = nil
        currentSpeedMetersPerSecond = 0
        pendingResume = date
    }

    /// Total paused time as of `now`, including the interval in flight. The live active clock
    /// is `elapsed - pausedSeconds(asOf:)`, so this has to grow *while* the rider is stopped
    /// rather than only when the interval closes.
    public func pausedSeconds(asOf now: Date) -> TimeInterval {
        guard let start = openPauseStart else { return closedPausedSeconds }
        return closedPausedSeconds + max(0, (pendingResume ?? now).timeIntervalSince(start))
    }

    /// The ride so far, for the pause-boundary flush (spec D7). Carries `rideID`, so the store
    /// updates the same row the finished ride will write, and `endedAt: nil`, because the ride
    /// has not ended — a jetsam kill during a long pause leaves an honest unfinished ride
    /// rather than a fabricated end time.
    public func checkpoint(at date: Date, destinationName: String? = nil) -> Ride {
        Ride(id: rideID, kind: kind, startedAt: startedAt ?? date, endedAt: nil,
             segments: normalizedSegments, stats: stats,
             pausedSeconds: pausedSeconds(asOf: date), destinationName: destinationName,
             routeId: nil, destinationPlaceId: nil)
    }

    @discardableResult
    public func end(at date: Date, destinationName: String? = nil) -> Ride {
        // Close any interval still open, or every ride ended while paused over-reports active
        // time by the length of the tail (spec D6). `date` is the ride's end stamp — the same
        // clock `endedAt`, and therefore elapsed, is measured on.
        let paused = pausedSeconds(asOf: date)
        state = .idle
        openPauseStart = nil
        pendingResume = nil
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
