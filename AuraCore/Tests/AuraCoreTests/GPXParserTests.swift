import XCTest
@testable import AuraCore

final class GPXParserTests: XCTestCase {
    private let sample = """
    <?xml version="1.0"?>
    <gpx version="1.1"><trk><trkseg>
      <trkpt lat="40.4400" lon="-80.0000"><ele>250.0</ele><time>2026-06-22T14:00:00Z</time></trkpt>
      <trkpt lat="40.4410" lon="-80.0000"><ele>255.0</ele><time>2026-06-22T14:00:20Z</time></trkpt>
    </trkseg></trk></gpx>
    """

    func test_parsesTrackPointsWithElevationAndTime() throws {
        let track = try GPXParser.parse(sample)
        XCTAssertEqual(track.points.count, 2)
        XCTAssertEqual(track.points[0].coordinate.latitude, 40.44, accuracy: 0.0001)
        XCTAssertEqual(track.points[0].coordinate.longitude, -80.0, accuracy: 0.0001)
        XCTAssertEqual(track.points[0].elevation, 250.0)
        XCTAssertEqual(track.points[1].elevation, 255.0)
        XCTAssertEqual(track.points[1].timestamp.timeIntervalSince(track.points[0].timestamp), 20, accuracy: 0.001)
    }

    func test_emptyGPX_yieldsNoPoints() throws {
        let track = try GPXParser.parse("<?xml version=\"1.0\"?><gpx></gpx>")
        XCTAssertTrue(track.points.isEmpty)
    }
}
