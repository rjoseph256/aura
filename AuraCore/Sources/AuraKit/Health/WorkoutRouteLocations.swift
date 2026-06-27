import Foundation
import CoreLocation
import AuraCore

/// Reconstructs `CLLocation`s from a recorded track for `HKWorkoutRouteBuilder`.
/// Pure and CoreLocation-only, so it builds and tests on the macOS CI host; the
/// route builder itself (iOS-only HealthKit) consumes the result in the app target.
public enum WorkoutRouteLocations {
    /// The recorded track was accuracy-filtered at capture (Wave 0), but the per-fix
    /// horizontal accuracy was not retained on `TrackPoint`. The route builder rejects
    /// any location with `horizontalAccuracy <= 0`, so a positive value is synthesized.
    public static let synthesizedHorizontalAccuracy: CLLocationAccuracy = 5

    public static func clLocations(from track: [TrackPoint]) -> [CLLocation] {
        track.compactMap { point in
            let coordinate = CLLocationCoordinate2D(latitude: point.coordinate.latitude,
                                                    longitude: point.coordinate.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            if let elevation = point.elevation {
                return CLLocation(
                    coordinate: coordinate, altitude: elevation,
                    horizontalAccuracy: synthesizedHorizontalAccuracy,
                    verticalAccuracy: synthesizedHorizontalAccuracy,
                    course: -1, speed: -1, timestamp: point.timestamp)
            }
            return CLLocation(
                coordinate: coordinate, altitude: 0,
                horizontalAccuracy: synthesizedHorizontalAccuracy,
                verticalAccuracy: -1,
                course: -1, speed: -1, timestamp: point.timestamp)
        }
    }
}
