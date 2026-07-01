# AuraUITests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an XCUITest bundle that launches the real Aura app and drives its deterministic, sensor-free flows, closing the untested-app-layer gap.

**Architecture:** A new `AuraUITests` target (type `bundle.ui-testing`) hosted by the Aura app, wired into the Aura scheme's test action via XcodeGen. Tests use small screen-object structs and bind to accessibility labels that already exist, adding an `accessibilityIdentifier` in the app only where a control is otherwise unstable.

**Tech Stack:** XCTest / XCUITest, XcodeGen, iOS Simulator.

## Global Constraints

- Swift 6 (`SWIFT_VERSION: 6.0`) for the test target.
- The `.xcodeproj` is XcodeGen-generated and gitignored: run `cd Aura && xcodegen generate` before any `xcodebuild`. If `Aura/Resources/MapboxAccessToken` is missing, copy it from `/Users/rohunjoseph/projects/biking-app/Aura/Resources/MapboxAccessToken`.
- After any build/test, `git checkout -- AuraCore/Package.resolved` to drop the resolution churn xcodebuild writes.
- Test destination for the simulator: `platform=iOS Simulator,name=iPhone 17` (booted, iOS 26.x).
- UI tests are black-box: the target links only XCTest, not AuraKit/AuraCore.
- Known live locators (read from the running app): tab bar `app.tabBars.buttons["Ride"|"History"|"Settings"]`; `app.switches["Turn haptics"]` and `app.switches["Save rides to Health"]` (value `"0"`/`"1"`); Home `app.buttons["Join a ride"]`; Join screen `app.textFields["Join code"]`, `app.buttons["Join"]`, `app.buttons["Cancel"]`.
- Do NOT flip the "Save rides to Health" switch in a test: on a fresh simulator, turning it on presents the HealthKit system authorization sheet, which flakes CI. Read it and assert it exists only.
- Commit conventions: `feat(ui-tests: ...)` / `chore(...)`; end commit bodies with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

**TDD note for this plan:** the "implementation" under test is the already-built app, so a UI test written against a working screen passes on first run rather than failing first. That is expected here. The value is the assertion existing and being run; a failure means either a wrong locator (fix the test) or a real app regression (the point). Each task ends by running the new test on the simulator and confirming it passes with clean output.

---

### Task 1: Target, scheme wiring, and launch smoke test

**Files:**
- Modify: `Aura/project.yml`
- Create: `Aura/UITests/LaunchUITests.swift`

**Interfaces:**
- Produces: the `AuraUITests` target and an `Aura` scheme whose test action runs it; a first test proving the harness works.

- [ ] **Step 1: Add the target and scheme to project.yml**

In `Aura/project.yml`, add a new entry under `targets:` (alongside `Aura` and `AuraWidgets`):

```yaml
  AuraUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - path: UITests
    dependencies:
      - target: Aura
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.rohunjoseph.aura.uitests
        GENERATE_INFOPLIST_FILE: "YES"
        TEST_TARGET_NAME: Aura
        TARGETED_DEVICE_FAMILY: "1"
        SWIFT_VERSION: "6.0"
```

Then add a top-level `schemes:` block (if one does not already exist) so `xcodebuild test -scheme Aura` runs the UI tests:

```yaml
schemes:
  Aura:
    build:
      targets:
        Aura: all
        AuraUITests: [test]
    test:
      gatherCoverageData: false
      targets:
        - AuraUITests
```

- [ ] **Step 2: Write the launch smoke test**

Create `Aura/UITests/LaunchUITests.swift`:

```swift
import XCTest

final class LaunchUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchShowsTabBar() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30),
                      "Tab bar should appear after launch")
        XCTAssertTrue(app.tabBars.buttons["Ride"].exists, "Ride tab missing")
        XCTAssertTrue(app.tabBars.buttons["History"].exists, "History tab missing")
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists, "Settings tab missing")
    }
}
```

- [ ] **Step 3: Regenerate and run the test on the simulator**

