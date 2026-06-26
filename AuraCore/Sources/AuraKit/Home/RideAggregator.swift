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

/// Rolls a list of ride summaries up into the home dashboard's figures. `now` and
/// `calendar` are injectable so the week boundary (and "this week" membership) are
/// deterministic in tests rather than tied to the wall clock / device locale.
public enum RideAggregator {

    /// Sum of every summary that *started* within the calendar week containing `now`.
    /// A statless summary carries `0` for its stat fields, so it counts toward
    /// `rideCount` but contributes no distance (it can't move the ring), matching
    /// what History would display.
    public static func weekToDate(_ rides: [RideSummary], now: Date,
                                  calendar: Calendar = .current) -> WeeklyRideStats {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return .zero }
        var out = WeeklyRideStats.zero
        for ride in rides where week.contains(ride.startedAt) {
            out.rideCount += 1
            out.distanceMeters += ride.distanceMeters
            out.elevationGainMeters += ride.elevationGainMeters
            out.movingTimeSeconds += ride.movingTimeSeconds
        }
        return out
    }

    /// The most recently started summary, if any.
    public static func mostRecent(_ rides: [RideSummary]) -> RideSummary? {
        rides.max { $0.startedAt < $1.startedAt }
    }

    /// Whether the ride identified by `rideID` ties or beats every other ride in
    /// `rides` by distance — the "Longest ride yet" badge rule. `rides` is the full
    /// saved set (the just-finished ride included), and `distance` is that ride's own
    /// distance. Returns `false` unless the distance is positive and there's more than
    /// one ride, so a lone first ride doesn't trumpet a record. Reads only the cheap
    /// `distanceMeters` column, so callers never have to fault a GPS track.
    public static func isLongest(rideID: UUID, distanceMeters distance: Double,
                                 among rides: [RideSummary]) -> Bool {
        guard distance > 0, rides.count > 1 else { return false }
        return rides.allSatisfy { $0.id == rideID || $0.distanceMeters <= distance }
    }
}
