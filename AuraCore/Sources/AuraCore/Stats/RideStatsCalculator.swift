import Foundation

public enum RideStatsCalculator {
    /// Computes ride statistics from an ordered list of GPS samples.
    /// - movingSpeedThreshold: segments slower than this (m/s) are treated as "stopped".
    /// - elevationNoiseThreshold: positive elevation deltas smaller than this (m) are ignored as GPS noise.
    public static func stats(from points: [TrackPoint],
                             movingSpeedThreshold: Double = 0.5,
                             elevationNoiseThreshold: Double = 1.0) -> RideStats {
        guard points.count >= 2 else { return .zero }

        var distance = 0.0
        var movingTime = 0.0
        var maxSpeed = 0.0
        var elevationGain = 0.0

        for i in 1..<points.count {
            let prev = points[i - 1], curr = points[i]
            let segDistance = Geo.distance(prev.coordinate, curr.coordinate)
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            distance += segDistance

            if dt > 0 {
                let speed = segDistance / dt
                if speed >= movingSpeedThreshold {
                    movingTime += dt
                    maxSpeed = max(maxSpeed, speed)
                }
            }

            if let e1 = prev.elevation, let e2 = curr.elevation {
                let delta = e2 - e1
                if delta >= elevationNoiseThreshold { elevationGain += delta }
            }
        }

        let avgSpeed = movingTime > 0 ? distance / movingTime : 0
        return RideStats(distanceMeters: distance,
                         movingTimeSeconds: movingTime,
                         averageSpeedMetersPerSecond: avgSpeed,
                         maxSpeedMetersPerSecond: maxSpeed,
                         elevationGainMeters: elevationGain)
    }
}
