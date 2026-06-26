# Aura Wave 2 — Composed VoiceOver labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the cockpit's TurnCard, SpeedRail, and TripStrip composed VoiceOver labels so each reads as one coherent element, and make the turn-card distance unit-aware.

**Architecture:** All string composition lives in the Swift package (`AuraCore`/`AuraKit`) so CI unit-tests it; the SwiftUI views only apply the strings. The turn card and trip strip gain a stored `accessibilityLabel` on their state types, populated by their presenters; the speed rail gets a new pure `SpeedRailVoice` composer. A shared spoken-unit vocabulary lives on `RideStatsFormatter`.

**Tech Stack:** Swift 6.2 / Xcode 26, SwiftUI, Swift Testing + XCTest, XcodeGen, SwiftLint 0.64.1.

## Global Constraints

- Swift 6 language mode across all targets; `@Observable` UI stores are `@MainActor`.
- The package builds on a macOS CI host. Any iOS-only API must be `#if os(iOS)`-guarded. This plan introduces none (pure strings + SwiftUI `.accessibility*` modifiers in the app target only).
- Pure, testable string composition lives in `AuraCore`/`AuraKit`; the SwiftUI views only apply it.
- Reuse the mono-lime `AuraTheme`. No visual, layout, font, color, or motion change.
- Units honor the rider's setting throughout. Abbreviations spell to speakable form: ft→feet, mi→miles, m→meters, km→kilometers, mph→miles per hour, km/h→kilometers per hour.
- Street and instruction strings come from Mapbox verbatim (no road-suffix expansion).
- `maneuverDistance` must stay byte-identical (imperial and metric) — two widget callers depend on it (`Aura/Widgets/RideLiveActivity.swift:160`, `Aura/Widgets/RideLockScreenView.swift:135`).
- NEVER `git add AuraCore/Package.resolved`. Don't commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored). Stage only the files each task names.
- Package files under `AuraCore/Sources/**` and `AuraCore/Tests/**` are auto-globbed by SwiftPM; no `xcodegen` needed. This plan adds no app-target files (only modifies existing ones), so no `xcodegen generate` is required for file membership.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Package tests: `cd AuraCore && swift test`. App builds: delegate to the `apple-platform-build-tools:builder` subagent.

## File structure

Package (`AuraCore/`):
- Modify `Sources/AuraKit/Formatting/RideStatsFormatter.swift` — spoken unit words + maneuver value/unit split + `maneuverDistanceSpoken` (Task 1).
- Modify `Sources/AuraKit/TurnCardPresenter.swift` — `TurnCardState.accessibilityLabel`, unit-aware presenter (Task 2).
- Modify `Sources/AuraKit/Guidance/GuidanceViewModel.swift` — `units` input (Task 2).
- Modify `Sources/AuraKit/Guidance/CruisingPresenter.swift` — `CruisingState.accessibilityLabel` (Task 3).
- Create `Sources/AuraKit/Formatting/SpeedRailVoice.swift` — speed-rail label composer (Task 4).
- Modify `Tests/AuraKitTests/RideStatsFormatterTests.swift` (Task 1), `TurnCardPresenterTests.swift` + `TurnCardPresenterEdgeTests.swift` + `GuidanceViewModelTests.swift` (Task 2), `CruisingPresenterTests.swift` (Task 3).
- Create `Tests/AuraKitTests/SpeedRailVoiceTests.swift` (Task 4).

App (`Aura/`):
- Modify `Sources/Ride/TurnCardView.swift`, `Sources/Ride/SpeedRail.swift`, `Sources/Ride/TripStripView.swift`, `Sources/Ride/NavigateHUDView.swift` (Task 5).

Docs:
- Modify `docs/ROADMAP.md` (Task 7).

---

### Task 1: `RideStatsFormatter` spoken vocabulary and shared maneuver path

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Formatting/RideStatsFormatter.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideStatsFormatterTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `var speedUnitSpoken: String` ("miles per hour" / "kilometers per hour")
  - `var distanceUnitSpoken: String` ("miles" / "kilometers")
  - `var elevationUnitSpoken: String` ("feet" / "meters")
  - `func maneuverDistanceSpoken(_ meters: Double) -> String` ("390 feet", "0.2 miles", "120 meters", "2.5 kilometers")
  - `func maneuverDistance(_ meters: Double) -> String` — unchanged output ("390 ft" etc.)

- [ ] **Step 1: Write the failing tests**

Add these methods to `RideStatsFormatterTests` (keep all existing tests unchanged):

```swift
    func test_maneuverDistanceSpoken_imperial() {
        let f = RideStatsFormatter(units: .imperial)
        XCTAssertEqual(f.maneuverDistanceSpoken(120), "390 feet")
        XCTAssertEqual(f.maneuverDistanceSpoken(8), "30 feet")
        XCTAssertEqual(f.maneuverDistanceSpoken(1609.344), "1.0 miles")
    }

    func test_maneuverDistanceSpoken_metric() {
        let f = RideStatsFormatter(units: .metric)
        XCTAssertEqual(f.maneuverDistanceSpoken(120), "120 meters")
        XCTAssertEqual(f.maneuverDistanceSpoken(2500), "2.5 kilometers")
    }

    func test_spokenUnitWords() {
        let imperial = RideStatsFormatter(units: .imperial)
        let metric = RideStatsFormatter(units: .metric)
        XCTAssertEqual(imperial.speedUnitSpoken, "miles per hour")
        XCTAssertEqual(metric.speedUnitSpoken, "kilometers per hour")
        XCTAssertEqual(imperial.distanceUnitSpoken, "miles")
        XCTAssertEqual(metric.distanceUnitSpoken, "kilometers")
        XCTAssertEqual(imperial.elevationUnitSpoken, "feet")
        XCTAssertEqual(metric.elevationUnitSpoken, "meters")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd AuraCore && swift test --filter RideStatsFormatterTests`
