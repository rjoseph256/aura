import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func openSettings() -> SettingsScreen {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        return HomeScreen(app: app).goToSettings()
    }

    func testTurnHapticsSwitchFlips() {
        let settings = openSettings()
        let toggle = settings.turnHapticsSwitch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(before, settings.turnHapticsSwitch.value as? String,
                          "Turn haptics switch did not change value")
    }

    func testWeeklyGoalStepperIncrements() {
        let settings = openSettings()
        XCTAssertTrue(settings.weeklyGoalValue.waitForExistence(timeout: 5))
        let before = settings.weeklyGoalValue.label
        settings.goalIncrement.tap()
        XCTAssertNotEqual(before, settings.weeklyGoalValue.label,
                          "Weekly goal did not change after increment")
    }

    func testSaveToHealthSwitchIsPresent() {
        let settings = openSettings()
        // Do NOT tap: turning it on shows the HealthKit auth sheet, which flakes CI.
        XCTAssertTrue(settings.saveToHealthSwitch.waitForExistence(timeout: 5))
        XCTAssertNotNil(settings.saveToHealthSwitch.value as? String, "Health switch has no value")
    }
}
