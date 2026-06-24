import XCTest
@testable import AuraCore

final class GPXLocationPlayerTests: XCTestCase {
    private func pt(_ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0), elevation: 250,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_scheduleOffsets_areRelativeToFirstPoint() {
        let track = GPXTrack(points: [pt(100), pt(120), pt(180)])
        let schedule = GPXLocationPlayer.schedule(track: track)
        XCTAssertEqual(schedule.map(\.offset), [0, 20, 80])
    }

    func test_speedMultiplier_compressesOffsets() {
        let track = GPXTrack(points: [pt(0), pt(20), pt(40)])
        let schedule = GPXLocationPlayer.schedule(track: track, speedMultiplier: 2)
        XCTAssertEqual(schedule.map(\.offset), [0, 10, 20])
    }

    func test_emptyTrack_yieldsEmptySchedule() {
        XCTAssertTrue(GPXLocationPlayer.schedule(track: GPXTrack(points: [])).isEmpty)
    }
}