Expected: FAIL — `value of type 'RideStatsFormatter' has no member 'maneuverDistanceSpoken'` (and the unit-word members).

- [ ] **Step 3: Implement**

In `RideStatsFormatter.swift`, add the spoken unit words after the existing `speedUnit` property:

```swift
    public var speedUnitSpoken: String     { metric ? "kilometers per hour" : "miles per hour" }
    public var distanceUnitSpoken: String  { metric ? "kilometers" : "miles" }
    public var elevationUnitSpoken: String { metric ? "meters" : "feet" }
```

Then replace the existing `maneuverDistance(_:)` method with a shared-path version plus the spoken form:

```swift
    /// The maneuver distance split into its formatted value and both unit forms, so the
    /// short glyph string and the spoken string share one rounding path and never drift.
    private func maneuverParts(_ meters: Double) -> (value: String, short: String, spoken: String) {
        if metric {
            if meters >= 1000 {
                return (String(format: "%.1f", UnitConverter.km(fromMeters: meters)), "km", "kilometers")
            }
            let rounded = Int((meters / 10).rounded()) * 10
            return ("\(rounded)", "m", "meters")
        } else {
            let feet = UnitConverter.feet(fromMeters: meters)
            if feet >= 1000 {
                return (String(format: "%.1f", UnitConverter.miles(fromMeters: meters)), "mi", "miles")
            }
            let rounded = Int((feet / 10).rounded()) * 10
            return ("\(rounded)", "ft", "feet")
        }
    }

    /// Short distance-to-maneuver string, e.g. "390 ft" / "0.2 mi" / "120 m" / "0.3 km".
    /// Output is unchanged from the previous implementation (the Live Activity and Lock
    /// Screen widgets depend on it).
    public func maneuverDistance(_ meters: Double) -> String {
        let p = maneuverParts(meters)
        return "\(p.value) \(p.short)"
    }

    /// Spoken distance-to-maneuver, e.g. "390 feet" / "0.2 miles" / "120 meters" /
    /// "0.3 kilometers". Same value and rounding as `maneuverDistance`, spelled units.
    public func maneuverDistanceSpoken(_ meters: Double) -> String {
        let p = maneuverParts(meters)
        return "\(p.value) \(p.spoken)"
    }
```

Delete the original `maneuverDistance(_:)` body (the one with the inline `if feet >= 1000` branches and its doc comment) so only the two public methods above remain.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd AuraCore && swift test --filter RideStatsFormatterTests`
Expected: PASS — the new tests pass and the existing `test_maneuverDistance_imperial`/`_metric` still pass (byte-identical output).

- [ ] **Step 5: Commit**

```bash
cd AuraCore
git add Sources/AuraKit/Formatting/RideStatsFormatter.swift Tests/AuraKitTests/RideStatsFormatterTests.swift
git checkout -- Package.resolved 2>/dev/null || true
git commit -m "$(cat <<'EOF'
feat(core): add spoken distance and unit words to RideStatsFormatter

Split maneuverDistance into a shared value/unit path so the short glyph
form and a new spoken form (maneuverDistanceSpoken) cannot drift, and add
spoken unit words for the composed VoiceOver labels. maneuverDistance
output is unchanged; the Live Activity and Lock Screen callers are unaffected.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Turn card unit-aware with a composed label

**Files:**
- Modify: `AuraCore/Sources/AuraKit/TurnCardPresenter.swift`
- Modify: `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift`
- Test: `AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift`, `TurnCardPresenterEdgeTests.swift`, `GuidanceViewModelTests.swift`

**Interfaces:**
- Consumes: `RideStatsFormatter.maneuverDistance`, `.maneuverDistanceSpoken` (Task 1); `DistanceUnits` (AuraKit).
- Produces:
  - `TurnCardState.accessibilityLabel: String`
  - `TurnCardPresenter.state(distanceToManeuverMeters:instruction:units:expandWithinMeters:) -> TurnCardState`
  - `TurnCardPresenter.state(for:units:expandWithinMeters:) -> TurnCardState`
  - `GuidanceViewModel.units: DistanceUnits` (default `.imperial`)

- [ ] **Step 1: Write/adjust the failing tests**

Replace the entire contents of `TurnCardPresenterTests.swift` with (every call now passes `units:`, plus new metric and label tests):

