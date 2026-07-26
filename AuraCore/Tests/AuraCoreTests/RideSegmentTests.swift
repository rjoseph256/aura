import XCTest
@testable import AuraCore

final class RideSegmentTests: XCTestCase {
    private func pt(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80.0),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: t))
    }

    private func ride(segments: [RideSegment]) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
             endedAt: Date(timeIntervalSince1970: 100), segments: segments, stats: nil,
             routeId: nil, destinationPlaceId: nil)
    }

    func test_flattenedPoints_concatenatesInSegmentOrder() {
        let r = ride(segments: [RideSegment(points: [pt(40.0, 0), pt(40.1, 10)]),
                                RideSegment(points: [pt(41.0, 600)])])
        XCTAssertEqual(r.flattenedPoints, [pt(40.0, 0), pt(40.1, 10), pt(41.0, 600)])
    }

    func test_flattenedPoints_skipsInteriorEmptySegments() {
        let r = ride(segments: [RideSegment(points: []),
                                RideSegment(points: [pt(40.0, 0)]),
                                RideSegment(points: [])])
        XCTAssertEqual(r.flattenedPoints, [pt(40.0, 0)])
        XCTAssertEqual(r.segments.count, 3, "interior empties are legal and must survive")
    }

    /// The write-side convenience the spec deliberately keeps: a caller that has a flat
    /// track still gets a ride, as exactly one segment.
    func test_trackConvenienceInit_wrapsInOneSegment() {
        let points = [pt(40.0, 0), pt(40.1, 10)]
        let r = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                     endedAt: nil, track: points, stats: nil,
                     routeId: nil, destinationPlaceId: nil)
        XCTAssertEqual(r.segments.count, 1)
        XCTAssertEqual(r.segments[0].points, points)
        XCTAssertEqual(r.flattenedPoints, points)
    }

    /// Canonical form: "no points" is ZERO segments, never one empty one. Without this,
    /// `RideMapper`'s save/load path converts a 0-segment ride into a 1-segment ride and
    /// `Ride`'s `Equatable` round trip stops holding.
    func test_trackConvenienceInit_emptyTrack_isZeroSegments() {
        let r = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                     endedAt: nil, track: [], stats: nil,
                     routeId: nil, destinationPlaceId: nil)
        XCTAssertTrue(r.segments.isEmpty)
        XCTAssertTrue(r.flattenedPoints.isEmpty)
    }

    func test_ride_codableRoundTripsSegments() throws {
        let r = ride(segments: [RideSegment(points: [pt(40.0, 0), pt(40.1, 10)]),
                                RideSegment(points: [pt(41.0, 600)])])
        let back = try JSONDecoder().decode(Ride.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.segments.count, 2)
    }

    /// Pins the ON-DISK SHAPE, not just round-trip consistency. Schema V6 (Pass 3) persists
    /// `[RideSegment]` as the `segmentsData` blob and its V5→V6 backfill must emit bytes an
    /// already-shipped V6 build can decode; a round-trip test is invariant under any
    /// consistent shape change and would not catch a rename.
    func test_rideSegment_encodesAsPointsWrapper() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode([RideSegment(points: []), RideSegment(points: [])])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"[{"points":[]},{"points":[]}]"#)
    }
}
