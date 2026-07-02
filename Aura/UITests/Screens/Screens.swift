import XCTest

@MainActor
struct HomeScreen {
    let app: XCUIApplication
    var joinRideButton: XCUIElement { app.buttons["Join a ride"] }
    var whereTo: XCUIElement { app.buttons["home.whereTo"] }
    var exploreButton: XCUIElement { app.buttons["Explore"] }
    var glance: XCUIElement { app.staticTexts["home.glance"] }
    var searchField: XCUIElement { app.textFields["home.searchField"] }
    var searchCancel: XCUIElement { app.buttons["home.searchCancel"] }

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

    /// Launch seeded past first-run via the built-in NSArgumentDomain, so Home shows the
    /// populated layout (not the first-run composition) without any app-side test-seed code.
    @MainActor static func launched(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if onboarded { app.launchArguments += ["-auraDidCompleteOnboarding", "YES"] }
        app.launch()
        return app
    }
}
