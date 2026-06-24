import Foundation

/// Pure helpers that turn raw route geometry/annotations into the metrics
/// `AuraCore.CandidateRoute` needs (so `RouteRanker` can label routes).
public enum RouteMetrics {
    /// Distance-weighted share (0...1) of a route you must walk — i.e. dismount and
    /// push the bike. On a cycling profile these are forced-walk segments (stairs,
    /// pedestrian-only links); a higher value means a *less* rideable route, so it is
    /// a penalty for the "Most paths" label, not a reward.
    public static func walkFraction(segments: [(distanceMeters: Double, isWalking: Bool)]) -> Double {
        let total = segments.reduce(0) { $0 + $1.distanceMeters }
        guard total > 0 else { return 0 }
        let walking = segments.reduce(0) { $0 + ($1.isWalking ? $1.distanceMeters : 0) }
        return walking / total
    }

    /// Total climb (m): sum of positive elevation deltas above a noise threshold.
    public static func elevationGain(elevations: [Double], noiseThreshold: Double = 1.0) -> Double {
        guard elevations.count >= 2 else { return 0 }
        var gain = 0.0
        for i in 1..<elevations.count {
            let delta = elevations[i] - elevations[i - 1]
            if delta >= noiseThreshold { gain += delta }
        }
        return gain
    }
}
