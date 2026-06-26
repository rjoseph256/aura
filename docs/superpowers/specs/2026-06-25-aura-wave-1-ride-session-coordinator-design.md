# Aura Wave 1 — Ride-session coordinator design

**Goal:** Route ride start and finish through one `AuraKit` coordinator instead of
duplicating the lifecycle in both ride HUDs. After Wave 0, `RideHUDView` and
`NavigateHUDView` each repeat the same start/end sequence, the permission gate, the
screen-awake calls, the Live Activity start/update/end loop, the save, and the
`openSettings` helper. Consolidating that into `RideSessionCoordinator` removes the
duplication and gives ride completion a testable boundary that the Live Activity,
HealthKit, and haptics all hook into later.

**Status:** approved design, ready to plan.

## Context

Wave 1 is the structural-foundations wave, five sub-projects in build order: quality
gates, design system, ride-session coordinator, persistence, navigation. The first two
shipped (PRs #3 and #4). This is the third. It is a behavior-preserving refactor plus a
new testable seam, not a feature. Scope is the coordinator only. Persistence and
navigation are the next two sub-projects and stay out of this one.

The architecture has three compiled layers plus the widget extension:

- `AuraCore`: pure Swift models and protocols. Builds on the macOS CI host.
- `AuraKit`: depends on `AuraCore`, may import CoreLocation, imports no SwiftUI. Holds the
  observable stores (`RideRecorder`, `RideStore`, `SettingsStore`, `LocationService`).
  Also builds on the macOS CI host, so any iOS-only CoreLocation API must be
  `#if os(iOS)`-guarded.
- `Aura`: the app target. SwiftUI plus the Mapbox-backed implementations.
- `AuraWidgets`: the WidgetKit extension that carries the Live Activity.

Current state, confirmed in code:

- `RideHUDView` (`Aura/Sources/Ride/RideHUDView.swift`) and `NavigateHUDView`
  (`Aura/Sources/Ride/NavigateHUDView.swift`) each own a `@State RideRecorder`, a
  `streamTask`, `finishedRide`, `saveFailed`, a `startDate`/`now` pair, and a
  `showPermission` flag. Each has a `startRide()`, an idempotent `endRide()`, an
  `openSettings()`, an `onDisappear` teardown, and a `.task(id: recorder.isRecording)`
  loop that ticks `now` every 0.5 s and calls `RideLiveActivityController.shared.update`.
- The permission gate is the same check in both (`.denied`/`.restricted` shows the
  permission sheet), wired at different points: free ride gates on the Start button,
  navigate gates on appear.
- `RideRecorder`, `RideStore`, `LocationService`, `LocationStreaming`, and
  `LocationAuthorization` already live in `AuraKit`. `RideRecorder.end(at:destinationName:)`
  returns a `Ride`. `RideStore.save(_:)` throws.
- `RideScreen.keepAwake(_:)` (`Aura/Sources/Location/RideScreen.swift`) is an app-target
  enum that sets `UIApplication.shared.isIdleTimerDisabled`.
- `RideLiveActivityController` (`Aura/Sources/LiveActivity/`) is an app-target `@MainActor`
  singleton that imports ActivityKit. `RideActivityMode` lives next to its attributes in
  the app target. Its `update(stats:maneuver:)` and `end()` already take AuraKit/AuraCore
  types; only `start` takes the app-target `RideActivityMode`.
- The package, the app, and the widget build under Swift 6 with the `xcodebuild` and
  SwiftLint gates from the quality-gates sub-project. Those gates are what make this
  refactor safe to land in steps.

The central constraint: the coordinator belongs in `AuraKit` so the lifecycle becomes
unit-testable on the macOS host, but the two side effects it must drive (screen-awake via
UIKit, the Live Activity via ActivityKit) are app-target concerns that do not compile on
macOS. The coordinator reaches them through injected protocol seams. That is the same
pattern the package already uses for `LocationStreaming` and `GuidanceSession`, and it is
what makes every finish path assertable with a test double.

## Decisions

Settled with the user during brainstorming:

1. **Full lifecycle plus the Live Activity loop.** The coordinator owns start, finish,
   save, screen-awake, and the mid-ride loop (the 0.5 s elapsed tick and the throttled
   Live Activity start/update/end). Both HUDs collapse to: render the map and speed,
   call `start()`/`finish()`, bind the result. The alternative (lifecycle only, with each
   view keeping its own update loop) was rejected because it leaves loop code duplicated.
2. **Focused protocol seams.** Three small `@MainActor` protocols in `AuraKit`:
   `ScreenWakeControlling`, `RideActivityControlling`, `RideSaving`. The app conforms its
   concrete types; tests inject spies and an in-memory or throwing store. Closure injection
   and a single combined seam were both rejected: closures diverge from the codebase's
   protocol-seam convention and make spying awkward, and one combined seam conflates
   unrelated concerns and forces every double to implement the whole surface.
3. **Name `RideSessionCoordinator`.** It matches the roadmap term and stays clear of
   `RideSession`, which the Wave 4 group-ride plan reserves for a wrapper around `Ride`.
4. **Construction splits by dependency origin.** The HUD owns the coordinator as inline
   `@State`, built from the env-free pieces (kind, destination name, the two side-effect
   seams). The collaborators that come from `@Environment` (the location stream, the store,
   the units, the current authorization) arrive at `start()`. This keeps the `@State`
   initializer free of environment access and avoids an optional coordinator with a
   first-frame flash.
5. **New tests use Swift Testing.** The roadmap names Swift Testing as the framework for
   new tests. The coordinator suite is greenfield, so it adopts it. The existing XCTest
   suites are left as they are.

## Coordinator surface

`RideSessionCoordinator` is a `@MainActor @Observable final class` in
`AuraCore/Sources/AuraKit/RideSession/`. As a main-actor class it is implicitly `Sendable`,
so it takes no explicit `Sendable` conformance.

```swift
@MainActor @Observable
public final class RideSessionCoordinator {
    // Observed by the HUDs.
    public var stats: RideStats { recorder.stats }       // passthrough
    public var track: [TrackPoint] { recorder.track }    // free-ride map reads this
    public var isRecording: Bool { recorder.isRecording }
    public private(set) var elapsed: TimeInterval = 0
    public var finishedRide: Ride?                        // bound by .sheet(item:)
    public private(set) var saveFailed = false

    /// Navigate keeps this synced to its latest maneuver; free ride leaves it nil.
    public var maneuver: GuidanceUpdate?

    private let kind: Ride.Kind
    private let recorder: RideRecorder
    private let destinationName: String?
    private let screen: any ScreenWakeControlling
    private let activity: any RideActivityControlling

    // Stashed at start() for the rest of the ride.
    private var location: (any LocationStreaming)?
    private var saving: (any RideSaving)?
    private var units: DistanceUnits = .imperial
    private var startedAt: Date?
    private var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    public init(kind: Ride.Kind,
                destinationName: String?,
                screen: any ScreenWakeControlling,
                activity: any RideActivityControlling)

    public enum StartOutcome: Sendable { case started, permissionDenied }

    @discardableResult
    public func start(location: any LocationStreaming,
                      saving: any RideSaving,
                      units: DistanceUnits,
                      authorization: LocationAuthorization) -> StartOutcome

    public func finish()
    public func cancel()
}
```

The observable properties have valid defaults before `start()` runs (`stats == .zero`,
`track == []`, `isRecording == false`, `elapsed == 0`, `finishedRide == nil`,
`saveFailed == false`), so the HUD body renders the instant the view appears, before any
ride has begun.

### `start(location:saving:units:authorization:)`

Returns `.permissionDenied` when `authorization` is `.denied` or `.restricted`, with no
side effects: no recorder start, no screen-awake, no Live Activity. The view turns that
outcome into its permission sheet.

Otherwise it stashes the collaborators, records `startedAt`, starts the recorder, calls
`screen.setKeepAwake(true)`, calls `activity.start(kind:startedAt:units:destinationName:)`,
and spins two stored tasks:

- `streamTask` consumes `location.points()` into `recorder.record(_:)`.
- `tickerTask` loops every 0.5 s while recording, updates `elapsed` from `startedAt`, and
  calls the activity update. The push to the activity is factored into one private method
  so a test can call it directly without waiting on the timer.

`start()` is a no-op that returns `.started` if a ride is already recording, so a double
call cannot start two streams.

### `finish()`

Idempotent on `isRecording`: it returns immediately if no ride is recording, so the
End-ride button and a navigate arrival cannot both finish twice. When recording, it cancels
the stream and ticker, stops the location stream, calls `screen.setKeepAwake(false)`, calls
`activity.end()`, ends the recorder to produce the `Ride`, saves through `saving`, sets
`saveFailed` on a thrown error, and publishes `finishedRide`. The ride is always published
even when the save fails, which matches today's behavior (the summary still shows with a
save-failed banner).

