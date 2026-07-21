import XCTest

@MainActor
struct HomeScreen {
    let app: XCUIApplication
    var joinRideButton: XCUIElement { app.buttons["home.join"] }
    var whereTo: XCUIElement { app.buttons["home.whereTo"] }
    var exploreButton: XCUIElement { app.buttons["home.explore"] }
    var savedButton: XCUIElement { app.buttons["home.saved"] }
    var glance: XCUIElement { app.staticTexts["home.glance"] }
    var searchField: XCUIElement { app.textFields["home.searchField"] }
    var searchCancel: XCUIElement { app.buttons["home.searchCancel"] }
    // Maps-style utility cluster on the Home header (there is no tab bar).
    var historyButton: XCUIElement { app.buttons["home.history"] }
    var settingsButton: XCUIElement { app.buttons["home.settings"] }
    // Idle-map affordance (HomeMapCanvas) and the live-map recenter control (HomeLiveMap).
    var tapToExplore: XCUIElement { app.buttons["home.tapToExplore"] }
    var recenterButton: XCUIElement { app.buttons["home.recenter"] }

    @discardableResult func goToHistory() -> HistoryScreen {
        historyButton.tap()
        return HistoryScreen(app: app)
    }
    @discardableResult func goToSettings() -> SettingsScreen {
        settingsButton.tap()
        return SettingsScreen(app: app)
    }
    /// Return to Home from a pushed History/Settings screen via the nav back button.
    @discardableResult func goToRide() -> HomeScreen {
        app.navigationBars.buttons.firstMatch.tap()
        return self
    }
}

@MainActor
struct HistoryScreen {
    let app: XCUIApplication
    // "Rides" nav title on the pushed History screen; present whether the list has rows or is empty.
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
