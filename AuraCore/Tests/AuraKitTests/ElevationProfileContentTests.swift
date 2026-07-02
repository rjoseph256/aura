import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ElevationProfileContentTests {
    private func pt(_ e: Double?) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 0),
                   elevation: e, timestamp: Date(timeIntervalSince1970: 0))
    }
    private func stats(climb: Double) -> RideStats {
        RideStats(distanceMeters: 8046.72, movingTimeSeconds: 2520,
                  averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 9,
                  elevationGainMeters: climb)
    }
    private func ride(track: [TrackPoint], climb: Double) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
             track: track, stats: stats(climb: climb), destinationName: nil,
             routeId: nil, destinationPlaceId: nil)
    }

    @Test func imperialClimbStrings() {
        let c = ElevationProfileContent(ride: ride(track: [pt(10), pt(40)], climb: 73.152),
                                        units: .imperial)
        #expect(c.climbedValue == "240")           // 73.152 m -> 240 ft
        #expect(c.climbedUnit == "ft")
        #expect(c.climbedUnitSpoken == "feet")
        #expect(c.kind == .profile([10, 40]))
    }

    @Test func metricClimbStrings() {
        let c = ElevationProfileContent(ride: ride(track: [pt(10), pt(40)], climb: 73.152),
                                        units: .metric)
        #expect(c.climbedValue == "73")
        #expect(c.climbedUnit == "m")
        #expect(c.climbedUnitSpoken == "meters")
    }

    @Test func trivialClimbFlagsWhenFormattedZero() {
        // Flat ride, gain rounds to 0 -> isTrivialClimb true, kind .flat.
        let c = ElevationProfileContent(ride: ride(track: [pt(12), pt(12)], climb: 0),
                                        units: .imperial)
        #expect(c.kind == .flat)
        #expect(c.isTrivialClimb == true)
        #expect(c.climbedValue == "0")
    }

    @Test func flatButNonTrivialClimb() {
        // 6 m gain (< 10 m floor) -> flat, but formatted climb is non-zero.
        let c = ElevationProfileContent(ride: ride(track: [pt(10), pt(13)], climb: 6),
                                        units: .imperial)
        #expect(c.kind == .flat)
        #expect(c.isTrivialClimb == false)         // 6 m -> "20" ft
    }

    @Test func preElevationRideIsUnavailable() {
        let c = ElevationProfileContent(ride: ride(track: [pt(nil), pt(nil)], climb: 0),
                                        units: .imperial)
        #expect(c.kind == .unavailable)
    }

    @Test func accessibilityLabelsPerState() {
        let profile = ElevationProfileContent(ride: ride(track: [pt(10), pt(40)], climb: 73.152),
                                              units: .imperial)
        #expect(profile.accessibilityLabel == "Elevation. Climbed 240 feet.")
        let flat = ElevationProfileContent(ride: ride(track: [pt(10), pt(13)], climb: 6),
                                           units: .imperial)
        #expect(flat.accessibilityLabel == "Mostly flat. Climbed 20 feet.")
        let trivial = ElevationProfileContent(ride: ride(track: [pt(12), pt(12)], climb: 0),
                                              units: .imperial)
        #expect(trivial.accessibilityLabel == "Mostly flat.")
        let unavailable = ElevationProfileContent(ride: ride(track: [pt(nil), pt(nil)], climb: 0),
                                                  units: .imperial)
        #expect(unavailable.accessibilityLabel == nil)
    }
}
