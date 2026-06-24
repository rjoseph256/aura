import Foundation
import AuraCore

/// The glanceable week-to-date figures the home dashboard's ring shows. Pure value
/// type so the aggregation is testable without SwiftData or a view.
public struct WeeklyRideStats: Equatable, Sendable {
    public var distanceMeters: Double
    public var rideCount: Int
    public var elevationGainMeters: Double
    public var movingTimeSeconds: Double

    public static let zero = WeeklyRideStats(distanceMeters: 0, rideCount: 0,
                                             elevationGainMeters: 0, movingTimeSeconds: 0)

    public init(distanceMeters: Double, rideCount: Int,
                elevationGainMeters: Double, movingTimeSeconds: Double) {
        self.distanceMeters = distanceMeters
        self.rideCount = rideCount
        self.elevationGainMeters = elevationGainMeters
        self.movingTimeSeconds = movingTimeSeconds
    }

    /// Progress toward the weekly goal, clamped to `0...1` for the ring's arc.
    public func goalFraction(goalMeters: Double) -> Double {
        guard goalMeters > 0 else { return 0 }
        return min(1, max(0, distanceMeters / goalMeters))
    }

    /// Whole-percent of the weekly goal — uncapped, so an over-goal week reads "120%".
    public func goalPercent(goalMeters: Double) -> Int {
        guard goalMeters > 0 else { return 0 }
        return Int((distanceMeters / goalMeters * 100).rounded())
    }
}

/// Rolls a list of persisted rides up into the home dashboard's figures. `now` and
/// `calendar` are injectable so the week boundary (and "this week" membership) are
/// deterministic in tests rather than tied to the wall clock / device locale.
public enum RideAggregator {

    /// Sum of every ride that *started* within the calendar week containing `now`.
    /// Rides without computed `stats` count toward `rideCount` but contribute no
    /// distance (they can't move the ring), matching what History would display.
    public static func weekToDate(_ rides: [Ride], now: Date,
                                  calendar: Calendar = .current) -> WeeklyRideStats {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return .zero }
        var out = WeeklyRideStats.zero
        for ride in rides where week.contains(ride.startedAt) {
            out.rideCount += 1
            if let s = ride.stats {
                out.distanceMeters += s.distanceMeters
                out.elevationGainMeters += s.elevationGainMeters
                out.movingTimeSeconds += s.movingTimeSeconds
            }
        }
        return out
    }

    /// The most recently started ride, if any.
    public static func mostRecent(_ rides: [Ride]) -> Ride? {
        rides.max { $0.startedAt < $1.startedAt }
    }
}
