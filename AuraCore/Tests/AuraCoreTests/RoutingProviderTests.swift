import XCTest
@testable import AuraCore

final class RoutingProviderTests: XCTestCase {
    func test_mockProvider_returnsConfiguredRoutes() async throws {
        let route = Route(origin: .init(latitude: 40.44, longitude: -80.0),
                          destination: .init(latitude: 40.45, longitude: -80.01),
                          waypoints: [], geometry: [], profile: .fastest,
                          distanceMeters: 1000, estimatedDurationSeconds: 300, elevationGainMeters: 10)
        let provider: RoutingProvider = MockRoutingProvider(result: [route])
        let request = RouteRequest(origin: route.origin, destination: route.destination, waypoints: [])
        let routes = try await provider.routes(for: request)
        XCTAssertEqual(routes, [route])
    }

    func test_mockProvider_canBeConfiguredToThrow() async {
        struct Boom: Error {}
        let provider: RoutingProvider = MockRoutingProvider(error: Boom())
        let request = RouteRequest(origin: .init(latitude: 0, longitude: 0),
                                   destination: .init(latitude: 1, longitude: 1), waypoints: [])
        do { _ = try await provider.routes(for: request); XCTFail("should throw") } catch { /* expected */ }
    }
}
