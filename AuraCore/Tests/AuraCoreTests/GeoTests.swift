import XCTest
@testable import AuraCore

final class GeoTests: XCTestCase {
    func test_distance_betweenTwoKnownPoints_isAccurateWithinTwoPercent() {
        // ~0.67 km apart near downtown Pittsburgh
        let a = Coordinate(latitude: 40.4417, longitude: -80.0098)
        let b = Coordinate(latitude: 40.4469, longitude: -80.0057)
        let meters = Geo.distance(a, b)
        XCTAssertEqual(meters, 675, accuracy: 675 * 0.02) // within 2%
    }

    func test_distance_betweenIdenticalPoints_isZero() {
        let a = Coordinate(latitude: 40.44, longitude: -80.0)
        XCTAssertEqual(Geo.distance(a, a), 0, accuracy: 0.0001)
    }
}
