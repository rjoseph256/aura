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
        XCTAssertEqual(recorder.segments, [RideSegment(points: points)])
        XCTAssertEqual(recorder.flattenedPoints, points)
    }

    func test_ignoresPointsWhenNotRecording() {
        let recorder = RideRecorder()
        recorder.record(pt(40.44, ele: 250, t: 0)) // before start
        XCTAssertTrue(recorder.flattenedPoints.isEmpty)
        XCTAssertEqual(recorder.stats, .zero)
    }

    /// An unpaused ride is exactly one open segment from `start` onward — including before
    /// the first fix arrives, so `record` always has somewhere to append.
    func test_start_opensExactlyOneSegment() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(recorder.segments.count, 1)
        XCTAssertTrue(recorder.flattenedPoints.isEmpty)
    }

    /// Restarting must not leave the previous ride's segment behind.
    func test_restart_resetsToOneEmptySegment() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        recorder.record(pt(40.44, ele: 250, t: 0))
        recorder.start(at: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(recorder.segments.count, 1)
        XCTAssertTrue(recorder.flattenedPoints.isEmpty)
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
        XCTAssertEqual(ride.flattenedPoints.count, 2)
        XCTAssertEqual(ride.segments.count, 1)
        XCTAssertFalse(recorder.isRecording)
    }

    /// Canonical form: a ride that never got a fix ends with ZERO segments, matching what
    /// `Ride(track: [])` produces and what a save/load round trip returns. Without the
    /// trailing-empty drop, `segments.count` changes across persistence on an `Equatable` type.
    func test_end_withNoFixes_producesZeroSegments() {
        let recorder = RideRecorder(kind: .freeRide)
        recorder.start(at: Date(timeIntervalSince1970: 0))
        let ride = recorder.end(at: Date(timeIntervalSince1970: 60))
        XCTAssertTrue(ride.segments.isEmpty)
    }
}
