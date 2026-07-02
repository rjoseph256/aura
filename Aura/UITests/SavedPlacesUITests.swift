import XCTest

/// Save-from-preview lands on the dashboard. Runs locally/on-demand — the
/// UI-test CI job is still deferred (see the AuraUITests plan).
final class SavedPlacesUITests: XCTestCase {
    @MainActor
    func testSaveFromPreviewAppearsInSavedSection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-openURL",
            "aura://preview?lat=40.4406&lng=-79.9959&name=Save%20Target"]
        app.launch()

        // The app requests location on launch; the system alert would swallow the
        // first tap. Dismiss it explicitly (interruption monitors are unreliable here).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }

        let star = app.buttons["Save place"]
        XCTAssertTrue(star.waitForExistence(timeout: 10), "preview star missing")
        star.tap()

        let savedValue = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Saved"),
            object: star)
        XCTAssertEqual(XCTWaiter().wait(for: [savedValue], timeout: 5), .completed,
                       "star value did not settle to 'Saved'")

        // firstMatch: the failed/empty route states add a second "Back" button.
        app.buttons["Back"].firstMatch.tap()

        // Case-insensitive: the header renders through .textCase(.uppercase)
        // and the AX label casing is not guaranteed.
        let savedHeader = app.staticTexts
            .matching(NSPredicate(format: "label ==[c] %@", "saved")).firstMatch
        XCTAssertTrue(savedHeader.waitForExistence(timeout: 5),
                      "Saved section header missing on dashboard")
        XCTAssertTrue(app.staticTexts["Save Target"].exists)

        // Cleanup so reruns start clean: delete through the row's ellipsis menu
        // (its own element — the row deliberately does not combine children).
        app.buttons["Actions for Save Target"].firstMatch.tap()
        app.buttons["Delete"].tap()
    }
}
