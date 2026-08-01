import XCTest
import AuraCore
@testable import AuraKit

final class ShareMapRequestTests: XCTestCase {
    private let rideID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func line(_ n: Int, lat0: Double = 40.44) -> [Coordinate] {
        (0..<n).map { Coordinate(latitude: lat0 + Double($0) * 0.0005, longitude: -79.99 + Double($0) * 0.0006) }
    }

    private func request(style: MapStyle = .auraTerrain, lat0: Double = 40.44) throws -> ShareMapRequest {
        try XCTUnwrap(ShareMapRequest(rideID: rideID, segments: [line(50, lat0: lat0)], style: style))
    }

    func testNilOnDegenerateSegments() {
        XCTAssertNil(ShareMapRequest(rideID: rideID, segments: [], style: .auraTerrain))
        XCTAssertNil(ShareMapRequest(rideID: rideID, segments: [[Coordinate(latitude: 40, longitude: -79)]],
                                     style: .auraTerrain))
        let stationary = Array(repeating: Coordinate(latitude: 40, longitude: -79), count: 50)
        XCTAssertNil(ShareMapRequest(rideID: rideID, segments: [stationary], style: .dark))
    }

    func testNilWhenAllCoordinatesOutOfRange() {
        // The doc's "degenerate routes never become requests" claim leans on
        // ShareRouteGeometry.prepare dropping out-of-range coordinates (|lat| > 90).
        let offEarth = (0..<10).map { Coordinate(latitude: 200 + Double($0), longitude: -79) }
        XCTAssertNil(ShareMapRequest(rideID: rideID, segments: [offEarth], style: .auraTerrain))
    }

    func testSizeAndScaleArePinnedToShareCardLayout() throws {
        // Invariants, not defaults: the initializer takes no size/scale — the card is
        // fixed-geometry and downstream code treats these as constants (the 90×60
        // acceptance downsample; MapSnapshotOptions preconditions crash on bad values).
        let request = try request()
        XCTAssertEqual(request.size, ShareCardLayout.mapFieldSize)
        XCTAssertEqual(request.scale, ShareCardLayout.rasterScale)
    }

    func testCacheKeyIsFilenameSafe() throws {
        // TerrainSnapshotDiskCache uses the key as a filename; "/" and ":" silently
        // break the write. The FNV-1a digest keeps the key safe by construction.
        for style in [MapStyle.auraTerrain, .dark, .standard] {
            let key = try request(style: style).cacheKey
            XCTAssertFalse(key.contains("/"), key)
            XCTAssertFalse(key.contains(":"), key)
            XCTAssertTrue(key.hasPrefix("sharemap-"), key)
        }
    }

    func testCacheKeyStableAcrossConstructions() throws {
        XCTAssertEqual(try request().cacheKey, try request().cacheKey)
    }

    func testCacheKeySensitiveToStyle() throws {
        let keys = try [MapStyle.auraTerrain, .dark, .standard].map { try request(style: $0).cacheKey }
        XCTAssertEqual(Set(keys).count, 3)
    }

    func testCacheKeySensitiveToRoute() throws {
        XCTAssertNotEqual(try request().cacheKey, try request(lat0: 40.45).cacheKey)
    }

    func testCacheKeySensitiveToRideID() throws {
        let other = try XCTUnwrap(ShareMapRequest(rideID: UUID(), segments: [line(50)], style: .auraTerrain))
        XCTAssertNotEqual(try request().cacheKey, other.cacheKey)
    }

    func testCacheKeySensitiveToCompositeVersion() throws {
        // compositeVersion is a static let; sensitivity is asserted on the composer the
        // initializer delegates to.
        let route = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(50)]))
        let v1 = ShareMapRequest.cacheKey(rideID: rideID, route: route, style: .dark,
                                          size: ShareCardLayout.mapFieldSize,
                                          scale: ShareCardLayout.rasterScale, compositeVersion: 1)
        let v2 = ShareMapRequest.cacheKey(rideID: rideID, route: route, style: .dark,
                                          size: ShareCardLayout.mapFieldSize,
                                          scale: ShareCardLayout.rasterScale, compositeVersion: 2)
        XCTAssertNotEqual(v1, v2)
    }

    func testInitFoldsPublishedCompositeVersionIntoPublicCacheKey() throws {
        // Both directions: the PUBLIC key the initializer produces must equal the
        // composer fed `ShareMapRequest.compositeVersion` (an init hardcoding a stale
        // version would pass composer-only sensitivity tests), and must differ from
        // the composer fed the next version.
        let request = try request(style: .dark)
        let route = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(50)]))
        let published = ShareMapRequest.cacheKey(
            rideID: rideID, route: route, style: .dark,
            size: ShareCardLayout.mapFieldSize, scale: ShareCardLayout.rasterScale,
            compositeVersion: ShareMapRequest.compositeVersion)
        let bumped = ShareMapRequest.cacheKey(
            rideID: rideID, route: route, style: .dark,
            size: ShareCardLayout.mapFieldSize, scale: ShareCardLayout.rasterScale,
            compositeVersion: ShareMapRequest.compositeVersion + 1)
        XCTAssertEqual(request.cacheKey, published)
        XCTAssertNotEqual(request.cacheKey, bumped)
    }

    func testStyleIdentityTracksAuthoredTerrainVersion() {
        // A restyle of the authored terrain bumps `TerrainStyle.styleVersion`, which must
        // flow into the key; the stock styles use stable slugs (the SDK's MapStyle.data
        // is internal, so identity is derived from the AuraKit case).
        XCTAssertEqual(ShareMapRequest.styleIdentity(.auraTerrain), TerrainStyle.authoredStyleIdentity)
        XCTAssertEqual(ShareMapRequest.styleIdentity(.dark), "style-dark")
        XCTAssertEqual(ShareMapRequest.styleIdentity(.standard), "style-standard")
    }

    func testCarriesPreparedRoute() throws {
        let request = try request()
        XCTAssertEqual(request.route, ShareRouteGeometry.prepare(segments: [line(50)]))
        XCTAssertEqual(request.rideID, rideID)
        XCTAssertEqual(request.style, .auraTerrain)
    }
}
