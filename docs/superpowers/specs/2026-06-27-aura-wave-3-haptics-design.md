# Aura Wave 3 — Turn haptics: design

**Goal:** During a navigated ride, the phone gives the rider a haptic nudge as a
turn nears and a distinct one when they reach the destination. Each fires exactly
once per maneuver, on the moment the condition first becomes true, gated by a
"Turn haptics" Settings opt-in. The decision of *when* to fire is pure, lives in
the package, and is unit-tested; the act of *playing* a haptic lives in the app
target behind a new `HapticPlaying` seam, so the package keeps building on the
macOS CI host.

**Status:** approved design (built autonomously), ready to plan.

## Context

Wave 3 is three near-term features in build order: HealthKit, then turn haptics,
then home and lock-screen widgets. HealthKit shipped as PR #12 (main `7faadac`).
This is the second, and it ships on its own.

The architecture has three compiled layers plus the widget extension:

- `AuraCore`: pure Swift models and protocols, no UIKit/SwiftUI/Mapbox/UIKit
  feedback generators. Builds on the macOS CI host.
- `AuraKit`: depends on `AuraCore`, may import CoreLocation, imports no SwiftUI and
  no UIKit. Holds the observable stores and view models (`GuidanceViewModel`,
  `SettingsStore`, `RideSessionCoordinator`). Also builds on macOS, so any iOS-only
  API here must be `#if os(iOS)` guarded.
- `Aura`: the app target. SwiftUI plus the Mapbox-backed implementations and, now,
  the UIKit-feedback-generator implementation.
- `AuraWidgets`: the WidgetKit extension. Untouched by this work.

This sub-project extends two patterns Wave 1/3 established: the guidance event
pipeline (a pure `GuidanceUpdate`/`GuidanceEvent` stream that `GuidanceViewModel`
consumes, with `ScriptedGuidanceSession` driving it in tests) and the injected
`@MainActor` seam (the HealthKit `WorkoutWriting` protocol is the live template for
an app-target side effect kept out of the package).

### Current state, confirmed in code

- `GuidanceUpdate` (`AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift`)
  carries `distanceToManeuverMeters` (decoded by `MapboxGuidanceSession` from
  `currentStepProgress.distanceRemaining` — the distance to the upcoming maneuver),
  `instruction` (the upcoming maneuver text, e.g. "Right onto Penn Ave"), and the
  three cruising fields. There is no maneuver id in the stream.
- `GuidanceEvent` is the discrete event enum: `.progress(GuidanceUpdate)`,
  `.spokenInstruction`, `.arrivedAtDestination`, `.rerouting`, `.rerouted`.
  Arrival is one event, emitted by `MapboxGuidanceSession` from
  `waypointsArrival` → `ToFinalDestination`.
- `GuidanceViewModel` (`AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift`,
  `@Observable @MainActor`) owns the stream. Its `run(route:)` switches on each
  event: `.progress` updates `turn`/`lastUpdate`; `.arrivedAtDestination` calls
  `onArrive()` and returns. It already carries `@ObservationIgnored` view-set hooks
  (`onSpeak`, `onArrive`) and a `units` setting, so adding more of the same shape is
  the established idiom.
- `TurnCardPresenter` (`AuraCore/Sources/AuraKit/TurnCardPresenter.swift`) expands
  the turn card — grows it and shifts it to the solid lime fill — when
  `distanceToManeuverMeters <= expandWithinMeters`, default **150**. That is the
  existing "the turn is imminent" threshold this feature reuses.
- `NavigateHUDView` (`Aura/Sources/Ride/NavigateHUDView.swift`) owns the
  `GuidanceViewModel`, wires `onSpeak`/`onArrive` in `.task` before
  `guidance.start(route:)`, sets `guidance.units` from `settings.units` (in `.task`
  and an `.onChange`), and ends the ride through `endRide()` →
  `teardownGuidance(); coordinator.finish()`. Free-ride `RideHUDView` has no
  guidance and no turns.
- `SettingsStore` (`AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`) is an
  `@Observable` class whose `Bool`/enum properties mirror into `UserDefaults` in
  `didSet` and seed from `UserDefaults` in `init`. `voiceEnabled` (default true) is
  the model for a new defaulted-on `Bool`.
- `SettingsView` (`Aura/Sources/Settings/SettingsView.swift`) renders the Voice
  guidance row as a plain `row(icon:tint:title:)` with a `Toggle` bound straight to
  `$settings.voiceEnabled`. No authorization, no custom component.
