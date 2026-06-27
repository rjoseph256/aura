# Aura Wave 3 — HealthKit cycling workouts: design

**Goal:** When a rider who has opted in finishes a ride, write it to Apple Health
as a cycling workout: start and end, total distance, and the GPS route drawn from
the recorded track. The write hangs off `RideSessionCoordinator.finish()` through
a new injected `WorkoutWriting` seam, so the HealthKit code lives in the app
target and the package keeps building on the macOS CI host. A "Save to Health"
toggle in Settings is the opt-in, and flipping it on is what triggers the system
authorization prompt.

**Status:** approved design, ready to plan.

## Context

Wave 3 is three near-term features in build order: HealthKit, then turn haptics,
then home and lock-screen widgets. This is the first, and it ships on its own.
The roadmap calls it the smallest blast radius of the three, and the design keeps
it that way: one new seam, one settings toggle, one entitlement, and a body of
pure mapping and gating logic that is unit-tested in the package.

The architecture has three compiled layers plus the widget extension:

- `AuraCore`: pure Swift models and protocols, no UIKit/SwiftUI/Mapbox/HealthKit.
  Builds on the macOS CI host.
- `AuraKit`: depends on `AuraCore`, may import CoreLocation, imports no SwiftUI
  and no HealthKit. Holds the observable stores (`RideRecorder`, `RideStore`,
  `SettingsStore`, `LocationService`) and the `RideSessionCoordinator`. Also
  builds on the macOS CI host, so any iOS-only API here must be `#if os(iOS)`
  guarded.
- `Aura`: the app target. SwiftUI plus the Mapbox-backed implementations and,
  now, the HealthKit implementation.
- `AuraWidgets`: the WidgetKit extension that carries the Live Activity. Untouched
  by this work.

This sub-project extends the seam pattern Wave 1 established. `RideSessionCoordinator`
already drives its app-target side effects through injected `@MainActor` protocols
(`ScreenWakeControlling`, `RideActivityControlling`, `RideSaving`); the coordinator
spec named HealthKit as one of the hooks this boundary was built for. HealthKit
becomes a fourth seam of the same shape.

### Current state, confirmed in code

- `RideSessionCoordinator` (`AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`)
  takes `screen:` and `activity:` seams at `init` and the env-derived collaborators
  (`location`, `saving`, `units`, `authorization`) at `start()`. Its `finish()` is a
  synchronous `@MainActor` method: it stops streaming, releases the screen, ends the
  activity, builds the `Ride` with `recorder.end(...)`, calls `saving?.save(ride)`
  inside a `do/catch` that sets `saveFailed`, and publishes `finishedRide`. `finish()`
  is idempotent, guarded on `recorder.isRecording`, so it runs exactly once per ride.
- The seams live in `RideSessionSeams.swift`: `ScreenWakeControlling`,
  `RideActivityControlling`, and `RideSaving`, each `@MainActor protocol … : AnyObject`,
  with `extension RideStore: RideSaving {}`.
- Both HUDs construct the coordinator the same way. `RideHUDView` uses
  `@State private var coordinator = RideSessionCoordinator(kind: .freeRide, …,
  screen: ScreenWakeController(), activity: RideLiveActivityController.shared)`;
  `NavigateHUDView` builds it in `init` with `kind: .navigate`. Both call
  `coordinator.start(location: location, saving: rideStore, units: settings.units,
  authorization: location.authorization)`.
- `RideLiveActivityController` (`Aura/Sources/LiveActivity/…`) is the template for an
  app-target seam implementation: a `@MainActor` class that wraps an iOS-only framework,
  is fire-and-forget (its `update`/`end` spawn their own `Task`), is guarded on the
  framework's availability check, and is adapted to the AuraKit protocol in a small
  `+RideActivityControlling` extension.
- `Ride` (`AuraCore/Sources/AuraCore/Models/Ride.swift`) carries `id: UUID`,
  `kind`, `startedAt`, `endedAt: Date?`, `track: [TrackPoint]`, and `stats: RideStats?`.
  `RideStats` carries `distanceMeters`. `TrackPoint` carries `coordinate`,
  `elevation: Double?`, and `timestamp`. The track is already accuracy-filtered (Wave 0),
  but the per-fix horizontal accuracy was not retained on `TrackPoint`.
