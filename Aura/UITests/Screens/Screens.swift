import XCTest
import AuraKit

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
    var rideRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: RideTestID.historyRow)
    }
    var firstRow: XCUIElement { rideRows.firstMatch }
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

@MainActor
struct RideScreen {
    let app: XCUIApplication
    var probe: XCUIElement { app.staticTexts[RideTestID.hudProbe] }
    var backButton: XCUIElement { app.buttons[RideTestID.hudBack] }
    var endButton: XCUIElement { app.buttons[RideTestID.hudEnd] }
    var endAlert: XCUIElement { app.alerts["End ride?"] }
    var pauseControl: XCUIElement { app.buttons[RideTestID.hudPause] }
    var pausedBanner: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.hudPausedBanner).firstMatch
    }
    /// The cockpit's hero speed readout. `InstrumentChassis` composes it into one element
    /// whose value is the spoken speed, e.g. "0 miles per hour" — so a paused reading is a
    /// `"0 "` prefix in either unit system.
    var speedValue: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.hudSpeed).firstMatch
    }
    /// The composed distance/time/gain column. Its label carries the clock at second
    /// resolution, which is how the freeze is asserted at the rendered surface rather than
    /// only on the probe.
    var statsColumn: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.hudStats).firstMatch
    }

    func probeValues() -> RideTestProbe.Values? { RideTestProbe.parse(probe.label) }

    /// Polls the probe until recorded distance reaches `meters` (or fails at `timeout`).
    /// Real sleep between polls — waitForExistence on an already-present element returns
    /// instantly and would busy-spin the a11y server.
    func waitForDistance(atLeast meters: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let values = probeValues(), values.distanceMeters >= meters { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// Polls until the probe's elapsed reading exceeds `seconds` (or fails at `timeout`).
    /// Real sleep between polls, same rationale as `waitForDistance`.
    func waitForElapsedToAdvance(beyond seconds: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let values = probeValues(), values.elapsed > seconds { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }
}

@MainActor
struct SummaryScreen {
    let app: XCUIApplication
    var title: XCUIElement { app.staticTexts["Nice ride"] }
    // Element type of a combined SwiftUI a11y element varies by runtime — query any type.
    var heroDistance: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.summaryDistance).firstMatch
    }
    var movingStat: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.summaryMoving).firstMatch
    }
    var doneButton: XCUIElement { app.buttons["Done"] }
}

@MainActor
struct PreviewScreen {
    let app: XCUIApplication
    var startRide: XCUIElement { app.buttons[RideTestID.previewStart] }

    /// Polls until the CTA is enabled. The button exists (disabled) in every preview
    /// phase, and the fixture route auto-selects one runloop after the view's .task —
    /// so a bare waitForExistence would tap a disabled button. Real sleep between
    /// polls, same rationale as RideScreen.waitForDistance.
    func waitForStartEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if startRide.exists && startRide.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}

extension XCUIApplication {
    @MainActor static func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [ephemeralStoreFlag]
        app.launch()
        return app
    }

    /// Launch seeded past first-run via the built-in NSArgumentDomain, so Home shows the
    /// populated layout (not the first-run composition) without any app-side test-seed code.
    @MainActor static func launched(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if onboarded { app.launchArguments += ["-auraDidCompleteOnboarding", "YES"] }
        app.launchArguments += [ephemeralStoreFlag]
        app.launch()
        return app
    }

    /// ROH-95: every UI-test launch uses the ephemeral in-memory ride store. The
    /// unsigned (CODE_SIGNING_ALLOWED=NO) test build has no iCloud entitlements, and
    /// any launch that opens the CloudKit-mirrored SwiftData store SIGTRAPs later on
    /// CoreData's background CloudKit setup. No suite asserts cross-launch persistence.
    static let ephemeralStoreFlag = "-auraInMemoryRideStore"
}
