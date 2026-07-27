import Foundation

/// What to write to Health for one finished ride, framework-free so the mapping
/// is testable on the macOS CI host. The HealthKit-touching code lives in the app
/// target and consumes this value.
public struct WorkoutData: Equatable, Sendable {
    public let externalID: UUID
    public let start: Date
    public let end: Date
    public let distanceMeters: Double
    public let route: [TrackPoint]

    public init(externalID: UUID, start: Date, end: Date,
                distanceMeters: Double, route: [TrackPoint]) {
        self.externalID = externalID
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.route = route
    }

    /// Maps a finished ride. `end` falls back from `endedAt` to the last track
    /// timestamp to `startedAt`, then is clamped to `>= start` so a degenerate or
    /// clock-skewed ride can never produce `end < start` (which `HKWorkoutBuilder`
    /// rejects).
    ///
    /// Flattens deliberately: Slice A does not write `HKWorkoutEvent(type: .pause)`, so a
    /// ride ended after a long pause is still written to Health with wall-clock duration.
    /// Known inaccuracy, listed as out of scope in the segmented-rides spec.
    public init(from ride: Ride) {
        let points = ride.flattenedPoints
        let rawEnd = ride.endedAt ?? points.last?.timestamp ?? ride.startedAt
        self.externalID = ride.id
        self.start = ride.startedAt
        self.end = max(rawEnd, ride.startedAt)
        self.distanceMeters = ride.stats?.distanceMeters ?? 0
        self.route = points
    }
}
