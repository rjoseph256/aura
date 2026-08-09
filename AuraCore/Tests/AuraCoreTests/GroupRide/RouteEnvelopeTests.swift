import Foundation
import Testing
@testable import AuraCore

struct RouteEnvelopeTests {
    private func route() -> Route {
        Route(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
              origin: Coordinate(latitude: 37.7749, longitude: -122.4194),
              destination: Coordinate(latitude: 37.8044, longitude: -122.2712),
              waypoints: [Coordinate(latitude: 37.79, longitude: -122.33)],
              geometry: [Coordinate(latitude: 37.7749, longitude: -122.4194),
                         Coordinate(latitude: 37.8044, longitude: -122.2712)],
              profile: .mostPaths,
              distanceMeters: 8000,
              estimatedDurationSeconds: 1800,
              elevationGainMeters: 120.5,
              elevationProfile: [3, 12.25, 40])
    }

    @Test func absentValueMeansOpenRide() throws {
        #expect(try RouteEnvelope.routeData(nil) == nil)
    }

    /// The case the first spec revision missed. A SQL-NULL column decodes to `.null` rather than to
    /// absence, and anything other than nil out of here sends an open ride's guest to the
    /// route-unavailable screen and then out of the ride.
    @Test func jsonNullMeansOpenRide() throws {
        #expect(try RouteEnvelope.routeData(.null) == nil)
    }

    @Test func aPresentValueIsCarriedThrough() throws {
        let data = try RouteEnvelope.routeData(.object(["distanceMeters": .integer(8000)]))
        #expect(data != nil)
    }

    /// The only assertion here that can catch a lossy mirror. Nil-folding still passes if
    /// `.integer` and `.double` are collapsed, or if a nested object is flattened; a real `Route`
    /// through the whole path — encode, decode into `RouteJSON`, fold, decode back — does not.
    @Test func aRealRouteSurvivesTheRoundTrip() throws {
        let original = route()
        let value = try JSONDecoder().decode(RouteJSON.self, from: JSONEncoder().encode(original))
        let folded = try #require(try RouteEnvelope.routeData(value))
        #expect(try JSONDecoder().decode(Route.self, from: folded) == original)
    }

    /// Whole numbers must not be widened on the way through, and this starts from wire bytes
    /// rather than a hand-built case so it covers both halves of the mirror — the decode that
    /// chooses a case and the encode that emits it.
    ///
    /// A real `Route` cannot carry this assertion: every number in one is a `Double` already, so
    /// the round trip above passes whether or not `.integer` and `.double` are collapsed. That
    /// makes this the test that holds the split in place. `Double` is exact only to 2^53, and past
    /// it a collapsed mirror loses the low bits silently, since the wrong value still decodes.
    @Test func aWideIntegerKeepsEveryBit() throws {
        let wide = 9_007_199_254_740_993  // 2^53 + 1, the first integer Double cannot hold
        let wire = Data("[\(wide)]".utf8)
        let value = try JSONDecoder().decode(RouteJSON.self, from: wire)
        let folded = try #require(try RouteEnvelope.routeData(value))
        #expect(try JSONDecoder().decode([Int].self, from: folded) == [wide])
    }
}
