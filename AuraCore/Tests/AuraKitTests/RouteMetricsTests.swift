import XCTest
@testable import AuraKit

final class RouteMetricsTests: XCTestCase {
    func test_walkFraction_isDistanceWeighted() {
        let segments: [(distanceMeters: Double, isWalking: Bool)] = [
            (300, true),   // pushing the bike
            (100, false),  // riding
            (100, true)   // pushing the bike
        ]
        // 400 walked of 500 total = 0.8
        XCTAssertEqual(RouteMetrics.walkFraction(segments: segments), 0.8, accuracy: 0.0001)
    }

    func test_walkFraction_emptyOrZeroDistance_isZero() {
        XCTAssertEqual(RouteMetrics.walkFraction(segments: []), 0, accuracy: 0.0001)
        XCTAssertEqual(RouteMetrics.walkFraction(segments: [(0, true)]), 0, accuracy: 0.0001)
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
