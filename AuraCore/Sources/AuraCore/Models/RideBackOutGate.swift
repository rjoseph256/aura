import Foundation

/// Decides whether an in-progress free ride is still short enough to discard silently
/// (back out with no summary) versus long enough that leaving must go through the end-ride
/// confirmation. One constant in one place so the floor is unit-tested and tunable, never a
/// magic number in the view.
public enum RideBackOutGate {
    /// Below this ridden distance, a ride is a mis-tap: backing out discards it with no
    /// summary. ~25 m is a short block, comfortably above the 10 m HealthKit save floor, so
    /// a discardable ride is never one that would have been saved.
    public static let discardFloorMeters: Double = 25

    /// True while the ride can be discarded silently.
    public static func canDiscard(distanceMeters: Double) -> Bool {
        distanceMeters < discardFloorMeters
    }
}