### `cancel()`

The `onDisappear` teardown for a ride that is being abandoned rather than finished: it
cancels the stream and ticker, stops the stashed location stream, and calls
`screen.setKeepAwake(false)`. It does not save and does not publish a ride. It does not end
the Live Activity, matching today's `onDisappear`, which only ends the activity through the
finish path. If `start()` never ran, the stashed location is nil and the stop is a no-op,
which is correct: `points()` was never called, so there is nothing streaming to stop.

## The seams

Three `@MainActor` protocols in `AuraKit`:

```swift
@MainActor public protocol ScreenWakeControlling: AnyObject {
    func setKeepAwake(_ on: Bool)
}

@MainActor public protocol RideActivityControlling: AnyObject {
    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?)
    func update(stats: RideStats, maneuver: GuidanceUpdate?)
    func end()
}

@MainActor public protocol RideSaving: AnyObject {
    func save(_ ride: Ride) throws
}
```

App-side conformers:

- A small `final class ScreenWakeController: ScreenWakeControlling` whose single method sets
  `UIApplication.shared.isIdleTimerDisabled`. It replaces the `RideScreen` enum, which has
  no other callers once both HUDs route through the coordinator.
- `extension RideLiveActivityController: RideActivityControlling`. The controller's existing
  `update(stats:maneuver:)` and `end()` already satisfy the protocol. The extension adds only
  the `start(kind:startedAt:units:destinationName:)` overload, which maps `Ride.Kind` to the
  app-target `RideActivityMode` and forwards to the existing `start(mode:...)`. This keeps
  `RideActivityMode` in the app target where the ActivityKit attributes live.
