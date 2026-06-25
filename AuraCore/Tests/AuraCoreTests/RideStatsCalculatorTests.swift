import XCTest
@testable import AuraCore

final class RideStatsCalculatorTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double, ele: Double, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: ele,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_emptyOrSinglePoint_yieldsZeroStats() {
        XCTAssertEqual(RideStatsCalculator.stats(from: []), .zero)
        let single = [pt(40.44, -80.0, ele: 250, t: 0)]
        XCTAssertEqual(RideStatsCalculator.stats(from: single), .zero)
    }

    func test_distanceAndElevationGain_accumulateOverSegments() {
        let track = [
            pt(40.4400, -80.0000, ele: 250, t: 0),
            pt(40.4410, -80.0000, ele: 255, t: 20),   // climb +5
            pt(40.4420, -80.0000, ele: 252, t: 40),   // descent (ignored for gain)
            pt(40.4430, -80.0000, ele: 258, t: 60)   // climb +6
        ]
        let s = RideStatsCalculator.stats(from: track)
        // Each 0.001° latitude ≈ 111 m → ~333 m total
        XCTAssertEqual(s.distanceMeters, 333, accuracy: 8)
        XCTAssertEqual(s.elevationGainMeters, 11, accuracy: 0.001) // 5 + 6
    }

    func test_movingTimeExcludesStoppedSegments_andComputesAverageSpeed() {
        let track = [
            pt(40.4400, -80.0000, ele: 250, t: 0),
            pt(40.4410, -80.0000, ele: 250, t: 20),   // ~111 m in 20 s → ~5.5 m/s (moving)
            pt(40.4410, -80.0000, ele: 250, t: 320),  // 0 m in 300 s → stopped (excluded)
            pt(40.4420, -80.0000, ele: 250, t: 340)  // ~111 m in 20 s → moving
        ]
        let s = RideStatsCalculator.stats(from: track)
        XCTAssertEqual(s.movingTimeSeconds, 40, accuracy: 0.001)        // 20 + 20, stop excluded
        XCTAssertGreaterThan(s.maxSpeedMetersPerSecond, 5.0)
        // avg = distance(~222 m) / movingTime(40 s) ≈ 5.55 m/s
        XCTAssertEqual(s.averageSpeedMetersPerSecond, 222.0 / 40.0, accuracy: 0.3)
    }
}