- `SettingsStore` (`AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`) is an
  `@Observable` class whose stored `Bool`/enum properties mirror into `UserDefaults`
  in `didSet` and seed from `UserDefaults` in `init`. `voiceEnabled` is the model
  for a new `Bool`.
- `SettingsView` (`Aura/Sources/Settings/SettingsView.swift`) renders a `List` of
  `Section`s with a `row(icon:tint:title:control:)` helper; the voice row binds a
  `Toggle` straight to `$settings.voiceEnabled`.
- `Aura/project.yml` has no entitlements file today and no `CODE_SIGN_ENTITLEMENTS`.
  `Info.plist` (`Aura/Resources/Info.plist`, `GENERATE_INFOPLIST_FILE: NO`) declares
  the location usage strings and `UIBackgroundModes`, but nothing HealthKit.
- CI runs three jobs: package `swift test` under Swift 6, an `xcodebuild` app build
  with `CODE_SIGNING_ALLOWED=NO`, and SwiftLint `--strict`.

## Decisions settled during brainstorming

The brainstorming forks were settled with a bias toward the ambitious, high-value
choice where the risk stayed contained.

1. **Write distance and the GPS route, not energy.** A finished ride becomes an
   `HKWorkout` of type `.cycling` with a total `distanceCycling` sample and a
   `HKWorkoutRoute` reconstructed from the track. The route is the standout: it
   renders the ride on the map in Health and the Fitness app, and it reuses data
   already recorded. Active energy is deliberately out: the app measures no heart
   rate or power, so any kilocalorie figure would be fabricated, and estimating it
   from body mass would mean requesting read access we otherwise never need.
   Energy is noted as a fast-follow, not shipped here.
2. **A fourth coordinator seam, fire-and-forget, after the save.** `WorkoutWriting`
   mirrors `RideSaving`: a `@MainActor` protocol injected into the coordinator,
   called once on `finish()`. It is called *after* `saving?.save(ride)` and never
   throws back into `finish()`, so a HealthKit failure, denial, or unavailable
   store can never block or fail the ride save or the summary.
3. **Authorize at the moment of intent.** The system prompt fires when the rider
   turns the "Save to Health" toggle on, not at launch and not silently at ride
   finish. If the rider grants, future finishes write. If the rider denies or the
   store is unavailable, the toggle reverts to off and an explainer points them to
   the Health app — no silent failure, mirroring the Wave 0 permission discipline.
4. **Request write-only authorization.** The share set is exactly the workout type,
   `distanceCycling`, and the workout-route series. No read types, which keeps the
   permission sheet minimal and sidesteps an App Review over-request flag. A
   consequence: the app cannot query Health to dedupe, so idempotency comes from
   the write path being single-shot (see below).
5. **Idempotency from a single-shot write, anchored by the ride id.** Because the
   coordinator writes only at `finish()`, which runs once per ride, and there is no
   retry or backfill, a ride cannot be written twice in the normal flow. The ride's
   `id` is stamped into the workout's `HKMetadataKeyExternalUUID` (a `String`-valued
   key), so the record is traceable and a future dedup or Strava-style export has a
   stable key. (This key is for traceability, not native dedup — HealthKit only
   dedupes on `HKMetadataKeySyncIdentifier` + `HKMetadataKeySyncVersion`, which this
   feature does not set; idempotency here comes solely from the single-shot write.)
6. **A committed entitlements file wired through XcodeGen.** Unlike Wave 0, which
   needed no entitlements file, HealthKit requires `com.apple.developer.healthkit`.
   It lands as `Aura/Resources/Aura.entitlements`, generated and referenced by
   XcodeGen, with `NSHealthUpdateUsageDescription` in `Info.plist`. The entitlement
   is consumed at code-sign time, so the unsigned CI build still compiles and links.

## The seam and the pure layer

The split puts every decision and transformation that can be tested into the
package, and leaves the app-target implementation as a thin shell over HealthKit.

### `AuraCore` — pure value type, mapping, and gate