```swift
import XCTest
@testable import AuraKit

final class TurnCardPresenterTests: XCTestCase {
    func test_distanceFormatting_feetThenMiles_imperial() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "x", units: .imperial).distanceText, "390 ft")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 400, instruction: "x", units: .imperial).distanceText, "0.2 mi")
    }

    func test_distanceFormatting_metric() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "x", units: .metric).distanceText, "120 m")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 2500, instruction: "x", units: .metric).distanceText, "2.5 km")
    }

    func test_isExpanded_whenWithinThreshold() {
        XCTAssertTrue(TurnCardPresenter.state(distanceToManeuverMeters: 100, instruction: "x", units: .imperial, expandWithinMeters: 150).isExpanded)
        XCTAssertFalse(TurnCardPresenter.state(distanceToManeuverMeters: 200, instruction: "x", units: .imperial, expandWithinMeters: 150).isExpanded)
    }

    func test_passesInstructionThrough() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 50, instruction: "Right onto Penn Ave", units: .imperial).primaryText,
                       "Right onto Penn Ave")
    }

    func test_accessibilityLabel_composed_imperial() {
        let s = TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave", units: .imperial)
        XCTAssertEqual(s.accessibilityLabel, "In 390 feet, Right onto Penn Ave")
    }

    func test_accessibilityLabel_composed_metric() {
        let s = TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave", units: .metric)
        XCTAssertEqual(s.accessibilityLabel, "In 120 meters, Right onto Penn Ave")
    }

    func test_staticStates_accessibilityLabel() {
        XCTAssertEqual(TurnCardState.starting.accessibilityLabel, "Starting navigation.")
        XCTAssertEqual(TurnCardState.unavailable.accessibilityLabel, "Navigate to destination.")
    }
}
```

Replace the entire contents of `TurnCardPresenterEdgeTests.swift` with (same characterization assertions, each call now passing `units: .imperial`):

```swift
import XCTest
@testable import AuraKit
import AuraCore

/// Boundary tests for `TurnCardPresenter.state` (imperial distance rounding).
final class TurnCardPresenterEdgeTests: XCTestCase {

    private let metersAtNominal1000ft = 1000.0 / 3.280839895013123 // ≈ 304.8 m

    func test_zeroMeters_showsZeroFeet() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 0, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "0 ft")
        XCTAssertTrue(state.isExpanded)
    }

    func test_justBelowSwitch_showsFeet() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 300, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "980 ft")
    }

    func test_atOrAboveSwitch_showsMiles() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: 305, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "0.2 mi")
    }

    func test_nominal1000ftBoundary_actuallyStaysInFeet_floatArtifact() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: metersAtNominal1000ft, instruction: "x", units: .imperial)
        XCTAssertEqual(state.distanceText, "1000 ft")
    }

    func test_justAboveSwitch_showsMiles() {
        let state = TurnCardPresenter.state(distanceToManeuverMeters: metersAtNominal1000ft + 1, instruction: "x", units: .imperial)
        XCTAssertTrue(state.distanceText.hasSuffix(" mi"),
                      "expected miles formatting just above the switch, got \(state.distanceText)")
    }

    func test_roundsFeetToNearest10() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 30, instruction: "x", units: .imperial).distanceText, "100 ft")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 8, instruction: "x", units: .imperial).distanceText, "30 ft")
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 1, instruction: "x", units: .imperial).distanceText, "0 ft")
    }
}
```

Add this test to `GuidanceViewModelTests.swift` (keep all existing tests; they stay green on the `.imperial` default):

```swift
    @MainActor
    func test_units_propagateToTurnCard() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        vm.units = .metric

        await vm.run(route: makeRoute())

        XCTAssertEqual(vm.turn.distanceText, "120 m")
        XCTAssertEqual(vm.turn.accessibilityLabel, "In 120 meters, Right onto Penn Ave")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd AuraCore && swift test --filter TurnCardPresenterTests`
Expected: FAIL — `incorrect argument label` / `extra argument 'units'` / no member `accessibilityLabel`.

- [ ] **Step 3: Implement**

Replace the entire contents of `TurnCardPresenter.swift` with:

```swift
import Foundation
import AuraCore

public struct TurnCardState: Equatable, Sendable {
    public var primaryText: String     // maneuver instruction, e.g. "Right onto Penn Ave"
    public var distanceText: String    // distance to the maneuver, e.g. "390 ft" or "120 m"
    public var isExpanded: Bool         // true when the maneuver is near → the card grows
    /// One composed VoiceOver read for the whole card, e.g. "In 390 feet, Right onto Penn Ave".
    public var accessibilityLabel: String

    public init(primaryText: String, distanceText: String, isExpanded: Bool, accessibilityLabel: String) {
        self.primaryText = primaryText
        self.distanceText = distanceText
        self.isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
    }

    /// Shown before the first progress update arrives.
    public static let starting = TurnCardState(
        primaryText: "Starting navigation…", distanceText: "–", isExpanded: false,
        accessibilityLabel: "Starting navigation.")

    /// Shown when guidance can't be established — recording and the map still work,
    /// the turn card just degrades to a generic prompt.
    public static let unavailable = TurnCardState(
        primaryText: "Navigate to destination", distanceText: "–", isExpanded: false,
        accessibilityLabel: "Navigate to destination.")
}

/// Adaptive turn-card display logic (the "option C" behavior). Pure + Mapbox-independent.
/// Unit-aware: the visible distance and the spoken label both honor the rider's units.
public enum TurnCardPresenter {
    public static func state(distanceToManeuverMeters: Double,
                             instruction: String,
                             units: DistanceUnits,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        let formatter = RideStatsFormatter(units: units)
        return TurnCardState(
            primaryText: instruction,
            distanceText: formatter.maneuverDistance(distanceToManeuverMeters),
            isExpanded: distanceToManeuverMeters <= expandWithinMeters,
            accessibilityLabel: "In \(formatter.maneuverDistanceSpoken(distanceToManeuverMeters)), \(instruction)")
    }

    /// Convenience overload mapping a pure `GuidanceUpdate` straight to card state.
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        state(distanceToManeuverMeters: update.distanceToManeuverMeters,
              instruction: update.instruction,
              units: units,
              expandWithinMeters: expandWithinMeters)
    }
}
```

