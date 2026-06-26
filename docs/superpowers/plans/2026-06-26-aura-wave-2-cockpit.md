# Aura Wave 2 — Navigate-HUD cockpit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the navigate HUD the cruising cockpit Section 5 describes: a bottom trip strip with the current street name, distance remaining, and an arrival ETA, plus one control cluster (recenter, mute, end-ride) built on `HUDControlButton`.

**Architecture:** The guidance seam (`GuidanceUpdate`) grows three optional fields that Mapbox already exposes on `RouteProgress`; a pure `CruisingPresenter` in AuraKit turns them into display strings under CI test. The app target gets a `TripStripView`, a `ControlCluster`, a destructive role on `HUDControlButton`, a speed-only `SpeedRail` layout, and a `NavigateHUDView` rewire. The number-to-text formatting stays in the package so CI covers it; the SwiftUI and Mapbox work is verified by an app build plus a simulator accessibility-tree pass.

**Tech Stack:** Swift 6 language mode, SwiftUI, Mapbox Navigation v3 / MapboxMaps, Swift Testing, XcodeGen, the mono-lime `AuraTheme` (lime accent, pink reserved for end-ride, Saira Condensed cockpit numerals).

## Global Constraints

- **Toolchain:** Swift 6.2 / Xcode 26, iPhone 17 / iOS 26.x simulator, SwiftLint 0.64.1 pinned, run `--strict`.
- **Layer rules:** `AuraCore` (pure, no UIKit/SwiftUI/CoreLocation) and `AuraKit` (no SwiftUI) build on the macOS CI host. Do not add iOS-only CoreLocation or UIKit APIs to the package without an `#if os(iOS)` guard. This plan adds none.
- **CI:** three jobs (AuraCore `swift test`, xcodebuild app build, SwiftLint `--strict`). All three must stay green.
- **XcodeGen:** an app-target file create or delete requires `cd Aura && xcodegen generate`. New files under `Aura/Sources/**` are picked up by the app target's `Sources` glob, so `project.yml` needs no edit. Package files under `AuraCore/Sources/**` and `AuraCore/Tests/**` are auto-globbed by SwiftPM (no regen).
- **Never stage:** `AuraCore/Package.resolved` (revert with `git checkout -- AuraCore/Package.resolved` if a build dirties it), the generated `Aura/Aura.xcodeproj`, or the gitignored `Aura/Resources/MapboxAccessToken`. Stage only the files each task names.
- **Identity:** reuse `AuraTheme` as-is. No new colors, fonts, or gradients. Lime `AuraTheme.accent` for active, pink `AuraTheme.destructive` for end-ride only.
- **Builds and tests are delegated** to the `apple-platform-build-tools:builder` subagent to preserve context. Package tests: `cd AuraCore && swift test`. App build: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`.
- **Commit conventions:** `feat(core)` / `refactor(core)` for the package, `feat(app)` / `refactor(app)` for the app, `docs(roadmap)` for the ROADMAP. End every commit body with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Local only; do not push until the finishing step.

## File structure

| File | Responsibility | Task |
| --- | --- | --- |
| `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` | `GuidanceUpdate` gains three optional fields | T1 |
| `AuraCore/Tests/AuraCoreTests/GuidanceUpdateTests.swift` | New: field defaults + round-trip | T1 |
| `AuraCore/Sources/AuraKit/Guidance/CruisingPresenter.swift` | New: `CruisingState` + `CruisingPresenter` (pure formatting) | T2 |
| `AuraCore/Tests/AuraKitTests/CruisingPresenterTests.swift` | New: distance, ETA clock, nil/empty handling | T2 |
| `Aura/Sources/Routing/MapboxGuidanceSession.swift` | Decode the three new values from `RouteProgress` | T3 |
| `Aura/Sources/Theme/HUDControlButton.swift` | Add `role` (destructive) + press scale | T4 |
| `Aura/Sources/Ride/SpeedRail.swift` | Add `Layout` (`.full` / `.speedOnly`) | T5 |
| `Aura/Sources/Ride/TripStripView.swift` | New: the bottom trip strip | T6 |
| `Aura/Sources/Ride/ControlCluster.swift` | New: recenter + mute + end-ride cluster | T7 |
| `Aura/Sources/Ride/NavigateHUDView.swift` | Integrate the strip + cluster; remove old controls | T8 |
| `docs/ROADMAP.md` | Mark the cockpit sub-project shipped | T9 |

---

### Task 1: `GuidanceUpdate` gains the three cruising fields

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` (the `GuidanceUpdate` struct, lines 6-16)
- Test: `AuraCore/Tests/AuraCoreTests/GuidanceUpdateTests.swift` (create)