- **`WorkoutData`** — a `Sendable`, `Equatable` value type describing exactly what
  to write, with no HealthKit or CoreLocation in sight:

  ```swift
  public struct WorkoutData: Equatable, Sendable {
      public let externalID: UUID      // ride.id, for HKMetadataKeyExternalUUID
      public let start: Date
      public let end: Date
      public let distanceMeters: Double
      public let route: [TrackPoint]   // reused AuraCore model; may be empty
  }
  ```

- **`WorkoutData(from:)`** — a pure mapping from `Ride`:
  `externalID = ride.id`; `start = ride.startedAt`;
  the raw end is `ride.endedAt ?? ride.track.last?.timestamp ?? ride.startedAt`,
  then **clamped to `end = max(rawEnd, start)`** so a degenerate or clock-skewed
  ride can never produce `end < start` (which `HKWorkoutBuilder` rejects from both
  `add(samples:)` and `endCollection`); an equal `end == start` zero-duration ride
  is fine; `distanceMeters = ride.stats?.distanceMeters ?? 0`; `route = ride.track`.
  The clamp is unit-tested.
- **`RideWorkoutGate.shouldWrite(ride:saveToHealthEnabled:) -> Bool`** — the pure
  gate: write only when the toggle is on, the ride has ended (`endedAt != nil`), and
  `(ride.stats?.distanceMeters ?? 0) >= 10` (a `nil`-coalescing compare, so a
  missing-stats ride fails the floor naturally without a force-unwrap). The 10-meter
  floor keeps an accidental few-second ride from littering Health with junk workouts.
  This is the gating logic the roadmap asks to be testable.

### `AuraKit` — the protocol seam and the route reconstruction

- **`WorkoutWriting`** — added to `RideSessionSeams.swift`, the same shape as the
  other three seams:

  ```swift
  @MainActor
  public protocol WorkoutWriting: AnyObject {
      func writeWorkout(_ data: WorkoutData)
  }
  ```

  No HealthKit, no return value, no `throws`: the coordinator calls it and moves on.
- **`WorkoutRouteLocations.clLocations(from:)`** — a pure helper that turns
  `[TrackPoint]` into `[CLLocation]` for the route builder. CoreLocation is already
  an `AuraKit` dependency and `CLLocation` constructs on the macOS host, so this is
  unit-tested. It carries the real logic worth testing: it drops points with an
  invalid coordinate, synthesizes a **positive** `horizontalAccuracy` (the route
  builder rejects any location with `horizontalAccuracy <= 0`, and `TrackPoint` did
  not keep the recorded value — the helper uses `5.0` meters and the test asserts
  `> 0`, not merely `>= 0`), sets `verticalAccuracy` and `altitude` only when the
  point has an elevation (negative `verticalAccuracy` otherwise, marking altitude
  invalid), and preserves timestamp order. It uses the full designated initializer
  `CLLocation(coordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:)`.
  That initializer is iOS/macOS common, so no `#if os(iOS)` guard is needed; the
  plan's first AuraKit task confirms it compiles under the package's Swift 6 macOS
  build before the test is written, since this is the load-bearing "testable on the
  CI host" claim.

### `Aura` app target — the HealthKit shell