In `GuidanceViewModel.swift`, add the `units` input after the `routeGeometry` property (around line 31):

```swift
    /// The rider's distance-units setting, set by the view. Drives the unit-aware turn
    /// card. Not observed (only read inside `run`), so `@ObservationIgnored`.
    @ObservationIgnored public var units: DistanceUnits = .imperial
```

And in `run(route:)`, change the progress case (line 75) from `turn = TurnCardPresenter.state(for: update)` to:

```swift
                turn = TurnCardPresenter.state(for: update, units: units)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd AuraCore && swift test`
Expected: PASS — all suites, including the unchanged `GuidanceViewModelTests` (default `.imperial` keeps "390 ft") and the new metric propagation test.

- [ ] **Step 5: Commit**

```bash
cd AuraCore
git add Sources/AuraKit/TurnCardPresenter.swift Sources/AuraKit/Guidance/GuidanceViewModel.swift \
        Tests/AuraKitTests/TurnCardPresenterTests.swift Tests/AuraKitTests/TurnCardPresenterEdgeTests.swift \
        Tests/AuraKitTests/GuidanceViewModelTests.swift
git checkout -- Package.resolved 2>/dev/null || true
git commit -m "$(cat <<'EOF'
feat(core): make the turn card unit-aware with a composed VoiceOver label

TurnCardState gains a composed accessibilityLabel ("In 390 feet, Right onto
Penn Ave"), and TurnCardPresenter now formats its distance through the
unit-aware RideStatsFormatter instead of imperial-only, so a metric rider
finally sees and hears meters. GuidanceViewModel threads the rider's units
through; the default keeps existing tests on imperial.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Compose the trip strip's VoiceOver label

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Guidance/CruisingPresenter.swift`
- Test: `AuraCore/Tests/AuraKitTests/CruisingPresenterTests.swift`

**Interfaces:**
- Consumes: `RideStatsFormatter.distanceValue`, `.distanceUnitSpoken` (Task 1).
- Produces: `CruisingState.accessibilityLabel: String`.

Note: `CruisingState`'s memberwise init gains a required `accessibilityLabel`. Its only constructors are in this file (`CruisingPresenter`) and the app-target `TripStripView` preview, which Task 5 updates. The package builds and tests via `swift test`, which does not compile the app target, so this task is green on its own.

- [ ] **Step 1: Write the failing tests**

Add these tests to `CruisingPresenterTests` (keep all existing tests):

```swift
    @Test func accessibilityLabel_full() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, duration: 1080, street: "Penn Ave"),
                                        units: .imperial, now: now(cal), calendar: cal)
        // 3380 m -> "2.1 miles"; 16:20 + 18 min -> "4:38 PM" (assert the stable parts).
        #expect(s.accessibilityLabel.hasPrefix("On Penn Ave, 2.1 miles to go, arriving "))
        #expect(s.accessibilityLabel.contains("4:38"))
    }

    @Test func accessibilityLabel_noStreet() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, duration: 1080),
                                        units: .imperial, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel.hasPrefix("2.1 miles to go, arriving "))
    }

    @Test func accessibilityLabel_missingDistance() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(duration: 1080, street: "Penn Ave"),
                                        units: .imperial, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel.hasPrefix("On Penn Ave, arriving "))
    }

    @Test func accessibilityLabel_missingEta() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, street: "Penn Ave"),
                                        units: .imperial, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel == "On Penn Ave, 2.1 miles to go")
    }

    @Test func accessibilityLabel_metricDistance() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380, street: "Penn Ave"),
                                        units: .metric, now: now(cal), calendar: cal)
        #expect(s.accessibilityLabel == "On Penn Ave, 3.4 kilometers to go")
    }

    @Test func accessibilityLabel_startingState() {
        #expect(CruisingState.starting.accessibilityLabel == "Starting navigation.")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd AuraCore && swift test --filter CruisingPresenterTests`
Expected: FAIL — no member `accessibilityLabel`.

- [ ] **Step 3: Implement**

Replace the entire contents of `CruisingPresenter.swift` with:

