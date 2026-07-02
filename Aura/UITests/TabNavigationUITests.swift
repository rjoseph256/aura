import XCTest

/// Top-level navigation now runs through the Home control cluster (History + Settings) and the
/// nav back button — there is no tab bar. These guard that both destinations are reachable and
/// that back returns to the Home surface.
@MainActor
final class TabNavigationUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testHistoryIsReachableFromHomeCluster() {
        let app = XCUIApplication.launched(onboarded: true)
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 30))
        let history = home.goToHistory()
        XCTAssertTrue(history.title.waitForExistence(timeout: 5), "History 'Rides' screen not shown")
        home.goToRide()
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 5), "Back should return to Home")
    }

    func testSettingsIsReachableFromHomeCluster() {
        let app = XCUIApplication.launched(onboarded: true)
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 30))
        let settings = home.goToSettings()
        XCTAssertTrue(settings.turnHapticsSwitch.waitForExistence(timeout: 5), "Settings not shown")
        home.goToRide()
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 5), "Back should return to Home")
    }
}
