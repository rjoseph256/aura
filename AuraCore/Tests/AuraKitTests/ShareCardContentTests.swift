import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ShareCardContentTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")
    /// 2026-07-01T12:00:00Z
    private let startedAt = Date(timeIntervalSince1970: 1_782_907_200)

    private func stats(distance: Double = 8046.72, moving: Double = 2520,
                       climb: Double = 73.152) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: moving,
                  averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 9,
                  elevationGainMeters: climb)
    }

    private func point(_ lat: Double, _ lon: Double, elevation: Double? = nil) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: elevation, timestamp: startedAt)
    }

    private func ride(track: [TrackPoint] = [], stats: RideStats? = nil,
                      destination: String? = nil) -> Ride {
        Ride(kind: .freeRide, startedAt: startedAt, endedAt: nil, track: track,
             stats: stats, destinationName: destination, routeId: nil, destinationPlaceId: nil)
    }

    @Test func imperialStrings() {
        let c = ShareCardContent(ride: ride(stats: stats()), units: .imperial,
                                 locale: posix, timeZone: utc)
        #expect(c.distanceValue == "5.0")       // 8046.72 m -> 5.0 mi
        #expect(c.distanceUnit == "mi")
        #expect(c.movingTime == "42 min")        // 2520 s
        #expect(c.climbedValue == "240")         // 73.152 m -> 240 ft
        #expect(c.climbedUnit == "ft")
    }

    @Test func metricStrings() {
        let c = ShareCardContent(ride: ride(stats: stats()), units: .metric,
                                 locale: posix, timeZone: utc)
        #expect(c.distanceValue == "8.0")        // 8046.72 m -> 8.0 km
        #expect(c.distanceUnit == "km")
        #expect(c.climbedValue == "73")          // meters, rounded
        #expect(c.climbedUnit == "m")
    }

    @Test func dateTextIsDeterministic() {
        let c = ShareCardContent(ride: ride(stats: stats()), units: .imperial,
                                 locale: posix, timeZone: utc)
        #expect(c.dateText == "Jul 1, 2026")
    }

    @Test func elevationRequiresTwoSamples() {
        let two = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 20)], stats: stats())
        #expect(ShareCardContent(ride: two, units: .imperial).elevationSamples == [10, 20])

        let one = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: nil)], stats: stats())
        #expect(ShareCardContent(ride: one, units: .imperial).elevationSamples.isEmpty)

        let none = ride(track: [point(0, 0), point(1, 1)], stats: stats())
        #expect(ShareCardContent(ride: none, units: .imperial).elevationSamples.isEmpty)
    }

    @Test func routeRequiresTwoPoints() {
        let multi = ride(track: [point(0, 0), point(1, 1)], stats: stats())
        #expect(ShareCardContent(ride: multi, units: .imperial).routeCoordinates.count == 2)

        let single = ride(track: [point(0, 0)], stats: stats())
        #expect(ShareCardContent(ride: single, units: .imperial).routeCoordinates.isEmpty)
    }

    @Test func destinationTrimmedAndNilled() {
        #expect(ShareCardContent(ride: ride(stats: stats(), destination: "  Millvale "),
                                 units: .imperial).destinationName == "Millvale")
        #expect(ShareCardContent(ride: ride(stats: stats(), destination: "   "),
                                 units: .imperial).destinationName == nil)
        #expect(ShareCardContent(ride: ride(stats: stats()), units: .imperial).destinationName == nil)
    }

    @Test func statsNilProducesZeroedStrings() {
        let c = ShareCardContent(ride: ride(stats: nil), units: .imperial,
                                 locale: posix, timeZone: utc)
        #expect(c.distanceValue == "0.0")
        #expect(c.movingTime == "0 min")
        #expect(c.climbedValue == "0")
    }
}
