import Foundation

/// Elapsed ride time, carrying where it came from.
///
/// The one definition of active time subtracts paused seconds from elapsed seconds, and those two
/// numbers have to be on the same clock or the subtraction is meaningless. A bare `TimeInterval`
/// cannot say which clock it is on, so this exists to make the wrong one require typing
/// `betweenStamps` at a live call site — which `scripts/check-single-active-definition.sh` then
/// rejects outside this file (ROH-130 D4).
public struct RideElapsed: Equatable, Sendable {
    public let seconds: TimeInterval

    /// A monotonic measurement — `RideRecorder.elapsedSeconds(asOf:)`. What every live clock uses.
    public static func measured(_ seconds: TimeInterval) -> RideElapsed {
        RideElapsed(seconds: max(0, seconds))
    }

    /// The interval between a finished ride's two stamps. **Legal for a saved ride and nothing
    /// else.** It is correct there because `RideRecorder.end(at:)` derives `endedAt` from the
    /// monotonic elapsed, so the pair spans no clock step; used for a running ride it would be a
    /// wall subtraction and ROH-130 all over again.
    public static func betweenStamps(startedAt: Date, endedAt: Date) -> RideElapsed {
        RideElapsed(seconds: max(0, endedAt.timeIntervalSince(startedAt)))
    }

    private init(seconds: TimeInterval) { self.seconds = seconds }
}

/// A finished ride's two durations.
///
/// The counterpart of `RideActiveClock`, which answers the same question while the ride is still
/// running. Both route through `activeSeconds(elapsed:pausedSeconds:)` below, so the number the
/// rider watched on the HUD and the number the summary shows cannot drift (parent spec D5).
public struct RideDuration: Equatable, Sendable {
    /// Wall clock from the start of the ride to its end.
    public let elapsedSeconds: TimeInterval
    /// `elapsedSeconds` less the time the rider spent paused. Equal to elapsed on any ride with no
    /// recorded pauses, which includes every ride recorded before pause existed.
    public let activeSeconds: TimeInterval

    /// Nil when this ride's end instant cannot be trusted as the end of the *riding*.
    ///
    /// **This is deliberately NOT `isUnfinished`, and must not be "corrected" into it.**
    /// `Ride.isUnfinished` is `checkpointedAt != nil || endedAt == nil`, and two different rides
    /// satisfy its first clause:
    ///
    /// - **A checkpoint row.** `RideRecorder.checkpoint(at:)` writes `endedAt` and
    ///   `checkpointedAt` to the *same* instant, the pause. The rider may have resumed and ridden
    ///   for another hour before the kill, so the interval can be a fraction of the real ride.
    ///   Reporting "30 min" for a 90-minute ride is confidently wrong in a way the unfinished
    ///   badge does not cover: a rider reads that badge as "the last bit is missing".
    /// - **A ride that failed to save.** `RideSessionCoordinator.finish()`'s catch branch restores
    ///   the marker onto a ride whose `endedAt` came from `RideRecorder.end(at:)` — the real End
    ///   tap, strictly *after* the checkpoint. Both durations are exactly known, and this is the
    ///   summary the rider is looking at the moment their ride failed to save. Blanking it there,
    ///   beside a real distance and a real top speed, reads as "the app lost my ride".
    ///
    /// So the disqualifier is `checkpointedAt >= endedAt`, which selects the first and spares the
    /// second. `RideDurationTests.saveFailureRideKeepsItsDuration` is what pins that rule;
    /// `RideSessionCheckpointFlushTests.swift:238` is context for why that second state exists —
    /// it asserts the underlying ride's `endedAt` is set, not anything about `RideDuration`.
    ///
    /// A nil `endedAt` with no marker is the legacy PR #90 dev-build row, also nil here.
    public init?(startedAt: Date, endedAt: Date?, checkpointedAt: Date?,
                 pausedSeconds: TimeInterval) {
        guard let endedAt else { return nil }
        if let checkpointedAt, checkpointedAt >= endedAt { return nil }

        // Clamped, and NOT asserted — the clamp lives inside `RideElapsed.betweenStamps` now, not
        // here. Revision 1 trapped here on the theory that only a degenerate recorder state
        // produces it; tracing `checkpoint(at:)` and `end(at:)` shows neither can (both collapse
        // to a zero interval, not a negative one). The real producer is a backward wall-clock
        // step — the same clock-skew residual ROH-130 documents rather than eliminates, since
        // `checkpointedAt` stays on the raw wall clock while `endedAt` is monotonic-derived (see
        // `RideRecorder.end(at:)`) — and unlike `RideMigrationPlan`'s assertion,
        // which runs once over local data inside a migration, this runs inside
        // `RideSummaryView.body` over rows CloudKit mirrored from another device. A trap there
        // fails the summary screen, the UI-test suite, and the device pass for a clock skew the
        // app already knows it does not handle.
        let elapsed = RideElapsed.betweenStamps(startedAt: startedAt, endedAt: endedAt)
        elapsedSeconds = elapsed.seconds

        // The persisted column is floored HERE, not inside the shared primitive: the two live
        // clocks read `RideRecorder.pausedSeconds(asOf:)`, which is structurally non-negative and
        // bounded by the session, while this reads a CloudKit-mirrored `Double`
        // (`RideSchemaV7.swift:42`). Without this floor, a negative value renders active ABOVE
        // elapsed, with the caption present to make it unmissable. An oversized stored value
        // needs no matching upper clamp here: the primitive already floors its own result at
        // zero, so `max(0, elapsed - pausedSeconds)` cannot exceed `elapsed` for any
        // non-negative `pausedSeconds` — `RideDurationTests.activeIsBoundedByElapsed` pins this.
        activeSeconds = RideDuration.activeSeconds(elapsed: elapsed,
                                                   pausedSeconds: max(0, pausedSeconds))
    }

