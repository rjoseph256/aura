# Explore Cockpit Reinvention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Explore (free-ride) in-ride cockpit up to the navigate cockpit bar — a quarter-screen speed-dominant instrument panel, a recenter+end control cluster, and auto-start with an always-visible discard/end back-out — by extracting a shared instrument chassis.

**Architecture:** Extract the navigate `InstrumentPanel`'s speed-hero-plus-panel skeleton into a shared `InstrumentChassis` that takes a caller-supplied secondary-instrument column. Navigate refills the column with to-go/ETA; a new `ExploreInstrumentPanel` fills it with distance/time/climb, driven by a pure `ExploreInstrumentState`. `RideHUDView` is rebuilt to auto-start, own the map viewport (so it can recenter), show the panel + `ControlCluster`, and gate back-out on a pure `RideBackOutGate`. Discard is made a full teardown by having `RideSessionCoordinator.cancel()` end the Live Activity.

**Tech Stack:** Swift 6, SwiftUI, MapboxMaps (viewport), Swift Testing (package tests), XcodeGen (project generation), SwiftLint.

## Global Constraints

- Swift 6 language mode across all compiled targets.
- SwiftLint runs `--strict`; the whole repo must pass.
- The SwiftPM package (`AuraCore`, with the `AuraCore` and `AuraKit` modules) must not import UIKit, MapboxMaps, ActivityKit, or HealthKit — it builds on the macOS CI host. App-target-only code (views, Mapbox, ActivityKit) stays under `Aura/Sources`.
- Accent is mint `#7CF0A8` via `AuraTheme.accent`; destructive is pink via the `.destructive` HUD role. No new hardcoded colors.
- Cockpit numerals use Saira Condensed via `AuraTheme.Typography.metricCockpit(_:relativeTo:)` / `speedHero(_:relativeTo:)`; chrome uses SF Pro Rounded. No new fonts.
- The Xcode project is XcodeGen-generated and gitignored. **Regenerate it (`xcodegen generate` from `Aura/`, or the project's generate step) whenever a task adds or deletes a `.swift` file before building.**
- App-target views have no unit-test bundle: their verification is a clean `xcodebuild` (delegate to the builder agent) plus `swiftlint --strict`, and — for the final cockpit — a simulator/device accessibility-tree check. Only the pure `AuraCore`/`AuraKit` code is unit-tested.
- Spec: `docs/superpowers/specs/2026-07-03-explore-cockpit-reinvention-design.md`.

---

### Task 1: `ExploreInstrumentState` (pure Explore instrument values)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Formatting/ExploreInstrumentState.swift`
- Test: `AuraCore/Tests/AuraKitTests/ExploreInstrumentStateTests.swift`

**Interfaces:**
- Consumes: `AuraCore.RideStats` (`.distanceMeters`, `.elevationGainMeters`, `.zero`), `AuraCore.DistanceUnits`, `AuraKit.RideStatsFormatter`, `AuraKit.SpeedRailVoice.statsLabel(_:elapsed:units:)`.
- Produces: `struct ExploreInstrumentState { let distance: String; let time: String; let elevationGain: String; let accessibilityLabel: String; init(stats: RideStats, elapsed: TimeInterval, units: DistanceUnits) }`

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/ExploreInstrumentStateTests.swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ExploreInstrumentStateTests {
    private func stats(distance: Double, elevation: Double) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: 0,
                  averageSpeedMetersPerSecond: 0, maxSpeedMetersPerSecond: 0,
                  elevationGainMeters: elevation)
    }

    @Test func imperialValues() {
        let s = ExploreInstrumentState(stats: stats(distance: 8046.72, elevation: 103.6),
                                       elapsed: 1440, units: .imperial)
        #expect(s.distance == "5.0 mi")
        #expect(s.time == "24:00")
        #expect(s.elevationGain == "340 ft")
    }

    @Test func metricValues() {
        let s = ExploreInstrumentState(stats: stats(distance: 5000, elevation: 120),
                                       elapsed: 90, units: .metric)
        #expect(s.distance == "5.0 km")
        #expect(s.time == "1:30")
        #expect(s.elevationGain == "120 m")
    }

    @Test func zeroValues() {
        let s = ExploreInstrumentState(stats: .zero, elapsed: 0, units: .imperial)
        #expect(s.distance == "0.0 mi")
        #expect(s.time == "0:00")
        #expect(s.elevationGain == "0 ft")
    }

    @Test func accessibilityLabelReusesSpeedRailVoice() {
        let st = stats(distance: 8046.72, elevation: 103.6)
        let s = ExploreInstrumentState(stats: st, elapsed: 1440, units: .imperial)
        #expect(s.accessibilityLabel == SpeedRailVoice.statsLabel(st, elapsed: 1440, units: .imperial))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter ExploreInstrumentStateTests`
Expected: FAIL — `cannot find 'ExploreInstrumentState' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// AuraCore/Sources/AuraKit/Formatting/ExploreInstrumentState.swift
import Foundation
import AuraCore

/// The formatted instruments the Explore (free-ride) cockpit renders beside the speed
/// hero: distance ridden, elapsed time, and elevation climbed, plus one composed VoiceOver
/// read. Pure and unit-aware, mirroring the `CruisingState`/`CruisingPresenter` pattern the
/// navigate cockpit uses, so the composition is unit-tested in CI instead of living in the
/// SwiftUI view. The spoken label delegates to `SpeedRailVoice.statsLabel`, so the free-ride
/// read stays identical to the rail this cockpit replaces.
public struct ExploreInstrumentState: Equatable, Sendable {
    /// Distance ridden with its short unit, e.g. "5.0 mi".
    public let distance: String
    /// Elapsed clock, e.g. "24:00".
    public let time: String
    /// Elevation climbed with its short unit, e.g. "340 ft".
    public let elevationGain: String
    /// One composed VoiceOver read for the whole instrument cluster, e.g.
    /// "Distance 5.0 miles, time 24 minutes, elevation gain 340 feet".
    public let accessibilityLabel: String

    public init(stats: RideStats, elapsed: TimeInterval, units: DistanceUnits) {
        let fmt = RideStatsFormatter(units: units)
        self.distance = "\(fmt.distanceValue(stats.distanceMeters)) \(fmt.distanceUnit)"
        self.time = RideStatsFormatter.clock(elapsed)
        self.elevationGain = "\(fmt.elevationValue(stats.elevationGainMeters)) \(fmt.elevationUnit)"
        self.accessibilityLabel = SpeedRailVoice.statsLabel(stats, elapsed: elapsed, units: units)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter ExploreInstrumentStateTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Formatting/ExploreInstrumentState.swift AuraCore/Tests/AuraKitTests/ExploreInstrumentStateTests.swift
git commit -m "feat(explore): pure ExploreInstrumentState for free-ride instruments"
```

---

### Task 2: `RideBackOutGate` (pure discard-floor predicate)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/RideBackOutGate.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideBackOutGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum RideBackOutGate { static let discardFloorMeters: Double; static func canDiscard(distanceMeters: Double) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraCoreTests/RideBackOutGateTests.swift
import Testing
@testable import AuraCore

struct RideBackOutGateTests {
    @Test func belowFloorCanDiscard() {
        #expect(RideBackOutGate.canDiscard(distanceMeters: 0) == true)
        #expect(RideBackOutGate.canDiscard(distanceMeters: 24) == true)
    }
    @Test func atFloorCannotDiscard() {
        #expect(RideBackOutGate.canDiscard(distanceMeters: 25) == false)
    }
    @Test func aboveFloorCannotDiscard() {
        #expect(RideBackOutGate.canDiscard(distanceMeters: 26) == false)
        #expect(RideBackOutGate.canDiscard(distanceMeters: 5000) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideBackOutGateTests`
Expected: FAIL — `cannot find 'RideBackOutGate' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// AuraCore/Sources/AuraCore/Models/RideBackOutGate.swift
import Foundation

/// Decides whether an in-progress free ride is still short enough to discard silently
/// (back out with no summary) versus long enough that leaving must go through the end-ride
/// confirmation. One constant in one place so the floor is unit-tested and tunable, never a
/// magic number in the view.
public enum RideBackOutGate {
    /// Below this ridden distance, a ride is a mis-tap: backing out discards it with no
    /// summary. ~25 m is a short block, comfortably above the 10 m HealthKit save floor, so
    /// a discardable ride is never one that would have been saved.
    public static let discardFloorMeters: Double = 25

    /// True while the ride can be discarded silently.
    public static func canDiscard(distanceMeters: Double) -> Bool {
        distanceMeters < discardFloorMeters
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RideBackOutGateTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models/RideBackOutGate.swift AuraCore/Tests/AuraCoreTests/RideBackOutGateTests.swift
git commit -m "feat(explore): pure RideBackOutGate discard-floor predicate"
```

---

### Task 3: Extract `InstrumentChassis` + shared `CockpitInstrument`

Extract the speed hero, opaque panel, layout, and Dynamic Type cap from `InstrumentPanel` into a reusable chassis, plus a shared secondary-instrument view. Nothing consumes them yet (Task 4 wires navigate; Task 5 wires Explore), so the app just needs to keep building.

**Files:**
- Create: `Aura/Sources/Ride/InstrumentChassis.swift`

**Interfaces:**
- Consumes: `AuraKit.RideStatsFormatter`, `AuraKit.SpeedRailVoice` (indirect), `AuraTheme`.
- Produces:
  - `struct InstrumentChassis<Column: View>: View` with `init(currentSpeedMetersPerSecond: Double, units: DistanceUnits, topLine: String?, columnAccessibilityLabel: String, @ViewBuilder column: () -> Column)`.
  - `struct CockpitInstrument: View { init(value: String, label: String) }`.

- [ ] **Step 1: Create the chassis and shared instrument (copied verbatim from the current `InstrumentPanel` skeleton, then generalized)**

```swift
// Aura/Sources/Ride/InstrumentChassis.swift
import SwiftUI
import AuraCore
import AuraKit

/// The shared cockpit instrument chassis: a hero SPEED readout beside a caller-supplied
/// column of secondary instruments, on the opaque quarter-screen panel. Navigate fills the
/// column with to-go + ETA; Explore fills it with distance + time + climb. The chassis owns
/// the optional top line (navigate's street name) and applies ONE composed VoiceOver label
/// across the secondary column, so it reads as a single utterance (the top line's own Text
/// is hidden and folded into that label). Speed stays its own composed element.
struct InstrumentChassis<Column: View>: View {
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    /// Optional context line above the instruments (navigate: current street; Explore: nil).
    let topLine: String?
    /// The composed VoiceOver read for the whole secondary cluster (includes the top line).
    let columnAccessibilityLabel: String
    @ViewBuilder let column: Column

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            if let topLine {
                Text(topLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true) // folded into the column's composed read
            }

            // Speed hero + secondary column sit together as one centered cluster with a
            // fixed gap, so the panel's slack falls to the outer margins.
            HStack(alignment: .center, spacing: AuraTheme.Spacing.xxl) {
                speedInstrument
                column
                    // One composed VoiceOver read for the whole secondary cluster, so the
                    // instruments read once, not as several mechanical stops.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(columnAccessibilityLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, AuraTheme.Spacing.xl)
        .padding(.top, AuraTheme.Spacing.lg)
        .padding(.bottom, AuraTheme.Spacing.xl) // clear the home indicator
        .background(panelBackground)
        // A cockpit glance target: let it enlarge but cap the accessibility tail so the hero
        // speed can't swamp the whole panel.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // Hero speed: the panel's dominant element. Realistic cycling speeds are 1–2 digits, so
    // the value can run large without overflow; `minimumScaleFactor` guards the edge case.
    private var speedInstrument: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.sm) {
            Text(fmt.speedValue(currentSpeedMetersPerSecond))
                .font(AuraTheme.Typography.speedHero(150, relativeTo: .largeTitle))
                .foregroundStyle(AuraTheme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(fmt.speedUnit.uppercased())
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(AuraTheme.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue(SpeedRailVoice.speedValue(currentSpeedMetersPerSecond, units: units))
    }

    // Opaque surface with rounded top corners + a hairline, bleeding to the bottom edge.
    // Legibility beats atmosphere in the cockpit, so the panel stays solid.
    private var panelBackground: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: AuraTheme.Radius.xl,
            topTrailingRadius: AuraTheme.Radius.xl,
            style: .continuous)
        return shape
            .fill(AuraTheme.surface)
            .overlay(shape.stroke(AuraTheme.hairline(contrast), lineWidth: 1))
            .ignoresSafeArea(edges: .bottom)
    }
}

/// One secondary cockpit instrument: a large Saira value over a small caption label. Shared
/// by the navigate (to-go / ETA) and Explore (distance / time / climb) panel columns.
struct CockpitInstrument: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(AuraTheme.Typography.metricCockpit(34, relativeTo: .title2))
                .foregroundStyle(AuraTheme.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
```

- [ ] **Step 2: Regenerate the project and build**

Regenerate the XcodeGen project (a `.swift` file was added), then delegate to the builder agent: build the `Aura` scheme for an iOS simulator.
Expected: BUILD SUCCEEDED (the new types are unused for now — acceptable).

- [ ] **Step 3: Lint**

Run: `swiftlint --strict` (repo root)
Expected: no violations.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/InstrumentChassis.swift
git commit -m "refactor(cockpit): extract shared InstrumentChassis + CockpitInstrument"
```

---

### Task 4: Make navigate `InstrumentPanel` a thin caller of the chassis

Rewrite `InstrumentPanel` to render through `InstrumentChassis` with a to-go/ETA column. It renders the same pixels and reads as one composed VoiceOver element, as today — note the composed label moves from the TO-GO instrument to the column container, an equivalent single-element read, confirmed on device in Task 9.

**Files:**
- Modify: `Aura/Sources/Ride/InstrumentPanel.swift`

**Interfaces:**
- Consumes: `InstrumentChassis`, `CockpitInstrument` (Task 3), `AuraKit.CruisingState`.
- Produces: `InstrumentPanel(currentSpeedMetersPerSecond:units:trip:)` — unchanged public shape.

- [ ] **Step 1: Replace the file body**

```swift
// Aura/Sources/Ride/InstrumentPanel.swift
import SwiftUI
import AuraCore
import AuraKit

/// The navigate cockpit's instrument panel: a hero SPEED readout beside the distance still
/// to go and the arrival ETA, on the shared `InstrumentChassis`. Driven by the live current
/// speed and the pure `CruisingState`, so it previews without any guidance engine.
struct InstrumentPanel: View {
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    let trip: CruisingState

    var body: some View {
        InstrumentChassis(
            currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            units: units,
            topLine: trip.streetName,
            columnAccessibilityLabel: trip.accessibilityLabel) {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                CockpitInstrument(value: trip.distanceRemaining ?? "–", label: "TO GO")
                CockpitInstrument(value: trip.eta ?? "–", label: "ARRIVE")
            }
        }
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        InstrumentPanel(
            currentSpeedMetersPerSecond: 8.1, // ~18 mph
            units: .imperial,
            trip: .init(streetName: "Stedman Street", distanceRemaining: "7.2 mi",
                        eta: "11:32 PM",
                        accessibilityLabel: "On Stedman Street, 7.2 miles to go, arriving 11:32 PM"))
            .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
    }
}
```

- [ ] **Step 2: Build**

Delegate to the builder agent: build the `Aura` scheme for an iOS simulator (no files added/removed → no XcodeGen regen needed).
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Lint**

Run: `swiftlint --strict`
Expected: no violations.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/InstrumentPanel.swift
git commit -m "refactor(cockpit): InstrumentPanel renders through InstrumentChassis"
```

> Navigate regression (identical pixels + one-breath VoiceOver read) is confirmed in the final device/sim verification task; the `CruisingPresenter`/`CruisingState` suites are unaffected by this view change and stay green.

---

### Task 5: `ExploreInstrumentPanel`

**Files:**
- Create: `Aura/Sources/Ride/ExploreInstrumentPanel.swift`

**Interfaces:**
- Consumes: `InstrumentChassis`, `CockpitInstrument` (Task 3), `AuraKit.ExploreInstrumentState` (Task 1).
- Produces: `ExploreInstrumentPanel(currentSpeedMetersPerSecond:units:state:)`.

- [ ] **Step 1: Create the panel**

```swift
// Aura/Sources/Ride/ExploreInstrumentPanel.swift
import SwiftUI
import AuraCore
import AuraKit

/// The Explore (free-ride) cockpit's instrument panel: a hero SPEED readout beside distance
/// ridden, elapsed time, and elevation climbed, on the shared `InstrumentChassis`. Driven by
/// the live current speed and the pure `ExploreInstrumentState` — no destination, no ETA, no
/// street — so it previews without a running ride.
struct ExploreInstrumentPanel: View {
    /// Smoothed live current speed (m/s) — the hero reads this, not the ride average.
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    let state: ExploreInstrumentState

    var body: some View {
        InstrumentChassis(
            currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            units: units,
            topLine: nil,
            columnAccessibilityLabel: state.accessibilityLabel) {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                CockpitInstrument(value: state.distance, label: "DISTANCE")
                CockpitInstrument(value: state.time, label: "TIME")
                CockpitInstrument(value: state.elevationGain, label: "CLIMB")
            }
        }
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        AuraTheme.background.ignoresSafeArea()
        ExploreInstrumentPanel(
            currentSpeedMetersPerSecond: 8.1,
            units: .imperial,
            state: ExploreInstrumentState(
                stats: RideStats(distanceMeters: 8046.72, movingTimeSeconds: 1440,
                                 averageSpeedMetersPerSecond: 5.6, maxSpeedMetersPerSecond: 9,
                                 elevationGainMeters: 103.6),
                elapsed: 1440, units: .imperial))
            .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
    }
}
```

- [ ] **Step 2: Regenerate the project and build**

Regenerate the XcodeGen project (a `.swift` file was added), then delegate to the builder agent: build the `Aura` scheme for an iOS simulator.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Lint**

Run: `swiftlint --strict`
Expected: no violations.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/ExploreInstrumentPanel.swift
git commit -m "feat(explore): ExploreInstrumentPanel on the shared chassis"
```

---

### Task 6: `ControlCluster` — optional mute

Make the mute button optional so Explore can drop it. Navigate's call site is unchanged (it still passes both mute args).

**Files:**
- Modify: `Aura/Sources/Ride/ControlCluster.swift`

**Interfaces:**
- Consumes: `AuraTheme`, `.hudControl` button styles.
- Produces: `ControlCluster(isFollowing: Bool, isMuted: Bool = false, onRecenter: () -> Void, onToggleMute: (() -> Void)? = nil, onEndRide: () -> Void)` — mute button rendered only when `onToggleMute != nil`.

- [ ] **Step 1: Replace the file body**

```swift
// Aura/Sources/Ride/ControlCluster.swift
import SwiftUI

/// The ride HUD's persistent control cluster: recenter, an optional mute, and end-ride, all
/// on `HUDControlButton`. Recenter lights when the map is panned off the puck; mute lights
/// when muted; end-ride is pink. Mute is omitted (pass `onToggleMute: nil`) on a free ride,
/// which has no turn-by-turn voice to mute. The caller owns the end-ride confirmation, so
/// this stays a dumb control surface.
struct ControlCluster: View {
    let isFollowing: Bool
    var isMuted: Bool = false
    var onRecenter: () -> Void
    /// When nil, the mute button is omitted.
    var onToggleMute: (() -> Void)?
    var onEndRide: () -> Void

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.md) {
            Button(action: onRecenter) {
                Image(systemName: "location.fill")
            }
            .buttonStyle(.hudControl(active: !isFollowing))
            .accessibilityLabel("Recenter map")
            .accessibilityValue(isFollowing ? "Following" : "Off")

            if let onToggleMute {
                Button(action: onToggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.hudControl(active: isMuted))
                .accessibilityLabel("Mute voice guidance")
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(isMuted ? "On" : "Off")
            }

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
        // Navigate: with mute.
        ControlCluster(isFollowing: true, isMuted: false,
                       onRecenter: {}, onToggleMute: {}, onEndRide: {})
        // Explore: no mute.
        ControlCluster(isFollowing: false, onRecenter: {}, onEndRide: {})
    }
    .padding()
    .background(AuraTheme.background)
}
```

- [ ] **Step 2: Build**

Delegate to the builder agent: build the `Aura` scheme (NavigateHUDView's call site still compiles — it passes `isMuted:` and `onToggleMute:`).
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Lint**

Run: `swiftlint --strict`
Expected: no violations.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/ControlCluster.swift
git commit -m "refactor(cockpit): ControlCluster mute is optional (free ride drops it)"
```

---

### Task 7: `RideSessionCoordinator.cancel()` ends the Live Activity

Discard must fully tear down. Auto-start fires `activity.start()`, so a back-out that calls `cancel()` must also end the activity or it orphans a ticking Lock Screen activity.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:147-153`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `RideActivityControlling.end()` (already in the seam; `RideLiveActivityController.end()` is idempotent).
- Produces: `cancel()` now also calls `activity.end()`.

- [ ] **Step 1: Write the failing test (add to `RideSessionCoordinatorTests`)**

```swift
    @Test func cancelEndsActivityAndReleasesScreen() throws {
        let screen = SpyScreenWake(); let activity = SpyRideActivity()
        let c = makeCoordinator(screen: screen, activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        #expect(activity.ended == false)
        c.cancel()
        #expect(activity.ended == true)
        #expect(screen.keepAwakeCalls == [true, false])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests/cancelEndsActivityAndReleasesScreen`
Expected: FAIL — `#expect(activity.ended == true)` is false (cancel does not yet end the activity).

- [ ] **Step 3: Update `cancel()`**

Replace the current `cancel()` (and its doc comment) at `RideSessionCoordinator.swift:147-153` with:

```swift
    /// Teardown for an abandoned (not finished) ride, called from `onDisappear` and from the
    /// free-ride back-out discard. Stops streaming, releases the screen, and ends the Live
    /// Activity — so an auto-started ride discarded before it is worth saving leaves no
    /// orphaned Lock Screen activity. Does not save or publish a ride. `activity.end()` is
    /// idempotent, so calling this after `finish()` (e.g. onDisappear after End) is a no-op.
    public func cancel() {
        stopStreaming()
        screen.setKeepAwake(false)
        activity.end()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: PASS (all coordinator tests, including the new one; the existing tests that call `cancel()` do not assert `ended == false`, so they are unaffected).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift
git commit -m "fix(ride): cancel() ends the Live Activity so a discarded ride doesn't orphan it"
```

---

### Task 8: Rebuild `RideHUDView` (auto-start, cockpit, recenter, back-out) + `RideMapView` viewport binding

The core integration. `RideMapView` gains a `@Binding` viewport (so the HUD can recenter); `RideHUDView` is its only production caller, so both change together to keep the build green. `RideHUDView` is rebuilt: auto-start in `.task`, the `ExploreInstrumentPanel` + `ControlCluster` cockpit, an always-visible discard/end back button, and matched `swipeBackEnabled`.

> **Depends on Task 7:** discard relies on `cancel()` ending the Live Activity. `.task` auto-start is safe against re-fire (e.g. after the permission sheet dismisses) because `coordinator.start()` is a no-op while already recording; the discard + `onDisappear` double-`cancel()` is safe because `activity.end()` and `stopStreaming()` are idempotent.

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift` (viewport binding + preview)
- Modify: `Aura/Sources/Ride/RideHUDView.swift` (full rebuild)

**Interfaces:**
- Consumes: `ExploreInstrumentPanel` (Task 5), `ExploreInstrumentState` (Task 1), `ControlCluster` (Task 6), `RideBackOutGate` (Task 2), `RideSessionCoordinator` (`.start`, `.cancel`, `.finish`, `.stats`, `.elapsed`, `.currentSpeedMetersPerSecond`, `.isRecording`, `.finishedRide`, `.saveFailed`), `MapboxMaps.Viewport` / `withViewportAnimation`.
- Produces: an Explore cockpit that reads `RideMapView(track:viewport:)`.

- [ ] **Step 0: Confirm `RideMapView` has no other production caller**

Run: `grep -rn "RideMapView(" Aura/Sources --include="*.swift" | grep -v "struct RideMapView"`
Expected: only `RideHUDView.swift` and the `RideMapView.swift` `#Preview`. If another production caller appears, it must also pass the new `viewport` binding — reconcile before proceeding.

- [ ] **Step 1: Add the viewport binding to `RideMapView`**

In `Aura/Sources/Ride/RideMapView.swift`, replace the stored viewport state
```swift
    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
```
with a binding:
```swift
    @Binding var viewport: Viewport
```
(The `Map(viewport: $viewport)` line and everything else stay as-is.) Then update the `#Preview` at the bottom to own the state and pass the binding:

```swift
#Preview {
    @Previewable @State var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
    let peers: [RidePeer] = [
        RidePeer(userID: UUID(), displayName: "Mara",
                coordinate: Coordinate(latitude: 37.7752, longitude: -122.4192),
                progressMeters: 900, motionState: .moving, status: .riding),
        RidePeer(userID: UUID(), displayName: "Devon",
                coordinate: Coordinate(latitude: 37.7742, longitude: -122.4182),
                progressMeters: 450, motionState: .stopped, status: .stopped),
        RidePeer(userID: UUID(), displayName: "Priya",
                coordinate: Coordinate(latitude: 37.7732, longitude: -122.4172),
                progressMeters: 200, status: .awaiting),
        RidePeer(userID: UUID(), displayName: "Sam",
                coordinate: nil, progressMeters: nil, status: .dropped)
    ]
    let track = stride(from: 0, through: 1200, by: 40).map { meters in
        TrackPoint(coordinate: Coordinate(latitude: 37.7700 + Double(meters) * 0.00003,
                                          longitude: -122.4210 + Double(meters) * 0.00002),
                  elevation: nil, timestamp: Date())
    }
    return RideMapView(track: track, peers: peers,
                       nameMap: [:], selfProgress: 550, viewport: $viewport)
        .environment(SettingsStore())
}
```

- [ ] **Step 2: Rebuild `RideHUDView`**

Replace the entire contents of `Aura/Sources/Ride/RideHUDView.swift` with the following (note the added `import MapboxMaps`, needed for `Viewport` and `withViewportAnimation`; the cockpit chrome and actions live in a `private extension` so the main type body stays under SwiftLint's `type_body_length`):

```swift
import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// The Explore (free-ride) cockpit. Auto-starts recording on appear (parity with navigate),
/// shows the quarter-screen `ExploreInstrumentPanel` + a recenter/end `ControlCluster` over
/// the terrain map, and offers an always-visible back-out: a just-started ride (below the
/// discard floor) is discarded with no summary; once it is worth a summary, back opens the
/// End confirmation. Ending routes through the coordinator's finish → summary sheet.
struct RideHUDView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var coordinator = RideSessionCoordinator(
        kind: .freeRide, destinationName: nil,
        screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
        workout: WorkoutWriter.shared)
    @State private var showPermission = false
    @State private var showEndConfirm = false
    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)

    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottom) {
            RideMapView(track: coordinator.track, viewport: $viewport)
            bottomCockpit
        }
        // Always-visible back-out: discards a just-started ride (below the floor) or opens
        // the End confirmation once the ride is long enough to be worth a summary. The label
        // announces which, so the change of meaning isn't silent.
        .overlay(alignment: .topLeading) {
            backButton
                .padding(.top, 8)
                .padding(.leading, 16)
        }
        // GPS signal chip — top-trailing so it doesn't collide with the back button.
        .overlay(alignment: .topTrailing) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.trailing, 16)
        }
        .background(AuraTheme.background)
        .alert("End ride?", isPresented: $showEndConfirm) {
            Button("End ride", role: .destructive) { coordinator.finish() }
            Button("Keep riding", role: .cancel) { }
        }
        // Returning from the summary drops to the home dashboard, mirroring NavigateHUDView.
        .sheet(item: $coordinator.finishedRide, onDismiss: { router.popToRoot() }, content: { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        })
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: RideSettingsLink.open)
        }
        // Auto-start recording on appear (parity with navigate). A denied permission surfaces
        // the explainer; the back button (at zero distance) discards cleanly.
        .task {
            let outcome = coordinator.start(
                location: location, saving: rideStore, units: settings.units,
                authorization: location.authorization, saveToHealth: settings.saveToHealth)
            if outcome == .permissionDenied { showPermission = true }
        }
        .onChange(of: coordinator.isRecording) { _, recording in
            router.isRideActive = recording
        }
        .onChange(of: coordinator.finishedRide) { _, ride in
            if ride != nil { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
        }
        .onDisappear {
            router.isRideActive = false
            coordinator.cancel()
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        // Edge-swipe mirrors the back button: a just-started ride can be swiped away
        // (discard on teardown); once it's worth a summary, the swipe is disabled so a stray
        // gesture can't drop a real ride.
        .swipeBackEnabled(canDiscard)
    }
}

/// Cockpit chrome + actions, in an extension so the main type body stays under SwiftLint's
/// `type_body_length` (the pattern the navigate cockpit used). Same-file `private` members of
/// `RideHUDView` remain reachable here.
private extension RideHUDView {
    var canDiscard: Bool {
        RideBackOutGate.canDiscard(distanceMeters: coordinator.stats.distanceMeters)
    }

    var bottomCockpit: some View {
        VStack(spacing: AuraTheme.Spacing.sm) {
            HStack {
                Spacer()
                ControlCluster(
                    isFollowing: viewport.followPuck != nil,
                    onRecenter: { recenter() },
                    onEndRide: { showEndConfirm = true })
            }
            .padding(.horizontal, AuraTheme.Spacing.lg)

            ExploreInstrumentPanel(
                currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                units: settings.units,
                state: ExploreInstrumentState(stats: coordinator.stats,
                                              elapsed: coordinator.elapsed,
                                              units: settings.units))
                .containerRelativeFrame(.vertical, count: 4, span: 1, spacing: 0)
        }
    }

    var backButton: some View {
        Button(action: backTapped) {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.hudControl)
        .accessibilityLabel(canDiscard ? "Discard ride" : "End ride")
    }

    func backTapped() {
        if canDiscard {
            coordinator.cancel()
            router.popToRoot()
        } else {
            showEndConfirm = true
        }
    }

    /// Re-engages puck-following after the rider has panned. Snaps under Reduce Motion,
    /// flies otherwise — the same behavior navigate uses.
    func recenter() {
        if reduceMotion {
            viewport = .followPuck(zoom: 16, bearing: .heading)
        } else {
            withViewportAnimation(.easeOut(duration: 0.4)) {
                viewport = .followPuck(zoom: 16, bearing: .heading)
            }
        }
    }
}
```

- [ ] **Step 3: Build**

Delegate to the builder agent: build the `Aura` scheme for an iOS simulator (no files added/removed → no XcodeGen regen needed).
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Lint**

Run: `swiftlint --strict`
Expected: no violations.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(explore): rebuild the free-ride cockpit on the shared chassis with auto-start + back-out"
```

---

### Task 9: Remove the dead `SpeedRail` + `SpeedReadout`, then full verification

`RideHUDView` was the only caller of `SpeedRail`, which was the only caller of `SpeedReadout`. Both are now dead. `SpeedRailVoice` (used by `ExploreInstrumentState`) and `StatPair` (used by the summary/share card) stay.

**Files:**
- Delete: `Aura/Sources/Ride/SpeedRail.swift`
- Delete: `Aura/Sources/Theme/SpeedReadout.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing.

- [ ] **Step 1: Confirm they're dead**

Run:
```bash
grep -rn "SpeedRail(" Aura/Sources --include="*.swift" | grep -v "struct SpeedRail"
grep -rn "SpeedReadout(" Aura/Sources --include="*.swift" | grep -v "struct SpeedReadout"
```
Expected: no output (no remaining callers). If either prints a caller, stop and reconcile before deleting.

- [ ] **Step 2: Delete and regenerate**

```bash
git rm Aura/Sources/Ride/SpeedRail.swift Aura/Sources/Theme/SpeedReadout.swift
```
Then fix the now-stale doc comment in `NavigateHUDView.swift:15` (it still reads "SpeedRail bottom-trailing with live speed and elapsed time"; navigate uses `InstrumentPanel` now) — reword it to mention the instrument panel. Then regenerate the XcodeGen project (files removed).

- [ ] **Step 3: Full build + lint + package tests**

- Delegate to the builder agent: build the `Aura` scheme for an iOS simulator. Expected: BUILD SUCCEEDED.
- Run: `swiftlint --strict`. Expected: no violations.
- Run: `cd AuraCore && swift test`. Expected: the whole package suite passes (including the two new suites from Tasks 1–2 and the updated coordinator suite from Task 7).

- [ ] **Step 4: Device/simulator verification (device-first, via the tunnel)**

Drive the app and confirm through the accessibility tree / on-device:
- **Explore cockpit:** Home → Explore auto-starts a ride; the panel shows the 150pt speed hero + DISTANCE/TIME/CLIMB; the instruments update as the ride records.
- **Recenter:** pan the map → the recenter button lights (off-puck) → tap → the map re-follows the puck.
- **Back-out below the floor:** immediately after entering, the top-leading control reads "Discard ride"; tapping it returns to Home with no summary and no lingering Lock Screen Live Activity.
- **End above the floor:** after riding past ~25 m, the control reads "End ride" and opens the "Keep riding / End ride" confirmation; ending shows the summary; dismissing returns Home.
- **Navigate regression:** start a navigate ride and confirm the InstrumentPanel is visually unchanged and its trip instruments still read as one composed VoiceOver utterance ("On …, … to go, arriving …").
- **Group navigate regression:** confirm a group navigate ride still renders peer dots (the `RideMapView` viewport-binding change did not touch navigate's own map, so this is a sanity check).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(cockpit): remove dead SpeedRail + SpeedReadout after the Explore rebuild"
```

---

## Self-Review

**1. Spec coverage:**
- Shared `InstrumentChassis` + composed-a11y ownership → Tasks 3, 4. ✓
- `ExploreInstrumentState` (AuraKit, mirrors CruisingState pattern, own tests) → Task 1. ✓
- `RideBackOutGate` (AuraCore, tested at/below/above floor) → Task 2. ✓
- Recenter plumbing (hoist viewport + RideMapView binding, mirror navigate) → Task 8. ✓
- Live Activity teardown on discard (`cancel()` ends the activity) → Task 7. ✓
- Auto-start `.task`, End moves into cluster, permission-denied path → Task 8. ✓
- Always-visible back-out (discard below floor / End-confirm above), matched `swipeBackEnabled`, label announces the change → Task 8. ✓
- `ControlCluster` optional mute → Task 6. ✓
- `finishedRide` summary sheet unchanged → Task 8 (kept verbatim). ✓
- Solo-only (RideMapView default empty peers) → Task 8 (no peers passed). ✓
- Terrain map already applied → unchanged (`RideMapView.mapStyle`); no task needed. ✓
- Remove dead `SpeedRail`/`SpeedReadout` → Task 9. ✓
- Device/sim verify incl. navigate + group regression → Task 9 Step 4. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has an expected result.

**3. Type consistency:** `InstrumentChassis(currentSpeedMetersPerSecond:units:topLine:columnAccessibilityLabel:column:)` and `CockpitInstrument(value:label:)` are defined in Task 3 and consumed with those exact labels in Tasks 4–5. `ExploreInstrumentState(stats:elapsed:units:)` is defined in Task 1 and consumed in Tasks 5, 8. `RideBackOutGate.canDiscard(distanceMeters:)` is defined in Task 2 and consumed in Task 8. `ControlCluster`'s optional `onToggleMute` (Task 6) matches the Explore call site omitting it (Task 8) and navigate's existing call (unchanged). `RideMapView(track:viewport:)` binding (Task 8 Step 1) matches its sole caller (Task 8 Step 2).
