import XCTest
@testable import AuraCore

/// `TrackRibbon` decides what the live/summary maps actually stroke. Its whole job is that
/// two segments never end up in one polyline, so the map cannot draw the chord across a
/// pause. Pure, so the SwiftUI layers stay dumb projections.
final class TrackRibbonTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: 0))
    }

    private func seg(_ coords: [(Double, Double)]) -> RideSegment {
        RideSegment(points: coords.map { pt($0.0, $0.1) })
    }

    func test_noSplit_onePiecePerSegment() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([(40.0, -80.0), (40.001, -80.0)]),
                       seg([(41.0, -80.0), (41.001, -80.0)])],
            splitAtMeters: nil)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1])
        XCTAssertFalse(pieces.contains { $0.isBehind })
        // The chord: no piece may contain a point from two different segments.
        XCTAssertFalse(pieces.contains {
            $0.coordinates.contains(Coordinate(latitude: 40.001, longitude: -80.0))
            && $0.coordinates.contains(Coordinate(latitude: 41.0, longitude: -80.0))
        })
    }

    /// Runs shorter than two points stroke nothing, but must not shift the `sourceIndex` of
    /// the runs after them.
    func test_segmentsWithFewerThanTwoPoints_areDroppedWithoutShiftingIndices() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([]), seg([(40.0, -80.0)]), seg([(41.0, -80.0), (41.001, -80.0)])],
            splitAtMeters: nil)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].coordinates.count, 2)
        XCTAssertEqual(pieces[0].sourceIndex, 2)
    }

    func test_split_marksRiddenPortionBehind() {
        // Four points ~111 m apart in latitude; split at 150 m lands inside the run.
        let segment = seg([(40.000, -80.0), (40.001, -80.0), (40.002, -80.0), (40.003, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [segment], splitAtMeters: 150)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces[0].isBehind)
        XCTAssertFalse(pieces[1].isBehind)
        // Behind and ahead share the boundary point, so the ribbon has no visual gap.
        XCTAssertEqual(pieces[0].coordinates.last, pieces[1].coordinates.first)
        XCTAssertEqual(pieces.map(\.sourceIndex), [0, 0])
    }

    /// THE discriminating test. Segment 1 is ~111 m; segment 2 starts ~111 km away, so the
    /// pause chord dwarfs everything. Splitting at 261 m must consume segment 1's 111 m and
    /// carry the remaining 150 m into segment 2 — NOT walk the 111 km chord and conclude the
    /// budget is exhausted. A split measured on flattened geometry marks segment 2 wholly
    /// ahead and this test fails.
    func test_split_isMeasuredPerSegment_notAcrossThePauseChord() {
        let one = seg([(40.000, -80.0), (40.001, -80.0)])
        let two = seg([(41.000, -80.0), (41.001, -80.0), (41.002, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [one, two], splitAtMeters: 261)

        let fromOne = pieces.filter { $0.sourceIndex == 0 }
        XCTAssertEqual(fromOne.count, 1)
        XCTAssertTrue(fromOne[0].isBehind, "segment 1 is shorter than the split — wholly ridden")

        let fromTwo = pieces.filter { $0.sourceIndex == 1 }
        XCTAssertEqual(fromTwo.count, 2, "the remaining 150 m must split segment 2")
        XCTAssertTrue(fromTwo[0].isBehind)
        XCTAssertFalse(fromTwo[1].isBehind)
    }

    func test_splitBeyondTotalLength_isAllBehind() {
        let segment = seg([(40.000, -80.0), (40.001, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [segment], splitAtMeters: 100_000)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertTrue(pieces[0].isBehind)
    }

    func test_splitAtZero_isAllAhead() {
        let segment = seg([(40.000, -80.0), (40.001, -80.0)])
        let pieces = TrackRibbon.pieces(segments: [segment], splitAtMeters: 0)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertFalse(pieces[0].isBehind)
    }

    func test_noSegments_isEmpty() {
        XCTAssertTrue(TrackRibbon.pieces(segments: [], splitAtMeters: nil).isEmpty)
        XCTAssertTrue(TrackRibbon.pieces(segments: [], splitAtMeters: 100).isEmpty)
    }
}