- **`WorkoutWriter`** — a `@MainActor final class` conforming to `WorkoutWriting`,
  the HealthKit analog of `RideLiveActivityController`. It is a **shared singleton**
  (`WorkoutWriter.shared`, `private init()`), mirroring `RideLiveActivityController.shared`,
  so the coordinator (injected at both HUDs) and the Settings row use the same
  instance and one process-global authorization state. (Authorization is global to
  the app anyway, but one instance keeps the model obvious.)
  - Holds one reused `HKHealthStore`.
  - The write share set, used everywhere: `HKWorkoutType.workoutType()`,
    `HKQuantityType(.distanceCycling)`, and `HKSeriesType.workoutRoute()`.
  - `writeWorkout(_:)` is fire-and-forget: it spawns a `Task` that guards
    `HKHealthStore.isHealthDataAvailable()` and that the workout type's share status
    is `.sharingAuthorized`, then writes with `HKWorkoutBuilder` (config `.cycling`,
    `.outdoor`) in this strict, fully-awaited order, all inside one `do/catch`:
    1. `try await builder.beginCollection(at: data.start)`
    2. `try await builder.add([distanceSample])` — one `HKQuantitySample` of
       `.distanceCycling` over `[data.start, data.end]` (`data.end >= data.start` is
       guaranteed by the clamp in `WorkoutData(from:)`)
    3. `try await builder.endCollection(at: data.end)`
    4. `let workout = try await builder.finishWorkout()` — with metadata
       `[HKMetadataKeyExternalUUID: data.externalID.uuidString]` set on the builder
       beforehand; `finishWorkout()` returns `HKWorkout?`
    5. Only if `workout != nil` **and** the reconstructed `[CLLocation]` is non-empty:
       `HKWorkoutRouteBuilder(healthStore:device:)`, `try await insertRouteData(locations)`,
       `try await finishRoute(with: workout!, metadata: nil)`.

    Any thrown error is caught and logged with `os.Logger`; nothing propagates, and
    a failure between `finishWorkout()` and `finishRoute` leaves a valid routeless
    workout (benign — see risks).
  - `requestAuthorization() async -> WorkoutAuthorizationResult` — used by Settings.
    Guards `isHealthDataAvailable()` first → `.unavailable`. Otherwise
    `try await healthStore.requestAuthorization(toShare: shareSet, read: [])` (a
    thrown error maps to `.unavailable`), then reads
    `authorizationStatus(for:)` on **both** `workoutType()` and
    `.distanceCycling` (the load-bearing sample): `.authorized` only when both are
    `.sharingAuthorized`, else `.denied`. HealthKit authorization is per-type, so the
    distance check guards against the rider granting the workout but toggling cycling
    distance off in the sheet — the toggle then stays honest rather than reporting a
    false grant. The enum maps to `HKAuthorizationStatus` `.sharingAuthorized` /
    `.sharingDenied` / `.notDetermined`.
  - `var isHealthDataAvailable: Bool` (`HKHealthStore.isHealthDataAvailable()`).
- **`WorkoutWriter+WorkoutWriting.swift`** is unnecessary; `WorkoutWriter` conforms
  directly. (The Live Activity needed an adapter only because its `start` signature
  differed; here the protocol method matches.)

### How the coordinator uses it

- `init` gains `workout: (any WorkoutWriting)? = nil`, stored alongside `screen` and
  `activity`. Optional so tests and any non-HealthKit construction pass `nil`; both
  HUDs pass `WorkoutWriter.shared` at their existing construction sites (the `@State`
  default initializer in `RideHUDView`, the `init` in `NavigateHUDView`), exactly as
  they already pass `RideLiveActivityController.shared`.
- `start(...)` gains `saveToHealth: Bool`, snapshotted into a stored property exactly
  as `units` is snapshotted — the established pattern. (The rider toggling mid-ride
  is not honored, matching how `units` is fixed at start; this is predictable and
  documented.)
- `finish()` adds one line after `finishedRide = ride`:

  ```swift
  if RideWorkoutGate.shouldWrite(ride: ride, saveToHealthEnabled: saveToHealth) {
      workout?.writeWorkout(WorkoutData(from: ride))
  }
  ```

  Placed last, so the write sees the final ride and cannot affect `saveFailed` or
  `finishedRide`.

## Authorization and privacy UX

The "Save to Health" toggle is a new `Bool` on `SettingsStore` (`saveToHealth`,
default off, persisted like `voiceEnabled`). The HealthKit behavior behind it lives
in the app target.

- **A dedicated Settings row component in the app target** owns the HealthKit
  interaction so `SettingsView` stays declarative and AuraKit stays HealthKit-free.
  It binds a `Toggle` to `settings.saveToHealth` and, on an off→on transition, calls
  `WorkoutWriter.requestAuthorization()`:
  - `.authorized` → leave the toggle on.
  - `.denied` → set `saveToHealth = false` and present an explainer.
  - `.unavailable` → set `saveToHealth = false` and present the unavailable explainer.