```swift
import Foundation
import AuraCore

/// The formatted cruising-state line the navigate HUD's trip strip renders: the road
/// the rider is on, the distance left to the destination, and the arrival ETA. Pure
/// and engine-independent, mirroring `TurnCardState`. Unlike `TurnCardPresenter`,
/// which formats its maneuver distance imperial-only, this is unit-aware.
public struct CruisingState: Equatable, Sendable {
    /// Current road, e.g. "Penn Ave". nil omits the label.
    public var streetName: String?
    /// Distance left to the destination, e.g. "2.1 mi". nil shows a placeholder.
    public var distanceRemaining: String?
    /// Arrival clock, e.g. "4:38 PM". nil shows a placeholder.
    public var eta: String?
    /// One composed VoiceOver read for the whole strip, e.g.
    /// "On Penn Ave, 2.1 miles to go, arriving 4:38 PM".
    public var accessibilityLabel: String

    public init(streetName: String?, distanceRemaining: String?, eta: String?, accessibilityLabel: String) {
        self.streetName = streetName
        self.distanceRemaining = distanceRemaining
        self.eta = eta
        self.accessibilityLabel = accessibilityLabel
    }

    /// Before the first usable progress update; the strip reads a calm "Starting…".
    public static let starting = CruisingState(streetName: nil, distanceRemaining: nil, eta: nil,
                                               accessibilityLabel: "Starting navigation.")
}

/// Turns a `GuidanceUpdate` into a `CruisingState`. Pure: the caller passes `now` and a
/// `Calendar`, so the ETA clock is deterministic in tests instead of reading the wall clock.
public enum CruisingPresenter {
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             now: Date,
                             calendar: Calendar = .current) -> CruisingState {
        let streetName = street(update.currentStreetName)
        let distanceRemaining = distance(update.distanceRemainingMeters, units: units)
        let eta = eta(update.durationRemainingSeconds, now: now, calendar: calendar)
        return CruisingState(
            streetName: streetName,
            distanceRemaining: distanceRemaining,
            eta: eta,
            accessibilityLabel: label(streetName: streetName,
                                      meters: update.distanceRemainingMeters,
                                      eta: eta, units: units))
    }

    /// Empty or whitespace-only names (unnamed trails) become nil so the strip omits them.
    private static func street(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    /// Composes `RideStatsFormatter`'s value and unit ("2.1" + "mi" -> "2.1 mi").
    private static func distance(_ meters: Double?, units: DistanceUnits) -> String? {
        guard let meters, meters > 0 else { return nil }
        let formatter = RideStatsFormatter(units: units)
        return "\(formatter.distanceValue(meters)) \(formatter.distanceUnit)"
    }

    /// Arrival = now + remaining, formatted to a locale-aware short time so a 12-hour
    /// locale gets "4:38 PM" and a 24-hour locale gets "16:38".
    private static func eta(_ seconds: Double?, now: Date, calendar: Calendar) -> String? {
        // Accepts `>= 0` (unlike the distance guard's `> 0`): zero seconds means "arriving
        // now", which is a valid ETA, whereas zero meters remaining is indistinguishable
        // from "not yet known" and so reads as a placeholder.
        guard let seconds, seconds >= 0 else { return nil }
        let arrival = now.addingTimeInterval(seconds)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: arrival)
    }

    /// Composes the spoken strip read from the resolved parts, omitting whichever clause
    /// has no value. Distance is spelled from the raw meters (so "2.1 miles", not "2.1 mi").
    private static func label(streetName: String?, meters: Double?, eta: String?,
                              units: DistanceUnits) -> String {
        var clauses: [String] = []
        if let streetName { clauses.append("On \(streetName)") }
        if let meters, meters > 0 {
            let formatter = RideStatsFormatter(units: units)
            clauses.append("\(formatter.distanceValue(meters)) \(formatter.distanceUnitSpoken) to go")
        }
        if let eta { clauses.append("arriving \(eta)") }
        return clauses.isEmpty ? "Starting navigation." : clauses.joined(separator: ", ")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd AuraCore && swift test --filter CruisingPresenterTests`
Expected: PASS — including the existing distance/ETA/street tests (unchanged behavior) and the six new label tests.

- [ ] **Step 5: Commit**

