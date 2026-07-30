import XCTest
import AuraCore
@testable import AuraKit

final class ShareRouteGeometryTests: XCTestCase {
    private func line(_ n: Int, lat0: Double = 40.44, lon0: Double = -79.99) -> [Coordinate] {
        (0..<n).map { Coordinate(latitude: lat0 + Double($0) * 0.0005, longitude: lon0 + Double($0) * 0.0006) }
    }

    /// A looping route whose lat/lon extremes fall in the interior of the point list —
    /// a monotonic line would leave its extremes at the stride-kept endpoints and make
    /// the extreme-preservation assertions vacuous.
    private func loop(_ n: Int) -> [Coordinate] {
        (0..<n).map { i in
            Coordinate(latitude: 40.44 + 0.01 * sin(Double(i) / 300),
                       longitude: -79.99 + 0.01 * cos(Double(i) / 300))
        }
    }

    func testRejectsDegenerateInput() {
        XCTAssertNil(ShareRouteGeometry.prepare(segments: []))
        XCTAssertNil(ShareRouteGeometry.prepare(segments: [[Coordinate(latitude: 40, longitude: -79)]]))
        let stationary = Array(repeating: Coordinate(latitude: 40, longitude: -79), count: 50)
        XCTAssertNil(ShareRouteGeometry.prepare(segments: [stationary]))
    }

    func testDropsNonFiniteAndKeepsRest() {
        var pts = line(20)
        pts.insert(Coordinate(latitude: .nan, longitude: -79.99), at: 5)
        pts.insert(Coordinate(latitude: 40.44, longitude: .infinity), at: 10)
        let prepared = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        XCTAssertEqual(prepared.segments[0].count, 20)
        XCTAssertTrue(prepared.segments.allSatisfy { $0.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite } })
    }

    func testDecimationCapsAndKeepsExtremes() {
        let pts = loop(5000)
        let prepared = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        // The cap must hold INCLUDING the four force-kept extreme points.
        XCTAssertLessThanOrEqual(prepared.segments[0].count, ShareRouteGeometry.maxPointsPerSegment)
        let lats = prepared.segments[0].map(\.latitude), lons = prepared.segments[0].map(\.longitude)
        XCTAssertEqual(lats.min(), pts.map(\.latitude).min())
        XCTAssertEqual(lats.max(), pts.map(\.latitude).max())
        XCTAssertEqual(lons.min(), pts.map(\.longitude).min())
        XCTAssertEqual(lons.max(), pts.map(\.longitude).max())
    }

    func testShortSegmentsPassThroughUndecimated() {
        let pts = line(30)
        let prepared = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        XCTAssertEqual(prepared.segments[0], pts)
    }

    func testSegmentsStaySeparate() {
        let prepared = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(30), line(30, lat0: 40.5)]))
        XCTAssertEqual(prepared.segments.count, 2)
    }

    func testContentHashStableAndSensitive() {
        let a = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100)]))
        let b = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100)]))
        XCTAssertEqual(a.contentHash, b.contentHash)
        let c = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100, lat0: 40.45)]))
        XCTAssertNotEqual(a.contentHash, c.contentHash)
    }

    func testContentHashSensitiveToSegmentBoundaries() {
        let pts = line(60)
        let one = try! XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        let two = try! XCTUnwrap(ShareRouteGeometry.prepare(
            segments: [Array(pts[0..<30]), Array(pts[30...])]))
        XCTAssertNotEqual(one.contentHash, two.contentHash)
    }
}
