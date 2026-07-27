import XCTest
@testable import AuraCore

/// `<trkseg>` handling. `GPXTrack.points` stays a flattened accessor so every existing
/// parser assertion, `GPXLocationPlayer`, `SimulatedLocationProvider` and
/// `GoldenRideFixture` are unaffected (spec D10).
final class GPXParserSegmentTests: XCTestCase {
    private func gpx(_ body: String) -> String {
        "<?xml version=\"1.0\"?>\n<gpx version=\"1.1\"><trk>\(body)</trk></gpx>"
    }

    private func trkpt(_ lat: Double, _ time: String) -> String {
        "<trkpt lat=\"\(lat)\" lon=\"-80.0\"><ele>250.0</ele><time>\(time)</time></trkpt>"
    }

    func test_twoTrksegs_yieldTwoSegments() throws {
        let track = try GPXParser.parse(gpx("""
        <trkseg>\(trkpt(40.44, "2026-06-22T14:00:00Z"))\(trkpt(40.45, "2026-06-22T14:00:20Z"))</trkseg>
        <trkseg>\(trkpt(40.54, "2026-06-22T14:15:00Z"))\(trkpt(40.55, "2026-06-22T14:15:20Z"))</trkseg>
        """))
        XCTAssertEqual(track.segments.count, 2)
        XCTAssertEqual(track.segments[0].points.count, 2)
        XCTAssertEqual(track.segments[1].points.count, 2)
    }

    func test_points_flattensInDocumentOrder() throws {
        let track = try GPXParser.parse(gpx("""
        <trkseg>\(trkpt(40.44, "2026-06-22T14:00:00Z"))</trkseg>
        <trkseg>\(trkpt(40.54, "2026-06-22T14:15:00Z"))</trkseg>
        """))
        XCTAssertEqual(track.points.count, 2)
        XCTAssertEqual(track.points[0].coordinate.latitude, 40.44, accuracy: 0.0001)
        XCTAssertEqual(track.points[1].coordinate.latitude, 40.54, accuracy: 0.0001)
    }

    func test_singleTrkseg_isOneSegment() throws {
        let track = try GPXParser.parse(gpx(
            "<trkseg>\(trkpt(40.44, "2026-06-22T14:00:00Z"))\(trkpt(40.45, "2026-06-22T14:00:20Z"))</trkseg>"))
        XCTAssertEqual(track.segments.count, 1)
        XCTAssertEqual(track.segments[0].points.count, 2)
    }

    /// A `<trkseg>` whose points were all skipped as incomplete carries no information, so
    /// it is dropped rather than emitted as an empty segment that consumers must tolerate.
    func test_trksegWithNoValidPoints_isDropped() throws {
        let track = try GPXParser.parse(gpx("""
        <trkseg></trkseg>
        <trkseg><trkpt lat="40.44" lon="-80.0"></trkpt></trkseg>
        <trkseg>\(trkpt(40.54, "2026-06-22T14:15:00Z"))</trkseg>
        """))
        XCTAssertEqual(track.segments.count, 1)
        XCTAssertEqual(track.segments[0].points.count, 1)
    }

    func test_emptyGPX_hasNoSegmentsAndNoPoints() throws {
        let track = try GPXParser.parse("<?xml version=\"1.0\"?><gpx></gpx>")
        XCTAssertTrue(track.segments.isEmpty)
        XCTAssertTrue(track.points.isEmpty)
    }

    /// Defensive: a `<trkpt>` outside any `<trkseg>` is malformed GPX. It must land
    /// somewhere rather than crash or vanish silently.
    func test_trackpointOutsideTrkseg_isKept() throws {
        let track = try GPXParser.parse(gpx(trkpt(40.44, "2026-06-22T14:00:00Z")))
        XCTAssertEqual(track.points.count, 1)
        XCTAssertEqual(track.segments.count, 1)
    }
}
