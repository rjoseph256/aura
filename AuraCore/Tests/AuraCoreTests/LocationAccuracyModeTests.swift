import XCTest
@testable import AuraCore

final class LocationAccuracyModeTests: XCTestCase {
    func test_desired_rideAlwaysWins() {
        // A ride is active regardless of Home/foreground/auth -> navigating.
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: true, isHomeForeground: false, authorized: false), .navigating)
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: true, isHomeForeground: true, authorized: true), .navigating)
    }

    func test_desired_ambientOnlyWhenHomeForegroundAndAuthorized() {
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: true, authorized: true), .ambient)
    }

    func test_desired_idleOtherwise() {
        // Not on Home (pushed screen) -> idle.
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: false, authorized: true), .idle)
        // On Home but not authorized -> idle (never locate without permission).
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: true, authorized: false), .idle)
        // Backgrounded (isHomeForeground already folds scenePhase) -> idle.
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: false, authorized: false), .idle)
    }
}
