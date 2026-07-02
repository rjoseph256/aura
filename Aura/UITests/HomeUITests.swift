import XCTest

@MainActor
final class HomeUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    // The dominant launch action is "Where to?"; "Explore" and "Join a ride" are the demoted
    // secondaries. None of them render the old "Free ride" copy.
    func testLaunchBandShowsWhereToAndExplore_notFreeRide() {
        let app = XCUIApplication.launched(onboarded: true)
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 30), "primary 'Where to?' not shown")
        XCTAssertTrue(home.exploreButton.exists, "'Explore' secondary not shown")
        XCTAssertFalse(app.buttons["Free ride"].exists, "stale 'Free ride' button present")
    }

    // The motivation hook renders with no gesture — visible at the peek detent on launch.
    func testGlanceVisibleAtPeek() {
        let app = XCUIApplication.launched(onboarded: true)
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.glance.waitForExistence(timeout: 30), "weekly glance not visible at peek")
    }

    // Tapping the primary expands the search overlay (focused field); Cancel collapses it.
    func testSearchExpandsAndCollapses() {
        let app = XCUIApplication.launched(onboarded: true)
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 30))
        home.whereTo.tap()
        XCTAssertTrue(home.searchField.waitForExistence(timeout: 5), "search field did not appear")
        home.searchCancel.tap()
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 5), "did not collapse back to launch band")
    }
}
