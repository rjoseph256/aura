import Testing
import AuraCore
@testable import AuraKit

@Suite struct TerrainSnapshotRequestTests {
    private func req(_ lat: Double, _ lng: Double, _ style: String = "mapbox://styles/aura/t",
                     w: Double = 390, h: Double = 700) -> TerrainSnapshotRequest {
        TerrainSnapshotRequest(center: .init(latitude: lat, longitude: lng), styleURI: style, width: w, height: h)
    }

    @Test func jitterWithinGridReusesCacheKey() {
        #expect(req(40.4406, -79.9959).cacheKey == req(40.4409, -79.9961).cacheKey)
    }
    @Test func movingPastGridChangesCacheKey() {
        #expect(req(40.44, -79.99).cacheKey != req(40.46, -79.99).cacheKey)
    }
    @Test func styleIsPartOfCacheKey() {
        #expect(req(40.44, -79.99).cacheKey != req(40.44, -79.99, "mapbox://styles/mapbox/dark-v11").cacheKey)
    }
    @Test func sizeBucketIsPartOfCacheKey() {
        #expect(req(40.44, -79.99, w: 390, h: 700).cacheKey != req(40.44, -79.99, w: 800, h: 700).cacheKey)
    }
    // The load-bearing test: a cross-launch guarantee can't be unit-tested in one process,
    // so pin an EXACT literal key for a known input. If someone reintroduces String.hashValue
    // this literal changes and the test fails.
    @Test func cacheKeyIsDeterministicLiteral() {
        #expect(req(40.44, -79.99, "mapbox://styles/aura/t", w: 390, h: 700).cacheKey
                == "terrain-4044--7999-390x700-s1075307649")
    }
    @Test func usesRiderCoordinateWhenAvailable() {
        let rider = Coordinate(latitude: 37.77, longitude: -122.41)
        #expect(TerrainSnapshotRequest.center(forRider: rider) == rider)
    }
    @Test func fallsBackToCuratedDefault() {
        #expect(TerrainSnapshotRequest.center(forRider: nil) == TerrainSnapshotRequest.curatedDefaultCenter)
    }
}
