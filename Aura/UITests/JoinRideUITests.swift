import XCTest

@MainActor
final class JoinRideUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testJoinScreenPresentsAndCancels() {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let home = HomeScreen(app: app)
        home.goToRide()
        let joinButton = home.joinRideButton
        XCTAssertTrue(joinButton.waitForExistence(timeout: 5), "Join a ride button missing")
        // The button sits at the bottom of the dashboard scroll view; scroll it into view.
        if !joinButton.isHittable { app.swipeUp() }
        joinButton.tap()

        // Identify the join sheet by its Cancel + Join controls. The code field is not
        // exercised here: GroupRideJoinView deliberately hides the raw TextField from
        // accessibility (`.accessibilityHidden(true)`) and composes a custom VoiceOver
        // element over invisible input boxes, so it has no text-field locator to type into
        // without changing that a11y design. Code entry stays in the on-device pass.
        let join = JoinRideScreen(app: app)
        XCTAssertTrue(join.cancelButton.waitForExistence(timeout: 8), "Join sheet did not present")
        XCTAssertTrue(join.joinButton.exists, "Join button missing (wrong sheet presented?)")

        join.cancelButton.tap()
        XCTAssertFalse(join.cancelButton.waitForExistence(timeout: 3), "Join sheet did not dismiss")
    }
}
