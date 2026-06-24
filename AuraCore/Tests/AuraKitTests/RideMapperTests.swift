import XCTest
import AuraCore
@testable import AuraKit

final class RideMapperTests: XCTestCase {
    func test_ride_roundTripsThroughRecord() throws {
        let ride = Ride(
            kind: .navigate,
            startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 2000),
            track: [TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0), elevation: 250,
                               timestamp: Date(timeIntervalSince1970: 1000))],
            stats: RideStats(distanceMeters: 1234, movingTimeSeconds: 600,
                             averageSpeedMetersPerSecond: 2.0, maxSpeedMetersPerSecond: 6.0,
                             elevationGainMeters: 42),
            destinationName: "The Church Brew Works",
            routeId: UUID(),
            destinationPlaceId: UUID())
        let record = try RideMapper.record(from: ride)
        let back = try RideMapper.ride(from: record)
        XCTAssertEqual(back, ride)
        XCTAssertEqual(back.destinationName, "The Church Brew Works")
    }

    @MainActor
    func test_recorder_end_carriesDestinationName() {
        let recorder = RideRecorder(kind: .navigate)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        let ride = recorder.end(at: Date(timeIntervalSince1970: 100), destinationName: "Frick Park")
        XCTAssertEqual(ride.destinationName, "Frick Park")
        XCTAssertEqual(ride.kind, .navigate)
    }

    func test_freeRide_withNilStats_roundTrips() throws {
        let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
                        track: [], stats: nil, routeId: nil, destinationPlaceId: nil)
        XCTAssertEqual(try RideMapper.ride(from: RideMapper.record(from: ride)), ride)
    }
}
