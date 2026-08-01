import Foundation

/// The stop currently in progress, as two values stamped together at the pause.
///
/// One optional instead of two: `since` and `activeSecondsAtPause` are non-nil under exactly the
/// same condition, and a half-supplied pair is a state `make` would have to decide about.
public struct RideOpenStop: Equatable, Sendable {
    /// When this stop began, on the current system clock — `RideRecorder.anchorPausedSince`.
    public let since: Date
    /// The ride's active time frozen at that instant — `RideRecorder.activeSecondsAtPause`, which
    /// is where the floor-at-zero this type does not enforce actually lives.
    public let activeSecondsAtPause: TimeInterval

    public init(since: Date, activeSecondsAtPause: TimeInterval) {
        self.since = since
        self.activeSecondsAtPause = activeSecondsAtPause
    }
}

/// What the Live Activity's clock should display, as a value the widget renders without
/// arithmetic. Two cases, because a paused clock answers a different question than a running one
/// (spec D1).
///
/// **Neither case carries a value that moves while the ride is paused**, which is the whole point
/// of the shape: `RideRecorder.pausedSeconds(asOf:)` grows on every tick of a stop, so a clock
/// storing it raw would be a distinct value every tick and the controller's dedupe — which exists
/// precisely for a long stop — could never fire (spec D3). The paused case's values are *frozen at
/// the pause* — the recorder stamps both of them once, at the tap — rather than kept constant by
/// two growing terms cancelling per tick (ROH-130 D5).
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

    /// Build the clock from values that do not move between events.
    ///
    /// **The paused case's fields are copied, not computed; the running anchor is built from
    /// stamps.** The controller skips a push when the whole payload is unchanged, which is what
    /// keeps a forty-minute café stop to one heartbeat push a minute.
    ///
    /// What is banned, and enforced: a value derived from a **wall** elapsed. `now` and a monotonic
    /// reading cannot be sampled at the same instant, so a payload built that way is distinct every
    /// tick and pushes every coalescing interval (ROH-130 D5).
    /// `scripts/check-single-active-definition.sh`'s `betweenStamps` detector is what rejects it.
    ///
    /// A recompute that is monotonic on *both* sides would in fact be stable — both terms come from
    /// one `RideInstant`, so they cancel — and neither a fixture nor the guard script would flag it.
    /// It is avoided anyway, because it re-couples the payload to the tick rate for no benefit. No
    /// test pins that distinction and none can: `FakeRideClock` cannot model the two-syscall
    /// incoherence of a real `RideInstant.now`, so this shape is held by this comment.
    ///
    /// A real clock step moves `startedAt` and `openStop.since` through the recorder's
    /// `wallOffset`, which emits exactly one push and lets the Lock Screen correct itself.
    public static func make(startedAt: Date,
                            pausedSeconds: TimeInterval,
                            openStop: RideOpenStop?,
                            now: Date) -> RideActiveClock {
        if let openStop {
            // Symmetric with the running clamp, and for the same reason: `Text(_, style: .timer)`
            // counts DOWN from a future instant. `RideRecorder.anchorPausedSince` cannot produce
            // one, so this only ever catches a `RideInstant.now` whose two clocks were sampled
            // across a deschedule.
            return .paused(since: min(now, openStop.since),
                           activeSeconds: openStop.activeSecondsAtPause)
        }
        return .running(anchor: RideDuration.runningAnchor(startedAt: startedAt,
                                                           pausedSeconds: pausedSeconds,
                                                           now: now))
    }
}
