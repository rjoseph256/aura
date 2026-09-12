#if DEBUG
import Foundation

/// Deterministic rides for the replay suites and the DEBUG seed (spec §9). Not a fixture of
/// anything real: a loop around a center at a constant 6 m/s with four stops placed where the
/// playback regime needs them. In the library rather than the test target because the app's
/// DEBUG seed inserts it into the store; `#if DEBUG` keeps it out of release.
public enum SyntheticRide {
    static let center = Coordinate(latitude: 40.44, longitude: -79.99)
    public static let threeHourID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    /// 3 hours, one point per second, 10,800 points in two segments (split at i == 5400):
    /// - i 1800…2099: 300 s of jitter (a `.stopped` hold)
    /// - between i 5399 and 5400: the second segment starts 601 s after the first ends (`.paused`)
    /// - i 7200 (in the second segment): one leg stamped 120 s late spanning 700 m (`.signalLost`),
    ///   followed by a backwards stamp that normalizes to zero width
    /// - i 9000…9089: 90 s of jitter (`.stopped`)
    /// Elevation is a slow three-lobe wave over 300–380 m so the profile has a shape.
    public static func threeHour(startingAt start: Date) -> Ride {
        let speed = 6.0
        let totalSeconds = 10_800
        let radius = speed * Double(totalSeconds) / (2 * .pi)
        let metersPerDegreeLat = 6_371_000 * Double.pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * cos(center.latitude * .pi / 180)

        func onLoop(_ meters: Double) -> Coordinate {
            let theta = meters / radius
            return Coordinate(latitude: center.latitude + radius * sin(theta) / metersPerDegreeLat,
                              longitude: center.longitude + radius * cos(theta) / metersPerDegreeLon)
        }
        func elevation(_ meters: Double) -> Double { 340 + 40 * sin(3 * meters / radius) }
        func jitter(_ c: Coordinate, _ i: Int) -> Coordinate {
            Coordinate(latitude: c.latitude + 0.2 * sin(Double(i)) / metersPerDegreeLat,
                       longitude: c.longitude + 0.2 * cos(Double(i)) / metersPerDegreeLon)
        }

        var first: [TrackPoint] = [], second: [TrackPoint] = []
        var meters = 0.0
        for i in 0..<totalSeconds {
            let stamp = start.addingTimeInterval(Double(i))
            let stationary = (1800..<2100).contains(i) || (9000..<9090).contains(i)
            var point: TrackPoint
            if stationary {
                point = TrackPoint(coordinate: jitter(onLoop(meters), i), elevation: elevation(meters), timestamp: stamp)
            } else if i == 7200 {
                meters += 700
                point = TrackPoint(coordinate: onLoop(meters), elevation: elevation(meters),
                                   timestamp: stamp.addingTimeInterval(119))
            } else {
                point = TrackPoint(coordinate: onLoop(meters), elevation: elevation(meters), timestamp: stamp)
                meters += speed
            }
            if i < 5400 {
                first.append(point)
            } else {
                point.timestamp = point.timestamp.addingTimeInterval(600)
                second.append(point)
            }
        }
        let segments = [RideSegment(points: first), RideSegment(points: second)]
        return Ride(id: threeHourID, kind: .freeRide, startedAt: start, endedAt: second[second.count - 1].timestamp,
                    segments: segments, stats: RideStatsCalculator.stats(segments: segments), pausedSeconds: 600,
                    destinationName: nil, routeId: nil, destinationPlaceId: nil)
    }
}
#endif
