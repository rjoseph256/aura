import Foundation
import AuraCore

/// The always-visible Home motivation hook — a specific sentence with a number. Pure and
/// deterministic (injected calendar, fixed POSIX locale) so it is unit-tested on CI. Framing
/// is distance-to-goal (PO decision), with a last-ride fallback when there's no weekly story.
public enum WeeklyGlance {
    public static func headline(week: WeeklyRideStats, goalMeters: Double, lastRide: RideSummary?,
                                units: DistanceUnits, now: Date, calendar: Calendar = .current) -> String {
        if week.rideCount == 0 {
            guard let last = lastRide else { return "Plan your first ride to start your weekly goal" }
            return "\(distanceText(last.distanceMeters, units)) last ride, \(dayText(last.startedAt, now: now, calendar: calendar))"
        }
        let percent = week.goalPercent(goalMeters: goalMeters)
        if percent >= 100 { return "Weekly goal complete — \(percent)%" }
        let remaining = max(0, goalMeters - week.distanceMeters)
        return "\(distanceText(remaining, units)) to your weekly goal"
    }

    public static func ringFraction(week: WeeklyRideStats, goalMeters: Double) -> Double {
        week.goalFraction(goalMeters: goalMeters)
    }

    private static func distanceText(_ meters: Double, _ units: DistanceUnits) -> String {
        let fmt = RideStatsFormatter(units: units)
        return "\(fmt.distanceValue(meters)) \(fmt.distanceUnit)"
    }

    private static func dayText(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: y) { return "yesterday" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"
        return f.string(from: date) // e.g. "Tue"
    }
}