**Interfaces:**
- Produces: `GuidanceUpdate(distanceToManeuverMeters:instruction:distanceRemainingMeters:durationRemainingSeconds:currentStreetName:)` where the last three are `Double?`, `Double?`, `String?`, each defaulting to `nil`. New stored properties: `distanceRemainingMeters: Double?`, `durationRemainingSeconds: Double?`, `currentStreetName: String?`.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraCoreTests/GuidanceUpdateTests.swift`:

```swift
import Testing
@testable import AuraCore

@Suite struct GuidanceUpdateTests {
    @Test func newFieldsDefaultToNil() {
        let update = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right")
        #expect(update.distanceRemainingMeters == nil)
        #expect(update.durationRemainingSeconds == nil)
        #expect(update.currentStreetName == nil)
    }

    @Test func allFieldsRoundTrip() {
        let update = GuidanceUpdate(
            distanceToManeuverMeters: 100, instruction: "Turn right onto Penn Ave",
            distanceRemainingMeters: 3380, durationRemainingSeconds: 1080,
            currentStreetName: "Penn Ave")
        #expect(update.distanceRemainingMeters == 3380)
        #expect(update.durationRemainingSeconds == 1080)
        #expect(update.currentStreetName == "Penn Ave")
        #expect(update == update)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd AuraCore && swift test --filter GuidanceUpdateTests`
Expected: FAIL to compile, "extra arguments at positions ... in call" / "value of type 'GuidanceUpdate' has no member 'distanceRemainingMeters'".

- [ ] **Step 3: Add the fields to `GuidanceUpdate`**

Replace the `GuidanceUpdate` struct (lines 6-16) with:

```swift
public struct GuidanceUpdate: Equatable, Sendable {
    /// Remaining distance, in meters, to the upcoming maneuver.
    public var distanceToManeuverMeters: Double
    /// Human-readable instruction for the upcoming maneuver, e.g. "Right onto Penn Ave".
    public var instruction: String
    /// Whole-route distance remaining to the destination, in meters. nil until known.
    public var distanceRemainingMeters: Double?
    /// Whole-route time remaining to the destination, in seconds. ETA = now + this.
    public var durationRemainingSeconds: Double?
    /// The road the rider is currently on, e.g. "Penn Ave". nil when the engine has no
    /// name for the current step.
    public var currentStreetName: String?

    public init(distanceToManeuverMeters: Double,
                instruction: String,
                distanceRemainingMeters: Double? = nil,
                durationRemainingSeconds: Double? = nil,
                currentStreetName: String? = nil) {
        self.distanceToManeuverMeters = distanceToManeuverMeters
        self.instruction = instruction
        self.distanceRemainingMeters = distanceRemainingMeters
        self.durationRemainingSeconds = durationRemainingSeconds
        self.currentStreetName = currentStreetName
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd AuraCore && swift test --filter GuidanceUpdateTests`
Expected: PASS (2 tests). Then run the full suite to confirm nothing regressed: `cd AuraCore && swift test`. Expected: all green (count goes up by 2 from the prior baseline).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift AuraCore/Tests/AuraCoreTests/GuidanceUpdateTests.swift
git commit -m "feat(core): add cruising fields to GuidanceUpdate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `CruisingPresenter` and `CruisingState`

**Files:**
- Create: `AuraCore/Sources/AuraKit/Guidance/CruisingPresenter.swift`
- Test: `AuraCore/Tests/AuraKitTests/CruisingPresenterTests.swift` (create)

**Interfaces:**
- Consumes: `GuidanceUpdate` (T1), `DistanceUnits` (cases `.imperial` / `.metric`), `RideStatsFormatter(units:)` with `distanceValue(_:) -> String` and `distanceUnit: String`.
- Produces: `CruisingState` (a `public struct` with `streetName: String?`, `distanceRemaining: String?`, `eta: String?`, and a `static let starting`) and `CruisingPresenter.state(for: GuidanceUpdate, units: DistanceUnits, now: Date, calendar: Calendar = .current) -> CruisingState`.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/CruisingPresenterTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite struct CruisingPresenterTests {
    private func calendar(_ localeID: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: localeID)
        return cal
    }
    private func now(_ cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 16, minute: 20))!
    }
    private func update(distance: Double? = nil, duration: Double? = nil,
                        street: String? = nil) -> GuidanceUpdate {
        GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "x",
                       distanceRemainingMeters: distance,
                       durationRemainingSeconds: duration, currentStreetName: street)
    }

    @Test func distanceRemainingImperial() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380), units: .imperial,
                                        now: now(cal), calendar: cal)
        #expect(s.distanceRemaining == "2.1 mi")
    }

    @Test func distanceRemainingMetric() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(distance: 3380), units: .metric,
                                        now: now(cal), calendar: cal)
        #expect(s.distanceRemaining == "3.4 km")
    }

    @Test func etaTwelveHour() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(duration: 1080), units: .imperial,
                                        now: now(cal), calendar: cal)
        // 16:20 UTC + 18 min = 16:38, which a 12-hour locale renders as "4:38 PM".
        // Assert it contains "4:38" rather than the exact "4:38 PM" string: recent
        // Apple OSes put a narrow no-break space (U+202F) before "PM", so an exact
        // equality check is OS-fragile. "4:38" (not "16:38") proves the 12-hour split.
        #expect(s.eta?.contains("4:38") == true)
    }

    @Test func etaTwentyFourHour() {
        let cal = calendar("en_GB")
        let s = CruisingPresenter.state(for: update(duration: 1080), units: .metric,
                                        now: now(cal), calendar: cal)
        // A 24-hour locale has no AM/PM glyph, so the exact string is stable.
        #expect(s.eta == "16:38")
    }

    @Test func nilFieldsYieldStarting() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(), units: .imperial,
                                        now: now(cal), calendar: cal)
        #expect(s.streetName == nil)
        #expect(s.distanceRemaining == nil)
        #expect(s.eta == nil)
        #expect(s == .starting)
    }

    @Test func emptyOrWhitespaceStreetYieldsNil() {
        let cal = calendar("en_US")
        let empty = CruisingPresenter.state(for: update(street: ""), units: .imperial,
                                            now: now(cal), calendar: cal)
        let spaces = CruisingPresenter.state(for: update(street: "   "), units: .imperial,
                                             now: now(cal), calendar: cal)
        #expect(empty.streetName == nil)
        #expect(spaces.streetName == nil)
    }

    @Test func streetPassesThrough() {
        let cal = calendar("en_US")
        let s = CruisingPresenter.state(for: update(street: "Penn Ave"), units: .imperial,
                                        now: now(cal), calendar: cal)
        #expect(s.streetName == "Penn Ave")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd AuraCore && swift test --filter CruisingPresenterTests`
Expected: FAIL to compile, "cannot find 'CruisingPresenter' in scope".

- [ ] **Step 3: Implement `CruisingState` and `CruisingPresenter`**

Create `AuraCore/Sources/AuraKit/Guidance/CruisingPresenter.swift`:

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

    public init(streetName: String?, distanceRemaining: String?, eta: String?) {
        self.streetName = streetName
        self.distanceRemaining = distanceRemaining
        self.eta = eta
    }

    /// Before the first usable progress update; the strip reads a calm "Starting…".
    public static let starting = CruisingState(streetName: nil, distanceRemaining: nil, eta: nil)
}

