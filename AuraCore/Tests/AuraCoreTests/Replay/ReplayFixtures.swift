import Foundation
@testable import AuraCore

/// Segment builders for the replay suites. One point per second unless a builder says
/// otherwise, so "seconds" and "points − 1" are the same number. Distances use the same
/// sphere `Geo.distance` uses (R = 6 371 000 m), so a fixture's meters are the meters the
/// timeline measures, to ~1e-8.
enum ReplayFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let origin = Coordinate(latitude: 40.44, longitude: -79.99)
    static let metersPerDegree = 6_371_000 * Double.pi / 180

    static func east(_ meters: Double, from: Coordinate = origin) -> Coordinate {
        Coordinate(latitude: from.latitude,
                   longitude: from.longitude + meters / (metersPerDegree * cos(from.latitude * .pi / 180)))
    }

    static func north(_ meters: Double, from: Coordinate = origin) -> Coordinate {
        Coordinate(latitude: from.latitude + meters / metersPerDegree, longitude: from.longitude)
    }

    /// `meters` along `bearing` (degrees clockwise from north), flat-earth.
    static func move(_ meters: Double, bearing: Double, from: Coordinate) -> Coordinate {
        let rad = bearing * .pi / 180
        return north(meters * cos(rad), from: east(meters * sin(rad), from: from))
    }

    static func point(_ c: Coordinate, at offset: TimeInterval, elevation: Double? = 300) -> TrackPoint {
        TrackPoint(coordinate: c, elevation: elevation, timestamp: t0.addingTimeInterval(offset))
    }

    /// Straight east at `speed` m/s for `seconds` seconds, first point at `start`.
    static func straight(seconds: Int, speed: Double = 6, start: TimeInterval = 0,
                         from: Coordinate = origin, elevation: (Int) -> Double? = { _ in 300 }) -> RideSegment {
        RideSegment(points: (0...seconds).map { i in
            point(east(Double(i) * speed, from: from), at: start + Double(i), elevation: elevation(i))
        })
    }

    /// `seconds` of GPS jitter around `at`: ±0.2 m, well under the 0.5 m/s stopped threshold.
    static func jitter(seconds: Int, at: Coordinate, start: TimeInterval) -> [TrackPoint] {
        (0..<seconds).map { i in point(east(0.2 * sin(Double(i)), from: at), at: start + Double(i)) }
    }

    /// A quarter circle of radius `radius` m at `speed` m/s. The arc length is what a leg-sum
    /// speed reads; a chord implementation reads less.
    static func quarterCircle(radius: Double = 500, speed: Double = 6, start: TimeInterval = 0) -> RideSegment {
        let seconds = Int((.pi / 2 * radius / speed).rounded(.down))
        return RideSegment(points: (0...seconds).map { i in
            let theta = Double(i) * speed / radius
            return point(north(radius * sin(theta), from: east(radius * cos(theta))), at: start + Double(i))
        })
    }

    /// Legs alternate between bearings 60° and 120° at 6 m/s: the net course is 90° but every
    /// single leg is 30° off it.
    static func zigzag(seconds: Int, start: TimeInterval = 0) -> RideSegment {
        var pts = [point(origin, at: start)]
        var c = origin
        for i in 1...seconds {
            c = move(6, bearing: i.isMultiple(of: 2) ? 60 : 120, from: c)
            pts.append(point(c, at: start + Double(i)))
        }
        return RideSegment(points: pts)
    }

    static func timeline(_ segments: [RideSegment], config: ReplayTimeline.Config = .init()) -> ReplayTimeline {
        ReplayTimeline(segments: segments, config: config)
    }
}
