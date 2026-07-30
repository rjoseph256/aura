import Foundation

/// When to nudge a rider who paused and never resumed, and what to say.
///
/// **A bounded ladder, not a repeating trigger.** A repeating notification cannot rewrite its
/// own body, so it can never say how long the stop has been; it nags a deliberate two-hour
/// lunch a dozen times; and because a long pause is exactly the condition that invites a
/// jetsam kill (spec D7), an orphaned repeat fires every ten minutes forever at a rider who is
/// not going to open the app. Five one-shot rungs fix all three: each states its own duration,
/// the gaps widen as the stop starts to look deliberate, and the worst an orphan can do is five
/// notifications ending two hours after the pause.
///
/// Plain values with no UserNotifications import, so the schedule is unit-tested on the macOS
/// host and the app target holds only the conformer that posts them.
public enum PauseNudgePolicy {
    public struct Rung: Equatable, Sendable {
        /// Seconds after the pause began.
        public let after: TimeInterval
        /// Stable request identifier, so cancellation removes exactly these.
        public let identifier: String
        public let title: String
        public let body: String

        public init(after: TimeInterval, identifier: String, title: String, body: String) {
            self.after = after
            self.identifier = identifier
            self.title = title
            self.body = body
        }
    }

    /// 10, 25, 45, 75 and 120 minutes. Ten minutes clears a coffee queue, a mechanical or a
    /// photo stop without firing; the widening gaps stop punishing a rider who paused on purpose.
    ///
    /// **The copy says what Aura has not recorded, never that the ride is still paused.** These
    /// are scheduled once, at the tap, and then fire from the system whether or not the app is
    /// still alive — and a long stop is the condition most likely to have got the process
    /// jetsammed (see above). After that the ride is not paused, it is gone, and the later
    /// rungs are both the most likely to fire orphaned and the most likely to be lying. "Aura
    /// hasn't recorded anything since you paused 45 minutes ago" is true of a live pause and of
    /// a dead process alike, and it points at the thing the rider actually cares about.
    public static let rungs: [Rung] = [
        Rung(after: 600, identifier: "pause.nudge.1", title: "Aura isn't recording",
             body: "Aura hasn't recorded anything since you paused 10 minutes ago."),
        Rung(after: 1500, identifier: "pause.nudge.2", title: "Aura isn't recording",
             body: "Aura hasn't recorded anything since you paused 25 minutes ago."),
        Rung(after: 2700, identifier: "pause.nudge.3", title: "Aura isn't recording",
             body: "Aura hasn't recorded anything since you paused 45 minutes ago."),
        Rung(after: 4500, identifier: "pause.nudge.4", title: "Aura isn't recording",
             body: "Aura hasn't recorded anything since you paused 75 minutes ago."),
        Rung(after: 7200, identifier: "pause.nudge.5", title: "Aura isn't recording",
             body: "Aura hasn't recorded anything since you paused 2 hours ago.")
    ]

    public static var allIdentifiers: [String] { rungs.map(\.identifier) }

    /// A rung that is still ahead of the stop, paired with the interval its trigger needs.
    public struct PendingRung: Equatable, Sendable {
        public let rung: Rung
        /// Seconds from now until this rung should fire.
        public let interval: TimeInterval

        public init(rung: Rung, interval: TimeInterval) {
            self.rung = rung
            self.interval = interval
        }
    }

    /// The rungs still ahead of a stop that began `elapsedSincePause` seconds ago.
    ///
    /// This is the only arithmetic in the feature, and it lives here rather than in the
    /// app-target conformer because the app target has no test bundle — and the failure mode of
    /// getting it wrong is scheduling *nothing*, which is the exact outcome the ladder's design
    /// note exists to prevent. The conformer is left a loop over this result.
    ///
    /// A stop that has already outrun the whole ladder yields an empty array, which is correct:
    /// every rung's moment has passed, and iOS would reject a non-positive interval anyway.
    public static func pendingRungs(elapsedSincePause: TimeInterval) -> [PendingRung] {
        // A negative elapsed means the caller handed us a pause that has not happened yet;
        // treat it as this instant rather than pushing every rung further out.
        let elapsed = max(0, elapsedSincePause)
        return rungs.compactMap { rung in
            let interval = rung.after - elapsed
            // A non-repeating time-interval trigger only requires a positive interval. The
            // 60-second minimum applies to `repeats: true`, which no rung uses.
            guard interval > 0 else { return nil }
            return PendingRung(rung: rung, interval: interval)
        }
    }
}