- `extension RideStore: RideSaving {}`, empty, because `save(_:)` already matches.

The app injects `RideLiveActivityController.shared` and a `ScreenWakeController()` into the
coordinator at construction, and `RideStore` (from the environment) at `start()`. Tests
inject a `SpyScreenWake`, a `SpyRideActivity`, a scripted `LocationStreaming`, and an
in-memory or throwing store.

## View wiring

Each HUD owns the coordinator as inline `@State`:

```swift
@State private var coordinator = RideSessionCoordinator(
    kind: .freeRide, destinationName: nil,
    screen: ScreenWakeController(), activity: RideLiveActivityController.shared)
```

`NavigateHUDView` passes `.navigate` and the chosen destination's name. The existing
`@Environment` for `location`, `rideStore`, and `settings` is unchanged, so `AuraApp`'s
environment injection needs no edit. The seams are app values constructed in the HUD, not
new environment entries.

What each HUD keeps, because it is genuinely view-owned: the Mapbox map, the `SpeedRail`
layout, the `GPSSignalChip` (it reads `location.signal` from the environment), the summary
`.sheet(item: $coordinator.finishedRide, onDismiss: { router.screen = .plan })` and its
`RideSummaryView(saveFailed: coordinator.saveFailed)`, the permission `.sheet`, and
`RideHUDView`'s pre-recording back button. `NavigateHUDView` additionally keeps the
`GuidanceViewModel`, the mute toggle, the audio session, the speech synthesizer, and
`teardownGuidance()`.