Run:
```
cd Aura && xcodegen generate && xcodebuild test -project Aura.xcodeproj -scheme Aura \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **`, with `LaunchUITests.testLaunchShowsTabBar` passing. If xcodebuild reports the scheme has no test target, re-check the `schemes:` block. Then `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 4: Commit**

```bash
git add Aura/project.yml Aura/UITests/LaunchUITests.swift
git commit -m "feat(ui-tests): AuraUITests target + scheme wiring + launch smoke test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Screen objects and tab navigation

**Files:**
- Create: `Aura/UITests/Screens/Screens.swift`
- Create: `Aura/UITests/TabNavigationUITests.swift`

**Interfaces:**
- Consumes: the `AuraUITests` target from Task 1.
- Produces: `HomeScreen`, `HistoryScreen`, `SettingsScreen` structs with navigation methods used by Tasks 3 and 4.

- [ ] **Step 1: Write the screen objects**

Create `Aura/UITests/Screens/Screens.swift`:

```swift
import XCTest

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

struct HistoryScreen {
    let app: XCUIApplication
    // "Rides" nav title on the History tab; present whether the list has rows or is empty.
    var title: XCUIElement { app.navigationBars["Rides"] }
}

struct SettingsScreen {
    let app: XCUIApplication
    var turnHapticsSwitch: XCUIElement { app.switches["Turn haptics"] }
    var saveToHealthSwitch: XCUIElement { app.switches["Save rides to Health"] }
    var weeklyGoalValue: XCUIElement { app.staticTexts["settings.weeklyGoalValue"] }
    var goalIncrement: XCUIElement { app.steppers.buttons["Increment"] }
}

extension XCUIApplication {
    static func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }
}
```

- [ ] **Step 2: Write the navigation test**

Create `Aura/UITests/TabNavigationUITests.swift`:

```swift
import XCTest

final class TabNavigationUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testHistoryTabIsReachable() {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let history = HomeScreen(app: app).goToHistory()
        XCTAssertTrue(history.title.waitForExistence(timeout: 5), "History 'Rides' screen not shown")
    }

    func testSettingsTabIsReachable() {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let settings = HomeScreen(app: app).goToSettings()
        XCTAssertTrue(settings.turnHapticsSwitch.waitForExistence(timeout: 5), "Settings not shown")
    }
}
```

- [ ] **Step 3: Run the tests**

Run:
```
cd Aura && xcodegen generate && xcodebuild test -project Aura.xcodeproj -scheme Aura \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AuraUITests/TabNavigationUITests 2>&1 | tail -25
```
Expected: both tests pass. (`weeklyGoalValue` is asserted in Task 3, not here.) Then `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 4: Commit**

```bash
git add Aura/UITests/Screens/Screens.swift Aura/UITests/TabNavigationUITests.swift
git commit -m "feat(ui-tests): screen objects + tab navigation tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Settings control wiring

**Files:**
- Modify: `Aura/Sources/Settings/SettingsView.swift:39` (add one accessibility identifier)
- Create: `Aura/UITests/SettingsUITests.swift`

**Interfaces:**
- Consumes: `SettingsScreen` (Task 2).
- Produces: assertions that the Turn-haptics switch flips, the weekly-goal stepper increments, and the Health switch is present.

- [ ] **Step 1: Add a stable identifier to the weekly-goal value**

In `Aura/Sources/Settings/SettingsView.swift`, the Stepper label is `Text(goalLabel(settings))` (around line 39). Add an identifier so the test binds to it rather than the ambiguous "25 mi" display text:

```swift
                    Stepper(value: goalBinding(settings), in: 5...200, step: 5) {
                        Text(goalLabel(settings))
                            .foregroundStyle(AuraTheme.textSecondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("settings.weeklyGoalValue")
                    }
```

- [ ] **Step 2: Write the settings tests**

Create `Aura/UITests/SettingsUITests.swift`:

```swift
import XCTest

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
```

- [ ] **Step 3: Run the tests**