- **The explainer** mirrors `LocationPermissionView`: a short sheet/alert in the
  mono-lime theme explaining that Aura could not get permission to save rides to
  Health, with a button that deep-links to the Health app's data-access screen
  (`x-apple-health://` / Settings) and a dismiss. Keeping the toggle honest (off
  when we cannot write) is the anti-silent-failure stance.
- **Already-authorized re-entry.** `requestAuthorization()` is safe to call when the
  status is already determined: HealthKit returns without showing a sheet. The
  off→on handler therefore behaves correctly whether or not the prompt has been seen.
  A rare reinstall case — toggle persisted on from a prior install, status reset to
  `notDetermined`, rider never re-toggles — means rides silently will not save until
  the rider toggles again; this is acknowledged and judged acceptable for v1 rather
  than adding a launch-time re-request.
- **Copy** (run through the writing pass): the toggle title "Save rides to Health";
  the write usage string "Aura saves your finished rides to Health as cycling
  workouts, including distance and route."; the denied explainer "Aura doesn't have
  permission to save rides to Health. You can turn it on in the Health app under
  Sharing." These are finalized in the plan.

## Entitlement, Info.plist, and XcodeGen

- **`Aura/Resources/Aura.entitlements`** carries one key,
  `com.apple.developer.healthkit = true`. No background-delivery sub-capability (the
  app does no background HealthKit work) and no `com.apple.developer.healthkit.access`
  array (that is for clinical health records, not workouts).
- **`Aura/project.yml`** adds, under the `Aura` target, `CODE_SIGN_ENTITLEMENTS:
  Resources/Aura.entitlements` in `settings.base`, and an `entitlements:` block so
  XcodeGen generates the file with that one property. `Info.plist` gains
  `NSHealthUpdateUsageDescription` (write). No `NSHealthShareUsageDescription` —
  there is no read. `healthkit` is deliberately not added to
  `UIRequiredDeviceCapabilities`, so the app is not blocked from installing on any
  device (it is always present on iPhone regardless).
- **CI tolerance.** The entitlement is applied during code signing, which the app
  build skips (`CODE_SIGNING_ALLOWED=NO`). `import HealthKit` compiles against the
  SDK on the CI host, so the build stays green. This is confirmed by the build gate,
  not assumed.

## CI-safety

- `WorkoutData`, `WorkoutData(from:)`, and `RideWorkoutGate` are pure AuraCore — no
  imports beyond Foundation. Build and test on macOS.
- `WorkoutWriting` references only `WorkoutData`; `WorkoutRouteLocations` imports only
  CoreLocation, which is available on macOS. No HealthKit enters the package.
- Every HealthKit symbol (`HKHealthStore`, `HKWorkoutBuilder`, `HKWorkoutRouteBuilder`,
  `HKQuantitySample`) lives in the `Aura` app target, compiled only for iOS.
- The package's new files are auto-globbed; only the app-target additions
  (`WorkoutWriter`, the Settings row component, the explainer) and the new
  entitlements file require `xcodegen generate` in `Aura/`.

## Accessibility

This sub-project is almost entirely non-visual. The only new UI is the Settings
toggle row and the denied explainer.

- The toggle row reuses the existing `row(icon:tint:title:control:)` pattern, so it
  inherits Dynamic Type, the VoiceOver reading of an icon + title + toggle, and the
  mono-lime tint. The icon is a HealthKit-appropriate SF Symbol (`heart.fill` tinted
  with the lime accent, consistent with the other rows).
- The explainer follows `LocationPermissionView`: real text styles, a clear action
  button, and a dismissable surface. It reads correctly under VoiceOver and Dynamic
  Type.
- No motion, no contrast tokens change.

## Testing

The pure layer carries the unit tests; the seam and the real write are verified on
the simulator.

- **`AuraCore` (Swift Testing):** `WorkoutData(from:)` mapping (end-date fallback
  chain, distance from stats, route passthrough, empty-track ride); `RideWorkoutGate`
  (off blocks, ended-and-over-floor writes, under-floor blocks, missing-stats blocks).