```bash
cd AuraCore
git add Sources/AuraKit/Guidance/CruisingPresenter.swift Tests/AuraKitTests/CruisingPresenterTests.swift
git checkout -- Package.resolved 2>/dev/null || true
git commit -m "$(cat <<'EOF'
feat(core): compose the trip strip's VoiceOver label in CruisingPresenter

CruisingState gains a composed accessibilityLabel ("On Penn Ave, 2.1 miles
to go, arriving 4:38 PM"), built from the raw meters/seconds so the spoken
distance is spelled and unit-aware, with each clause omitted when its value
is absent.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `SpeedRailVoice` composer

**Files:**
- Create: `AuraCore/Sources/AuraKit/Formatting/SpeedRailVoice.swift`
- Test: `AuraCore/Tests/AuraKitTests/SpeedRailVoiceTests.swift`

**Interfaces:**
- Consumes: `RideStatsFormatter` spoken vocabulary (Task 1); `RideStats` (AuraCore); `DistanceUnits` (AuraKit).
- Produces:
  - `SpeedRailVoice.speedValue(_ stats: RideStats, units: DistanceUnits) -> String` ("24 miles per hour")
  - `SpeedRailVoice.statsLabel(_ stats: RideStats, elapsed: TimeInterval, units: DistanceUnits) -> String` ("Distance 5.0 miles, time 12 minutes 30 seconds, elevation gain 340 feet")

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/SpeedRailVoiceTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct SpeedRailVoiceTests {
    /// 24 mph average, 5.0 mi, 340 ft climb (imperial) or 24 km/h, 8.0 km, 104 m (metric).
    private func stats(speed: Double, distance: Double, elevation: Double) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: 0,
                  averageSpeedMetersPerSecond: speed, maxSpeedMetersPerSecond: 0,
                  elevationGainMeters: elevation)
    }

    @Test func speedValue_imperial() {
        // 10.728 m/s ≈ 24 mph
        let s = SpeedRailVoice.speedValue(stats(speed: 10.728, distance: 0, elevation: 0), units: .imperial)
        #expect(s == "24 miles per hour")
    }

    @Test func speedValue_metric() {
        // 6.6667 m/s = 24 km/h
        let s = SpeedRailVoice.speedValue(stats(speed: 6.6667, distance: 0, elevation: 0), units: .metric)
        #expect(s == "24 kilometers per hour")
    }

    @Test func statsLabel_imperial() {
        // 8046.72 m = 5.0 mi; 103.632 m = 340 ft
        let s = SpeedRailVoice.statsLabel(stats(speed: 0, distance: 8046.72, elevation: 103.632),
                                          elapsed: 750, units: .imperial)
        #expect(s == "Distance 5.0 miles, time 12 minutes 30 seconds, elevation gain 340 feet")
    }

    @Test func statsLabel_metric() {
        let s = SpeedRailVoice.statsLabel(stats(speed: 0, distance: 8000, elevation: 104),
                                          elapsed: 750, units: .metric)
        #expect(s == "Distance 8.0 kilometers, time 12 minutes 30 seconds, elevation gain 104 meters")
    }

    @Test func elapsedSpoken_edgeCases() {
        let z = stats(speed: 0, distance: 0, elevation: 0)
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 0, units: .imperial).contains("time 0 seconds"))
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 45, units: .imperial).contains("time 45 seconds"))
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 720, units: .imperial).contains("time 12 minutes,"))
        #expect(SpeedRailVoice.statsLabel(z, elapsed: 61, units: .imperial).contains("time 1 minute 1 second"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd AuraCore && swift test --filter SpeedRailVoiceTests`
Expected: FAIL — cannot find `SpeedRailVoice` in scope.

- [ ] **Step 3: Implement**

Create `AuraCore/Sources/AuraKit/Formatting/SpeedRailVoice.swift`:

```swift
import Foundation
import AuraCore

/// Composes the SpeedRail's VoiceOver strings. Pure and unit-aware, so the cockpit's
/// most-glanced element reads as coherent speech instead of mechanical fragments, and
/// the composition is unit-tested in CI rather than buried in the SwiftUI view.
public enum SpeedRailVoice {
    /// The speed element's spoken value, e.g. "24 miles per hour". Used as the
    /// `accessibilityValue` so it re-announces alone as the (slow-moving average) speed
    /// changes, while the static "Speed" label does not.
    public static func speedValue(_ stats: RideStats, units: DistanceUnits) -> String {
        let formatter = RideStatsFormatter(units: units)
        return "\(formatter.speedValue(stats.averageSpeedMetersPerSecond)) \(formatter.speedUnitSpoken)"
    }

    /// The free-ride stats element, e.g.
    /// "Distance 5.0 miles, time 12 minutes 30 seconds, elevation gain 340 feet".
    public static func statsLabel(_ stats: RideStats, elapsed: TimeInterval, units: DistanceUnits) -> String {
        let formatter = RideStatsFormatter(units: units)
        let distance = "\(formatter.distanceValue(stats.distanceMeters)) \(formatter.distanceUnitSpoken)"
        let elevation = "\(formatter.elevationValue(stats.elevationGainMeters)) \(formatter.elevationUnitSpoken)"
        return "Distance \(distance), time \(spokenElapsed(elapsed)), elevation gain \(elevation)"
    }

    /// Spells elapsed seconds, singularizing the unit words and dropping a zero component:
    /// 750 -> "12 minutes 30 seconds", 45 -> "45 seconds", 720 -> "12 minutes",
    /// 61 -> "1 minute 1 second", 0 -> "0 seconds".
    static func spokenElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let minutes = total / 60
        let secs = total % 60
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        if minutes == 0 { return plural(secs, "second") }
        if secs == 0 { return plural(minutes, "minute") }
        return "\(plural(minutes, "minute")) \(plural(secs, "second"))"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd AuraCore && swift test --filter SpeedRailVoiceTests`
Expected: PASS.

- [ ] **Step 5: Run the full package suite**

Run: `cd AuraCore && swift test`
Expected: PASS — all suites.

- [ ] **Step 6: Commit**

```bash
cd AuraCore
git add Sources/AuraKit/Formatting/SpeedRailVoice.swift Tests/AuraKitTests/SpeedRailVoiceTests.swift
git checkout -- Package.resolved 2>/dev/null || true
git commit -m "$(cat <<'EOF'
feat(core): add SpeedRailVoice composer for the speed-rail labels

A pure, unit-aware composer for the speed element's spoken value ("24 miles
per hour") and the free-ride stats element ("Distance ..., time ...,
elevation gain ..."), with elapsed spelled out and singularized. CI-tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Apply the composed labels to the cockpit views

**Files:**
- Modify: `Aura/Sources/Ride/TurnCardView.swift`
- Modify: `Aura/Sources/Ride/SpeedRail.swift`
- Modify: `Aura/Sources/Ride/TripStripView.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `TurnCardState.accessibilityLabel`, `CruisingState.accessibilityLabel`, `SpeedRailVoice.speedValue`, `.statsLabel`, `GuidanceViewModel.units`.
- Produces: nothing for later tasks (the package phase is complete).