- CI runs three jobs: package `swift test` under Swift 6, an `xcodebuild` app build
  with `CODE_SIGNING_ALLOWED=NO`, and SwiftLint `--strict`.

## Decisions settled during brainstorming

The forks were settled toward the high-value choice while keeping the risk
contained, and grounded in the `swiftui-patterns` and `ios-accessibility` skills
rather than recalled API.

1. **One approach event plus arrival, not a multi-stage countdown.** A single
   approach haptic fires when `distanceToManeuverMeters` first reaches the approach
   threshold, and a distinct arrival haptic fires on `arrivedAtDestination`. The
   approach threshold defaults to **150 m**, matching `TurnCardPresenter`'s expand
   threshold, so the buzz lands at the exact moment the rider sees the turn card
   grow and turn lime — one coherent "imminent" moment across the haptic and visual
   channels. This is the literal roadmap ask ("turn approach and arrival"). The
   threshold is a named constant, so a multi-stage countdown ("get ready" then
   "turn now") is a clean fast-follow on the same engine rather than a redesign.
2. **The edge-trigger lives in a pure `TurnHapticEngine` value type, owned by the
   view model.** The roadmap says "edge-triggered in the view model"; the
   architecture rule says the threshold logic must be pure and tested in the
   package. Both hold: `GuidanceViewModel` owns a `TurnHapticEngine` (a pure
   `AuraCore` struct) and feeds each event to it, but every decision about whether
   to fire lives in the engine, where a Swift Testing suite drives it with no
   Mapbox and no UIKit.
3. **Keying "current maneuver" on the instruction string; fire once per key.** The
   stream has no maneuver id, so the engine keys the current maneuver on
   `GuidanceUpdate.instruction` and remembers the key it last fired an approach for.
   Once it fires for a key, it never fires again for that key, so a maneuver buzzes
   exactly once no matter how its distance behaves afterward. This matters because
   Mapbox's `currentStepProgress.distanceRemaining` is recomputed every fix and is
   *not* monotonic — it rises when the rider stops or the position re-snaps — so a
   model that re-armed on a receding distance would re-fire the same turn on a
   stop-and-go ride. Keying the once-only guard to the maneuver itself avoids that
   entirely and needs no hysteresis band. Re-arming happens only when the key changes
   (a genuinely new maneuver). The one cost is that two consecutive steps that share
   byte-identical instruction text would get a single buzz; a missed buzz is benign,
   whereas a double buzz or a wrong-time buzz is not, and the design biases against
   the latter.
4. **UIKit feedback generators behind the seam, not Core Haptics.** The trigger
   originates in `GuidanceViewModel` consuming an async event stream — a non-view,
   imperative integration point. The `swiftui-patterns` skill calls for UIKit
   feedback generators (centralized in a `HapticManager`) for exactly this case,
   and reserves Core Haptics for custom patterns that exceed the built-in feedback
   types. Two simple cues do not need a `CHHapticEngine` and its start/stop/reset
   lifecycle, audio-session coupling, and restart-after-interruption handling. The
   approach is a `UIImpactFeedbackGenerator(style: .rigid)` impact; the arrival is a
   `UINotificationFeedbackGenerator` `.success`, a distinct rhythm so the two read
   apart by feel.
5. **A new "Turn haptics" toggle, default on, with no permission flow.** Haptics
   need no authorization, so unlike the HealthKit row this is a plain Settings
   toggle bound straight to the store, mirroring Voice guidance. It defaults on,
   like Voice guidance: it is an expected navigation affordance and non-destructive.
   It is honored live mid-ride (the rider can flip it and the next turn obeys),
   matching how `units` is live, not snapshotted. One asymmetry is accepted: voice
   has an in-ride kill switch (the mute button) while haptics are controlled only
   from Settings (decision 6 keeps them off the mute button), so a rider who wants
   them off mid-ride uses Settings. That is a deliberate trade to keep haptics as the
   silent channel.
6. **Haptics are independent of voice and the mute button, and not tied to Reduce
   Motion.** A rider who mutes voice — riding to music — still benefits from a
   silent nudge; haptics are most valuable precisely when voice is off. So the
   toggle is independent of `voiceEnabled` and of the in-ride mute (which stays
   voice-only). The `ios-accessibility` skill lists the system preferences to honor
   (Reduce Motion, Reduce Transparency, Increase Contrast, Bold Text); haptics is
   not among them and there is no "reduce haptics" flag, and Reduce Motion governs
   animation, not haptics. The control surface is this toggle plus the system
   Settings → Sounds & Haptics → System Haptics switch, which `UIFeedbackGenerator`
   honors natively (it no-ops when the system setting is off or the hardware lacks a
   Taptic Engine), so no explicit capability gate is needed.

