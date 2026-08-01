import Foundation

/// What the Live Activity's clock should display, as a value the widget renders without
/// arithmetic. Two cases, because a paused clock answers a different question than a running one
/// (spec D1).
///
/// **Neither case carries a value that moves while the ride is paused**, which is the whole point
/// of the shape: `RideRecorder.pausedSeconds(asOf:)` grows on every tick of a stop, so a clock
/// storing it raw would be a distinct value every tick and the controller's dedupe — which exists
/// precisely for a long stop — could never fire (spec D3).
///
/// **Wire-format note.** This type is `Codable` inside `RideActivityAttributes.ContentState`, so
/// an activity in flight across an app update is decoded by a *new* binary from bytes an *old* one
/// wrote. Adding a case is safe; **renaming a case or an associated-value label is not** — the new
/// binary would throw and strand the activity on its last rendered frame.
public enum RideActiveClock: Codable, Hashable, Sendable {
    /// Active time is `now - anchor`, rendered by the OS via `Text(anchor, style: .timer)` with
    /// no per-second pushes. `anchor` is `startedAt + pausedSeconds`, never in the future.
    case running(anchor: Date)
    /// `since` is the instant this stop began — the widget counts *up* from it, so the paused
    /// clock keeps moving and answers "how long have I been stopped". `activeSeconds` is the
    /// ride's active time frozen at that instant, carried for the ride's end, not rendered.
    case paused(since: Date, activeSeconds: TimeInterval)

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// Build the clock from the three numbers the recorder holds.
    ///
    /// **`pausedSeconds` must be measured as of `now`** — `RideRecorder.pausedSeconds(asOf: now)`,
    /// which includes the stop currently open. That coupling is what makes the paused case
    /// constant through a stop: both terms grow in lockstep, so their difference does not.
    /// A caller that measures the two at different instants reintroduces D3's trap.
    ///
    /// `pausedSince` is non-nil exactly while a stop is open, so it — not a separate flag —
    /// selects the case.
    public static func make(startedAt: Date,
                            pausedSeconds: TimeInterval,
                            pausedSince: Date?,
                            now: Date) -> RideActiveClock {
        let activeSeconds = RideDuration.activeSeconds(
            elapsed: .betweenStamps(startedAt: startedAt, endedAt: now),
            pausedSeconds: pausedSeconds)
        if let pausedSince {
            return .paused(since: pausedSince, activeSeconds: activeSeconds)
        }
        // Anchored at `now` less the active seconds, which is identical to
        // `startedAt + pausedSeconds` whenever that is in the past, and equal to `now` when it is
        // not: a backward wall-clock step can push `startedAt + pausedSeconds` past `now`, and
        // `Text(_, style: .timer)` with a future anchor counts DOWN. The clamp now lives inside
        // `RideDuration.activeSeconds`, which is why this reads as a subtraction from `now`
        // rather than an addition to `startedAt`. While it is active the anchor tracks `now` and
        // the clock reads 0:00, which costs a push per coalescing interval until wall-clock
        // catches up — bounded by the size of the backward step, and strictly better than a Lock
        // Screen counting down. The in-app clock clamps for the same reason
        // (`RideSessionCoordinator.refreshElapsed`); the residual wall-clock weakness is ROH-130.
        return .running(anchor: now.addingTimeInterval(-activeSeconds))
    }
}
