import Foundation
import AuraCore

/// The formatted cruising-state line the navigate HUD's trip strip renders: the road
/// the rider is on, the distance left to the destination, and the arrival ETA. Pure
/// and engine-independent, mirroring `TurnCardState`. Unlike `TurnCardPresenter`,
/// which formats its maneuver distance imperial-only, this is unit-aware.
public struct CruisingState: Equatable, Sendable {
    /// Current road, e.g. "Penn Ave". nil omits the label.
    public var streetName: String?
    /// Distance left to the destination, e.g. "2.1 mi". nil shows a placeholder.
    public var distanceRemaining: String?
    /// Arrival clock, e.g. "4:38 PM". nil shows a placeholder.
    public var eta: String?
    /// One composed VoiceOver read for the whole strip, e.g.
    /// "On Penn Ave, 2.1 miles to go, arriving 4:38 PM".
    public var accessibilityLabel: String
    /// The same read with the arrival time dropped, for a paused ride whose ETA is no longer
    /// meaningful. Pure, so the wording is tested rather than eyeballed (ROH-101 P4).
    public var pausedAccessibilityLabel: String

    public init(streetName: String?, distanceRemaining: String?, eta: String?, accessibilityLabel: String,
                pausedAccessibilityLabel: String) {
        self.streetName = streetName
        self.distanceRemaining = distanceRemaining
        self.eta = eta
        self.accessibilityLabel = accessibilityLabel
        self.pausedAccessibilityLabel = pausedAccessibilityLabel
    }

    /// Before the first usable progress update; the strip reads a calm "Starting…".
    public static let starting = CruisingState(streetName: nil, distanceRemaining: nil, eta: nil,
                                               accessibilityLabel: "Starting navigation.",
                                               pausedAccessibilityLabel: "Starting navigation.")
}

/// Turns a `GuidanceUpdate` into a `CruisingState`. Pure: the caller passes `now` and a
/// `Calendar`, so the ETA clock is deterministic in tests instead of reading the wall clock.
public enum CruisingPresenter {
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             now: Date,
                             calendar: Calendar = .current) -> CruisingState {
        let streetName = street(update.currentStreetName)
        let distanceRemaining = distance(update.distanceRemainingMeters, units: units)
        let eta = eta(update.durationRemainingSeconds, now: now, calendar: calendar)
        return CruisingState(
            streetName: streetName,
            distanceRemaining: distanceRemaining,
            eta: eta,
            accessibilityLabel: label(streetName: streetName,
                                      meters: update.distanceRemainingMeters,
                                      eta: eta, units: units),
            pausedAccessibilityLabel: label(streetName: streetName,
                                            meters: update.distanceRemainingMeters,
                                            eta: nil, units: units))
    }

    /// Empty or whitespace-only names (unnamed trails) become nil so the strip omits them.
    private static func street(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    /// Composes `RideStatsFormatter`'s value and unit ("2.1" + "mi" -> "2.1 mi").
    private static func distance(_ meters: Double?, units: DistanceUnits) -> String? {
        guard let meters, meters > 0 else { return nil }
        let formatter = RideStatsFormatter(units: units)
        return "\(formatter.distanceValue(meters)) \(formatter.distanceUnit)"
    }

    /// Arrival = now + remaining, formatted to a locale-aware short time so a 12-hour
    /// locale gets "4:38 PM" and a 24-hour locale gets "16:38".
    private static func eta(_ seconds: Double?, now: Date, calendar: Calendar) -> String? {
        // Accepts `>= 0` (unlike the distance guard's `> 0`): zero seconds means "arriving
        // now", which is a valid ETA, whereas zero meters remaining is indistinguishable
        // from "not yet known" and so reads as a placeholder.
        guard let seconds, seconds >= 0 else { return nil }
        let arrival = now.addingTimeInterval(seconds)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: arrival)
    }

    /// Composes the spoken strip read from the resolved parts, omitting whichever clause
    /// has no value. Distance is spelled from the raw meters (so "2.1 miles", not "2.1 mi").
    private static func label(streetName: String?, meters: Double?, eta: String?,
                              units: DistanceUnits) -> String {
        var clauses: [String] = []
        if let streetName { clauses.append("On \(streetName)") }
        if let meters, meters > 0 {
            let formatter = RideStatsFormatter(units: units)
            clauses.append("\(formatter.distanceValue(meters)) \(formatter.distanceUnitSpoken) to go")
        }
        if let eta { clauses.append("arriving \(eta)") }
        return clauses.isEmpty ? "Starting navigation." : clauses.joined(separator: ", ")
    }
}