## The seam and the pure layer

The split puts every decision into the package and leaves the app-target
implementation a thin shell over the feedback generators.

### `AuraCore` — the cue and the edge-trigger engine

- **`RideHapticCue`** — a tiny `Equatable, Sendable` enum naming what to play:

  ```swift
  public enum RideHapticCue: Equatable, Sendable {
      case approach   // a turn is imminent
      case arrival    // reached the destination
  }
  ```

- **`TurnHapticEngine`** (`AuraCore/Sources/AuraCore/Guidance/TurnHapticEngine.swift`)
  — a pure, deterministic value type. No Foundation type beyond `Double`/`String`;
  no CoreLocation, no UIKit. It remembers the maneuver key it last fired an approach
  for and the arrival flag, and returns a cue to fire, or `nil`:

  ```swift
  public struct TurnHapticEngine {
      private let approachWithinMeters: Double   // fire at/under this
      private var firedApproachKey: String?      // key we already buzzed for
      private var arrivalFired = false

      public init(approachWithinMeters: Double = 150) {
          self.approachWithinMeters = approachWithinMeters
      }

      /// Feed one progress update. Returns `.approach` exactly once per maneuver:
      /// the first update for a not-yet-fired key that is within the threshold.
      public mutating func onProgress(distanceToManeuverMeters: Double,
                                      maneuverKey: String) -> RideHapticCue? {
          guard maneuverKey != firedApproachKey else { return nil }   // already buzzed this turn
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

  Once `onProgress` fires for a key, every later update for that same key returns
  `nil`, so the buzz is once-per-maneuver regardless of how the (non-monotonic)
  distance moves afterward — no hysteresis band needed. A different key (a new
  maneuver, or the end-of-route flip from the upcoming step to the current step) is
  eligible to fire again, so the final maneuver can buzz approach and then arrival
  (two distinct cues), which is intended. The 150 m default is documented as
  matching `TurnCardPresenter.expandWithinMeters`; the two are kept independently
  defaulted rather than sharing one symbol, because `expandWithinMeters` is a
  presenter default argument, not a public constant.

### `AuraKit` — the seam and the view-model wiring

- **`HapticPlaying`** (`AuraCore/Sources/AuraKit/Guidance/HapticPlaying.swift`) — a
  `@MainActor` protocol of the same shape as the other seams, referencing only the
  pure `RideHapticCue`. Unlike the coordinator seams (which sit together in
  `RideSessionSeams.swift`), this one is guidance-scoped — driven by
  `GuidanceViewModel`, not `RideSessionCoordinator` — so it lives next to the view
  model in `Guidance/`:

  ```swift
  @MainActor
  public protocol HapticPlaying: AnyObject {
      func prepare()
      func play(_ cue: RideHapticCue)
  }
  ```

  `prepare()` warms the generators to cut first-tap latency; `play(_:)` takes the
  cue so the view model forwards whatever the engine returns. A single enum-typed
  method (rather than `turnApproaching()`/`arrived()`) means a future multi-stage
  cue is a new enum case, not a protocol and implementation signature change.

- **`GuidanceViewModel`** gains three `@ObservationIgnored` members and feeds the
  engine inside `run`:
  - `public var haptics: (any HapticPlaying)?` — injected by the view; `nil` in
    existing tests, so they are unaffected.
  - `public var hapticsEnabled: Bool = false` — set from `settings.turnHaptics`,
    live like `units`. The default `false` keeps existing tests silent.
  - `private var hapticEngine = TurnHapticEngine()` — the pure engine.
  - `start(route:)` calls `haptics?.prepare()` once (the view sets `haptics` before
    calling `start`, exactly as it sets `onSpeak`/`onArrive`).
  - In `run`, the `.progress` case, after updating `turn`/`lastUpdate`:

    ```swift
    let cue = hapticEngine.onProgress(
        distanceToManeuverMeters: update.distanceToManeuverMeters,
        maneuverKey: update.instruction)
    if hapticsEnabled, let cue { haptics?.play(cue) }
    ```

  - In the `.arrivedAtDestination` case, before `onArrive()`:

    ```swift
    let cue = hapticEngine.onArrival()
    if hapticsEnabled, let cue { haptics?.play(cue) }
    onArrive()
    return
    ```

    The engine is fed whether or not haptics are enabled, so its edge state stays
    coherent if the rider toggles mid-ride; only the `play` is gated. The arrival
    haptic is played before `onArrive()` (which tears the session down) so the call
    is never dropped.

### `Aura` app target — the feedback-generator shell

- **`HapticPlayer`** (`Aura/Sources/Ride/HapticPlayer.swift`, new) — a
  `@MainActor final class HapticPlaying` conforming type, the haptics analog of
  `RideLiveActivityController`/`WorkoutWriter`: a shared singleton
  (`HapticPlayer.shared`, `private init()`) holding two reused generators.

  ```swift
  import UIKit
  import os
  import AuraCore
  import AuraKit

  @MainActor
  final class HapticPlayer: HapticPlaying {
      static let shared = HapticPlayer()
      private let approachGenerator = UIImpactFeedbackGenerator(style: .rigid)
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
              approachGenerator.prepare()    // re-prime for the next turn
          case .arrival:
              arrivalGenerator.notificationOccurred(.success)
          }
          log.info("Turn haptic fired: \(String(describing: cue), privacy: .public)")
      }
  }
  ```

  The `log.info` line is the instrumentation the simulator verification greps: the
  simulator has no Taptic Engine, so the *feel* cannot be reproduced, but the fire
  can be confirmed from the log. The `.rigid` impact and `.success` notification are
  sensible defaults and the device-tuning knobs; the feel itself is a device-only
  confirmation boundary (like Wave 0's locked-screen recording).

### How the HUD uses it

- `NavigateHUDView.task`, in the `.started` success path (alongside the existing
  `guidance.units = settings.units` / `guidance.start(route:)` lines, so the
  generators are only warmed when a ride actually starts — the permission-denied
  early return never reaches it):

  ```swift
  guidance.haptics = HapticPlayer.shared
  guidance.hapticsEnabled = settings.turnHaptics
  guidance.units = settings.units
  guidance.start(route: route)   // start() calls haptics?.prepare() once
  ```

- A live toggle, mirroring the existing `units` `.onChange`:

  ```swift
  .onChange(of: settings.turnHaptics) { _, on in guidance.hapticsEnabled = on }
  ```

  No change to `RideHUDView` (free ride has no turns), `RideSessionCoordinator`, or
  the widget extension.

## Settings and accessibility

- **`SettingsStore.turnHaptics`** — a new `Bool`, default `true`, persisted under
  the key `"turnHaptics"` exactly like `voiceEnabled` (`didSet` mirror, seeded with
  `defaults.object(forKey:) as? Bool ?? true`).
- **The Settings row** is added to `SettingsView`'s "Ride" section right after Voice
  guidance, using the existing `row(icon:tint:title:)` helper:

  ```swift
  row(icon: "hand.tap.fill", tint: AuraTheme.accent, title: "Turn haptics") {
      Toggle("", isOn: $settings.turnHaptics)
          .labelsHidden().tint(AuraTheme.accent)
  }
  ```

  It inherits the row's Dynamic Type, the mono-lime tint, and the VoiceOver reading
  of icon + title + toggle. The label "Turn haptics" is speakable and unique for
  Voice Control. `hand.tap.fill` reads as a tap/haptic and sits in the lime accent
  with the other rows. No new palette, no motion, no contrast tokens change.
- The toggle is a plain preference: no authorization, no explainer, no async work,
  so no dedicated component (unlike `HealthAccessRow`).

## CI-safety

- `RideHapticCue` and `TurnHapticEngine` are pure `AuraCore` (no import beyond what
  `Double`/`String` need). Build and test on macOS.
- `HapticPlaying` references only `RideHapticCue`; no UIKit enters the package. No
  `#if os(iOS)` guard is needed anywhere in the package for this feature.
