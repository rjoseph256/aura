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
    public static let rungs: [Rung] = [
        Rung(after: 600, identifier: "pause.nudge.1", title: "Ride still paused",
             body: "Your ride has been paused for 10 minutes and isn't recording."),
        Rung(after: 1500, identifier: "pause.nudge.2", title: "Ride still paused",
             body: "Your ride has been paused for 25 minutes and isn't recording."),
        Rung(after: 2700, identifier: "pause.nudge.3", title: "Ride still paused",
             body: "Your ride has been paused for 45 minutes and isn't recording."),
        Rung(after: 4500, identifier: "pause.nudge.4", title: "Ride still paused",
             body: "Your ride has been paused for 75 minutes and isn't recording."),
        Rung(after: 7200, identifier: "pause.nudge.5", title: "Ride still paused",
             body: "Your ride has been paused for 2 hours and isn't recording.")
    ]

    public static var allIdentifiers: [String] { rungs.map(\.identifier) }
}
