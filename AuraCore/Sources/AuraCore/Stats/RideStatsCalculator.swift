import Foundation

public enum RideStatsCalculator {
    /// Computes ride statistics from an ordered list of GPS samples.
    /// - movingSpeedThreshold: legs slower than this (m/s) are treated as "stopped".
    /// - elevationNoiseThreshold: positive elevation deltas smaller than this (m) are ignored as GPS noise.
    ///
    /// Retained beside `stats(segments:)` for callers that genuinely hold one contiguous run
    /// of points (the golden-ride record helper, the stats snapshot test).
    public static func stats(from points: [TrackPoint],
                             movingSpeedThreshold: Double = 0.5,
                             elevationNoiseThreshold: Double = 1.0) -> RideStats {
        finish(walk(points, movingSpeedThreshold: movingSpeedThreshold,
                    elevationNoiseThreshold: elevationNoiseThreshold))
    }

    /// Statistics over a segmented ride. Every pairwise quantity is computed strictly
    /// *inside* a segment, so a pause contributes no distance, no moving time, no elevation
    /// gain and can never set max speed. Distance, moving time and gain sum; max speed is the
    /// maximum over segments; average speed is recomputed once from the totals rather than
    /// averaged from per-segment averages (spec D4).
    ///
    /// Deliberately NOT an overload of `stats(from:)`: an existing call site passes a bare
    /// `[]` literal, which two same-labelled array overloads render ambiguous.
    public static func stats(segments: [RideSegment],
                             movingSpeedThreshold: Double = 0.5,
                             elevationNoiseThreshold: Double = 1.0) -> RideStats {
        var total = Accumulator()
        for segment in segments {
            // The `count >= 2` guard lives inside `walk`, so it is applied per segment
            // rather than once for the whole ride. Moving it up would leave the per-segment
            // body reaching `points[0]` on an empty segment — an index-out-of-range crash on
            // the main actor, and empty segments are reachable once pause exists (D6).
            total.merge(walk(segment.points, movingSpeedThreshold: movingSpeedThreshold,
                             elevationNoiseThreshold: elevationNoiseThreshold))
        }
        return finish(total)
    }

    /// Per-segment totals, before average speed is derived.
    private struct Accumulator {
        var distance = 0.0
        var movingTime = 0.0
        var maxSpeed = 0.0
        var elevationGain = 0.0

        mutating func merge(_ other: Accumulator) {
            distance += other.distance
            movingTime += other.movingTime
            maxSpeed = max(maxSpeed, other.maxSpeed)
            elevationGain += other.elevationGain
        }
    }

    /// The pairwise walk over ONE contiguous run of points. Fewer than two points has no
    /// pairs and therefore contributes nothing.
    private static func walk(_ points: [TrackPoint],
                             movingSpeedThreshold: Double,
                             elevationNoiseThreshold: Double) -> Accumulator {
        var acc = Accumulator()
        guard points.count >= 2 else { return acc }

        // Carry the last known elevation forward across points that lack one, so a
        // climb straddling a nil-elevation sample is bridged rather than dropped. Local to
        // this run, so the baseline resets at every segment boundary — the step across a
        // pause is elevation the rider did not ride under power.
        var lastElevation = points[0].elevation

        for i in 1..<points.count {
            let prev = points[i - 1], curr = points[i]
            let legDistance = Geo.distance(prev.coordinate, curr.coordinate)
            let dt = curr.timestamp.timeIntervalSince(prev.timestamp)
            acc.distance += legDistance

            if dt > 0 {
                let speed = legDistance / dt
                if speed >= movingSpeedThreshold {
                    acc.movingTime += dt
                    acc.maxSpeed = max(acc.maxSpeed, speed)
                }
            }

            if let e2 = curr.elevation {
                if let e1 = lastElevation {
                    let delta = e2 - e1
                    if delta >= elevationNoiseThreshold { acc.elevationGain += delta }
                }
                lastElevation = e2
            }
        }
        return acc
    }

    private static func finish(_ acc: Accumulator) -> RideStats {
        let avgSpeed = acc.movingTime > 0 ? acc.distance / acc.movingTime : 0
        return RideStats(distanceMeters: acc.distance,
                         movingTimeSeconds: acc.movingTime,
                         averageSpeedMetersPerSecond: avgSpeed,
                         maxSpeedMetersPerSecond: acc.maxSpeed,
                         elevationGainMeters: acc.elevationGain)
    }
}