Run:
```
cd Aura && xcodegen generate && xcodebuild test -project Aura.xcodeproj -scheme Aura \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AuraUITests/SettingsUITests 2>&1 | tail -25
```
Expected: all three pass. Then `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Settings/SettingsView.swift Aura/UITests/SettingsUITests.swift
git commit -m "feat(ui-tests): settings control wiring (haptics toggle, goal stepper, health present)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Group-ride join screen reachability

**Files:**
- Create: `Aura/UITests/JoinRideUITests.swift`
- Modify: `Aura/UITests/Screens/Screens.swift` (add `JoinRideScreen`)

**Interfaces:**
- Consumes: `HomeScreen` (Task 2).
- Produces: assertions that the join screen presents, its code field accepts 8 characters, and Cancel dismisses it.

- [ ] **Step 1: Add the JoinRideScreen object**

Append to `Aura/UITests/Screens/Screens.swift`:

```swift
struct JoinRideScreen {
    let app: XCUIApplication
    var codeField: XCUIElement { app.textFields["Join code"] }
    var joinButton: XCUIElement { app.buttons["Join"] }
    var cancelButton: XCUIElement { app.buttons["Cancel"] }
}
```

- [ ] **Step 2: Write the join reachability test**

Create `Aura/UITests/JoinRideUITests.swift`:

```swift
import XCTest

final class JoinRideUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    func testJoinScreenAcceptsCodeAndCancels() {
        let app = XCUIApplication.launched()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let home = HomeScreen(app: app)
        home.goToRide()
        home.joinRideButton.tap()

        let join = JoinRideScreen(app: app)
        XCTAssertTrue(join.codeField.waitForExistence(timeout: 5), "Join code field not shown")
        join.codeField.tap()
        join.codeField.typeText("ABCD1234")
        // The field enforces 8 characters; the value should reflect the entry.
        XCTAssertEqual((join.codeField.value as? String)?.count, 8, "Code field did not hold 8 chars")

        XCTAssertTrue(join.cancelButton.exists, "Cancel missing")
        join.cancelButton.tap()
        XCTAssertFalse(join.codeField.waitForExistence(timeout: 3), "Join sheet did not dismiss")
    }
}
```

- [ ] **Step 3: Run the test**

Run:
```
cd Aura && xcodegen generate && xcodebuild test -project Aura.xcodeproj -scheme Aura \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AuraUITests/JoinRideUITests 2>&1 | tail -25
```
Expected: the test passes. If the code field enforces uppercase or strips characters such that the count is not 8, adjust the assertion to match the field's real behavior (read the actual value from the failure log) rather than forcing 8. Then `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 4: Run the whole AuraUITests suite once**

Run:
```
cd Aura && xcodegen generate && xcodebuild test -project Aura.xcodeproj -scheme Aura \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AuraUITests 2>&1 | tail -30
```
Expected: all tests across `LaunchUITests`, `TabNavigationUITests`, `SettingsUITests`, `JoinRideUITests` pass. Then `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 5: Commit**

```bash
git add Aura/UITests/Screens/Screens.swift Aura/UITests/JoinRideUITests.swift
git commit -m "feat(ui-tests): group-ride join screen reachability + code field

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** launch + tab bar (Task 1); History and Settings reachable (Task 2); Turn-haptics flip, weekly-goal stepper, Health present (Task 3); join screen reachable + code field (Task 4). The free-ride pre-start screen named in the spec is intentionally deferred: its entry point was not confirmable on the home dashboard during design, so forcing a locator would be a guess. Note it as a follow-up rather than shipping a fragile test. CI job is deferred per the spec.

**Placeholder scan:** none. Task 4 Step 3 gives a concrete fallback (read the field's real value) rather than a vague "handle it", because the code field's exact character handling is the one locator not verified by value during design.

**Type consistency:** `HomeScreen`, `HistoryScreen`, `SettingsScreen`, `JoinRideScreen`, `XCUIApplication.launched()`, `turnHapticsSwitch`, `saveToHealthSwitch`, `weeklyGoalValue`, `goalIncrement`, `codeField`, `joinButton`, `cancelButton` are defined once and used consistently.
