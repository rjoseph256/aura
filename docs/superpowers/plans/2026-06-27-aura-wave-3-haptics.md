# Wave 3 Turn Haptics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During a navigated ride, fire a haptic once when a turn approaches and once on arrival, gated by a "Turn haptics" Settings toggle.

**Architecture:** A pure `TurnHapticEngine` (AuraCore) decides *when* to fire (once per maneuver, keyed on the instruction string). `GuidanceViewModel` (AuraKit) owns the engine, feeds it each guidance event, and calls a new `HapticPlaying` seam when it returns a cue. The app-target `HapticPlayer` plays UIKit feedback generators behind that seam. A `SettingsStore.turnHaptics` Bool (default on, live mid-ride) gates the play.

**Tech Stack:** Swift 6.2 / Xcode 26, SwiftPM package (`AuraCore` + `AuraKit`), SwiftUI app target, XcodeGen, Swift Testing (new suites) + XCTest (existing), UIKit `UIFeedbackGenerator`.

**Spec:** `docs/superpowers/specs/2026-06-27-aura-wave-3-haptics-design.md`

## Global Constraints

- Swift 6.2 / Xcode 26; iPhone 17 / iOS 26.x simulator.
- SwiftLint **0.64.1** pinned, run `--strict` over the whole repo via `scripts/lint.sh` as part of EVERY task gate (package tasks included). `line_length` ≤ 140; no 3-member tuples (`large_tuple` caps at 2 — use a struct/enum); aligned-brace spacing (no multi-space before `{`).
- Package code (`AuraCore/`, `AuraKit/`) must compile on the macOS CI host: **no UIKit, no CoreHaptics, no iOS-only API** anywhere in the package for this feature (verified by `cd AuraCore && swift test`). All UIKit feedback-generator code lives in the `Aura` app target.
- NEVER `git add AuraCore/Package.resolved` (revert with `git checkout -- AuraCore/Package.resolved` if a build dirties it). Don't commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored). Stage only the files each task names.
- Any app-target file ADD/DELETE requires `xcodegen generate` in `Aura/` (the `Sources` dir is globbed, so no `project.yml` edit is needed for a new `Sources/Ride/*.swift` file). Package files under `AuraCore/Sources/**` are auto-globbed.
- Delegate all builds, app builds, simulator, and device operations to the `apple-platform-build-tools:builder` subagent.
- Commit messages end with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Commit-scope convention: `feat(core)`/`test(core)` for package work, `feat(app)` for app-target, `docs(roadmap)` for the roadmap.

## File Structure

| File | Responsibility |
|------|----------------|
| `AuraCore/Sources/AuraCore/Guidance/RideHapticCue.swift` (create) | The pure cue enum (`.approach`, `.arrival`). |
| `AuraCore/Sources/AuraCore/Guidance/TurnHapticEngine.swift` (create) | Pure once-per-maneuver edge-trigger keyed on the instruction string. |
| `AuraCore/Tests/AuraCoreTests/TurnHapticEngineTests.swift` (create) | Swift Testing suite for the engine. |
| `AuraCore/Sources/AuraKit/Guidance/HapticPlaying.swift` (create) | `@MainActor` seam protocol (`prepare()`, `play(_:)`). |
| `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift` (modify) | Own the engine; feed it; call the seam (gated). |
| `AuraCore/Tests/AuraKitTests/GuidanceViewModelHapticsTests.swift` (create) | Swift Testing suite driving the VM with a `HapticPlaying` spy. |
| `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift` (modify) | `turnHaptics` Bool (default on, persisted). |
| `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift` (modify) | Default-on + persistence test. |
| `Aura/Sources/Ride/HapticPlayer.swift` (create) | App-target `HapticPlaying` shell over UIKit feedback generators + os.Logger. |
| `Aura/Sources/Settings/SettingsView.swift` (modify) | "Turn haptics" toggle row. |
| `Aura/Sources/Ride/NavigateHUDView.swift` (modify) | Wire `haptics`/`hapticsEnabled` + live `.onChange`. |
| `docs/ROADMAP.md` (modify) | Mark Wave 3 item 2 shipped. |

