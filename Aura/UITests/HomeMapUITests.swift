import XCTest

@MainActor
final class HomeMapUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    // Idle Home shows the "tap to explore" affordance over the frozen snapshot; tapping it
    // activates the live map at the same camera, and a user pan then reveals the recenter
    // control (HomeLiveMap only shows it once the camera has moved off the rider).
    func testTapToExploreActivatesMapAndRecenterAppears() {
        let app = XCUIApplication.launched(onboarded: true)
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.tapToExplore.waitForExistence(timeout: 30), "tap-to-explore affordance missing")
        home.tapToExplore.tap()
        app.swipeLeft()
        XCTAssertTrue(home.recenterButton.waitForExistence(timeout: 5), "recenter control did not appear after pan")
    }
}
