import XCTest
@testable import AuraCore

final class GPSSignalTests: XCTestCase {
    func test_quality_goodWhenAccurateAndFresh() {
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 8, age: 1), .good)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 20, age: 0), .good)
    }
    func test_quality_weakBetweenThresholds() {
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 35, age: 1), .weak)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 50, age: 1), .weak)
    }
    func test_quality_lostWhenInaccurateNegativeOrStale() {
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 80, age: 1), .lost)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: -1, age: 1), .lost)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 5, age: 30), .lost) // stale
    }
    func test_isAcceptable_rejectsNegativeAndTooInaccurate() {
        XCTAssertTrue(GPSFix.isAcceptable(horizontalAccuracy: 49))
        XCTAssertFalse(GPSFix.isAcceptable(horizontalAccuracy: 51))
        XCTAssertFalse(GPSFix.isAcceptable(horizontalAccuracy: -1))
    }
}
