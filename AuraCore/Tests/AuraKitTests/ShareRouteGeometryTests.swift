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

    func testDropsNonFiniteAndKeepsRest() throws {
        var pts = line(20)
        pts.insert(Coordinate(latitude: .nan, longitude: -79.99), at: 5)
        pts.insert(Coordinate(latitude: 40.44, longitude: .infinity), at: 10)
        let prepared = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        XCTAssertEqual(prepared.segments[0].count, 20)
        XCTAssertTrue(prepared.segments.allSatisfy { $0.allSatisfy { $0.latitude.isFinite && $0.longitude.isFinite } })
    }

    /// Mirrors `WorkoutRouteLocationsTests.dropsInvalidCoordinates`: finite-but-out-of-range
    /// coordinates (|lat| > 90, |lon| > 180) are hygiene failures too, not just NaN/inf.
    func testDropsOutOfRangeCoordinatesAndKeepsRest() throws {
        var pts = line(20)
        pts.insert(Coordinate(latitude: 200, longitude: 999), at: 5)
        let prepared = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        XCTAssertEqual(prepared.segments[0], line(20))
    }

    func testAllInvalidCoordinatesYieldNil() {
        // Includes a huge finite value: without the range check this input doesn't just
        // slip through, it traps on Int conversion inside quantization.
        let junk = [Coordinate(latitude: 200, longitude: 999),
                    Coordinate(latitude: -90.0001, longitude: 180.0001),
                    Coordinate(latitude: 1e14, longitude: 0),
                    Coordinate(latitude: .nan, longitude: 0)]
        XCTAssertNil(ShareRouteGeometry.prepare(segments: [junk]))
    }

    /// Pins the span-epsilon guard: two points DISTINCT at 1e5 quantization (5 quanta
    /// apart, so the distinct-count guard passes) whose bounding span (~0.00005°, ~5.5 m)
    /// is below `minimumSpanDegrees` — only the span guard can reject this.
    func testRejectsSubEpsilonSpanEvenWithDistinctPoints() {
        let pts = [Coordinate(latitude: 40.44, longitude: -79.99),
                   Coordinate(latitude: 40.44005, longitude: -79.99)]
        XCTAssertNil(ShareRouteGeometry.prepare(segments: [pts]))
    }

    /// Two coordinates that differ by less than the quantization quantum (1e-7° << 1e-5°)
    /// are the same point in content-identity terms: prepare must return nil even though
    /// the raw doubles are not identical. The distinct-quantized guard names this case,
    /// but the span guard mathematically subsumes it (<2 distinct quantized points ⇒ raw
    /// span < 1e-5° < minimumSpanDegrees), so this test goes red only when BOTH guards
    /// are deleted — verified; no input can isolate the distinct guard alone.
    func testRejectsPointsDistinctOnlyBelowQuantum() {
        let pts = [Coordinate(latitude: 40.44, longitude: -79.99),
                   Coordinate(latitude: 40.44 + 1e-7, longitude: -79.99)]
        XCTAssertNil(ShareRouteGeometry.prepare(segments: [pts]))
    }

    func testDecimationCapsAndKeepsExtremes() throws {
        let pts = loop(5000)
        let prepared = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        // The cap must hold INCLUDING the four force-kept extreme points.
        XCTAssertLessThanOrEqual(prepared.segments[0].count, ShareRouteGeometry.maxPointsPerSegment)
        let lats = prepared.segments[0].map(\.latitude), lons = prepared.segments[0].map(\.longitude)
        XCTAssertEqual(lats.min(), pts.map(\.latitude).min())
        XCTAssertEqual(lats.max(), pts.map(\.latitude).max())
        XCTAssertEqual(lons.min(), pts.map(\.longitude).min())
        XCTAssertEqual(lons.max(), pts.map(\.longitude).max())
    }

    func testShortSegmentsPassThroughUndecimated() throws {
        let pts = line(30)
        let prepared = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        XCTAssertEqual(prepared.segments[0], pts)
    }

    func testSegmentsStaySeparate() throws {
        let input = [line(30), line(30, lat0: 40.5)]
        let prepared = try XCTUnwrap(ShareRouteGeometry.prepare(segments: input))
        XCTAssertEqual(prepared.segments.count, 2)
        // Each output segment must be an order-preserving subsequence of ITS OWN input
        // segment — no points invented, reordered, or leaked across segments.
        for (out, source) in zip(prepared.segments, input) {
            XCTAssertTrue(isSubsequence(out, of: source),
                          "output segment contains points not drawn in order from its input segment")
        }
    }

    private func isSubsequence(_ sub: [Coordinate], of full: [Coordinate]) -> Bool {
        var iterator = full.makeIterator()
        for point in sub {
            var found = false
            while let candidate = iterator.next() {
                if candidate == point { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    func testContentHashStableAndSensitive() throws {
        let a = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100)]))
        let b = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100)]))
        XCTAssertEqual(a.contentHash, b.contentHash)
        let c = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [line(100, lat0: 40.45)]))
        XCTAssertNotEqual(a.contentHash, c.contentHash)
    }

    /// Pins the 1e5 quantization scale of the content hash: a ~1.5e-5° move (~1.5 m,
    /// larger than the 1e-5° quantum) must change the hash; a 1e-7° jitter (GPS noise,
    /// far below the quantum) must not.
    func testQuantizationScaleBoundsHashSensitivity() throws {
        let base = line(100)
        var moved = base
        moved[50] = Coordinate(latitude: moved[50].latitude + 1.5e-5, longitude: moved[50].longitude)
        var jittered = base
        jittered[50] = Coordinate(latitude: jittered[50].latitude + 1e-7, longitude: jittered[50].longitude)
        let a = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [base]))
        let b = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [moved]))
        let c = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [jittered]))
        XCTAssertNotEqual(a.contentHash, b.contentHash, "a super-quantum move must change the hash")
        XCTAssertEqual(a.contentHash, c.contentHash, "a sub-quantum jitter must not change the hash")
    }

    func testContentHashSensitiveToSegmentBoundaries() throws {
        let pts = line(60)
        let one = try XCTUnwrap(ShareRouteGeometry.prepare(segments: [pts]))
        let two = try XCTUnwrap(ShareRouteGeometry.prepare(
            segments: [Array(pts[0..<30]), Array(pts[30...])]))
        XCTAssertNotEqual(one.contentHash, two.contentHash)
    }
}