- **`AuraKit` (Swift Testing):** `WorkoutRouteLocations.clLocations(from:)` (drops
  invalid coordinates, synthesizes a positive `horizontalAccuracy` (`> 0`), altitude/
  vertical-accuracy only when elevation is present, preserves order and timestamps);
  and an extension of the existing `RideSessionCoordinator` suite using a
  `WorkoutWriting` spy double — asserts `writeWorkout` is called once with the right
  `WorkoutData` when enabled and the ride qualifies, is not called when disabled or
  under the floor, runs after the save, and that a writer is never consulted in a way
  that changes `saveFailed`.
- **CI gates** carry the app-target code: the package tests, the `xcodebuild` build
  of the app (which proves the entitlement and `import HealthKit` compile unsigned),
  and SwiftLint `--strict` over the whole repo at every task gate.
- **Simulator verification on iPhone 17 / iOS 26** is the real-result check a clean
  build cannot give:
  - Turning on "Save rides to Health" raises the system authorization sheet.
  - Granting, then finishing an opted-in ride, writes one `.cycling` workout — read
    it back in the Health app (or via a small read-back probe) with the expected
    distance, duration, and an attached route.
  - The opt-out path (toggle off) writes nothing and the ride still saves and shows
    its summary.
  - The denied path reverts the toggle, shows the explainer, and leaves ride save
    unaffected.
  - Idempotency holds: one finished ride produces exactly one workout, not two.
  - A final holistic review runs on the most capable model.

## Risks and mitigations

- **Route builder rejects locations with invalid accuracy.** `TrackPoint` did not
  retain horizontal accuracy, so the helper synthesizes a positive value; this is
  unit-tested, and the route is verified to appear in Health on the simulator.
- **The write must never harm the ride save.** The call is last in `finish()`,
  fire-and-forget in its own `Task`, and fully wrapped in availability/auth guards
  and a `do/catch`; the coordinator test asserts the ordering and isolation.
- **A partial write is possible but benign.** If the app is killed between
  `finishWorkout()` and `finishRoute`, Health keeps a valid `.cycling` workout with
  distance and duration but no route. This is acceptable (not a duplicate, not a
  crash, not a corrupt record); it is named here rather than implying the write is
  atomic. The current flow never retries, so this cannot accumulate.
- **The entitlement could break the unsigned CI build.** It is applied at sign time,
  not compile time; the app-build gate confirms green before merge, and the design
  does not assume it.
- **App Review over-request.** The share set is the three workout-related types and
  nothing else, and there is no read request, keeping the permission sheet tight.
- **Simulator cannot prove everything HealthKit does on device** (background delivery,
  some entitlement edges), but this feature does no background work, and the write +
  read-back is fully exercisable in the simulator.

## Out of scope

- Active-energy or any estimated-calorie sample (fast-follow once a sensor or a
  defensible estimate exists).
- Reading any HealthKit data, a HealthKit-backed in-app stats view, or an Activity
  ring surface.
- Background delivery, live `HKWorkoutSession`/`HKLiveWorkoutBuilder`, or Apple Watch.
- A read-query dedup or a retro-write/backfill of rides finished before opt-in.
- Strava or third-party export (the external-UUID metadata leaves the door open).
- Any change to the widget extension, the cockpit, or the summary.

## Rough task order

1. `AuraCore`: `WorkoutData` + `WorkoutData(from:)` + `RideWorkoutGate`, TDD.
2. `AuraKit`: `WorkoutWriting` protocol in `RideSessionSeams.swift`, and
   `WorkoutRouteLocations.clLocations(from:)` with tests.
3. `AuraKit`: thread `workout:` into `RideSessionCoordinator.init` and `saveToHealth:`
   into `start()`, call the gate + seam in `finish()`, extend the coordinator suite
   with the spy.
4. `AuraCore`: `saveToHealth` on `SettingsStore`.
5. App target: `WorkoutWriter` (the HealthKit shell) + `requestAuthorization`.
6. App target: the Settings "Save rides to Health" row component, the denied/unavailable
   explainer, and wiring; pass `workout:` and `saveToHealth:` from both HUDs.
7. `project.yml` + `Aura.entitlements` + `Info.plist`; `xcodegen generate`.
8. Simulator verification (prompt, write + read-back, opt-out, denied, idempotency),
   then a final holistic review.
9. Mark Wave 3 item 1 shipped in the ROADMAP.