No app-target files are added or deleted, so no `xcodegen` membership change is needed. The build still runs `xcodegen generate` first because the project is gitignored and may not exist in the worktree.

- [ ] **Step 1: TurnCardView — one element, label applied, arrow decorative**

In `TurnCardView.swift`, the body's root `HStack { ... }` carries a chain of modifiers. Add, immediately after the closing brace of the root `HStack` and before its first `.padding(.horizontal, ...)` modifier:

```swift
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
```

This makes the whole card a single VoiceOver element reading the composed label; `.ignore` subsumes the arrow, distance, and instruction children, so the decorative arrow is no longer a separate stop.

- [ ] **Step 2: SpeedRail — two composed elements**

In `SpeedRail.swift`, replace the `body` and the `metric` helper with:

```swift
    var body: some View {
        VStack(alignment: .trailing, spacing: AuraTheme.Spacing.xs) {
            // Hero speed: one element, static "Speed" label + spoken value, so the live
            // (slow-moving average) value re-announces alone, never the whole rail.
            SpeedReadout(value: fmt.speedValue(stats.averageSpeedMetersPerSecond),
                         unit: fmt.speedUnit.uppercased())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speed")
                .accessibilityValue(SpeedRailVoice.speedValue(stats, units: units))
            if layout == .full {
                HStack(spacing: AuraTheme.Spacing.md) {
                    metric(fmt.distanceValue(stats.distanceMeters), fmt.distanceUnit.uppercased())
                    metric(RideStatsFormatter.clock(elapsed), "TIME")
                    metric(fmt.elevationValue(stats.elevationGainMeters), "\(fmt.elevationUnit.uppercased()) ↑")
                }
                .padding(.top, AuraTheme.Spacing.xs)
                // The trio composes into one element so VoiceOver reads "Distance ...,
                // time ..., elevation gain ..." instead of four mechanical stops.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SpeedRailVoice.statsLabel(stats, elapsed: elapsed, units: units))
            }
        }
        .padding(AuraTheme.Spacing.lg)
        .background(AuraTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .cockpit)
    }
```

(The `.accessibilityElement(children: .combine)` calls are gone: the parent now owns one composed element per group, and `metric` no longer needs its own grouping.)

- [ ] **Step 3: TripStripView — one composed element, preview init fixed**

In `TripStripView.swift`, in `body`, add the accessibility modifiers right after `content`:

```swift
    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityLabel)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.vertical, AuraTheme.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(background)
            .animation(reduceMotion ? nil : .snappy, value: state)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
```

Then update the `#Preview` so the `CruisingState` constructions pass the now-required `accessibilityLabel`:

```swift
#Preview {
    VStack(spacing: 12) {
        TripStripView(state: .init(streetName: "Penn Ave", distanceRemaining: "2.1 mi", eta: "4:38 PM",
                                   accessibilityLabel: "On Penn Ave, 2.1 miles to go, arriving 4:38 PM"))
        TripStripView(state: .init(streetName: "Boulevard of the Allies and then some more",
                                   distanceRemaining: "12.4 mi", eta: "5:02 PM",
                                   accessibilityLabel: "On Boulevard of the Allies and then some more, 12.4 miles to go, arriving 5:02 PM"))
        TripStripView(state: .init(streetName: nil, distanceRemaining: "0.3 mi", eta: "4:51 PM",
                                   accessibilityLabel: "0.3 miles to go, arriving 4:51 PM"))
        TripStripView(state: .starting)
    }
    .padding()
    .background(AuraTheme.background)
}
```

- [ ] **Step 4: NavigateHUDView — feed the units into the view model**

In `NavigateHUDView.swift`, inside the `.task { ... }` block, add `guidance.units = settings.units` immediately before `guidance.start(route: route)`:

```swift
            guidance.units = settings.units
            guidance.start(route: route)
```

Then add a `.onChange` to keep it current if the rider changes units mid-ride. Place it next to the existing `.onChange(of: coordinator.isRecording)` modifier:

```swift
        .onChange(of: settings.units) { _, newUnits in
            guidance.units = newUnits
        }
```

- [ ] **Step 5: Build the app (delegate to the builder subagent)**

Dispatch the `apple-platform-build-tools:builder` subagent to run, from the worktree root:

```bash
cd Aura && xcodegen generate && \
xcodebuild -project Aura.xcodeproj -scheme Aura \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED (app + AuraWidgets compile). Have the builder report the exact `TARGET_BUILD_DIR` from `xcodebuild -showBuildSettings` for the install step in Task 6.

- [ ] **Step 6: Lint the whole repo**

Run from the worktree root: `scripts/lint.sh` (SwiftLint 0.64.1, `--strict`, whole repo).
Expected: 0 violations.

- [ ] **Step 7: Commit**

```bash
git add Aura/Sources/Ride/TurnCardView.swift Aura/Sources/Ride/SpeedRail.swift \
        Aura/Sources/Ride/TripStripView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "$(cat <<'EOF'