The control flow per HUD:

- **Free ride:** the Start button calls `coordinator.start(...)`; on `.permissionDenied` it
  sets `showPermission = true`. The End button calls `coordinator.finish()`. `onDisappear`
  calls `coordinator.cancel()`.
- **Navigate:** the appear `.task` keeps its existing front matter ahead of the coordinator
  call, in order: set `isMuted` from the voice setting, configure the audio session, and wire
  `guidance.onSpeak`/`guidance.onArrive`. Then it calls `coordinator.start(...)`, and on
  `.started` it starts guidance (`guidance.start(route:)`). It keeps `coordinator.maneuver`
  synced with `.onChange(of: guidance.lastUpdate)`. A thin `endRide()` calls
  `teardownGuidance()` then `coordinator.finish()`, and `guidance.onArrive = { endRide() }`
  stays as is. `onDisappear` calls `teardownGuidance()` then `coordinator.cancel()`.

The `track` passthrough exists for the free-ride map only (`RideMapView(track:)`).
`NavigateHUDView` draws from `guidance.routeGeometry ?? route.geometry` and does not read it,
so the rewire leaves navigate's map binding as it is rather than pointing it at the
coordinator.

The duplicated `openSettings()` becomes one app-target helper that both permission sheets
call.

## Behavior preservation

This is a refactor. The observable behavior of both rides stays the same, with the moving
parts relocated into the coordinator.

| Concern | Before | After |
|---|---|---|
| Permission gate | free ride on tap, navigate on appear | both call `start(authorization:)`, which returns `.permissionDenied`; the view shows the same sheet |
| Live Activity start | free ride inside `startRide`, navigate in `.task` after start | inside `start()` right after the recorder starts; destination name flows through `init` |
| Mid-ride loop | each HUD's `.task(id:)` ticks `now` and calls `update` | the coordinator's `tickerTask`; navigate syncs `coordinator.maneuver` from `guidance.lastUpdate` |
| Finish | idempotent `endRide()`, navigate also tears down guidance | view `endRide()` is `teardownGuidance(); finish()`; free ride calls `finish()` |
| `onDisappear` | cancel stream, stop location, release screen, (navigate) tear down guidance | `coordinator.cancel()`, plus `teardownGuidance()` in navigate |
| Summary and routing | `.sheet(item: $finishedRide, onDismiss:)`, `saveFailed` | identical, bound to `$coordinator.finishedRide` and `coordinator.saveFailed` |
| GPS chip, back button | view-owned | unchanged |

One intentional equivalence: an abandoned-before-start free ride currently calls
`location.stop()` in `onDisappear`. After the refactor `cancel()` stops only the stashed
location, which is nil when `start()` never ran. Either way the call is a no-op, because the
location stream was never started.

## Testing and verification

New Swift Testing suite, `RideSessionCoordinatorTests`, in the AuraKit test target. Doubles:
`SpyScreenWake` and `SpyRideActivity` record their calls and arguments; a scripted
`LocationStreaming` yields a fixed set of points then finishes (or `SimulatedLocationProvider`
over a short `GPXTrack`); `RideStore.inMemory()` is the real store for the happy path; a
`ThrowingRideSaving` forces the save-failure branch. Cases:

- Denied or restricted authorization returns `.permissionDenied`, leaves the recorder
  stopped, and makes no screen-awake or activity-start call.
- Authorized start returns `.started`, starts the recorder, calls `setKeepAwake(true)`, and
  calls `activity.start` with the right kind, units, and destination name.
