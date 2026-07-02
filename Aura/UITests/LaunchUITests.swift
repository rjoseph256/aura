import XCTest

@MainActor
final class LaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchShowsHomeAndControlCluster() {
        let app = XCUIApplication.launched(onboarded: true)
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 30),
                      "Home primary action should appear after launch")
        // There is no tab bar; History + Settings are the Home control cluster.
        XCTAssertTrue(home.historyButton.exists, "History control missing")
        XCTAssertTrue(home.settingsButton.exists, "Settings control missing")
        XCTAssertEqual(app.tabBars.count, 0, "There should be no tab bar")
    }
}
