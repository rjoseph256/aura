import XCTest
@testable import AuraCore

final class ModelCodableTests: XCTestCase {
    func test_ride_encodesAndDecodesLosslessly() throws {
        let ride = Ride(
            id: UUID(),
            kind: .freeRide,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 2_000),
            track: [TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0),
                               elevation: 250, timestamp: Date(timeIntervalSince1970: 1_000))],
            stats: .zero,
            routeId: nil,
            destinationPlaceId: nil
        )
        let data = try JSONEncoder().encode(ride)
        let decoded = try JSONDecoder().decode(Ride.self, from: data)
        XCTAssertEqual(decoded, ride)
    }

    func test_route_profileEnum_roundTrips() throws {
        let route = Route(id: UUID(), origin: .init(latitude: 40.44, longitude: -80.0),
                          destination: .init(latitude: 40.45, longitude: -80.01),
                          waypoints: [], geometry: [], profile: .flattest,
                          distanceMeters: 1200, estimatedDurationSeconds: 420, elevationGainMeters: 30)
        let decoded = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded.profile, .flattest)
        XCTAssertEqual(decoded, route)
    }
}
