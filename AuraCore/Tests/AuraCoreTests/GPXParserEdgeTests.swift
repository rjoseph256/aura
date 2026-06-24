import XCTest
@testable import AuraCore

/// Edge-case + characterization tests for `GPXParser`.
///
/// Several of these assertions pin behavior that is questionable but currently
/// real (the parser fabricates a (0,0) coordinate and an epoch timestamp for
/// incomplete trackpoints rather than skipping them). They are written to
/// document the present contract, not to endorse it.
final class GPXParserEdgeTests: XCTestCase {

    // MARK: Malformed input

    func test_malformedXML_throwsInvalidXML() {
        // Unclosed tags / garbage that XMLParser rejects outright.
        let garbage = "<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"2\"></gpx"
        XCTAssertThrowsError(try GPXParser.parse(garbage)) { error in
            XCTAssertEqual(error as? GPXParser.ParseError, .invalidXML)
        }
    }

    func test_nonXMLPlainText_throwsInvalidXML() {
        XCTAssertThrowsError(try GPXParser.parse("this is not xml at all")) { error in
            XCTAssertEqual(error as? GPXParser.ParseError, .invalidXML)
        }
    }

    // MARK: Missing lat/lon — CHARACTERIZATION (questionable behavior)

    func test_trackpointMissingLatLon_defaultsToZeroZero() throws {
        // A trkpt with no lat/lon attributes. The parser defaults both to 0,
        // producing a (0,0) coordinate (the "null island" point) instead of
        // skipping the malformed point. This is characterizing questionable
        // behavior — fabricating a (0,0) point — not endorsing it.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt><ele>10.0</ele><time>2026-06-22T14:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertEqual(track.points[0].coordinate.latitude, 0.0)
        XCTAssertEqual(track.points[0].coordinate.longitude, 0.0)
    }

    func test_trackpointWithUnparseableLatLon_defaultsToZeroZero() throws {
        // Non-numeric attribute values fall through the `Double(...) ?? 0` guard
        // to 0 as well — same (0,0) fabrication.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="abc" lon="xyz"></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertEqual(track.points[0].coordinate.latitude, 0.0)
        XCTAssertEqual(track.points[0].coordinate.longitude, 0.0)
    }

    // MARK: Missing <time> — CHARACTERIZATION (questionable behavior)

    func test_trackpointMissingTime_defaultsToEpoch() throws {
        // No <time> element → timestamp defaults to Date(timeIntervalSince1970: 0).
        // This is characterizing questionable behavior — a fabricated epoch
        // timestamp that will corrupt any dt-based stats — not endorsing it.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="40.44" lon="-80.0"><ele>250.0</ele></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertEqual(track.points[0].timestamp, Date(timeIntervalSince1970: 0))
    }

    func test_trackpointWithUnparseableTime_defaultsToEpoch() throws {
        // A <time> that ISO8601DateFormatter can't parse leaves `time` nil, so the
        // same epoch default is used.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="40.44" lon="-80.0"><time>not-a-date</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertEqual(track.points[0].timestamp, Date(timeIntervalSince1970: 0))
    }

    // MARK: Missing <ele> — elevation is nil (the intended optional contract)

    func test_trackpointMissingElevation_isNil() throws {
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="40.44" lon="-80.0"><time>2026-06-22T14:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertNil(track.points[0].elevation)
    }

    func test_trackpointWithUnparseableElevation_isNil() throws {
        // Garbage inside <ele> → Double(...) is nil → elevation nil.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="40.44" lon="-80.0"><ele>high</ele></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertNil(track.points[0].elevation)
    }
}
