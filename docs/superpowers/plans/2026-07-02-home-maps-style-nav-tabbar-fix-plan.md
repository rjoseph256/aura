# Home Maps-Style Navigation — Drop the Tab Bar Fix Plan

> **For agentic workers:** implemented controller-direct (app-target SwiftUI) + TDD on the pure AuraCore core. Steps use checkbox syntax.

**Goal:** Remove the bottom `TabView` so the always-on Home dashboard sheet no longer buries the tab bar; reach History + Settings from a Maps-style control cluster on Home (pushed onto the nav stack).

**Architecture:** One `NavigationStack` rooted at `HomeView` (no `TabView`). History/Settings become `AppRoute` cases reached by pushing — the existing `sheetPresented = path.isEmpty && !searchExpanded` logic then auto-dismisses the dashboard sheet, so they present full-screen with a system back button and no occlusion. Deep links map to the nav path instead of a tab. A pure `AppRoute.stack(for:)` mapping in AuraCore carries the deep-link→path logic so it is unit-testable (the app target has no unit-test bundle).

**Tech Stack:** SwiftUI (iOS 26), Swift 6, Swift Testing (AuraCore), XCUITest.

## Global Constraints

- **Frozen identifiers stay frozen:** `.freeRide` case + `"freeRide"` raw value, `DeepLink` cases, `aura://` scheme, `RideActivityMode`, `RideMapper` — untouched.
- **ROH-7 single-hoisted-map invariant holds:** no new live map; backdrop stays the cached snapshot.
- **Reuse the design system:** the Home cluster uses the shipped `.hudControl` button style (already handles Reduce Transparency / Reduce Motion / Increase Contrast). No new bespoke control style.
- **Accessibility:** cluster buttons carry `accessibilityLabel` "History"/"Settings" and identifiers `home.history` / `home.settings`; they do not out-prioritize the primary "Where to?" action in VoiceOver order.
- **Ride-active guard preserved:** `handle(url:)` still drops every deep link while `isRideActive`.

---

### Task 1: AuraCore — AppRoute cases + pure deep-link→path mapping (TDD)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Navigation/AppRoute.swift`
- Test: `AuraCore/Tests/AuraCoreTests/AppRouteTests.swift`

- Add `case history` and `case settings` to `AppRoute`, with hand-written `==` (`(.history,.history)`, `(.settings,.settings)` → true) and `hash` entries (`combine(5)`, `combine(6)`).
- Add a pure mapping: `static func stack(for link: DeepLink) -> [AppRoute]`:
  - `.home → []`
  - `.history → [.history]`
  - `.settings → [.settings]`
  - `.freeRide → [.freeRide]`
  - `.preview(p) → [.preview(p)]`
  - `.join(code) → [.groupRide(.join(code))]`
- Tests: history/settings equal-self + hash; distinct-case inequality incl. new cases; `stack(for:)` for each DeepLink case returns the expected path (verify `.home` → empty, `.history`/`.settings` push, `.join` wraps in `.groupRide`).

### Task 2: App — AppRouter drops tabs, routes via path

**Files:** Modify `Aura/Sources/App/AppRouter.swift`

- Delete the `Tab` enum and `selectedTab`.
- Rewrite `handle(url:)`: keep `guard !isRideActive, let link = DeepLink.parse(url)`; for `.preview` call `remember(place)` first; then `path = AppRoute.stack(for: link)` (note `.home` yields `[]` = pop to root). No `selectedTab` writes remain.

### Task 3: App — RootView single stack (remove TabView)

**Files:** Modify `Aura/Sources/AuraApp.swift`

- Replace the `TabView { … }` with a single `NavigationStack(path: $router.path) { HomeView().navigationDestination(for: AppRoute.self) { … } }`.
- Destination switch adds `case .history: HistoryView()` and `case .settings: SettingsView()` (no inner `NavigationStack` — they push onto Home's stack and get their own title + back button). Keep existing `.freeRide/.preview/.navigate/.groupRide/.joinRide` arms.
- Move the `.tint`, `.task` (widget reload, `-openURL`, kvSyncStream), and `.onChange(scenePhase)` modifiers from the old `TabView` onto the `NavigationStack`.

### Task 4: App/Design — Home header control cluster

**Files:** Modify `Aura/Sources/Home/HomeView.swift`

- In `header`, after `Spacer()`, add an `HStack(spacing: AuraTheme.Spacing.sm)` of two `Button`s using `.buttonStyle(.hudControl)`:
  - History: `Image(systemName: "clock.arrow.circlepath")`, `action: { router.push(.history) }`, `.accessibilityLabel("History")`, `.accessibilityIdentifier("home.history")`.
  - Settings: `Image(systemName: "gearshape.fill")`, `action: { router.push(.settings) }`, `.accessibilityLabel("Settings")`, `.accessibilityIdentifier("home.settings")`.
- Change the last-ride tap from `router.selectedTab = .history` to `router.push(.history)`.

### Task 5: UITests — navigate via cluster + back (no tab bar)

**Files:** Modify `Aura/UITests/Screens/Screens.swift`, `LaunchUITests.swift`, `TabNavigationUITests.swift`, `SettingsUITests.swift`, `JoinRideUITests.swift`

- `Screens.HomeScreen`: add `historyButton` (`home.history`), `settingsButton` (`home.settings`).
- `Screens` nav helpers: `goToHistory()` taps `home.history`; `goToSettings()` taps `home.settings`; `goToRide()` taps the nav back button (`app.navigationBars.buttons.firstMatch` / "Back").
- `LaunchUITests`: assert the Home surface (`home.whereTo`) + cluster buttons exist instead of a tab bar.
- `TabNavigationUITests`: navigate Home→History→back→Settings→back via the cluster + back button.
- `SettingsUITests` / `JoinRideUITests`: replace `app.tabBars.firstMatch.waitForExistence` gate with waiting on `home.whereTo`.

## Verification

- `cd AuraCore && swift test` green (new mapping + case tests).
- App + AuraWidgets build (SwiftLint strict); rename guard still passes.
- HomeUITests / TabNavigation / Settings / JoinRide / SavedPlaces on a fresh sim.
- Device re-verify: no tab bar on Home; History/Settings reachable via cluster; sheet dismisses on push; back returns to Home with the sheet restored; `aura://history` / `aura://settings` deep links land full-screen.