/// Turns a `GuidanceUpdate` into a `CruisingState`. Pure: the caller passes `now` and a
/// `Calendar`, so the ETA clock is deterministic in tests instead of reading the wall clock.
public enum CruisingPresenter {
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             now: Date,
                             calendar: Calendar = .current) -> CruisingState {
        CruisingState(streetName: street(update.currentStreetName),
                      distanceRemaining: distance(update.distanceRemainingMeters, units: units),
                      eta: eta(update.durationRemainingSeconds, now: now, calendar: calendar))
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
        guard let seconds, seconds >= 0 else { return nil }
        let arrival = now.addingTimeInterval(seconds)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: arrival)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd AuraCore && swift test --filter CruisingPresenterTests`
Expected: PASS (7 tests). The 12-hour ETA test asserts the string contains "4:38" (not an exact "4:38 PM"), so it is robust to the OS's AM/PM glyph and whitespace; the 24-hour test asserts the stable exact "16:38". Do not loosen these to match observed output beyond what is written. Then run `cd AuraCore && swift test`. Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Guidance/CruisingPresenter.swift AuraCore/Tests/AuraKitTests/CruisingPresenterTests.swift
git commit -m "feat(core): add CruisingPresenter for the trip strip

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Decode the cruising fields in `MapboxGuidanceSession`

**Files:**
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift` (the `guidanceUpdate(from:)` method, lines 176-185)