    /// **The one definition of active time**: elapsed time less time spent paused.
    ///
    /// Every clock calls this and nothing re-derives it — the HUD's live number
    /// (`RideSessionCoordinator.refreshElapsed`), the value frozen at a pause
    /// (`RideRecorder.pause(at:)`), and the finished ride's (`init` above). Parent spec D5 makes
    /// their agreement a product requirement: the rider must see the same clock after the ride
    /// that they watched during it. `scripts/check-single-active-definition.sh` is what keeps that
    /// true.
    ///
    /// `RideElapsed` is what records which clock the elapsed half came from; see its doc comment.
    public static func activeSeconds(elapsed: RideElapsed,
                                     pausedSeconds: TimeInterval) -> TimeInterval {
        max(0, elapsed.seconds - pausedSeconds)
    }

    /// Where the Live Activity's running timer counts up from.
    ///
    /// Lives here, and not in `RideActiveClock`, because the expression it needs is
    /// `addingTimeInterval(pausedSeconds)` and this file is the guard script's only exemption.
    ///
    /// Deliberately built from stamps rather than as `now - activeSeconds`: both inputs move only
    /// at a pause boundary, so the anchor is byte-identical between boundaries and the Live
    /// Activity's push dedupe survives (ROH-130 D5). The `min` keeps a future anchor — which
    /// `Text(_, style: .timer)` counts DOWN from — off the Lock Screen. While that clamp binds the
    /// anchor tracks `now` and costs a push per coalescing interval.
    public static func runningAnchor(startedAt: Date, pausedSeconds: TimeInterval,
                                     now: Date) -> Date {
        min(now, startedAt.addingTimeInterval(pausedSeconds))
    }
}

extension Ride {
    /// This ride's durations, or nil when its end instant cannot be trusted. See
    /// `RideDuration.init`, which explains why this is not `isUnfinished`.
    public var duration: RideDuration? {
        RideDuration(startedAt: startedAt, endedAt: endedAt,
                     checkpointedAt: checkpointedAt, pausedSeconds: pausedSeconds)
    }
}
