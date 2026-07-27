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

    @Test func gainGateDrivesElevationSamples() {
        // Discriminating cases: their result DIFFERS between the old 5 m-range gate and
        // the new 10 m-gain gate, so they go red against the un-migrated source and green
        // after — a real TDD red, not a coincidence that passes both ways.
        // Big range (30 m) but low gain (6 m < 10) -> empty. (Old range gate kept it.)
        let bigRangeLowGain = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 40)],
                                   stats: stats(climb: 6))
        #expect(ShareCardContent(ride: bigRangeLowGain, units: .imperial).elevationSamples.isEmpty)
        // Small range (3 m) but real gain (30 m >= 10) -> kept. (Old range gate dropped it.)
        let smallRangeRealGain = ride(track: [point(0, 0, elevation: 100), point(1, 1, elevation: 103)],
                                      stats: stats(climb: 30))
        #expect(ShareCardContent(ride: smallRangeRealGain, units: .imperial).elevationSamples == [100, 103])
        // Real climb -> kept (agrees under both gates; sanity anchor).
        let real = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 40)], stats: stats())
        #expect(ShareCardContent(ride: real, units: .imperial).elevationSamples == [10, 40])
    }

    @Test func cardAndSummaryClassifyIdentically() {
        // The card draws the silhouette (non-empty samples) exactly when the summary is
        // `.profile`, with the same samples; both are empty for `.flat` and `.unavailable`.
        func assertParity(_ r: Ride) {
            let cardSamples = ShareCardContent(ride: r, units: .imperial).elevationSamples
            switch ElevationProfileContent(ride: r, units: .imperial).kind {
            case .profile(let s): #expect(cardSamples == s)
            case .flat, .unavailable: #expect(cardSamples.isEmpty)
            }
        }
        // Profile.
        assertParity(ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 40)], stats: stats()))
        // Boundary: gain exactly 10 -> profile on both.
        assertParity(ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 20)], stats: stats(climb: 10)))
        // Flat.
        assertParity(ride(track: [point(0, 0, elevation: 12), point(1, 1, elevation: 12)], stats: stats(climb: 2)))
        // Discriminating: big range, low gain -> flat/empty (fails before migration, passes after).
        assertParity(ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 40)], stats: stats(climb: 6)))
        // Unavailable: no elevation samples.
        assertParity(ride(track: [point(0, 0), point(1, 1)], stats: stats(climb: 0)))
    }

    @Test func routeSegments_needTwoPointsInARun() {
        let multi = ride(track: [point(0, 0), point(1, 1)], stats: stats())
        #expect(ShareCardContent(ride: multi, units: .imperial).routeSegments.count == 1)
        #expect(ShareCardContent(ride: multi, units: .imperial).routeSegments[0].count == 2)
        let single = ride(track: [point(0, 0)], stats: stats())
        #expect(ShareCardContent(ride: single, units: .imperial).routeSegments.isEmpty)
    }

    @Test func routeSegments_keepSegmentsApart() {
        let paused = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                          endedAt: nil,
                          segments: [RideSegment(points: [point(0, 0), point(0, 1)]),
                                     RideSegment(points: [point(5, 5), point(5, 6)])],
                          stats: stats(), routeId: nil, destinationPlaceId: nil)
        let content = ShareCardContent(ride: paused, units: .imperial)
        #expect(content.routeSegments.count == 2)
        #expect(content.routeSegments.allSatisfy { $0.count == 2 })
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