feat(app): apply composed VoiceOver labels to the cockpit views

TurnCardView, SpeedRail (two elements: speed value + composed stats), and
TripStripView now each expose one composed accessibility element instead of
several mechanical stops, and NavigateHUDView feeds the rider's units into
the guidance view model so the turn card reads in the right units.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Simulator accessibility-tree verification

**Files:** none (verification only; a fix-up commit only if something is wrong).

This is the point of the accessibility wave: confirm the real `label`/`value`/`traits` VoiceOver sees, not just a green build.

- [ ] **Step 1: Install the build you just produced**

From the `TARGET_BUILD_DIR` the builder reported in Task 5 (authoritative — do not pick by mtime):

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl install booted "<TARGET_BUILD_DIR>/Aura.app"
xcrun simctl launch booted app.aura.ios
```

If a screenshot's md5 matches a prior frame, reboot the sim (`xcrun simctl shutdown booted && xcrun simctl boot "iPhone 17"`); the accessibility tree stays correct regardless.

- [ ] **Step 2: Verify the navigate HUD elements**

Drive into a navigate ride (or the scripted/desk-demo path) and read the accessibility tree (`axe describe-ui` or `ios-simulator-mcp ui_describe_all`). Confirm:
- The turn card is ONE element whose label reads "In <distance>, <instruction>" (e.g. "In 390 feet, Right onto Penn Ave"), with no separate arrow/distance/instruction stops.
- The speed element reads label "Speed", value "<n> miles per hour".
- The trip strip is ONE element reading "On <street>, <n> miles to go, arriving <time>".

- [ ] **Step 3: Verify the free-ride SpeedRail**

Drive into a free ride and confirm the SpeedRail reads as TWO elements: the speed element (label "Speed", value "<n> miles per hour"), then the stats element ("Distance ..., time ..., elevation gain ..."), with no "F T up arrow" fragment.

- [ ] **Step 4: Verify the degraded states**

Confirm the `.starting` turn card reads "Starting navigation." and the `.starting` trip strip reads "Starting navigation." (before the first progress update), and that an unavailable-guidance turn card reads "Navigate to destination."

- [ ] **Step 5: Regression check**

Confirm the free-ride full rail and the navigate speed-only rail still render their numbers visually as before (no layout change), and that the navigate controls (recenter/mute/end) still carry their SP1 labels and remain reachable.

If any element is wrong, fix the responsible view (Task 5 file) or presenter (Task 1-4 file), rebuild, reinstall from the fresh `TARGET_BUILD_DIR`, and re-verify before moving on.

---

### Task 7: Mark the sub-project shipped in the ROADMAP

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Update the Wave 2 bullet**

In `docs/ROADMAP.md`, under "### Wave 2 — The cockpit the spec promised", replace the second bullet ("Give the SpeedRail and TurnCard composed VoiceOver labels…") with a SHIPPED entry in the same voice as the cockpit bullet above it, recording: composed single-element labels for the TurnCard, SpeedRail (two elements: speed value + composed stats), and the TripStrip (taken in scope); the turn card made unit-aware (the metric-rider fix); pure composition in `RideStatsFormatter`/`TurnCardPresenter`/`CruisingPresenter`/`SpeedRailVoice` with CI tests; and simulator accessibility-tree verification. Also update the audit-finding paragraph ("Accessibility is strong on motion, weak in the cockpit") to note the composed labels are now done, leaving only the contrast lift (SP3).

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
docs(roadmap): mark the Wave 2 composed VoiceOver labels shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

**Spec coverage:**
- Turn card composed label + distance-first + degraded states → Task 2 (presenter) + Task 5 step 1 (view). ✓
- Turn card unit-aware → Task 1 (formatter) + Task 2 (presenter/VM) + Task 5 step 4 (units wiring). ✓
- SpeedRail two elements (speed value + composed stats), both layouts → Task 4 (composer) + Task 5 step 2 (view). ✓
- TripStrip composed label, all states → Task 3 (presenter) + Task 5 step 3 (view). ✓
- Spoken vocabulary, plural/singular, "1000 feet" verbatim → Task 1 + Task 4 (`spokenElapsed`). ✓
- `maneuverDistance` byte-identical for both widget callers → Task 1 (shared path, existing fixtures unchanged). ✓
- No proactive announcements; read-only traits via `.ignore` → Task 5. ✓
- CI unit tests for every composed string → Tasks 1-4. ✓
- Empirical sim verification → Task 6. ✓
- ROADMAP → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every test shows assertions; commands have expected output. ✓

**Type consistency:** `accessibilityLabel: String` on both `TurnCardState` and `CruisingState`; `SpeedRailVoice.speedValue(_:units:)` and `.statsLabel(_:elapsed:units:)` match between Task 4 definition and Task 5 use; `GuidanceViewModel.units` defined in Task 2, used in Task 5; `maneuverDistanceSpoken`/`distanceUnitSpoken`/`speedUnitSpoken`/`elevationUnitSpoken` defined in Task 1, used in Tasks 2-4. ✓

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-26-aura-wave-2-voiceover-labels.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, with a spec-compliance review and a code-quality review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints.

Which approach?
