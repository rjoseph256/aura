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

    func test_onePiecePerSegment() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([(40.0, -80.0), (40.001, -80.0)]),
                       seg([(41.0, -80.0), (41.001, -80.0)])])
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.sourceIndex), [0, 1])
        // The chord: no piece may contain a point from two different segments.
        XCTAssertFalse(pieces.contains {
            $0.coordinates.contains(Coordinate(latitude: 40.001, longitude: -80.0))
            && $0.coordinates.contains(Coordinate(latitude: 41.0, longitude: -80.0))
        })
    }

    /// Runs shorter than two points stroke nothing, but must not shift the `sourceIndex` of
    /// the runs after them. Reachable today: start a ride, pause before the first GPS fix,
    /// resume — that leaves an interior segment with no points, so output position and input
    /// position genuinely diverge.
    func test_segmentsWithFewerThanTwoPoints_areDroppedWithoutShiftingIndices() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([]), seg([(40.0, -80.0)]), seg([(41.0, -80.0), (41.001, -80.0)])])
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].coordinates.count, 2)
        XCTAssertEqual(pieces[0].sourceIndex, 2)
    }

    /// Reached on every Explore ride: `RideHUDView` starts recording in `.task`, which runs
    /// after the first body evaluation, so the first render of every mount asks for pieces
    /// from an empty segment list. `RideMapView`'s `if !pieces.isEmpty` guard depends on this.
    func test_noSegments_isEmpty() {
        XCTAssertTrue(TrackRibbon.pieces(segments: []).isEmpty)
    }

    /// `RideMapView` keys its `PolylineAnnotationGroup` on `sourceIndex`. Mapbox stores the
    /// element id in a persistent map and assigns both colliding elements the same feature id,
    /// silently — tap resolution then finds only the first. Uniqueness holds structurally today
    /// (one piece per segment); this test is what makes a future change to that visible.
    func test_sourceIndicesAreUnique() {
        let pieces = TrackRibbon.pieces(
            segments: [seg([(40.0, -80.0), (40.001, -80.0)]),
                       seg([]),
                       seg([(41.0, -80.0), (41.001, -80.0), (41.002, -80.0)])])
        XCTAssertEqual(Set(pieces.map(\.sourceIndex)).count, pieces.count)
    }

    func test_unpausedRideStylesEveryPieceAsRecorded() {
        let segments = [RideSegment(points: [pt(0, 0), pt(0, 1)]),
                        RideSegment(points: [pt(1, 0), pt(1, 1)])]
        let pieces = TrackRibbon.pieces(segments: segments, isPaused: false)
        XCTAssertEqual(pieces.map(\.style), [.recorded, .recorded])
    }

    func test_pausedRideStylesOnlyTheTrailingPiece() {
        let segments = [RideSegment(points: [pt(0, 0), pt(0, 1)]),
                        RideSegment(points: [pt(1, 0), pt(1, 1)])]
        let pieces = TrackRibbon.pieces(segments: segments, isPaused: true)
        XCTAssertEqual(pieces.map(\.style), [.recorded, .paused])
    }

    func test_pausedStyleFollowsTheLastDrawnPieceNotTheLastSegment() {
        // A trailing single-point segment strokes nothing and is dropped, so the paused style
        // must land on the piece that is actually drawn last.
        let segments = [RideSegment(points: [pt(0, 0), pt(0, 1)]),
                        RideSegment(points: [pt(1, 0)])]
        let pieces = TrackRibbon.pieces(segments: segments, isPaused: true)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.style, .paused)
        XCTAssertEqual(pieces.first?.sourceIndex, 0)
    }

    func test_pausedStylingKeepsSourceIndicesUnique() {
        let segments = (0..<4).map { i in
            RideSegment(points: [pt(Double(i), 0), pt(Double(i), 1)])
        }
        let indices = TrackRibbon.pieces(segments: segments, isPaused: true).map(\.sourceIndex)
        XCTAssertEqual(Set(indices).count, indices.count)
    }

    func test_emptyRideYieldsNoPiecesEvenWhenPaused() {
        XCTAssertTrue(TrackRibbon.pieces(segments: [], isPaused: true).isEmpty)
    }
}
