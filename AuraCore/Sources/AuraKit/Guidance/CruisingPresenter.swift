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

    public init(streetName: String?, distanceRemaining: String?, eta: String?) {
        self.streetName = streetName
        self.distanceRemaining = distanceRemaining
        self.eta = eta
    }

    /// Before the first usable progress update; the strip reads a calm "Starting…".
    public static let starting = CruisingState(streetName: nil, distanceRemaining: nil, eta: nil)
}

/// Turns a `GuidanceUpdate` into a `CruisingState`. Pure: the caller passes `now` and a
/// `Calendar`, so the ETA clock is deterministic in tests instead of reading the wall clock.
public enum CruisingPresenter {
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             now: Date,
                             calendar: Calendar = .current) -> CruisingState {
        CruisingState(streetName: street(update.currentStreetName),
                      distanceRemaining: distance(update.distanceRemainingMeters, units: units),
                      eta: eta(update.durationRemainingSeconds, now: now, calendar: calendar))
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
        guard let seconds, seconds >= 0 else { return nil }
        let arrival = now.addingTimeInterval(seconds)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: arrival)
    }
}
