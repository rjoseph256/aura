import Foundation
import AuraCore

/// Composes the SpeedRail's VoiceOver strings. Pure and unit-aware, so the cockpit's
/// most-glanced element reads as coherent speech instead of mechanical fragments, and
/// the composition is unit-tested in CI rather than buried in the SwiftUI view.
public enum SpeedRailVoice {
    /// The speed element's spoken value, e.g. "24 miles per hour". Used as the
    /// `accessibilityValue` so it re-announces alone as the (slow-moving average) speed
    /// changes, while the static "Speed" label does not.
    public static func speedValue(_ stats: RideStats, units: DistanceUnits) -> String {
        let formatter = RideStatsFormatter(units: units)
        return "\(formatter.speedValue(stats.averageSpeedMetersPerSecond)) \(formatter.speedUnitSpoken)"
    }

    /// The free-ride stats element, e.g.
    /// "Distance 5.0 miles, time 12 minutes 30 seconds, elevation gain 340 feet".
    public static func statsLabel(_ stats: RideStats, elapsed: TimeInterval, units: DistanceUnits) -> String {
        let formatter = RideStatsFormatter(units: units)
        let distance = "\(formatter.distanceValue(stats.distanceMeters)) \(formatter.distanceUnitSpoken)"
        let elevation = "\(formatter.elevationValue(stats.elevationGainMeters)) \(formatter.elevationUnitSpoken)"
        return "Distance \(distance), time \(spokenElapsed(elapsed)), elevation gain \(elevation)"
    }

    /// Spells elapsed seconds, singularizing the unit words and dropping a zero component:
    /// 750 -> "12 minutes 30 seconds", 45 -> "45 seconds", 720 -> "12 minutes",
    /// 61 -> "1 minute 1 second", 0 -> "0 seconds".
    static func spokenElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if minutes == 0 { return plural(secs, "second") }
        if secs == 0 { return plural(minutes, "minute") }
        return "\(plural(minutes, "minute")) \(plural(secs, "second"))"
    }
}
