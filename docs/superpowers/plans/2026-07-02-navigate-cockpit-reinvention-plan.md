# Navigate Cockpit Reinvention (ROH-44) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reinvent Aura's navigate cockpit — the authored terrain style live on the in-ride map, real directional maneuver arrows with a next-turn preview, a turn-forward re-layout, and an Aura motion pass.

**Architecture:** Four slices. Slice 1 (ROH-46) renders the bundled `AuraTerrainStyle.json` on the live map and ships alone. Slices 2–4 add structured maneuver data (`GuidanceUpdate.maneuver`/`nextManeuver` from the Mapbox step), a pure `ManeuverIcon` mapping, then the re-layout (`TurnCardView`/`ThenChip`/`InstrumentPanel`/`ControlRail`) and the motion/edge-state/group pass. Pure model + presenter logic lives in AuraCore/AuraKit (macOS-CI-tested with Swift Testing); MapboxMaps and SwiftUI views live in the app target (build + device-verified — the app target has no unit-test bundle).

**Tech Stack:** Swift 6.3, SwiftUI (iOS 26 target), MapboxMaps v11 + Mapbox Navigation v3, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), SwiftData/ActivityKit unchanged.

## Global Constraints

- AuraKit / AuraCore must NOT import MapboxMaps, SwiftUI, or UIKit — the package builds on the macOS CI host. `ManeuverIcon` returns a plain `String` (SF Symbol name), no UI import.
- iOS-only APIs must be `#if canImport(...)`-guarded in the package (they aren't needed here, but new code must not break the macOS package build).
- Accent is mint `#7CF0A8` via `AuraTheme.accent`; ink-on-accent `AuraTheme.onAccent`; destructive pink for end-ride. No new raw colors — use `AuraTheme` roles.
- No live blur over the moving map. Cockpit data sits on the opaque `AuraTheme.mapScrim(...)` fill. `.ultraThinMaterial` stays out of the moving cockpit.
- All motion is `@Environment(\.accessibilityReduceMotion)`-guarded; zero residual map drift while recording.
- Cockpit numerals use Saira via `AuraTheme.Typography.metricCockpit(_:relativeTo:)` / `.speedHero(_:)` — pass PLAIN base sizes (they self-scale via `relativeTo:`); brand SF sizes use `@ScaledMetric`. Never mix (double-scales).
- Builds: pin every device/simulator build to THIS worktree (`/Users/rohunjoseph/projects/biking-app/.claude/worktrees/objective-shamir-6c132f`) with an explicit `-derivedDataPath`; regenerate the xcodegen `.xcodeproj` (gitignored) before local builds; verify the built binary is this tree (screenshot a distinguishing feature) before trusting a device run. `git checkout AuraCore/Package.resolved` before committing if it churned.
- Delegate builds/tests to the `apple-platform-build-tools:builder` agent; delegate pure `swift test` runs likewise. Do NOT spawn write-capable subagents from an implementer (no grandchildren) — implement app-target/SwiftUI tasks directly.

---

## Slice 1 — ROH-46: live authored terrain style (independently shippable)

### Task 1: `MapStyle.auraTerrain` case + read-time default

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift:5` (enum), `:40` (default)
- Test: `AuraCore/Tests/AuraKitTests/MapStyleDefaultTests.swift` (create)

**Interfaces:**
- Produces: `AuraKit.MapStyle` gains `case auraTerrain` (rawValue `"auraTerrain"`); `SettingsStore().mapStyle` defaults to `.auraTerrain` when no value is stored.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AuraKit

@Suite struct MapStyleDefaultTests {
    private func emptyDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "MapStyleDefaultTests-\(UUID().uuidString)")!
        d.removePersistentDomain(forName: d.description); return d
    }

    @Test func defaultsToAuraTerrainWhenNothingStored() {
        let store = SettingsStore(defaults: emptyDefaults())
        #expect(store.mapStyle == .auraTerrain)
    }

    @Test func keepsAnExplicitStoredChoice() {
        let d = emptyDefaults()
        d.set("dark", forKey: "mapStyle")
        #expect(SettingsStore(defaults: d).mapStyle == .dark)
        d.set("standard", forKey: "mapStyle")
        #expect(SettingsStore(defaults: d).mapStyle == .standard)
    }

    @Test func unknownStoredValueFallsBackToAuraTerrain() {
        let d = emptyDefaults()
        d.set("bogus", forKey: "mapStyle")
        #expect(SettingsStore(defaults: d).mapStyle == .auraTerrain)
    }

    @Test func auraTerrainRoundTripsThroughRawValue() {
        #expect(MapStyle(rawValue: "auraTerrain") == .auraTerrain)
        #expect(MapStyle.auraTerrain.rawValue == "auraTerrain")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (via builder): `swift test --package-path AuraCore --filter MapStyleDefaultTests`
Expected: FAIL — `auraTerrain` is not a member of `MapStyle`.

- [ ] **Step 3: Add the case and flip the read-time default**

In `SettingsStore.swift` line 5:
```swift
public enum MapStyle: String, Sendable { case auraTerrain, dark, standard }
```
In `SettingsStore.swift` line 40:
```swift
mapStyle = MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .auraTerrain
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter MapStyleDefaultTests`
Expected: PASS (4 tests). Also run the full `applyRemoteMapStyle` path is unaffected: `swift test --package-path AuraCore --filter SettingsStore`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Settings/SettingsStore.swift AuraCore/Tests/AuraKitTests/MapStyleDefaultTests.swift
git commit -m "feat(theme): add MapStyle.auraTerrain and default the map to it"
```

### Task 2: live-map JSON bridge + Settings picker

**Files:**
- Modify: `Aura/Sources/Theme/MapStyle+Mapbox.swift` (bridge)
- Modify: the map-style Settings picker (find it: `grep -rn "mapStyle" Aura/Sources/Settings`) to list `.auraTerrain` as the first option labeled "Terrain (Aura)", keeping "Dark"/"Standard".
- No package test (app target); build + device-verified.

**Interfaces:**
- Consumes: `AuraKit.MapStyle.auraTerrain` (Task 1), app-target `AuraTerrainStyleLoader.json()` (`Aura/Sources/Home/AuraTerrainStyleLoader.swift`), `MapboxMaps.MapStyle(json:)` (SDK `MapStyle.swift:92`).
- Produces: `MapStyle.auraTerrain.mapboxStyle` returns the authored JSON style (or `.dark` on a missing asset); the three live maps render it via the existing `.mapStyle(settings.mapStyle.mapboxStyle)` calls.

- [ ] **Step 1: Extend the bridge**

`Aura/Sources/Theme/MapStyle+Mapbox.swift`:
```swift
import MapboxMaps
import AuraKit

extension AuraKit.MapStyle {
    var mapboxStyle: MapboxMaps.MapStyle {
        switch self {
        case .auraTerrain:
            // Reuse the app-target loader that Home's snapshotter uses; fall back to stock
            // dark on a missing/unreadable asset, exactly as Home falls back.
            AuraTerrainStyleLoader.json().map(MapboxMaps.MapStyle.init(json:)) ?? .dark
        case .dark: .dark
        case .standard: .standard
        }
    }
}
```

- [ ] **Step 2: Add `.auraTerrain` to the Settings map-style picker**

Add a "Terrain (Aura)" case first in the picker's `ForEach`/options (mirror the existing Dark/Standard rows; label copy: `Terrain (Aura)`).

- [ ] **Step 3: Regenerate the project and build the app**

Delegate to the builder (pinned to this worktree):
```
xcodegen generate   # .xcodeproj is gitignored
xcodebuild -scheme Aura -destination 'generic/platform=iOS Simulator' -derivedDataPath build-sim build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Simulator smoke — the three live maps render terrain**

Launch on the iPhone 17 sim; open (a) navigate preview / free-ride (`RideMapView`), (b) route preview (`RoutePreviewView`), (c) the navigate HUD. Confirm each shows the charcoal-green authored terrain, not stock dark. Screenshot each.

- [ ] **Step 5: Commit**

```bash
git checkout AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Theme/MapStyle+Mapbox.swift Aura/Sources/Settings
git commit -m "feat(map): render the authored terrain style on the live maps (ROH-46)"
```

### Task 3: device performance gate (blocks the terrain default)

**Files:** none (verification task). Produces the go/no-go on `.auraTerrain` as default.

- [ ] **Step 1: Build + install on the device**

Ask the user to open the tunnel. Build pinned to this worktree, verify the binary is this tree (screenshot the terrain Home), clean install on the iPhone 13 Pro Max (see `[[aura-on-device-automation]]`).

- [ ] **Step 2: Measure a recorded ride**

Record/replay a 30-minute ride in navigate mode on the terrain style. Capture Instruments Core Animation FPS + MetricKit `MXAnimationMetric` (hitch ratio) and `ProcessInfo.thermalState` over the run.

- [ ] **Step 3: Judge against the gate**

PASS = sustained 60 fps (120 on ProMotion), bounded hitch ratio, no sustained `.serious`/`.critical` thermal attributable to the style. If FAIL: open a follow-up to simplify the style JSON (shed relief/label layers) and re-measure; do NOT proceed to make terrain the shipped default until it passes. Record the result in the PR / Linear.

- [ ] **Step 4: Commit the finding** (docs only, if any style simplification lands)

---

## Slice 2 — structured maneuver data

### Task 4: `Maneuver` value type + `GuidanceUpdate` fields

**Files:**
- Create: `AuraCore/Sources/AuraCore/Guidance/Maneuver.swift`
- Modify: `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` (`GuidanceUpdate`)
- Test: `AuraCore/Tests/AuraCoreTests/ManeuverTests.swift` (create)

**Interfaces:**
- Produces: `AuraCore.Maneuver { kind: Kind; modifier: Modifier; label: String? }` with `Kind` and `Modifier` string enums; `GuidanceUpdate.maneuver: Maneuver?` and `GuidanceUpdate.nextManeuver: Maneuver?` (both default `nil`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraCore

@Suite struct ManeuverTests {
    @Test func guidanceUpdateDefaultsManeuversToNil() {
        let u = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right")
        #expect(u.maneuver == nil)
        #expect(u.nextManeuver == nil)
    }

    @Test func maneuverCarriesKindModifierAndLabel() {
        let m = Maneuver(kind: .roundabout, modifier: .right, label: "3")
        #expect(m.kind == .roundabout)
        #expect(m.modifier == .right)
        #expect(m.label == "3")
    }

    @Test func maneuversThreadThroughGuidanceUpdate() {
        let u = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right",
                               maneuver: Maneuver(kind: .turn, modifier: .right),
                               nextManeuver: Maneuver(kind: .turn, modifier: .left))
        #expect(u.maneuver?.modifier == .right)
        #expect(u.nextManeuver?.modifier == .left)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter ManeuverTests` → FAIL (no `Maneuver`).

- [ ] **Step 3: Implement `Maneuver` and extend `GuidanceUpdate`**

`Maneuver.swift`:
```swift
/// A structured turn maneuver, engine-independent (no SDK type). Mapbox's maneuver model
/// maps 1:1 onto these cases in `MapboxGuidanceSession`.
public struct Maneuver: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case turn, fork, roundabout, rotary, merge, onRamp, offRamp
        case depart, arrive, continueOn, endOfRoad, uTurn, other
    }
    public enum Modifier: String, Equatable, Sendable, CaseIterable {
        case left, right, slightLeft, slightRight, sharpLeft, sharpRight, straight, uTurn, none
    }
    public var kind: Kind
    public var modifier: Modifier
    /// Optional short label, e.g. a roundabout exit ordinal ("3") when the engine supplies it.
    public var label: String?
    public init(kind: Kind, modifier: Modifier, label: String? = nil) {
        self.kind = kind; self.modifier = modifier; self.label = label
    }
}
```
In `GuidanceUpdate` add stored properties `public var maneuver: Maneuver?` and `public var nextManeuver: Maneuver?`, and extend the initializer with `maneuver: Maneuver? = nil, nextManeuver: Maneuver? = nil` (appended after `currentStreetName`, both assigned). Keep existing call sites compiling via the defaults.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter ManeuverTests` → PASS. Then `swift test --package-path AuraCore --filter Guidance` → PASS (existing guidance tests unaffected by the defaulted fields).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Guidance/Maneuver.swift AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift AuraCore/Tests/AuraCoreTests/ManeuverTests.swift
git commit -m "feat(guidance): add structured Maneuver + next-maneuver to GuidanceUpdate"
```

### Task 5: `ManeuverIcon` mapping + completeness test

**Files:**
- Create: `AuraCore/Sources/AuraKit/Guidance/ManeuverIcon.swift`
- Test: `AuraCore/Tests/AuraKitTests/ManeuverIconTests.swift` (create)

**Interfaces:**
- Consumes: `AuraCore.Maneuver` (Task 4).
- Produces: `AuraKit.ManeuverIcon.symbol(for: Maneuver?) -> String` (SF Symbol name); `ManeuverIcon.genericSymbol` = `"arrow.turn.up.right"`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AuraCore
@testable import AuraKit

@Suite struct ManeuverIconTests {
    @Test func nilManeuverIsTheGenericArrow() {
        #expect(ManeuverIcon.symbol(for: nil) == ManeuverIcon.genericSymbol)
    }

    @Test func directionalTurnsPickASidedArrow() {
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .turn, modifier: .right)) == "arrow.turn.up.right")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .turn, modifier: .left))  == "arrow.turn.up.left")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .uTurn, modifier: .uTurn)) == "arrow.uturn.down")
    }

    @Test func everyKindAndModifierReturnsANonEmptySymbol() {
        for kind in Maneuver.Kind.allCases {
            for modifier in Maneuver.Modifier.allCases {
                let s = ManeuverIcon.symbol(for: Maneuver(kind: kind, modifier: modifier))
                #expect(!s.isEmpty, "empty symbol for \(kind)/\(modifier)")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter ManeuverIconTests` → FAIL (no `ManeuverIcon`).

- [ ] **Step 3: Implement the mapping**

```swift
import AuraCore

/// Maps a structured `Maneuver` to an SF Symbol name. Pure `String` output — no UI import —
/// so it is the single source of truth for the turn card, the then-chip, and the Live Activity.
public enum ManeuverIcon {
    public static let genericSymbol = "arrow.turn.up.right"

    public static func symbol(for maneuver: Maneuver?) -> String {
        guard let m = maneuver else { return genericSymbol }
        switch m.kind {
        case .turn, .endOfRoad, .fork, .merge, .onRamp, .offRamp:
            return directional(m.modifier)
        case .roundabout, .rotary:
            return "arrow.clockwise.circle"
        case .uTurn:
            return "arrow.uturn.down"
        case .continueOn:
            return "arrow.up"
        case .depart:
            return "location.fill"
        case .arrive:
            return "flag.checkered"
        case .other:
            return genericSymbol
        }
    }

    private static func directional(_ modifier: Maneuver.Modifier) -> String {
        switch modifier {
        case .left, .slightLeft, .sharpLeft: return "arrow.turn.up.left"
        case .right, .slightRight, .sharpRight: return "arrow.turn.up.right"
        case .straight, .none: return "arrow.up"
        case .uTurn: return "arrow.uturn.down"
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter ManeuverIconTests` → PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Guidance/ManeuverIcon.swift AuraCore/Tests/AuraKitTests/ManeuverIconTests.swift
git commit -m "feat(guidance): ManeuverIcon SF-Symbol mapping with a completeness test"
```

### Task 6: `TurnCardState.maneuver` + `NextManeuver` + presenter

**Files:**
- Modify: `AuraCore/Sources/AuraKit/TurnCardPresenter.swift` (`TurnCardState`, `TurnCardPresenter`, add `NextManeuver`)
- Test: `AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift` (add cases; file exists)

**Interfaces:**
- Consumes: `Maneuver` (Task 4).
- Produces: `TurnCardState.maneuver: Maneuver?`; a `NextManeuver { maneuver: Maneuver; label: String }`; `TurnCardPresenter.state(for:units:)` sets `maneuver` from `update.maneuver`; `TurnCardPresenter.nextManeuver(for: GuidanceUpdate) -> NextManeuver?` derived from `update.nextManeuver` (nil when absent); `TurnCardState.accessibilityLabel` gains a ", then <label>" suffix when a next maneuver with a label exists.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func stateCarriesTheManeuver() {
    let u = GuidanceUpdate(distanceToManeuverMeters: 120, instruction: "Turn right onto Penn Ave",
                           maneuver: Maneuver(kind: .turn, modifier: .right))
    #expect(TurnCardPresenter.state(for: u, units: .imperial).maneuver?.modifier == .right)
}

@Test func nextManeuverIsNilWhenAbsent() {
    let u = GuidanceUpdate(distanceToManeuverMeters: 120, instruction: "Turn right")
    #expect(TurnCardPresenter.nextManeuver(for: u) == nil)
}

@Test func nextManeuverCarriesLabelAndManeuver() {
    let u = GuidanceUpdate(distanceToManeuverMeters: 120, instruction: "Turn right",
                           nextManeuver: Maneuver(kind: .turn, modifier: .left, label: "Highland Ave"))
    let next = TurnCardPresenter.nextManeuver(for: u)
    #expect(next?.label == "Highland Ave")
    #expect(next?.maneuver.modifier == .left)
}

@Test func composedLabelAppendsThenClause() {
    let u = GuidanceUpdate(distanceToManeuverMeters: 120, instruction: "Turn right onto Penn Ave",
                           maneuver: Maneuver(kind: .turn, modifier: .right),
                           nextManeuver: Maneuver(kind: .turn, modifier: .left, label: "Highland Ave"))
    #expect(TurnCardPresenter.state(for: u, units: .imperial).accessibilityLabel.contains("then Highland Ave"))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path AuraCore --filter TurnCardPresenterTests` → FAIL.

- [ ] **Step 3: Implement**

Add `public var maneuver: Maneuver?` to `TurnCardState` (default `nil` in the initializer; update the two static states `.starting`/`.unavailable` to pass `nil`). Add:
```swift
public struct NextManeuver: Equatable, Sendable {
    public var maneuver: Maneuver
    public var label: String
    public init(maneuver: Maneuver, label: String) { self.maneuver = maneuver; self.label = label }
}
```
In `TurnCardPresenter.state(distanceToManeuverMeters:instruction:units:expandWithinMeters:)` add a `maneuver: Maneuver?` parameter (default `nil`), set it on the returned state, and when a next maneuver is passed, append `", then \(label)"` to the accessibilityLabel. Simplest: give the `state(for:units:)` overload the whole update so it can read both `maneuver` and `nextManeuver`:
```swift
public static func state(for update: GuidanceUpdate, units: DistanceUnits,
                         expandWithinMeters: Double = 150) -> TurnCardState {
    var s = state(distanceToManeuverMeters: update.distanceToManeuverMeters,
                  instruction: update.instruction, units: units,
                  maneuver: update.maneuver, expandWithinMeters: expandWithinMeters)
    if let next = nextManeuver(for: update) {
        s.accessibilityLabel += ", then \(next.label)"
    }
    return s
}
public static func nextManeuver(for update: GuidanceUpdate) -> NextManeuver? {
    guard let m = update.nextManeuver, let label = m.label, !label.isEmpty else { return nil }
    return NextManeuver(maneuver: m, label: label)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path AuraCore --filter TurnCardPresenterTests` → PASS. Then full package: `swift test --package-path AuraCore` → PASS (no regressions).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/TurnCardPresenter.swift AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift
git commit -m "feat(guidance): thread maneuver + next-maneuver through TurnCardState"
```

### Task 7: scripted-session threading + view-model coverage

**Files:**
- Test: `AuraCore/Tests/AuraKitTests/GuidanceViewModelTests.swift` (add a case)

**Interfaces:**
- Consumes: `ScriptedGuidanceSession` already forwards whatever `GuidanceUpdate` the script yields (no signature change needed — the new fields ride the existing `.progress(GuidanceUpdate)` event). This task proves the maneuver reaches `GuidanceViewModel.turn`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func progressWithManeuverSetsTurnManeuver() async {
    let update = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right",
                                maneuver: Maneuver(kind: .turn, modifier: .right))
    let vm = GuidanceViewModel(session: ScriptedGuidanceSession(script: [.progress(update)]))
    await vm.run(route: .init(geometry: [], distanceMeters: 0, expectedTravelTimeSeconds: 0))
    #expect(vm.turn.maneuver?.modifier == .right)
}
```
(Match the `Route` initializer to the real one — check `AuraCore/Sources/AuraCore/Models/Route.swift` and copy its exact signature.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GuidanceViewModelTests` → FAIL (maneuver not yet on `turn`, unless Task 6 already made it pass — if it passes immediately, keep it as a regression guard and note that).

- [ ] **Step 3: No implementation needed**

`GuidanceViewModel.run` already assigns `turn = TurnCardPresenter.state(for: update, units:)`, which now carries the maneuver (Task 6). This task is coverage that the wire is intact.

- [ ] **Step 4: Run to verify pass** → PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Tests/AuraKitTests/GuidanceViewModelTests.swift
git commit -m "test(guidance): maneuver reaches the turn card through the view model"
```

### Task 8: Mapbox step → maneuver population (app target)

**Files:**
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift` (`guidanceUpdate(from:)`)
- No package test (app target); build-verified + device-verified in Slice 3/4.

**Interfaces:**
- Consumes: `RouteProgress.currentLegProgress` (`currentStep`, `upcomingStep`, and the remaining steps).
- Produces: `guidanceUpdate(from:)` fills `maneuver` (from the upcoming/approached step) and `nextManeuver` (from the step after it) via a private `mapManeuver(_:)` mapping Mapbox `ManeuverType` + `ManeuverDirection` → `Maneuver`.

- [ ] **Step 1: API audit (first, no view depends on it)**

In `MapboxGuidanceSession.swift`, confirm the Mapbox `RouteStep` exposes `maneuverType: ManeuverType` and `maneuverDirection: ManeuverDirection?`, and how to reach the step AFTER `upcomingStep` (e.g. `currentLegProgress.remainingSteps` — index the one following the upcoming step, or `leg.steps[stepIndex + 2]`). Write a 3-line note in the PR of the exact accessors used. If a field is absent, the mapping returns `.other`/`.none` and the arrow degrades to generic — not a blocker.

- [ ] **Step 2: Implement the mapping + populate both fields**

Add:
```swift
private static func mapManeuver(_ step: RouteStep?) -> Maneuver? {
    guard let step else { return nil }
    let kind: Maneuver.Kind = {
        switch step.maneuverType {
        case .turn: return .turn
        case .reachFork: return .fork
        case .takeRoundabout, .turnAtRoundabout: return .roundabout
        case .takeRotary: return .rotary
        case .merge: return .merge
        case .takeOnRamp: return .onRamp
        case .takeOffRamp: return .offRamp
        case .depart: return .depart
        case .arrive: return .arrive
        case .continue, .passNameChange: return .continueOn
        case .reachEnd: return .endOfRoad
        case .makeUTurn: return .uTurn
        default: return .other
        }
    }()
    let modifier: Maneuver.Modifier = {
        switch step.maneuverDirection {
        case .left: return .left
        case .right: return .right
        case .slightLeft: return .slightLeft
        case .slightRight: return .slightRight
        case .sharpLeft: return .sharpLeft
        case .sharpRight: return .sharpRight
        case .straightAhead: return .straight
        case .uTurn: return .uTurn
        default: return .none
        }
    }()
    return Maneuver(kind: kind, modifier: modifier, label: nil)
}
```
(Adjust the Mapbox enum case names to the exact SDK spelling found in Step 1.) In `guidanceUpdate(from:)` pass `maneuver: mapManeuver(progress.currentLegProgress.upcomingStep)` and `nextManeuver: mapManeuver(stepAfterUpcoming)` where `stepAfterUpcoming` is the step following `upcomingStep` (nil on the final leg). Set the next-maneuver's `label` to that step's short street name when available (`step.names?.first` or the step's instruction street) so the then-chip has text.

- [ ] **Step 3: Build**

Delegate to builder: `xcodegen generate && xcodebuild -scheme Aura -destination 'generic/platform=iOS Simulator' -derivedDataPath build-sim build` → BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git checkout AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "feat(guidance): populate maneuver + next-maneuver from Mapbox steps"
```

---

## Slice 3 — the turn-forward re-layout

> Slice 3/4 views are app-target SwiftUI with no unit-test bundle: implement directly, build via the builder, and verify on device. Each task ends with a build + a sim smoke; the ride-at-speed / group / gate verifications are batched in Task 17.

### Task 9: `TurnCardView` directional arrow + `ThenChip`

**Files:**
- Modify: `Aura/Sources/Ride/TurnCardView.swift`
- Create: `Aura/Sources/Ride/ThenChip.swift`

**Interfaces:**
- Consumes: `TurnCardState.maneuver`, `ManeuverIcon.symbol(for:)`, `NextManeuver`.
- Produces: `TurnCardView` renders `Image(systemName: ManeuverIcon.symbol(for: state.maneuver))` in place of the hardcoded `arrow.turn.up.right`; `ThenChip(next: NextManeuver)` renders a compact "then <label>" pill with the next glyph, `.accessibilityHidden(true)`.

- [ ] **Step 1: Swap the hardcoded arrow**

In `TurnCardView.swift` replace `Image(systemName: "arrow.turn.up.right")` with `Image(systemName: ManeuverIcon.symbol(for: state.maneuver))` (import `AuraKit` already present). Keep the collapsed/expanded scale + color logic.

- [ ] **Step 2: Build `ThenChip`**

```swift
import SwiftUI
import AuraCore
import AuraKit

/// Compact next-maneuver preview shown under the turn band. Decorative for VoiceOver — its
/// "then …" text is composed into the turn card's single accessibility label by the presenter.
struct ThenChip: View {
    let next: NextManeuver
    var body: some View {
        HStack(spacing: AuraTheme.Spacing.xs) {
            Text("then").font(.caption.weight(.semibold)).foregroundStyle(AuraTheme.textSecondary)
            Image(systemName: ManeuverIcon.symbol(for: next.maneuver))
                .font(.caption.weight(.bold)).foregroundStyle(AuraTheme.accent)
            Text(next.label).font(.caption.weight(.semibold)).foregroundStyle(AuraTheme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, AuraTheme.Spacing.md).padding(.vertical, AuraTheme.Spacing.xs)
        .background(AuraTheme.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(AuraTheme.border))
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 3: Build + sim smoke**

Build (builder). On the sim navigate HUD, confirm the arrow now reflects the turn direction (drive a scripted route if needed) and the then-chip renders. Screenshot.

- [ ] **Step 4: Commit**

```bash
git checkout AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Ride/TurnCardView.swift Aura/Sources/Ride/ThenChip.swift
git commit -m "feat(cockpit): directional turn arrow + then-chip preview"
```

### Task 10: `InstrumentPanel`

**Files:**
- Create: `Aura/Sources/Ride/InstrumentPanel.swift`

**Interfaces:**
- Consumes: `RideStats`, `RideStatsFormatter`, `SpeedReadout`, `StatPair`, `AuraTheme`.
- Produces: `InstrumentPanel(currentSpeedMetersPerSecond:cruising:units:)` — a bumped bottom panel: a ~56pt Saira speed hero (via `AuraTheme.Typography.speedHero`) on the leading side and a right-aligned to-go / ETA block (reusing `CruisingState.distanceRemaining`/`eta`), on the opaque `mapScrim` fill; caps at `.accessibility1`; one composed VoiceOver label.

- [ ] **Step 1: Implement the panel** (compose from existing `SpeedReadout` + `StatPair`; speed hero left, to-go/ETA right; opaque `AuraTheme.mapScrim(reduceTransparency:contrast)` background; single `.accessibilityElement(children: .ignore)` with a composed label "18 miles per hour, 2.1 miles to go, arriving 4:38 PM"). Match the mockup proportions (speed ~56pt, stats ~26pt).

- [ ] **Step 2: Build + sim smoke** (render in a preview + on the HUD once wired in Task 12). Screenshot.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/InstrumentPanel.swift
git commit -m "feat(cockpit): bumped bottom instrument panel (speed hero + to-go + ETA)"
```

### Task 11: `ControlRail`

**Files:**
- Create: `Aura/Sources/Ride/ControlRail.swift` (or rework `ControlCluster.swift` into a leading vertical rail — keep the same actions/labels)

**Interfaces:**
- Produces: `ControlRail(isFollowing:isMuted:onRecenter:onToggleMute:onEndRide:)` — the recenter/mute/end buttons on `HUDControlButton`, as a leading vertical rail; identical accessibility to today's `ControlCluster`.

- [ ] **Step 1: Implement** (lift `ControlCluster`'s three buttons into the rail layout; preserve `.hudControl(active:)`, `.hudControl(role: .destructive)`, and every `accessibilityLabel`/`accessibilityValue`/`isToggle`).

- [ ] **Step 2: Build + sim smoke.** Screenshot.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/ControlRail.swift Aura/Sources/Ride/ControlCluster.swift
git commit -m "feat(cockpit): control rail (recenter/mute/end)"
```

### Task 12: recompose `NavigateHUDView`

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `TurnCardView`, `ThenChip`, `InstrumentPanel`, `ControlRail`, `TurnCardPresenter.nextManeuver(for:)`.
- Produces: the recomposed body — maneuver band + then-chip pinned top; `InstrumentPanel` + `ControlRail` at the bottom (replacing the `ControlCluster` + `SpeedRail(.speedOnly)` + `TripStripView` trio); every existing lifecycle hook (`.task` start, coordinator wiring, summary/permission sheets, group overlays, teardown, `.onChange`) preserved verbatim.

- [ ] **Step 1: Recompose the body** — top overlay stack = `TurnCardView(state: guidance.turn, ...)` with a `ThenChip` beneath it when `TurnCardPresenter.nextManeuver(for: guidance.lastUpdate)` is non-nil; bottom = `InstrumentPanel(...)` + `ControlRail(...)`. Remove the navigate-mode `SpeedRail`/`TripStripView` usage. Do NOT touch the `.task`, sheets, group overlays, or `.onChange` handlers.

- [ ] **Step 2: Build + sim smoke** — full navigate HUD renders: terrain map, directional turn card + then-chip, bumped instrument, control rail. Screenshot.

- [ ] **Step 3: Commit**

```bash
git checkout AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(cockpit): recompose the navigate HUD around the turn-forward layout"
```

---

## Slice 4 — motion, edge states, group, Live Activity

### Task 13: motion pass (celebrate completion, not imminence)

**Files:** Modify `Aura/Sources/Ride/TurnCardView.swift`, `ThenChip.swift`, `NavigateHUDView.swift`.

- [ ] **Step 1: Turn arrow + completion beat** — arrow swaps via `.contentTransition(.symbolEffect(.replace))` on `state.maneuver` change; on maneuver advance, a single subtle scale settle on the band; `.symbolEffectsRemoved(reduceMotion)`; under Reduce Motion, opacity crossfade only. Keep the existing `.smooth(0.38)` collapsed→expanded morph but with NO added per-turn bounce.
- [ ] **Step 2: ThenChip transition** — `.transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))`, animated with `.snappy` on `next` change.
- [ ] **Step 3: Numerics** — confirm speed/ETA/to-go use `.contentTransition(.numericText())` + `.snappy` in `InstrumentPanel` (no per-tick animation).
- [ ] **Step 4: Build + sim smoke.** Screenshot.
- [ ] **Step 5: Commit** `feat(cockpit): motion pass — completion beat, reduce-motion guards`.

### Task 14: edge states restyle

**Files:** Modify `NavigateHUDView.swift`, `GPSSignalChip.swift`.

- [ ] **Step 1: Rerouting / starting / unavailable** — re-skin the existing rerouting cue and the `.starting`/`.unavailable` turn-card states into the new band chrome (no behavior change, just style).
- [ ] **Step 2: GPS weak/lost** — when `location.signal` is poor, the `GPSSignalChip` escalates to the amber (`AuraTheme.warning`) chrome treatment; navigation does NOT pause (the turn card holds its last maneuver, the route stays drawn). No new location plumbing.
- [ ] **Step 3: Build + sim smoke** (simulate a poor signal / rerouting state). Screenshot.
- [ ] **Step 4: Commit** `feat(cockpit): restyle rerouting / GPS-weak edge states`.

### Task 15: group crew reflow

**Files:** Modify `NavigateHUDView.swift`, `NavigateHUDView+GroupCrew.swift`.

- [ ] **Step 1: Reflow spacing** — dock `GroupRosterSheet` above the new `InstrumentPanel` with explicit spacing so collapsed roster, expanded roster max-height, and the instrument+rail block clear each other within the safe area; keep `GroupToastHost` top-center and the reconnecting pill top. Preserve `showsGroupChrome`/`phase` logic.
- [ ] **Step 2: Peer-dot legibility** — verify peer dots (`.riding` mint, `.stopped` amber, self) read on the authored terrain; if any status color washes out, apply a minimal contrast fix (outline/opacity) only. Do NOT redesign the color system (Chunk 3).
- [ ] **Step 3: Build + sim smoke** (group preview). Screenshot.
- [ ] **Step 4: Commit** `feat(cockpit): reflow the group crew layer against the new bottom`.

### Task 16: Live Activity glyph (scope-lite)

**Files:** Modify `Aura/Sources/LiveActivity/RideActivityAttributes.swift` (add `turnGlyphSystemName: String?` to `ContentState` + init), `RideLiveActivityController.swift` (set it via `ManeuverIcon.symbol(for:)`), `Aura/Widgets/RideLockScreenView.swift` (render `Image(systemName: state.turnGlyphSystemName ?? "arrow.turn.up.right")`).

- [ ] **Step 1: Add the field** to `ContentState` (Codable/Hashable auto-synthesize; default `nil` in init to keep call sites compiling).
- [ ] **Step 2: Populate** in `RideLiveActivityController` where it already sets `turnInstruction`/`turnDistanceMeters`: `turnGlyphSystemName: ManeuverIcon.symbol(for: maneuver?.maneuver)` (the controller has the `GuidanceUpdate`; read its `.maneuver`).
- [ ] **Step 3: Render** the glyph in `RideLockScreenView` next to the instruction.
- [ ] **Step 4: Build app + widget extension** (builder). Screenshot the Live Activity in the sim if practical.
- [ ] **Step 5: Commit** `feat(live-activity): directional turn glyph via a pushed content-state string`.

### Task 17: device verification + acceptance gates

**Files:** none (verification). Ask the user to open the tunnel; build pinned to this worktree, verify the binary (screenshot a distinguishing feature), clean install.

- [ ] **Step 1: Ride-at-speed** — arrow direction correct at a sub-second glance; then-chip advances; instrument legible in sun; Reduce Motion path calm.
- [ ] **Step 2: Glanceability gate** — if the then-chip adds dwell, gate it to imminence (show only within N seconds of the turn). Record the decision.
- [ ] **Step 3: Ownability gate** — capture the HUD chrome alone (map hidden); with the user, judge "unmistakably Aura?" If no, add ONE non-climb identity signal (terrain-contour panel-edge motif or a signature route/speed treatment) and re-judge.
- [ ] **Step 4: Group reflow** — roster reachable one-handed; peer dots legible on terrain.
- [ ] **Step 5: Record results** in the PR / Linear; open follow-ups for anything deferred.

---

## Self-review notes

- **Spec coverage:** Slice 1 → Tasks 1–3; Slice 2 → Tasks 4–8; Slice 3 → Tasks 9–12; Slice 4 → Tasks 13–17. Maneuver taxonomy appendix → Task 5 (+ completeness test) and Task 8 (mapping). Live Activity boundary → Task 16 (pushed string). Default-flip semantics → Task 1. Perf/glanceability/ownability gates → Tasks 3, 17.
- **Type consistency:** `Maneuver`/`Maneuver.Kind`/`Maneuver.Modifier` (Task 4) used verbatim in Tasks 5–8; `NextManeuver { maneuver; label }` (Task 6) used in Tasks 9, 12; `ManeuverIcon.symbol(for:)`/`genericSymbol` (Task 5) used in Tasks 9, 13, 16; `MapStyle.auraTerrain` (Task 1) used in Task 2.
- **App-target reality:** Tasks 2, 8–17 have no package unit tests (no app test bundle) and use build + device verification, which the plan states explicitly rather than faking unit coverage.