---

### Task 1: Pure cue + edge-trigger engine (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Guidance/RideHapticCue.swift`
- Create: `AuraCore/Sources/AuraCore/Guidance/TurnHapticEngine.swift`
- Test: `AuraCore/Tests/AuraCoreTests/TurnHapticEngineTests.swift`

**Interfaces:**
- Produces: `enum RideHapticCue: Equatable, Sendable { case approach, arrival }`.
- Produces: `struct TurnHapticEngine` with `init(approachWithinMeters: Double = 150)`, `mutating func onProgress(distanceToManeuverMeters: Double, maneuverKey: String) -> RideHapticCue?`, `mutating func onArrival() -> RideHapticCue?`.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraCoreTests/TurnHapticEngineTests.swift`:

```swift
import Testing
import AuraCore

struct TurnHapticEngineTests {
    @Test func approachFiresOnceWhenCrossingThreshold() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 200, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 160, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
    }

    @Test func approachDoesNotFireAboveThreshold() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 300, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 151, maneuverKey: "A") == nil)
    }

    @Test func approachFiresImmediatelyWhenFirstUpdateAlreadyWithin() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 120, maneuverKey: "A") == .approach)
    }

    @Test func approachDoesNotDoubleFireForSameManeuver() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
        #expect(engine.onProgress(distanceToManeuverMeters: 120, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 100, maneuverKey: "A") == nil)
    }

    @Test func keyChangeReArmsForNextManeuver() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
        #expect(engine.onProgress(distanceToManeuverMeters: 300, maneuverKey: "B") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "B") == .approach)
    }

    @Test func sameKeyDoesNotReFireAfterRecedeAndReApproach() {
        // Non-monotonic distance (a stop or a position re-snap) must not double-fire
        // the same turn — the once-per-key guard, not a hysteresis band, handles this.
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
        #expect(engine.onProgress(distanceToManeuverMeters: 185, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 130, maneuverKey: "A") == nil)
    }

    @Test func arrivalFiresOnceOnly() {
        var engine = TurnHapticEngine()
        #expect(engine.onArrival() == .arrival)
        #expect(engine.onArrival() == nil)
    }

    @Test func finalManeuverFiresApproachThenArrival() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 120, maneuverKey: "Arriving") == .approach)
        #expect(engine.onArrival() == .arrival)
    }

    @Test func customThresholdHonored() {
        var engine = TurnHapticEngine(approachWithinMeters: 50)
        #expect(engine.onProgress(distanceToManeuverMeters: 80, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 50, maneuverKey: "A") == .approach)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter TurnHapticEngineTests`
Expected: FAIL — `cannot find 'TurnHapticEngine' in scope` / `cannot find 'RideHapticCue'`.

- [ ] **Step 3: Write the cue enum**

Create `AuraCore/Sources/AuraCore/Guidance/RideHapticCue.swift`:

```swift
/// A haptic cue to play during a navigated ride. Pure — names the moment, never the
/// hardware. The app-target player maps each case to a feedback generator.
public enum RideHapticCue: Equatable, Sendable {
    /// A turn is imminent (the maneuver distance reached the approach threshold).
    case approach
    /// The rider reached the destination.
    case arrival
}
```

- [ ] **Step 4: Write the engine**

Create `AuraCore/Sources/AuraCore/Guidance/TurnHapticEngine.swift`:

```swift
/// Decides when to fire turn-approach and arrival haptics, edge-triggered so each
/// fires exactly once per maneuver. Pure and deterministic: no Foundation type
/// beyond `Double`/`String`, no CoreLocation, no UIKit — it builds and tests on the
/// macOS CI host. `GuidanceViewModel` owns one of these and feeds it each event.
///
/// "Current maneuver" is keyed on the guidance instruction string (the stream
/// carries no maneuver id). Once an approach fires for a key, that key never fires
/// again, so the buzz is once-per-maneuver no matter how the (non-monotonic) maneuver
/// distance moves afterward — a stop or a position re-snap that pushes the distance
/// back up cannot re-fire it. A new key (a new maneuver, or the end-of-route flip
/// from the upcoming step to the current step) is eligible to fire again.
public struct TurnHapticEngine {
    private let approachWithinMeters: Double
    private var firedApproachKey: String?
    private var arrivalFired = false

    /// - Parameter approachWithinMeters: the maneuver distance at/under which the
    ///   approach fires. Defaults to 150, matching `TurnCardPresenter.expandWithinMeters`
    ///   so the buzz coincides with the turn card expanding to lime.
    public init(approachWithinMeters: Double = 150) {
        self.approachWithinMeters = approachWithinMeters
    }

    /// Feed one progress update. Returns `.approach` on the first update for a
    /// not-yet-fired key that is within the threshold; `nil` otherwise.
    public mutating func onProgress(distanceToManeuverMeters: Double,
                                    maneuverKey: String) -> RideHapticCue? {
        guard maneuverKey != firedApproachKey else { return nil }  // already buzzed this turn
        guard distanceToManeuverMeters <= approachWithinMeters else { return nil }
        firedApproachKey = maneuverKey
        return .approach
    }

    /// Feed arrival. Returns `.arrival` once, ever.
    public mutating func onArrival() -> RideHapticCue? {
        guard !arrivalFired else { return nil }
        arrivalFired = true
        return .arrival
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter TurnHapticEngineTests`
Expected: PASS (9 tests).

- [ ] **Step 6: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Guidance/RideHapticCue.swift \
        AuraCore/Sources/AuraCore/Guidance/TurnHapticEngine.swift \
        AuraCore/Tests/AuraCoreTests/TurnHapticEngineTests.swift
git commit -m "feat(core): pure turn-haptic edge-trigger engine

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Haptic seam + view-model wiring (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Guidance/HapticPlaying.swift`
- Modify: `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift`
- Test: `AuraCore/Tests/AuraKitTests/GuidanceViewModelHapticsTests.swift`

**Interfaces:**
- Consumes: `RideHapticCue`, `TurnHapticEngine` (Task 1).
- Produces: `@MainActor protocol HapticPlaying: AnyObject { func prepare(); func play(_ cue: RideHapticCue) }`.
- Produces: on `GuidanceViewModel` — `var haptics: (any HapticPlaying)?`, `var hapticsEnabled: Bool` (both `@ObservationIgnored`), and `prepare()`-on-`start`/fire-in-`run` behavior.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/GuidanceViewModelHapticsTests.swift`:

```swift
import Testing
import AuraCore
@testable import AuraKit

@MainActor
struct GuidanceViewModelHapticsTests {
    /// Records the cues the view model plays, and how often it prepared.
    final class HapticSpy: HapticPlaying {
        var cues: [RideHapticCue] = []
        var prepareCount = 0
        func prepare() { prepareCount += 1 }
        func play(_ cue: RideHapticCue) { cues.append(cue) }
    }

    private func makeRoute() -> Route {
        let o = Coordinate(latitude: 40.44, longitude: -79.99)
        let d = Coordinate(latitude: 40.45, longitude: -79.95)
        return Route(origin: o, destination: d, waypoints: [], geometry: [o, d],
                     profile: .fastest, distanceMeters: 3000,
                     estimatedDurationSeconds: 600, elevationGainMeters: 20)
    }

    @Test func enabledFiresApproachThenArrival() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 200, instruction: "Right onto Penn Ave")),
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Right onto Penn Ave")),
            .arrivedAtDestination
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        await vm.run(route: makeRoute())
        #expect(spy.cues == [.approach, .arrival])
    }

    @Test func disabledFiresNothing() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Turn")),
            .arrivedAtDestination
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = false
        await vm.run(route: makeRoute())
        #expect(spy.cues.isEmpty)
    }

    @Test func doesNotDoubleFireApproach() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Turn")),
            .progress(.init(distanceToManeuverMeters: 120, instruction: "Turn"))
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        await vm.run(route: makeRoute())
        #expect(spy.cues == [.approach])
    }

    @Test func prepareCalledOnStart() {
        let session = ScriptedGuidanceSession(script: [])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.start(route: makeRoute())
        #expect(spy.prepareCount == 1)
        vm.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter GuidanceViewModelHapticsTests`
Expected: FAIL — `cannot find type 'HapticPlaying' in scope` and `value of type 'GuidanceViewModel' has no member 'haptics'`.

- [ ] **Step 3: Write the seam protocol**

Create `AuraCore/Sources/AuraKit/Guidance/HapticPlaying.swift`:

```swift
import AuraCore

/// Plays a ride haptic. The app conforms a UIKit-feedback-generator-backed type; the
/// package never imports UIKit, so it builds on the macOS CI host. Guidance-scoped —
/// driven by `GuidanceViewModel`, not `RideSessionCoordinator` — so it lives here in
/// `Guidance/` rather than with the coordinator seams in `RideSessionSeams.swift`.
@MainActor
public protocol HapticPlaying: AnyObject {
    /// Warm the generators to cut first-tap latency. Called once when guidance starts.
    func prepare()
    /// Play the cue. Fire-and-forget; a no-op when haptics are unavailable.
    func play(_ cue: RideHapticCue)
}
```

- [ ] **Step 4: Wire the engine into `GuidanceViewModel`**

In `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift`, add the three members immediately after the existing `units` property (which ends the `@ObservationIgnored public var units = .imperial` block around line 35):

```swift
    /// The app-target haptic player. `nil` in tests and on free ride; the navigate
    /// HUD sets it. Not observed — only read inside `start`/`run`.
    @ObservationIgnored public var haptics: (any HapticPlaying)?

    /// Whether turn haptics are enabled (the rider's setting). Live, like `units`:
    /// the navigate HUD updates it on change, so a mid-ride toggle takes effect.
    @ObservationIgnored public var hapticsEnabled: Bool = false

    /// Pure once-per-maneuver edge-trigger for the approach + arrival cues.
    @ObservationIgnored private var hapticEngine = TurnHapticEngine()
```

In `start(route:)`, add `haptics?.prepare()` after the `task?.cancel()` line and before the `task = Task {…}` assignment:

```swift
    public func start(route: Route) {
        task?.cancel()
        haptics?.prepare()
        task = Task { @MainActor in
            await self.run(route: route)
        }
    }
```

In `run(route:)`, the `.progress(let update)` case, add the engine feed after the existing `turn = TurnCardPresenter.state(for: update, units: units)` line:

```swift
            case .progress(let update):
                isRerouting = false
                sawProgress = true
                lastUpdate = update
                turn = TurnCardPresenter.state(for: update, units: units)
                let cue = hapticEngine.onProgress(
                    distanceToManeuverMeters: update.distanceToManeuverMeters,
                    maneuverKey: update.instruction)
                if hapticsEnabled, let cue { haptics?.play(cue) }
```

In `run(route:)`, the `.arrivedAtDestination` case, play the arrival cue before `onArrive()` (which tears the session down):

```swift
            case .arrivedAtDestination:
                let cue = hapticEngine.onArrival()
                if hapticsEnabled, let cue { haptics?.play(cue) }
                // `onArrive` ends the ride, which tears down this very session. Stop
                // consuming by returning rather than letting teardown cancel the task
                // from inside its own loop.
                onArrive()
                return
```

(The engine is fed regardless of `hapticsEnabled` so its edge state stays coherent across a mid-ride toggle; only the `play` is gated.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter GuidanceViewModelHapticsTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Run the full package suite (no regressions)**

Run: `cd AuraCore && swift test`
Expected: PASS — all existing `GuidanceViewModelTests` (XCTest) still green; new suites pass.

- [ ] **Step 7: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations. (Watch the wrapped `onProgress` call — both lines must stay ≤ 140 chars.)

- [ ] **Step 8: Commit**

```bash
git add AuraCore/Sources/AuraKit/Guidance/HapticPlaying.swift \
        AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift \
        AuraCore/Tests/AuraKitTests/GuidanceViewModelHapticsTests.swift
git commit -m "feat(core): HapticPlaying seam + guidance view-model wiring

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Settings toggle store property (AuraCore/AuraKit)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `SettingsStore.turnHaptics: Bool` (default `true`, persisted under key `"turnHaptics"`).

- [ ] **Step 1: Write the failing test**

In `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift`, add this method inside the class (after `test_saveToHealth_defaultsOffAndPersists`):

```swift
    func test_turnHaptics_defaultsOnAndPersists() {
        let s = freshStore()
        XCTAssertTrue(s.turnHaptics)
        s.turnHaptics = false
        XCTAssertFalse(s.turnHaptics)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter SettingsStoreTests`
Expected: FAIL — `value of type 'SettingsStore' has no member 'turnHaptics'`.

- [ ] **Step 3: Add the property**

In `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`:

Add the stored property after the `saveToHealth` line:

```swift
    /// Opt-in: play a haptic on turn approach and arrival during a navigated ride.
    public var turnHaptics: Bool { didSet { defaults.set(turnHaptics, forKey: Key.turnHaptics) } }
```

Add the seed in `init`, after the `saveToHealth = …` line:

```swift
        turnHaptics = defaults.object(forKey: Key.turnHaptics) as? Bool ?? true
```

Add the key in the `Key` enum, after `static let saveToHealth = "saveToHealth"`:

```swift
        static let turnHaptics = "turnHaptics"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter SettingsStoreTests`
Expected: PASS.

- [ ] **Step 5: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Settings/SettingsStore.swift \
        AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift
git commit -m "feat(core): turnHaptics setting (default on)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: HapticPlayer shell (app target)

**Files:**
- Create: `Aura/Sources/Ride/HapticPlayer.swift`

**Interfaces:**
- Consumes: `HapticPlaying` (Task 2), `RideHapticCue` (Task 1).
- Produces: `HapticPlayer.shared` — a `@MainActor final class HapticPlaying` for the navigate HUD to inject.

There is no package unit test for the app target (CI builds but does not test it, per the established pattern); the gate is a green app build + lint, and the real behavior is verified on the simulator in Task 6.

- [ ] **Step 1: Create the player**

Create `Aura/Sources/Ride/HapticPlayer.swift`:

```swift
import UIKit
import os
import AuraCore
import AuraKit

/// Plays turn-approach and arrival haptics during a navigated ride — the app-target
/// shell behind AuraKit's `HapticPlaying` seam, the analog of `WorkoutWriter` and
/// `RideLiveActivityController`. UIKit feedback generators rather than Core Haptics:
/// two simple cues need no `CHHapticEngine` lifecycle, and the generators honor the
/// system "System Haptics" setting and no-op on hardware without a Taptic Engine, so
/// no explicit capability gate is needed.
@MainActor
final class HapticPlayer: HapticPlaying {
    static let shared = HapticPlayer()

    /// A firm, crisp tap for an imminent turn.
    private let approachGenerator = UIImpactFeedbackGenerator(style: .rigid)
    /// The distinct success rhythm for reaching the destination.
    private let arrivalGenerator = UINotificationFeedbackGenerator()
    private let log = Logger(subsystem: "app.aura.ios", category: "haptics")

    private init() {}

    func prepare() {
        approachGenerator.prepare()
        arrivalGenerator.prepare()
    }

    func play(_ cue: RideHapticCue) {
        switch cue {
        case .approach:
            approachGenerator.impactOccurred()
            approachGenerator.prepare()   // re-prime for the next turn
        case .arrival:
            arrivalGenerator.notificationOccurred(.success)
        }
        log.info("Turn haptic fired: \(String(describing: cue), privacy: .public)")
    }
}
```

- [ ] **Step 2: Regenerate the project (new app-target file)**

Run: `cd Aura && xcodegen generate`
Expected: "Created project at Aura.xcodeproj". (Do NOT commit `Aura.xcodeproj`.)

- [ ] **Step 3: Build the app (delegate to the builder subagent)**

Dispatch the `apple-platform-build-tools:builder` subagent: "Build the `Aura` scheme for the iPhone 17 simulator (`xcodebuild build -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17'`, run `cd Aura && xcodegen generate` first). Report success or the first compile error."
Expected: BUILD SUCCEEDED. (`HapticPlayer` conforms to `HapticPlaying`; the UIKit import compiles.)

- [ ] **Step 4: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/HapticPlayer.swift
git commit -m "feat(app): HapticPlayer feedback-generator shell

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Settings row + navigate-HUD wiring (app target)

**Files:**
- Modify: `Aura/Sources/Settings/SettingsView.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `SettingsStore.turnHaptics` (Task 3), `HapticPlayer.shared` (Task 4), `GuidanceViewModel.haptics`/`hapticsEnabled` (Task 2).

No new files, so no `xcodegen generate` is required; still rebuild to verify.

- [ ] **Step 1: Add the Settings toggle row**

In `Aura/Sources/Settings/SettingsView.swift`, in the `Section("Ride")` block, insert this row immediately after the "Voice guidance" row and before `HealthAccessRow()`:

```swift
                row(icon: "hand.tap.fill", tint: AuraTheme.accent, title: "Turn haptics") {
                    Toggle("", isOn: $settings.turnHaptics)
                        .labelsHidden().tint(AuraTheme.accent)
                }
```

- [ ] **Step 2: Wire the player into the navigate HUD**

In `Aura/Sources/Ride/NavigateHUDView.swift`, in the `.task` block, in the `.started` success path, change the two lines:

```swift
            guidance.units = settings.units
            guidance.start(route: route)
```

to:

```swift
            guidance.haptics = HapticPlayer.shared
            guidance.hapticsEnabled = settings.turnHaptics
            guidance.units = settings.units
            guidance.start(route: route)
```

- [ ] **Step 3: Honor a mid-ride toggle**

In `Aura/Sources/Ride/NavigateHUDView.swift`, add an `.onChange` immediately after the existing `.onChange(of: settings.units) { _, newUnits in guidance.units = newUnits }`:

```swift
        .onChange(of: settings.turnHaptics) { _, on in
            guidance.hapticsEnabled = on
        }
```

- [ ] **Step 4: Build the app (delegate to the builder subagent)**

Dispatch the `apple-platform-build-tools:builder` subagent: "Build the `Aura` scheme for the iPhone 17 simulator. Report success or the first compile error."
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/Settings/SettingsView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(app): turn-haptics Settings row + navigate-HUD wiring

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Simulator verification of the real trigger

**Files:** none (verification only).

The simulator has no Taptic Engine, so the haptic *feel* cannot be reproduced — that is a device-only confirmation boundary (like Wave 0's locked-screen recording). The *trigger* is fully verifiable from the os.Logger lines.

- [ ] **Step 1: Install the build you just produced**

Get the authoritative path: `cd Aura && xcodebuild -showBuildSettings -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' | grep -m1 TARGET_BUILD_DIR`. Install `$TARGET_BUILD_DIR/Aura.app` onto the booted iPhone 17 sim (`xcrun simctl install booted <path>`). Do not trust mtime; if a screenshot's md5 matches a prior frame, reboot the sim (`shutdown` + `boot`).

- [ ] **Step 2: Confirm the toggle defaults on and is reachable**

Launch the app; via the accessibility tree (`ui_describe_all` / `axe describe-ui`) open Settings → Ride and confirm the "Turn haptics" toggle exists and reads on by default.

- [ ] **Step 3: Drive a navigated ride with simulated movement**

Search a destination, pick a route, start guidance. Feed movement along the route:
`xcrun simctl location <udid> start --speed=9 --interval=1 <lat,lon pairs along the route>` so the guidance emits maneuvers and a final arrival. Stream the haptics log:
`xcrun simctl spawn <udid> log stream --predicate 'subsystem == "app.aura.ios" && category == "haptics"' --style compact`

- [ ] **Step 4: Confirm approach fires once per turn, arrival once**

Expected log: one `Turn haptic fired: approach` as each turn nears (≤ 150 m), and exactly one `Turn haptic fired: arrival` at the destination. Confirm no `approach` line repeats for the same turn while the rider sits at/near it (stop-and-go does not double-fire).

- [ ] **Step 5: Confirm the toggle-off path suppresses haptics**

Terminate the app, then (synthetic Toggle taps are flaky) set the pref directly:
`xcrun simctl spawn <udid> defaults write app.aura.ios turnHaptics -bool NO`
Relaunch, drive the same ride, and confirm the `haptics` log emits nothing while the ride still records and shows its summary. Restore with `defaults write app.aura.ios turnHaptics -bool YES`.

- [ ] **Step 6: Record the verification result**

Note the observed log lines (approach count per turn, single arrival, silent when off) for the PR body. If any expectation fails, stop and debug before proceeding.

---

### Task 7: Roadmap + final review

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Mark Wave 3 item 2 shipped**

In `docs/ROADMAP.md`, replace the haptics bullet under "Wave 3 — Near-term features":

```
- Haptics on turn approach and arrival, edge-triggered in the view model so they fire once
  on the false-to-true transition, gated by a settings toggle.
```

with a SHIPPED bullet in the voice of the HealthKit bullet above it (date 2026-06-27): a one-sentence summary, then the seam (`HapticPlaying`), the pure engine (`TurnHapticEngine`, once-per-key on the instruction string), UIKit feedback generators in the app target, the default-on `turnHaptics` toggle, the navigate-only scope, the new tests, and the simulator-trigger verification with the device-only feel boundary. End the Wave 3 framing by noting the next sub-project is the home + lock-screen widgets. Run the prose through the `humanizer` lens.

- [ ] **Step 2: Update the test count note**

In the "Testing" section of `docs/ROADMAP.md`, update the package test count to include the new `TurnHapticEngine` and guidance-view-model haptics suites.

- [ ] **Step 3: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark Wave 3 turn-haptics shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Final holistic review**

Run a final whole-branch review on the most capable model (per subagent-driven-development), then proceed to `finishing-a-development-branch` for the PR.

---

## Self-Review

**Spec coverage:**
- Decision 1 (approach + arrival, 150 m): Task 1 engine (threshold default 150) + Task 2 wiring. ✓
- Decision 2 (pure engine, owned by VM): Task 1 (AuraCore) + Task 2 (VM owns it). ✓
- Decision 3 (instruction-string key, once-per-key): Task 1 engine + the `sameKeyDoesNotReFireAfterRecedeAndReApproach` and `keyChangeReArmsForNextManeuver` tests. ✓
- Decision 4 (UIKit generators, not Core Haptics): Task 4 `HapticPlayer`. ✓
- Decision 5 (default-on toggle, live mid-ride): Task 3 (default true) + Task 5 (row + live `.onChange`). ✓
- Decision 6 (independent of voice/mute, not tied to Reduce Motion; system setting honored): Task 4 comment + Task 5 (separate row, no mute coupling). ✓
- CI-safety (no UIKit in package): Tasks 1–3 are package-only with no UIKit; Task 4 confines UIKit to the app. ✓
- Testing (engine suite, VM spy suite, settings test, sim trigger verification): Tasks 1, 2, 3, 6. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every command has an expected result.

**Type consistency:** `RideHapticCue` (.approach/.arrival), `TurnHapticEngine.onProgress(distanceToManeuverMeters:maneuverKey:)`/`onArrival()`, `HapticPlaying.prepare()`/`play(_:)`, `GuidanceViewModel.haptics`/`hapticsEnabled`, `SettingsStore.turnHaptics`, `HapticPlayer.shared` — used identically across Tasks 1→5 and the tests.
