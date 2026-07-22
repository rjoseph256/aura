import Testing
import AuraCore
import AuraKit

/// ROH-93: the fixture doubles as the navigate golden ride's preview Route. The start
/// literals exist so the E2E's deep-link URL is compile-time-tied to the fixture; this
/// suite pins them (and the route metadata) to the parsed track so a re-record that
/// forgets them fails here, not silently in the UI test.
struct GoldenRideFixtureRouteTests {
    @Test func startCoordinateLiteralsMatchFixtureFirstPoint() throws {
        let first = try #require(try GoldenRideFixture.track().points.first)
        #expect(first.coordinate.latitude == GoldenRideFixture.startLatitude)
        #expect(first.coordinate.longitude == GoldenRideFixture.startLongitude)
    }

    @Test func routeCarriesFixtureGeometryAndFrozenTruth() throws {
        let route = try GoldenRideFixture.route()
        #expect(route.geometry.count == GoldenRideFixture.expectedPointCount)
        #expect(route.origin == route.geometry.first)
        #expect(route.destination == route.geometry.last)
        #expect(route.profile == .mostPaths)
        #expect(route.waypoints.isEmpty)
        #expect(route.distanceMeters == GoldenRideFixture.expectedDistanceMeters)
        #expect(route.estimatedDurationSeconds == GoldenRideFixture.nominalDurationSeconds)
        #expect(route.elevationGainMeters == GoldenRideFixture.expectedElevationGainMeters)
        #expect(route.elevationProfile.count == GoldenRideFixture.expectedPointCount)
    }
}
