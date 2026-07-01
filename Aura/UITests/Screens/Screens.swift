import XCTest

@MainActor
struct HomeScreen {
    let app: XCUIApplication
    var joinRideButton: XCUIElement { app.buttons["Join a ride"] }

    @discardableResult func goToHistory() -> HistoryScreen {
        app.tabBars.buttons["History"].tap()
        return HistoryScreen(app: app)
    }
    @discardableResult func goToSettings() -> SettingsScreen {
        app.tabBars.buttons["Settings"].tap()
        return SettingsScreen(app: app)
    }
    @discardableResult func goToRide() -> HomeScreen {
        app.tabBars.buttons["Ride"].tap()
        return self
    }
}

@MainActor
struct HistoryScreen {
    let app: XCUIApplication
    // "Rides" nav title on the History tab; present whether the list has rows or is empty.
    var title: XCUIElement { app.navigationBars["Rides"] }
}

@MainActor
struct SettingsScreen {
    let app: XCUIApplication
    var turnHapticsSwitch: XCUIElement { app.switches["settings.turnHaptics"] }
    var saveToHealthSwitch: XCUIElement { app.switches["Save rides to Health"] }
    var weeklyGoalValue: XCUIElement { app.staticTexts["settings.weeklyGoalValue"] }
    var goalIncrement: XCUIElement { app.steppers.buttons["Increment"] }
}

@MainActor
struct JoinRideScreen {
    let app: XCUIApplication
    // Cancel + Join together identify the join sheet. The code field is intentionally
    // accessibility-hidden (custom VoiceOver composition), so it is not queried here.
    var joinButton: XCUIElement { app.buttons["Join"] }
    var cancelButton: XCUIElement { app.buttons["Cancel"] }
}

extension XCUIApplication {
    @MainActor static func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }
}
