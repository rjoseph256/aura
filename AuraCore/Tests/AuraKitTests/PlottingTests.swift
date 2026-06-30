import XCTest
import CoreGraphics
import AuraCore
@testable import AuraKit

final class PlottingTests: XCTestCase {

    // MARK: Sparkline

    func test_sparkline_mapsEndpointsAndExtremes() {
        let size = CGSize(width: 100, height: 50)
        let pts = Sparkline.points(values: [0, 10], in: size, inset: 0)
        XCTAssertEqual(pts.count, 2)
        // X spans the full width.
        XCTAssertEqual(pts.first!.x, 0, accuracy: 0.001)
        XCTAssertEqual(pts.last!.x, 100, accuracy: 0.001)
        // Min value sits at the bottom, max at the top (Y flipped).
        XCTAssertEqual(pts.first!.y, 50, accuracy: 0.001)  // value 0 → bottom
        XCTAssertEqual(pts.last!.y, 0, accuracy: 0.001)    // value 10 → top
    }

    func test_sparkline_flatSeries_centersVertically() {
        let pts = Sparkline.points(values: [5, 5, 5], in: CGSize(width: 60, height: 40), inset: 0)
        XCTAssertEqual(pts.count, 3)
        for p in pts { XCTAssertEqual(p.y, 20, accuracy: 0.001) } // all centered
    }

    func test_sparkline_respectsInset() {
        let pts = Sparkline.points(values: [0, 1], in: CGSize(width: 100, height: 50), inset: 5)
        XCTAssertEqual(pts.first!.x, 5, accuracy: 0.001)
        XCTAssertEqual(pts.last!.x, 95, accuracy: 0.001)
        XCTAssertEqual(pts.first!.y, 45, accuracy: 0.001) // bottom minus inset
        XCTAssertEqual(pts.last!.y, 5, accuracy: 0.001)   // top plus inset
    }

    func test_sparkline_tooFew_returnsEmpty() {
        XCTAssertTrue(Sparkline.points(values: [1], in: CGSize(width: 10, height: 10), inset: 0).isEmpty)
        XCTAssertTrue(Sparkline.points(values: [], in: CGSize(width: 10, height: 10), inset: 0).isEmpty)
    }

    // MARK: Sparkline — shared vertical scale (range overload)

    func test_sparkline_sharedRange_lowSeriesSitsLowNotCentered() {
        // A flat-ish low series under a wide shared range must sit LOW, not self-center.
        let pts = Sparkline.points(values: [2, 2], in: CGSize(width: 100, height: 50),
                                   inset: 0, range: 0...10)
        for p in pts { XCTAssertEqual(p.y, 40, accuracy: 0.001) } // t=0.2 → near bottom, not 25
    }

    func test_sparkline_sharedRange_twoSeriesShareOneScale() {
        let size = CGSize(width: 100, height: 50)
        let low = Sparkline.points(values: [0, 2], in: size, inset: 0, range: 0...10)
        let high = Sparkline.points(values: [8, 10], in: size, inset: 0, range: 0...10)
        // Under one scale the whole low series sits below the whole high series:
        // lowest point of `low` (largest y) is still below highest point of `high`.
        XCTAssertGreaterThan(low.map(\.y).min()!, high.map(\.y).max()!)
    }

    func test_sparkline_zeroSpanRange_centers() {
        let pts = Sparkline.points(values: [3, 7], in: CGSize(width: 60, height: 40),
                                   inset: 0, range: 5...5)
        for p in pts { XCTAssertEqual(p.y, 20, accuracy: 0.001) } // span 0 → center
    }

    func test_sparkline_selfScalingOverload_delegatesToOwnRange() {
        let size = CGSize(width: 100, height: 50)
        let vals = [0.0, 10.0]
        XCTAssertEqual(Sparkline.points(values: vals, in: size, inset: 0),
                       Sparkline.points(values: vals, in: size, inset: 0, range: 0...10))
    }

    // MARK: PolylineNormalizer

    func test_polyline_fitsWithinBounds_andPreservesAspect() {
        // A 2:1 (wide) box of coordinates near the equator (cos≈1).
        let coords = [
            Coordinate(latitude: 0.0, longitude: 0.0),
            Coordinate(latitude: 0.0, longitude: 2.0),
            Coordinate(latitude: 1.0, longitude: 2.0),
            Coordinate(latitude: 1.0, longitude: 0.0)
        ]
        let size = CGSize(width: 100, height: 100)
        let pts = PolylineNormalizer.points(coords, in: size, inset: 0)
        XCTAssertEqual(pts.count, 4)
        // All points inside the box.
        for p in pts {
            XCTAssert(p.x >= -0.001 && p.x <= 100.001, "x \(p.x) out of bounds")
            XCTAssert(p.y >= -0.001 && p.y <= 100.001, "y \(p.y) out of bounds")
        }
        // Aspect preserved: a 2-wide × 1-tall shape uses full width (100) but only half
        // the height (50), so it's vertically centered between y=25 and y=75.
        let ysUsed = pts.map(\.y)
        XCTAssertEqual(ysUsed.min()!, 25, accuracy: 0.5)
        XCTAssertEqual(ysUsed.max()!, 75, accuracy: 0.5)
        XCTAssertEqual(pts.map(\.x).min()!, 0, accuracy: 0.5)
        XCTAssertEqual(pts.map(\.x).max()!, 100, accuracy: 0.5)
    }

    func test_polyline_northIsUp() {
        // Higher latitude must map to a smaller y (top of the view).
        let coords = [
            Coordinate(latitude: 0.0, longitude: 0.0),  // south
            Coordinate(latitude: 1.0, longitude: 0.0)  // north
        ]
        let pts = PolylineNormalizer.points(coords, in: CGSize(width: 50, height: 50), inset: 0)
        XCTAssertGreaterThan(pts[0].y, pts[1].y) // south below north
    }

    func test_polyline_tooFew_returnsEmpty() {
        XCTAssertTrue(PolylineNormalizer.points([Coordinate(latitude: 1, longitude: 1)],
                                                in: CGSize(width: 10, height: 10), inset: 0).isEmpty)
    }
}
