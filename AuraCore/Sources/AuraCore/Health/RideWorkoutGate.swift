import Foundation

/// Pure decision for whether a finished ride should be written to Health.
public enum RideWorkoutGate {
    /// Minimum recorded distance (meters) worth a Health workout. Keeps an
    /// accidental few-second ride from littering Health with junk.
    public static let minimumDistanceMeters: Double = 10

    public static func shouldWrite(ride: Ride, saveToHealthEnabled: Bool) -> Bool {
        guard saveToHealthEnabled else { return false }
        guard ride.endedAt != nil else { return false }
        return (ride.stats?.distanceMeters ?? 0) >= minimumDistanceMeters
    }
}
