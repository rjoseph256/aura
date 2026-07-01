import XCTest

@MainActor
final class LaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchShowsTabBar() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30),
                      "Tab bar should appear after launch")
        XCTAssertTrue(app.tabBars.buttons["Ride"].exists, "Ride tab missing")
        XCTAssertTrue(app.tabBars.buttons["History"].exists, "History tab missing")
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists, "Settings tab missing")
    }
}