**Interfaces:**
- Consumes: `GuidanceUpdate` (T1), Mapbox `RouteProgress` with `distanceRemaining: CLLocationDistance`, `durationRemaining: TimeInterval`, and `currentLegProgress.currentStep.names: [String]?`.
- Produces: a `GuidanceUpdate` whose three new fields are populated, so `GuidanceViewModel.lastUpdate` carries them to the HUD.

App-target change with no unit test (the app target has no test target and `RouteProgress` cannot be constructed in a test). Verified by the app build here and by the simulator pass in Task 8.

- [ ] **Step 1: Update the decode**

Replace `guidanceUpdate(from:)` (lines 176-185) with:

```swift
    private static func guidanceUpdate(from progress: RouteProgress) -> GuidanceUpdate {
        let distanceToManeuver = progress.currentLegProgress.currentStepProgress.distanceRemaining
        let instruction: String
        if let upcoming = progress.currentLegProgress.upcomingStep {
            instruction = upcoming.instructions
        } else {
            instruction = progress.currentLegProgress.currentStep.instructions
        }
        return GuidanceUpdate(
            distanceToManeuverMeters: distanceToManeuver,
            instruction: instruction,
            distanceRemainingMeters: progress.distanceRemaining,
            durationRemainingSeconds: progress.durationRemaining,
            currentStreetName: progress.currentLegProgress.currentStep.names?.first
        )
    }
```

- [ ] **Step 2: Build the app to verify it compiles**

Run (via the builder subagent): `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. If `xcodebuild` dirties `AuraCore/Package.resolved`, run `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "feat(app): decode distance-remaining, ETA, and street into GuidanceUpdate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `HUDControlButton` gains a destructive role and press scale

**Files:**
- Modify: `Aura/Sources/Theme/HUDControlButton.swift` (whole file)

**Interfaces:**
- Produces: `HUDControlButton.Role` (`.normal` / `.destructive`), a `role` property, and `.hudControl(role:)`. Destructive tints the glyph `AuraTheme.destructive` (pink). Existing `.hudControl` and `.hudControl(active:)` are unchanged. Press adds a `scale(0.97)` alongside the existing opacity dim, gated by Reduce Motion.

App-target change, no unit test. Verified by the app build.

- [ ] **Step 1: Replace the file**

Replace the entire contents of `Aura/Sources/Theme/HUDControlButton.swift`:

```swift
import SwiftUI

struct HUDControlButton: ButtonStyle {
    enum Role { case normal, destructive }
    var role: Role = .normal
    var isActive = false
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(backgroundView)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .destructive: return AuraTheme.destructive
        case .normal: return isActive ? AuraTheme.accent : AuraTheme.textPrimary
        }
    }

    @ViewBuilder private var backgroundView: some View {
        if reduceTransparency {
            AuraTheme.surface
        } else {
            Color.clear.background(.ultraThinMaterial)
        }
    }
}

extension ButtonStyle where Self == HUDControlButton {
    static var hudControl: HUDControlButton { .init() }
    static func hudControl(active: Bool) -> HUDControlButton { .init(isActive: active) }
    static func hudControl(role: HUDControlButton.Role) -> HUDControlButton { .init(role: role) }
}
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (the existing `.hudControl` and `.hudControl(active:)` call sites in `RideHUDView` and `NavigateHUDView` still compile).

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Theme/HUDControlButton.swift
git commit -m "feat(app): add destructive role and press scale to HUDControlButton

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `SpeedRail` gains a speed-only layout

**Files:**
- Modify: `Aura/Sources/Ride/SpeedRail.swift` (whole file)

**Interfaces:**
- Produces: `SpeedRail.Layout` (`.full` / `.speedOnly`) and a `layout` property defaulting to `.full`. `.speedOnly` renders the `SpeedReadout` hero alone (no distance / time / elevation row). `RideHUDView` keeps the default and is untouched.

App-target change, no unit test. Verified by the app build.

- [ ] **Step 1: Replace the file**

Replace the entire contents of `Aura/Sources/Ride/SpeedRail.swift`:

```swift
import SwiftUI
import AuraCore
import AuraKit

