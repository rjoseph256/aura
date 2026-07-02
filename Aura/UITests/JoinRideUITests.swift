import XCTest

@MainActor
final class JoinRideUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testJoinScreenPresentsAndCancels() {
        // Seed past first-run so Home shows the populated layout (with the launch band).
        let app = XCUIApplication.launched(onboarded: true)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let home = HomeScreen(app: app)
        home.goToRide()
        let joinButton = home.joinRideButton
        XCTAssertTrue(joinButton.waitForExistence(timeout: 5), "Join a ride button missing")
        // "Join a ride" is a demoted secondary in the always-visible launch band.
        if !joinButton.isHittable { app.swipeUp() }
        joinButton.tap()

        // Identify the join screen (now pushed on the nav stack, not a sheet) by its Cancel +
        // Join controls. The code field is not exercised here: GroupRideJoinView deliberately
        // hides the raw TextField from accessibility (`.accessibilityHidden(true)`) and composes
        // a custom VoiceOver element over invisible input boxes, so it has no text-field locator
        // to type into without changing that a11y design. Code entry stays in the on-device pass.
        let join = JoinRideScreen(app: app)
        XCTAssertTrue(join.cancelButton.waitForExistence(timeout: 8), "Join screen did not present")
        XCTAssertTrue(join.joinButton.exists, "Join button missing (wrong screen pushed?)")

        join.cancelButton.tap()
        XCTAssertFalse(join.cancelButton.waitForExistence(timeout: 3), "Join screen did not dismiss")
    }
}
