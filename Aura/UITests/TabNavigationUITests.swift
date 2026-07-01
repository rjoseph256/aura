import XCTest

@MainActor
final class TabNavigationUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testHistoryTabIsReachable() {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let history = HomeScreen(app: app).goToHistory()
        XCTAssertTrue(history.title.waitForExistence(timeout: 5), "History 'Rides' screen not shown")
    }

    func testSettingsTabIsReachable() {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let settings = HomeScreen(app: app).goToSettings()
        XCTAssertTrue(settings.turnHapticsSwitch.waitForExistence(timeout: 5), "Settings not shown")
    }
}
