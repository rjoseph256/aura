import XCTest
@testable import AuraKit

final class RouteMetricsTests: XCTestCase {
    func test_offRoadFraction_isDistanceWeighted() {
        let segments: [(distanceMeters: Double, isOffRoad: Bool)] = [
            (300, true),   // path
            (100, false),  // road
            (100, true),   // path
        ]
        // 400 off-road of 500 total = 0.8
        XCTAssertEqual(RouteMetrics.offRoadFraction(segments: segments), 0.8, accuracy: 0.0001)
    }

    func test_offRoadFraction_emptyOrZeroDistance_isZero() {
        XCTAssertEqual(RouteMetrics.offRoadFraction(segments: []), 0, accuracy: 0.0001)
        XCTAssertEqual(RouteMetrics.offRoadFraction(segments: [(0, true)]), 0, accuracy: 0.0001)
    }

    func test_elevationGain_sumsPositiveDeltasAboveNoise() {
        // +5, -3 (ignored), +6, +0.4 (noise, ignored) = 11
        let profile = [250.0, 255, 252, 258, 258.4]
        XCTAssertEqual(RouteMetrics.elevationGain(elevations: profile), 11, accuracy: 0.0001)
    }

    func test_elevationGain_shortProfile_isZero() {
        XCTAssertEqual(RouteMetrics.elevationGain(elevations: [250]), 0, accuracy: 0.0001)
    }
}