- Streamed points accumulate into `stats`.
- `finish()` ends the recorder, leaves the ride in the store, calls `activity.end()` and
  `setKeepAwake(false)`, publishes `finishedRide`, and clears `isRecording`.
- A second `finish()` is a no-op and saves only once.
- A throwing save sets `saveFailed` and still publishes `finishedRide`.
- `cancel()` before finish calls `setKeepAwake(false)`, saves nothing, and publishes no ride.
- Setting `maneuver` flows it into `activity.update`, asserted by calling the factored push
  method directly rather than waiting on the 0.5 s timer.

Gates, green at every commit, delegated to the `apple-platform-build-tools:builder` so the
logs stay out of the working context:

- `cd AuraCore && swift test` on the macOS host. The coordinator and seams use only
  cross-platform AuraKit and AuraCore types, so no `#if os(iOS)` guard is needed in the new
  code. Confirm that `LocationAuthorization` stays free of platform-only cases at the use
  sites the coordinator touches (`.denied`, `.restricted`, the default path).
- `xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`,
  which also compiles `AuraWidgets`. Run `xcodegen generate` first only if `project.yml`
  changes. New files land under already-globbed directories, so a change is unlikely; the
  new app-target files go under `Aura/Sources/`, and the new package files are picked up by
  the package automatically.
- `./scripts/lint.sh` from the repo root, SwiftLint pinned to 0.64.1.
- A simulator smoke test of both flows on the iPhone 17 / iOS 26.3 simulator: a free-ride
  record to summary, and a navigate arrival to summary. Verify through the accessibility
  tree per the text-before-pixels rule, and reboot the simulator before trusting a pixel
  capture if the screenshot md5 matches the prior frame.

## Risks and mitigations

- **A behavior drifts during the move.** The refactor touches the live ride path, which the
  package tests do not cover end to end. Mitigation: the new coordinator suite covers the
  lifecycle, and the simulator smoke test covers both real flows before the PR.
- **The Live Activity stops updating.** If the navigate maneuver sync or the ticker is
  wired wrong, the Lock Screen turn could freeze. Mitigation: a coordinator test asserts the
  maneuver reaches `activity.update`, and the smoke test watches a navigate ride.
- **The macOS package build breaks on a platform-only type.** Mitigation: the coordinator
  is written against cross-platform types only, and `swift test` on the macOS host is the
  compile check that catches a slip.
- **Double-finish or double-start.** Mitigation: both are guarded on `isRecording` and
  covered by tests.

## Out of scope

- Persistence and navigation, which are the next two Wave 1 sub-projects. The coordinator
  saves through the existing `RideStore` and does not touch the schema or the router.
- HealthKit and haptics. The coordinator is the seam they hook into later; this sub-project
  does not add them.
- Any change to the HUD visuals. The mono-lime design system from PR #4 is reused as is.
- App-target tests. The app target still has no test target; the new tests live in the
  package, where the coordinator now lives.

## Rollout order

The plan sequences the work so each change set is small and independently verifiable. The
detailed task breakdown is the writing-plans step's job; this is the shape:

1. The three seams in `AuraKit` and the app-side conformers (`ScreenWakeController`, the
   `RideLiveActivityController` extension, the `RideStore` extension).
2. `RideSessionCoordinator` plus the Swift Testing suite, test-first.
3. Rewire `RideHUDView` onto the coordinator.
4. Rewire `NavigateHUDView` onto the coordinator, including the maneuver sync and the thin
   `endRide()`.
5. Fold the duplicated `openSettings()` into one helper and delete the `RideScreen` enum.
6. Update `docs/ROADMAP.md` to mark the sub-project shipped.

Commits follow the repo conventions: `feat(core)`/`refactor(core)` for the package,
`refactor(app)` for the app, staging only the files each task names, never
`AuraCore/Package.resolved` or the generated `Aura.xcodeproj`. The branch ships through a
PR into `main` like #3 and #4, after CI is green, with a reconcile of local `main` to
`origin/main`.