struct SpeedRail: View {
    enum Layout { case full, speedOnly }

    let stats: RideStats
    let elapsed: TimeInterval
    let units: DistanceUnits
    /// Navigate mode passes `.speedOnly`; free ride keeps the default `.full`.
    var layout: Layout = .full

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        VStack(alignment: .trailing, spacing: AuraTheme.Spacing.xs) {
            // Hero speed + lime unit — Saira Condensed via SpeedReadout. Grouped so it
            // reads as one VoiceOver element ("24, km/h") instead of two stops.
            SpeedReadout(value: fmt.speedValue(stats.averageSpeedMetersPerSecond),
                         unit: fmt.speedUnit.uppercased())
                .accessibilityElement(children: .combine)
            if layout == .full {
                HStack(spacing: AuraTheme.Spacing.md) {
                    metric(fmt.distanceValue(stats.distanceMeters), fmt.distanceUnit.uppercased())
                    metric(RideStatsFormatter.clock(elapsed), "TIME")
                    metric(fmt.elevationValue(stats.elevationGainMeters), "\(fmt.elevationUnit.uppercased()) ↑")
                }.padding(.top, AuraTheme.Spacing.xs)
            }
        }
        .padding(AuraTheme.Spacing.lg)
        .background(AuraTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg))
        // The HUD is a compact glance target; let it enlarge meaningfully but not so
        // far it swamps the map. Standard sizes scale freely; cap the accessibility tail.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .cockpit)
            .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (`RideHUDView`'s `SpeedRail(...)` call still compiles on the default `.full`).

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/SpeedRail.swift
git commit -m "feat(app): add speed-only SpeedRail layout for navigate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `TripStripView`

**Files:**
- Create: `Aura/Sources/Ride/TripStripView.swift`

**Interfaces:**
- Consumes: `CruisingState` (T2), `AuraTheme`.
- Produces: `TripStripView(state: CruisingState)`. Full-width row; street name (SF Pro, truncates) leading, distance and ETA (Saira numerals) trailing; "Starting…" when the state is `.starting`; Reduce Transparency falls back to a solid surface.

App-target file create (runs `xcodegen generate`). No unit test; verified by the app build and a `#Preview`, then the simulator pass in Task 8.

- [ ] **Step 1: Create the view**

Create `Aura/Sources/Ride/TripStripView.swift`:

```swift
import SwiftUI
import AuraKit

/// The cruising-state trip strip pinned to the bottom of the navigate HUD: the road the
/// rider is on, the distance left, and the arrival ETA. Driven by a pure `CruisingState`
/// so it previews and reads without any guidance engine.
struct TripStripView: View {
    let state: CruisingState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStarting: Bool { state == .starting }

    var body: some View {
        content
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.vertical, AuraTheme.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(background)
            .animation(reduceMotion ? nil : .snappy, value: state)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder private var content: some View {
        if isStarting {
            Text("Starting…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.textPrimary)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: AuraTheme.Spacing.md) {
                if let street = state.streetName {
                    Text(street)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                Spacer(minLength: AuraTheme.Spacing.sm)
                metric(state.distanceRemaining ?? "–")
                metric(state.eta ?? "–")
            }
        }
    }

    private func metric(_ text: String) -> some View {
        Text(text)
            .font(AuraTheme.Typography.metricCockpit(20, relativeTo: .title3))
            .foregroundStyle(AuraTheme.textPrimary)
            .contentTransition(.numericText())
            .lineLimit(1)
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            AuraTheme.surface
        } else {
            AuraTheme.surface.opacity(0.55).background(.ultraThinMaterial)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        TripStripView(state: .init(streetName: "Penn Ave", distanceRemaining: "2.1 mi", eta: "4:38 PM"))
        TripStripView(state: .init(streetName: "Boulevard of the Allies and then some more",
                                   distanceRemaining: "12.4 mi", eta: "5:02 PM"))
        TripStripView(state: .init(streetName: nil, distanceRemaining: "0.3 mi", eta: "4:51 PM"))
        TripStripView(state: .starting)
    }
    .padding()
    .background(AuraTheme.background)
}
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED (the new file is in the app target's `Sources` glob after `xcodegen generate`).

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/TripStripView.swift
git commit -m "feat(app): add TripStripView for the cruising trip strip

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `ControlCluster`

**Files:**
- Create: `Aura/Sources/Ride/ControlCluster.swift`

**Interfaces:**
- Consumes: `HUDControlButton` with `.hudControl(active:)` and `.hudControl(role:)` (T4), `AuraTheme`.
- Produces: `ControlCluster(isFollowing: Bool, isMuted: Bool, onRecenter: () -> Void, onToggleMute: () -> Void, onEndRide: () -> Void)`. A bottom-leading vertical stack of three circular buttons: recenter (lime when not following), mute (lime when muted, symbol-replace glyph), end-ride (pink). Each carries an accessibility label and value. The end-ride confirmation is owned by the caller, not the cluster.

App-target file create (runs `xcodegen generate`). No unit test; verified by the app build and a `#Preview`, then the simulator pass in Task 8.

- [ ] **Step 1: Create the view**

Create `Aura/Sources/Ride/ControlCluster.swift`:

```swift
import SwiftUI

/// The navigate HUD's persistent control cluster: recenter, mute, and end-ride, all on
/// `HUDControlButton`. Recenter lights when the map has been panned off the puck; mute
/// lights when muted; end-ride is pink. The caller owns the end-ride confirmation, so
/// this view stays a dumb control surface.
struct ControlCluster: View {
    let isFollowing: Bool
    let isMuted: Bool
    var onRecenter: () -> Void
    var onToggleMute: () -> Void
    var onEndRide: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.md) {
            Button(action: onRecenter) {
                Image(systemName: "location.fill")
            }
            .buttonStyle(.hudControl(active: !isFollowing))
            .accessibilityLabel("Recenter map")
            .accessibilityValue(isFollowing ? "Following" : "Off")

            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.hudControl(active: isMuted))
            .accessibilityLabel("Mute voice guidance")
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(isMuted ? "On" : "Off")

            Button(action: onEndRide) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.hudControl(role: .destructive))
            .accessibilityLabel("End ride")
        }
    }
}

#Preview {
    HStack(spacing: 40) {
        ControlCluster(isFollowing: true, isMuted: false,
                       onRecenter: {}, onToggleMute: {}, onEndRide: {})
        ControlCluster(isFollowing: false, isMuted: true,
                       onRecenter: {}, onToggleMute: {}, onEndRide: {})
    }
    .padding()
    .background(AuraTheme.background)
}
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/ControlCluster.swift
git commit -m "feat(app): add ControlCluster (recenter, mute, end-ride)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Wire the cockpit into `NavigateHUDView`

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (the `body`, lines 59-154; remove `endRideButton` lines 181-191 and `muteButton` lines 193-210; add helpers)

**Interfaces:**
- Consumes: `TripStripView` (T6), `ControlCluster` (T7), `SpeedRail(layout: .speedOnly)` (T5), `CruisingPresenter.state(for:units:now:)` (T2), `viewport.followPuck` (MapboxMaps), `withViewportAnimation` (MapboxMaps).
- Produces: the integrated cockpit. No new public interface.

App-target change. Verified by the app build and the simulator accessibility-tree pass.

- [ ] **Step 1: Add state for the end-ride confirmation**

In the "Voice" MARK section, next to `@State private var isMuted = false` (line 42), add:

```swift
    @State private var showEndConfirm = false
```

- [ ] **Step 2: Replace `body` with the cockpit layout**

Replace `var body: some View { ... }` (lines 59-154) with:

```swift
    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottom) {
            // Full-bleed map
            navigateMapView
                .ignoresSafeArea()

            // Bottom cockpit: controls + speed on one row, trip strip beneath them.
            VStack(spacing: AuraTheme.Spacing.sm) {
                HStack(alignment: .bottom) {
                    ControlCluster(
                        isFollowing: viewport.followPuck != nil,
                        isMuted: isMuted,
                        onRecenter: { recenter() },
                        onToggleMute: { toggleMute() },
                        onEndRide: { showEndConfirm = true })
                    Spacer()
                    SpeedRail(stats: coordinator.stats, elapsed: coordinator.elapsed,
                             units: settings.units, layout: .speedOnly)
                }
                .padding(.horizontal, AuraTheme.Spacing.lg)

                TripStripView(state: cruisingState)
            }
            .padding(.bottom, AuraTheme.Spacing.sm)
        }
        // Turn card pinned below the status bar
        .overlay(alignment: .top) {
            TurnCardView(state: guidance.turn, reduceMotion: reduceMotion)
                .padding(.top, 8) // sits in the safe area; no hardcoded status-bar inset
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
                           value: guidance.turn)
        }
        // GPS signal chip — top leading
        .overlay(alignment: .topLeading) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.leading, 16)
        }
        // Rerouting cue — centered below the turn card
        .overlay(alignment: .top) {
            if guidance.isRerouting {
                Label("Rerouting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textPrimary)
                    .padding(.horizontal, AuraTheme.Spacing.md)
                    .padding(.vertical, AuraTheme.Spacing.sm)
                    .background(AuraTheme.surface.opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(AuraTheme.border))
                    .padding(.top, 96)
                    .transition(.opacity)
                    .accessibilityLabel("Rerouting")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: guidance.isRerouting)
        .background(AuraTheme.background)
        // End-ride confirmation: the cluster's End button opens this.
        .confirmationDialog("End ride?", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("End ride", role: .destructive) { endRide() }
            Button("Keep riding", role: .cancel) { }
        }
        // Summary sheet: when dismissed, return to the home dashboard.
        .sheet(item: $coordinator.finishedRide, onDismiss: {
            router.popToRoot()
        }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: RideSettingsLink.open)
        }
        // Keep the coordinator's Live Activity turn current as guidance progresses.
        .onChange(of: guidance.lastUpdate) { _, update in
            coordinator.maneuver = update
        }
        // Start recording + guidance on appear. The voice/audio front matter stays ahead
        // of coordinator.start so its ordering is unchanged.
        .task {
            isMuted = !settings.voiceEnabled
            configureAudioSession()
            guidance.onSpeak = { speakInstruction($0) }
            guidance.onArrive = { endRide() }

            let outcome = coordinator.start(
                location: location, saving: rideStore, units: settings.units,
                authorization: location.authorization)
            guard outcome == .started else {
                showPermission = true
                return
            }
            guidance.start(route: route)
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onDisappear {
            router.isRideActive = false
            teardownGuidance()
            coordinator.cancel()
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled(false)
    }

    /// The formatted trip strip line, recomputed each render from the latest guidance
    /// update and the current time. nil update (pre-guidance) reads as `.starting`.
    private var cruisingState: CruisingState {
        guard let update = guidance.lastUpdate else { return .starting }
        return CruisingPresenter.state(for: update, units: settings.units, now: Date())
    }
```

- [ ] **Step 3: Replace `endRideButton` and `muteButton` with the cluster helpers**

Delete the `endRideButton` computed property (the `// MARK: End-ride button` block, lines 181-191) and the `muteButton` computed property (the `// MARK: Mute button` block, lines 193-210). In their place add:

```swift
    // MARK: Cluster actions

    /// Re-engages puck-following after the rider has panned the map. Snaps under Reduce
    /// Motion, flies otherwise.
    private func recenter() {
        if reduceMotion {
            viewport = .followPuck(zoom: 16, bearing: .heading)
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = .followPuck(zoom: 16, bearing: .heading)
            }
        }
    }

    /// Toggles voice mute; muting also cuts off any in-flight prompt.
    private func toggleMute() {
        isMuted.toggle()
        if isMuted {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }
```

Leave `endRide()`, `teardownGuidance()`, `configureAudioSession()`, and `speakInstruction(_:)` unchanged.

- [ ] **Step 4: Build the app to verify it compiles**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: BUILD SUCCEEDED. If `viewport.followPuck` does not resolve, confirm the property name against the MapboxMaps `Viewport` type in the SDK checkout and adjust; the fallback is `isFollowing: true` constant (recenter still works, it just never lights). The `withViewportAnimation(.easeOut(duration: 0.4)) { ... }` trailing closure binds to the function's `body:` parameter (its `completion:` parameter is optional with a default), which is intentional and correct; do not rewrite it to a labeled `body:` argument. If `AuraCore/Package.resolved` was dirtied, run `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 5: Verify on the simulator (accessibility tree first)**

Install the build you just produced (newest mtime, or the path the builder reports), launch on the iPhone 17 / iOS 26 simulator, and start a navigated ride (use the simulated location provider / a scripted route). Confirm via `axe describe-ui` / `ui_describe_all`:
- The trip strip shows a street name, a distance remaining, and an ETA, and they update as the ride progresses.
- The control cluster reads recenter, mute ("Mute voice guidance", toggle), and end-ride ("End ride") bottom-leading; the speed hero is bottom-trailing.
- Panning the map lights recenter (its accessibility value flips to "Off"); tapping recenter re-centers (value back to "Following").
- Tapping end-ride shows the "End ride?" confirmation; "Keep riding" dismisses it, "End ride" goes to the summary; dismissing the summary returns to the home dashboard.
- With Reduce Transparency on, the strip stays legible; at an accessibility Dynamic Type size the cluster and strip lay out without clipping.

If a pixel capture is needed and its md5 matches the prior frame, reboot the simulator before trusting it.

- [ ] **Step 6: Run SwiftLint over the whole repo**

Run: `scripts/lint.sh` (or `swiftlint lint --strict` from the repo root, version 0.64.1).
Expected: 0 violations across all files (CI lints everything, not just changed files).

- [ ] **Step 7: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(app): build the navigate cockpit (trip strip + control cluster)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Mark the cockpit sub-project shipped in the ROADMAP

**Files:**
- Modify: `docs/ROADMAP.md` (the "Wave 2" section, lines 258-268; the cockpit audit finding, lines 127-133; the accessibility finding, lines 153-161)

**Interfaces:** none (docs).

- [ ] **Step 1: Update the Wave 2 section**

In `docs/ROADMAP.md`, under "### Wave 2 — The cockpit the spec promised", mark the first two items shipped and note the sub-project, matching how Wave 1 items were marked. Add a short shipped paragraph for the navigate-HUD cockpit naming what landed (the three `GuidanceUpdate` fields, `CruisingPresenter`, `TripStripView`, `ControlCluster`, the `HUDControlButton` destructive role, the speed-only `SpeedRail`), keep VoiceOver (item 3) and the summary/contrast (item 4) as the remaining sub-projects, and run the wording through the humanizer lens (no em dashes, no AI-tell vocabulary). Update the "The cockpit does not yet match the HUD spec" audit finding with a "Resolved in Wave 2" note for the parts this sub-project closed (ETA, street name, recenter, the control cluster), leaving the safety-state wording accurate.

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark the Wave 2 navigate-HUD cockpit shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage:**
- Seam (three `GuidanceUpdate` fields, Mapbox decode): T1, T3.
- Pure formatting in AuraKit (`CruisingPresenter`, ETA via injected clock): T2.
- Trip strip (street, distance remaining, ETA, placeholder, Reduce Transparency, Dynamic Type cap): T6.
- Control cluster (recenter, mute, end-ride, destructive role, accessibility labels): T4, T7.
- Recenter behavior (`viewport.followPuck != nil`, re-engage, Reduce Motion): T8.
- Speed-only `SpeedRail`: T5.
- End-ride confirmation: T8.
- Edge states preserved (GPS chip, rerouting cue, permission gate, guidance-unavailable placeholder): T8 (kept in the rewired body).
- Motion (press scale, symbol replace, numericText, snappy with Reduce Motion): T4, T6, T7, T8.
- Testing (package unit tests + simulator a11y pass): T1, T2, T8.
- ROADMAP: T9.

**Placeholder scan:** every code step has complete code; no "TBD", no "add error handling", no "similar to Task N". The two app-target verification fallbacks (the ETA exact-string note in T2, the `viewport.followPuck` fallback in T8) name the concrete adjustment rather than leaving it open.

**Type consistency:** `CruisingState` fields (`streetName`, `distanceRemaining`, `eta`) and `CruisingPresenter.state(for:units:now:calendar:)` are used identically in T2, T6, and T8. `HUDControlButton.Role` / `.hudControl(role:)` defined in T4 are used in T7. `SpeedRail.Layout.speedOnly` defined in T5 is used in T8. `GuidanceUpdate`'s three new fields defined in T1 are set in T3 and read in T2.

## Execution handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-26-aura-wave-2-cockpit.md`.**

Execution options:
1. **Subagent-Driven (recommended):** a fresh subagent per task, a spec-compliance review and a code-quality review per task, fix-and-re-review loops, build/lint/sim kept green throughout, and a final holistic review.
2. **Inline Execution:** tasks run in this session with checkpoints.

The brief calls for subagent-driven.
