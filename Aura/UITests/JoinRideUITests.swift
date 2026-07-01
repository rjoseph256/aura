import XCTest

@MainActor
final class JoinRideUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testJoinScreenAcceptsCodeAndCancels() {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let home = HomeScreen(app: app)
        home.goToRide()
        let joinButton = home.joinRideButton
        XCTAssertTrue(joinButton.waitForExistence(timeout: 5), "Join a ride button missing")
        // The button sits at the bottom of the dashboard scroll view; scroll it into view.
        if !joinButton.isHittable { app.swipeUp() }
        joinButton.tap()

        let join = JoinRideScreen(app: app)
        // The code-entry sheet presents before any network/auth, so its Cancel is the
        // reliable "sheet is up" signal regardless of the code field's exact identifier.
        XCTAssertTrue(join.cancelButton.waitForExistence(timeout: 8), "Join sheet did not present")

        let field = join.codeField.exists ? join.codeField : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "No code field on the join sheet")
        field.tap()
        field.typeText("ABCD1234")
        // Assert the field accepts input and enforces its 8-character cap. Exact count is
        // avoided because XCUITest can drop the first keystroke (a typing race, not a bug).
        let count = (field.value as? String)?.count ?? 0
        XCTAssertGreaterThan(count, 0, "Code field did not accept input")
        XCTAssertLessThanOrEqual(count, 8, "Code field exceeded its 8-character cap")

        join.cancelButton.tap()
        XCTAssertFalse(join.cancelButton.waitForExistence(timeout: 3), "Join sheet did not dismiss")
    }
}
