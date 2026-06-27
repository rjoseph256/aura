import Testing
import Foundation
import CoreLocation
import AuraCore
@testable import AuraKit

@Suite struct WorkoutRouteLocationsTests {
    private func point(_ lat: Double, _ lon: Double, elevation: Double?, _ t: TimeInterval)
        -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: lon), elevation: elevation,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    @Test func synthesizesPositiveHorizontalAccuracy() {
        let locs = WorkoutRouteLocations.clLocations(from: [point(40.4, -80.0, elevation: 250, 0)])
        #expect(locs.count == 1)
        #expect(locs[0].horizontalAccuracy > 0)
    }

    @Test func preservesOrderAndTimestamps() {
        let track = [point(40.40, -80.0, elevation: 250, 0),
                     point(40.41, -80.0, elevation: 251, 10),
                     point(40.42, -80.0, elevation: 252, 20)]
        let locs = WorkoutRouteLocations.clLocations(from: track)
        #expect(locs.map { $0.timestamp.timeIntervalSince1970 } == [0, 10, 20])
        #expect(locs[0].coordinate.latitude == 40.40)
    }

    @Test func altitudeAndVerticalAccuracyOnlyWhenElevationPresent() {
        let withEle = WorkoutRouteLocations.clLocations(from: [point(40.4, -80, elevation: 300, 0)])
        let without = WorkoutRouteLocations.clLocations(from: [point(40.4, -80, elevation: nil, 0)])
        #expect(withEle[0].altitude == 300)
        #expect(withEle[0].verticalAccuracy > 0)
        #expect(without[0].verticalAccuracy < 0)
    }

    @Test func dropsInvalidCoordinates() {
        let track = [point(40.4, -80, elevation: nil, 0),
                     point(200, 999, elevation: nil, 10)]
        #expect(WorkoutRouteLocations.clLocations(from: track).count == 1)
    }

    @Test func emptyTrackYieldsEmpty() {
        #expect(WorkoutRouteLocations.clLocations(from: []).isEmpty)
    }
}
