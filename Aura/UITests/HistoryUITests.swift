import XCTest

/// ROH-127: deleting an unfinished ride asks first, and the question must offer a visible way
/// out. On iOS 26 a `confirmationDialog` raised from a swipe action renders as a popover anchored
/// to the row, which drops both the title and the cancel-role button — leaving "Delete ride" as
/// the only tappable action on an irreversible, all-devices delete.
@MainActor
final class HistoryUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launchWithUnfinishedRide() -> (XCUIApplication, HistoryScreen) {
        let app = XCUIApplication()
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                XCUIApplication.ephemeralStoreFlag, "-auraSeedUnfinishedRide"]
        app.launch()
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.whereTo.waitForExistence(timeout: 30))
        let history = home.goToHistory()
        XCTAssertTrue(history.firstRow.waitForExistence(timeout: 10), "Seeded unfinished ride not in History")
        return (app, history)
    }

    private func requestDelete(_ app: XCUIApplication, _ history: HistoryScreen) {
        history.firstRow.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Swipe did not reveal Delete")
        delete.tap()
    }

    func testUnfinishedRideDeleteConfirmationShowsTitleAndKeep() {
        let (app, history) = launchWithUnfinishedRide()
        requestDelete(app, history)

        XCTAssertTrue(app.staticTexts["Delete this ride?"].waitForExistence(timeout: 5),
                      "Confirmation title is not shown")
        let keep = app.buttons["Keep"]
        XCTAssertTrue(keep.exists && keep.isHittable, "No visible Keep button on the delete confirmation")

        keep.tap()
        XCTAssertFalse(keep.waitForExistence(timeout: 2), "Keep did not dismiss the confirmation")
        XCTAssertTrue(history.firstRow.exists, "Keep must leave the ride in History")
    }

    func testUnfinishedRideDeleteConfirmationDeletes() {
        let (app, history) = launchWithUnfinishedRide()
        requestDelete(app, history)

        let confirm = app.buttons["Delete ride"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "No destructive action on the confirmation")
        confirm.tap()

        XCTAssertTrue(history.firstRow.waitForNonExistence(timeout: 5), "Delete ride did not remove the row")
    }
}
