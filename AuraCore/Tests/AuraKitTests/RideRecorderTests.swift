import XCTest
import AuraCore
@testable import AuraKit

@MainActor
final class RideRecorderTests: XCTestCase {
    private func pt(_ lat: Double, ele: Double, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: ele,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_recordingPoints_matchesRideStatsCalculator() {
        let points = [
            pt(40.4400, ele: 250, t: 0),
            pt(40.4410, ele: 255, t: 20),
            pt(40.4420, ele: 252, t: 40),
            pt(40.4430, ele: 258, t: 60)
        ]
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        points.forEach { recorder.record($0) }
        XCTAssertEqual(recorder.stats, RideStatsCalculator.stats(from: points))
        XCTAssertEqual(recorder.track, points)
    }

    func test_ignoresPointsWhenNotRecording() {
        let recorder = RideRecorder()
        recorder.record(pt(40.44, ele: 250, t: 0)) // before start
        XCTAssertTrue(recorder.track.isEmpty)
        XCTAssertEqual(recorder.stats, .zero)
    }

    func test_end_returnsRideWithStatsAndEndTime() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 100))
        recorder.record(pt(40.44, ele: 250, t: 100))
        recorder.record(pt(40.45, ele: 250, t: 160))
        let ride = recorder.end(at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ride.kind, .freeRide)
        XCTAssertEqual(ride.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(ride.endedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ride.stats, recorder.stats)
        XCTAssertEqual(ride.track.count, 2)
        XCTAssertFalse(recorder.isRecording)
    }
}
