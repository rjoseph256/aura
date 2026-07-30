import Foundation

/// Every string the pause control and its state chip render, as plain values so they are
/// unit-tested on the host rather than eyeballed in a SwiftUI preview.
///
/// The clock is deliberately its own function rather than a `Duration.formatted` call: the chip
/// sits beside a Saira cockpit numeral at 56 pt of row height, and a localized "4 min 12 sec"
/// would wrap where "4:12" does not.
public enum PauseControlCopy {
    /// The word on the control.
    public static func buttonLabel(isPaused: Bool) -> String {
        isPaused ? "Resume" : "Pause"
    }

    /// The VoiceOver label. Changes with state instead of pairing a fixed label with a toggle
    /// value, because "Pause ride, on" does not say whether "on" is the pause or the ride.
    public static func accessibilityLabel(isPaused: Bool) -> String {
        isPaused ? "Resume ride" : "Pause ride"
    }

    /// Posted after the state changes, so a VoiceOver rider learns it landed without having to
    /// re-read the control.
    public static func announcement(isPaused: Bool) -> String {
        isPaused ? "Ride paused" : "Ride resumed"
    }

    public static let stateChipLabel = "PAUSED"

    /// `m:ss`, growing an hours field past an hour. Clamps negatives to zero.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// The chip's composed VoiceOver read. Spelled out, because "4:12" is read as a time of day.
    ///
    /// Grows an hours field past an hour, in the same spirit as `clock(_:)`: `PauseNudgePolicy`
    /// nudges at 75 and 120 minutes, so a long pause is exactly the case this has to read well
    /// for. A zero-valued trailing unit is omitted ("Paused for 1 minute", not "1 minute 0
    /// seconds"); once an hours field is showing, minutes below it round to the coarser grain a
    /// screen reader expects ("Paused for 1 hour 5 minutes", not "...5 minutes 0 seconds").
    public static func chipAccessibilityLabel(pausedSeconds: TimeInterval) -> String {
        let total = Int(max(0, pausedSeconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)

        func unit(_ value: Int, _ name: String) -> String {
            "\(value) \(name)\(value == 1 ? "" : "s")"
        }

        if h > 0 {
            guard m > 0 else { return "Paused for \(unit(h, "hour"))" }
            return "Paused for \(unit(h, "hour")) \(unit(m, "minute"))"
        }
        guard m > 0 else { return "Paused for \(unit(s, "second"))" }
        guard s > 0 else { return "Paused for \(unit(m, "minute"))" }
        return "Paused for \(unit(m, "minute")) \(unit(s, "second"))"
    }
}
