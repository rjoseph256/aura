import XCTest
@testable import AuraCore

/// Edge-case tests for `GPXParser`.
///
/// Incomplete trackpoints are *skipped*, not fabricated: a `<trkpt>` missing (or
/// with an unparseable) `lat`/`lon` or `<time>` is dropped rather than emitted as
/// a (0,0) "null island" coordinate or a 1970-epoch timestamp. Fabricated points
/// corrupt downstream stats — a single epoch timestamp creates a ~50-year `dt`
/// that wrecks moving time and average speed, and (0,0) injects a bogus
/// transcontinental distance segment.
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

    // MARK: Missing / unparseable lat/lon — point is skipped

    func test_trackpointMissingLatLon_isSkipped() throws {
        // A trkpt with no lat/lon attributes is dropped rather than emitted as (0,0).
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt><ele>10.0</ele><time>2026-06-22T14:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertTrue(track.points.isEmpty)
    }

    func test_trackpointWithUnparseableLatLon_isSkipped() throws {
        // Non-numeric attribute values can't be parsed → point dropped (not (0,0)).
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="abc" lon="xyz"><time>2026-06-22T14:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertTrue(track.points.isEmpty)
    }

    func test_trackpointMissingOnlyLat_isSkipped() throws {
        // Both lat and lon are required; a present lon doesn't rescue a missing lat.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lon="-80.0"><time>2026-06-22T14:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertTrue(track.points.isEmpty)
    }

    func test_trackpointWithExplicitZeroLatLon_isKept() throws {
        // (0,0) is a legitimate coordinate ("null island"). Only missing/unparseable
        // values are skipped — an explicit lat="0" lon="0" must survive.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="0" lon="0"><time>2026-06-22T14:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertEqual(track.points[0].coordinate.latitude, 0.0)
        XCTAssertEqual(track.points[0].coordinate.longitude, 0.0)
    }

    // MARK: Missing / unparseable <time> — point is skipped

    func test_trackpointMissingTime_isSkipped() throws {
        // No <time> element → point dropped rather than stamped with the 1970 epoch.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="40.44" lon="-80.0"><ele>250.0</ele></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertTrue(track.points.isEmpty)
    }

    func test_trackpointWithUnparseableTime_isSkipped() throws {
        // A <time> ISO8601DateFormatter can't parse leaves time nil → point dropped.
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="40.44" lon="-80.0"><time>not-a-date</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertTrue(track.points.isEmpty)
    }

    // MARK: Mixed track — only complete points survive, in order

    func test_incompletePointsAreSkippedButValidPointsSurvive() throws {
        // A real-world ride with two good points around a dropout. The bad point is
        // dropped; the two valid points remain in their original order.
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1"><trk><trkseg>
          <trkpt lat="40.4400" lon="-80.0000"><ele>250.0</ele><time>2026-06-22T14:00:00Z</time></trkpt>
          <trkpt lat="40.4410"><ele>252.0</ele></trkpt>
          <trkpt lat="40.4420" lon="-80.0000"><ele>255.0</ele><time>2026-06-22T14:00:40Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 2)
        XCTAssertEqual(track.points[0].coordinate.latitude, 40.4400, accuracy: 0.0001)
        XCTAssertEqual(track.points[1].coordinate.latitude, 40.4420, accuracy: 0.0001)
        XCTAssertEqual(track.points[1].timestamp.timeIntervalSince(track.points[0].timestamp), 40, accuracy: 0.001)
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
        // Garbage inside <ele> → Double(...) is nil → elevation nil. Elevation is
        // optional by contract, so the point is still kept (lat/lon/time are valid).
        let xml = """
        <?xml version="1.0"?>
        <gpx><trk><trkseg>
          <trkpt lat="40.44" lon="-80.0"><ele>high</ele><time>2026-06-22T14:00:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let track = try GPXParser.parse(xml)
        XCTAssertEqual(track.points.count, 1)
        XCTAssertNil(track.points[0].elevation)
    }
}