- Every UIKit feedback-generator symbol lives in the `Aura` app target, compiled
  for iOS only.
- The package's new files are auto-globbed. Only the one app-target file add
  (`HapticPlayer.swift`) requires `xcodegen generate` in `Aura/`; the `SettingsView`
  and `NavigateHUDView` edits touch existing files.

## Testing

The pure layer carries the unit tests; the seam and the real trigger are verified
on the simulator.

- **`AuraCore` (Swift Testing) — `TurnHapticEngineTests`:**
  - approach fires once on the crossing under the threshold (e.g. 200 → 160 → 140
    fires at 140);
  - approach does not fire while above the threshold;
  - approach fires immediately when the first update for a maneuver is already under
    the threshold;
  - no double fire across several sub-threshold updates for the same maneuver;
  - a key change (new instruction) re-arms, so the next maneuver fires;
  - once-per-key: after firing, the same key never fires again even when the distance
    recedes far and re-approaches (e.g. 140 fires, then 185, then 130 → a single
    approach), proving the stop-and-go / re-snap case does not double-fire;
  - arrival fires once and a second `onArrival()` returns `nil`;
  - approach and arrival both fire (distinct) for the final maneuver.
- **`AuraKit` — `GuidanceViewModel` haptics**, in a *new* Swift Testing file (the
  existing `GuidanceViewModelTests` is XCTest; new suites use Swift Testing per the
  established convention), driving the model with a `ScriptedGuidanceSession` and a
  `HapticPlaying` spy via the same `await vm.run(route:)` pattern the XCTest suite
  uses:
  - enabled: a script `[progress(200), progress(140), arrived]` makes the spy record
    `[.approach, .arrival]`;
  - disabled (`hapticsEnabled = false`): the same script records nothing;
  - no double fire across repeated sub-threshold progress;
  - `prepare()` is called once when `start` runs.
- **CI gates** carry the app-target code: the package tests, the `xcodebuild` build
  (which proves `HapticPlayer` and the UIKit import compile), and SwiftLint
  `--strict` over the whole repo at every task gate.
- **Simulator verification on iPhone 17 / iOS 26** is the real-trigger check a clean
  build cannot give. The simulator cannot reproduce the haptic sensation, so the
  trigger is verified instead: drive a real navigate ride (search a destination,
  pick a route, start guidance, feed movement with
  `xcrun simctl location <udid> start …` along the route so the guidance emits
  maneuvers and arrival), then confirm from the `haptics` os.Logger lines (and the
  a11y tree) that the approach fires once as a turn nears, the arrival fires once on
  arrival, toggling the setting off suppresses both, and neither double-fires. A
  final holistic review runs on the most capable model.

## Risks and mitigations

- **No maneuver id in the stream.** Keying on the instruction string is the
  available identity. Its one failure — two consecutive steps with byte-identical
  instruction text getting a single buzz — is benign and unit-tested. At the end of
  the route the key flips from the upcoming step to the current step; that extra key
  change can let the final approach buzz fire just before arrival, which is the
  intended "approach then arrival" pair, not a bug.
- **Non-monotonic maneuver distance could double-fire.** `currentStepProgress`'s
  remaining distance rises when the rider stops or the position re-snaps. The
  once-per-key guard means a turn that has already buzzed never buzzes again no
  matter how its distance moves, so stop-and-go riding cannot double-fire. Unit-tested
  (the recede-and-re-approach case).
- **The haptic must never affect the ride.** The engine is pure and the `play` call
  is a fire-and-forget UIKit no-op-on-unsupported-hardware call off the guidance
  loop; it touches no ride or save state.
- **Simulator cannot prove the feel.** The trigger is fully verifiable from logs;
  the sensation is a device-only boundary, named not assumed.

## Out of scope

- A multi-stage countdown (a second "turn now" cue closer in) — a fast-follow on the
  same engine and threshold constant.
- Custom Core Haptics patterns or AHAP files.
- Haptics on free-ride events (there are no turns), reroute, or GPS-weak.
- Per-event intensity preferences or a separate arrival toggle.
- Any change to `RideSessionCoordinator`, the widget extension, the cockpit layout,
  or the summary.

## Rough task order

1. `AuraCore`: `RideHapticCue` + `TurnHapticEngine`, TDD.
2. `AuraKit`: `HapticPlaying` protocol; thread `haptics`/`hapticsEnabled`/the engine
   into `GuidanceViewModel`, call `prepare()` in `start`, fire in `run`; extend the
   guidance tests with the spy.
3. `AuraCore`: `turnHaptics` on `SettingsStore`.
4. App target: `HapticPlayer` (the feedback-generator shell) with os.Logger
   instrumentation.
5. App target: the "Turn haptics" Settings row; wire `haptics`/`hapticsEnabled` and
   the live `.onChange` into `NavigateHUDView`; `xcodegen generate`.
6. Simulator verification (approach fires once, arrival fires once, toggle-off
   suppresses, no double-fire), then a final holistic review.
7. Mark Wave 3 item 2 shipped in the ROADMAP.
