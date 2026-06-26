# Ride-session coordinator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route ride start and finish through one `RideSessionCoordinator` in `AuraKit`, removing the duplicated lifecycle in both ride HUDs and giving ride completion a unit-tested boundary.

**Architecture:** A `@MainActor @Observable` coordinator owns the recorder, the location stream, the permission-gate decision, screen-wake, the Live Activity start/update/end loop, the save, and the finished-ride result. It reaches the two app-target side effects (screen-wake via UIKit, the Live Activity via ActivityKit) and the store through three injected `@MainActor` protocol seams, so the whole lifecycle compiles and tests on the macOS CI host. Each HUD owns the coordinator as `@State`, built from env-free pieces at init, with the environment-derived collaborators handed in at `start()`.

**Tech Stack:** Swift 6 / Xcode 26, SwiftUI, the local `AuraCore` SwiftPM package (`AuraCore` + `AuraKit`), ActivityKit (app target only), Swift Testing for the new suite, XcodeGen, SwiftLint 0.64.1.

**Spec:** `docs/superpowers/specs/2026-06-25-aura-wave-1-ride-session-coordinator-design.md`

---

## Conventions for every task

- **Builds and tests are delegated** to the `apple-platform-build-tools:builder` subagent so verbose logs stay out of context. The exact commands are given per task; hand them to the builder and act on its pass/fail summary.
- **Package tests:** `cd AuraCore && swift test` (optionally `--filter RideSessionCoordinatorTests` while iterating). Runs on the macOS host under Swift 6 language mode.
- **App build:** `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. This compiles the app and the embedded `AuraWidgets`. No `xcodegen generate` is needed: every new file lands under an already-globbed directory (`AuraCore/Sources/AuraKit/**` is picked up by SwiftPM; the app target globs `Aura/Sources/**`). `project.yml` is not edited in this plan, so do not run `xcodegen` unless a step says so.
- **Lint:** `./scripts/lint.sh` from the repo root (SwiftLint 0.64.1, `--strict`, merges the nested test config).
- **Git hygiene:** stage only the files each task names. Never `git add AuraCore/Package.resolved` (if a build dirties it, `git checkout -- AuraCore/Package.resolved`). Never commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored; copy the `pk.…` token in from the primary checkout if the app build reports it missing). End every commit message with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.
- **Keep green:** the package tests, the app build, and lint pass at the end of every task that touches their inputs.

## File structure

**Created (package, `AuraCore/Sources/AuraKit/RideSession/`):**
- `RideSessionSeams.swift` — the three `@MainActor` protocols (`ScreenWakeControlling`, `RideActivityControlling`, `RideSaving`) plus `extension RideStore: RideSaving {}`.
- `RideSessionCoordinator.swift` — the coordinator.

**Created (package tests, `AuraCore/Tests/AuraKitTests/`):**
- `RideSessionCoordinatorTests.swift` — the Swift Testing suite and its doubles.

**Created (app target):**
- `Aura/Sources/Location/ScreenWakeController.swift` — `ScreenWakeControlling` conformer (replaces `RideScreen`).
- `Aura/Sources/Location/RideSettingsLink.swift` — the shared `openSettings` helper.
- `Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift` — the `RideActivityControlling` conformance.

**Modified:**
- `Aura/Sources/Ride/RideHUDView.swift` — rewired onto the coordinator.
- `Aura/Sources/Ride/NavigateHUDView.swift` — rewired onto the coordinator.
- `docs/ROADMAP.md` — mark the sub-project shipped.

**Deleted:**
- `Aura/Sources/Location/RideScreen.swift` — no callers once both HUDs use the coordinator.

---

## Task 1: Seams in AuraKit + RideStore conformance

**Files:**
- Create: `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift` (created here, grown in Task 2)

- [ ] **Step 1: Write a failing test that `RideStore` is usable as `any RideSaving`**

Create `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct RideSessionCoordinatorTests {
    private func ride(_ t: TimeInterval) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: t),
             endedAt: Date(timeIntervalSince1970: t + 1), track: [], stats: .zero,
             routeId: nil, destinationPlaceId: nil)
    }

    @Test func rideStoreConformsToRideSaving() throws {
        let store = try RideStore.inMemory()
        let saving: any RideSaving = store
        try saving.save(ride(100))
        #expect(try store.allRides().count == 1)
    }
}
```

- [ ] **Step 2: Run it to verify it fails to compile**

Delegate to the builder: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: FAIL — `cannot find type 'RideSaving' in scope`.

- [ ] **Step 3: Create the seams file**

Create `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift`:

```swift
import Foundation
import AuraCore

/// Keeps the display awake while a ride records. The app conforms a UIKit-backed type;
/// the package stays free of UIKit so it builds on the macOS CI host.
@MainActor
public protocol ScreenWakeControlling: AnyObject {
    func setKeepAwake(_ on: Bool)
}

/// Drives the in-progress-ride Live Activity. The app conforms its ActivityKit-backed
/// controller; the package never imports ActivityKit. `start` takes `Ride.Kind` rather
/// than the app-target `RideActivityMode`, which the conformer maps.
@MainActor
public protocol RideActivityControlling: AnyObject {
    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?)
    func update(stats: RideStats, maneuver: GuidanceUpdate?)
    func end()
}

/// Persists a finished ride. `RideStore` already satisfies it; tests inject an
/// in-memory or throwing double.
@MainActor
public protocol RideSaving: AnyObject {
    func save(_ ride: Ride) throws
}

extension RideStore: RideSaving {}
```

- [ ] **Step 4: Run the test to verify it passes**

Delegate to the builder: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: PASS (1 test).

- [ ] **Step 5: Full package test run**

Delegate to the builder: `cd AuraCore && swift test`
Expected: PASS, 116 tests (115 existing + 1 new).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift \
        AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift
git commit -m "feat(core): add ride-session side-effect seams

ScreenWakeControlling, RideActivityControlling, RideSaving in AuraKit, with
RideStore conforming to RideSaving. The coordinator reaches the two app-target
side effects and the store through these so the lifecycle stays macOS-buildable
and testable.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: RideSessionCoordinator + Swift Testing suite

Test-first. Add the doubles, then one behavior at a time. The coordinator is written once (Step 3) and the remaining steps add tests against it; if a test fails, fix the coordinator, not the test.

**Files:**
- Create: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift` (extend)

- [ ] **Step 1: Add the test doubles to the suite file**

Append to `RideSessionCoordinatorTests.swift`, below the existing `@Test`:

```swift
// MARK: - Doubles

@MainActor
final class SpyScreenWake: ScreenWakeControlling {
    private(set) var keepAwakeCalls: [Bool] = []
    func setKeepAwake(_ on: Bool) { keepAwakeCalls.append(on) }
}

@MainActor
final class SpyRideActivity: RideActivityControlling {
    private(set) var started: (kind: Ride.Kind, units: DistanceUnits, destinationName: String?)?
    private(set) var updates: [(stats: RideStats, maneuver: GuidanceUpdate?)] = []
    private(set) var ended = false
    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?) {
        started = (kind, units, destinationName)
    }
    func update(stats: RideStats, maneuver: GuidanceUpdate?) { updates.append((stats, maneuver)) }
    func end() { ended = true }
}

/// Yields a fixed, buffered set of points then finishes, so a test can await the
/// coordinator's stream task to drain deterministically.
@MainActor
final class ScriptedLocationProvider: LocationStreaming {
    private let samples: [TrackPoint]
    private(set) var stopped = false
    init(_ samples: [TrackPoint]) { self.samples = samples }
    func points() -> AsyncStream<TrackPoint> {
        let samples = self.samples
        return AsyncStream { continuation in
            for p in samples { continuation.yield(p) }
            continuation.finish()
        }
    }
    func stop() { stopped = true }
}

@MainActor
final class ThrowingRideSaving: RideSaving {
    struct SaveError: Error {}
    private(set) var saveCount = 0
    func save(_ ride: Ride) throws { saveCount += 1; throw SaveError() }
}
```

Add these helpers as methods inside the `RideSessionCoordinatorTests` struct:

```swift
private func point(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
    TrackPoint(coordinate: .init(latitude: lat, longitude: -80), elevation: 250,
               timestamp: Date(timeIntervalSince1970: t))
}

private func makeCoordinator(kind: Ride.Kind = .freeRide, destinationName: String? = nil,
                             screen: SpyScreenWake, activity: SpyRideActivity)
    -> RideSessionCoordinator {
    RideSessionCoordinator(kind: kind, destinationName: destinationName,
                           screen: screen, activity: activity)
}
```

- [ ] **Step 2: Write the first failing behavior test (permission gate)**

Add inside the struct:

```swift
@Test func deniedAuthorizationGatesStart() throws {
    let screen = SpyScreenWake(); let activity = SpyRideActivity()
    let c = makeCoordinator(screen: screen, activity: activity)
    let outcome = c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                          units: .metric, authorization: .denied)
    #expect(outcome == .permissionDenied)
    #expect(c.isRecording == false)
    #expect(screen.keepAwakeCalls.isEmpty)
    #expect(activity.started == nil)
}
```

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: FAIL — `cannot find 'RideSessionCoordinator' in scope`.

- [ ] **Step 3: Implement the coordinator**

Create `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`:

```swift
import Foundation
import Observation
import AuraCore

/// Owns the start-to-finish lifecycle of one ride: the recorder, the location stream,
/// the permission-gate decision, screen-wake, the Live Activity loop, the save, and the
/// finished-ride result. The two app-target side effects and the store are injected as
/// protocol seams, so this whole type compiles and tests on the macOS host.
///
/// Construction takes the env-free pieces (kind, destination, the seams); the
/// environment-derived collaborators (the location stream, the store, the units, the
/// current authorization) arrive at `start()`.
@MainActor
@Observable
public final class RideSessionCoordinator {
    // Read by the HUDs.
    public var stats: RideStats { recorder.stats }
    public var track: [TrackPoint] { recorder.track }
    public var isRecording: Bool { recorder.isRecording }
    public private(set) var elapsed: TimeInterval = 0
    /// Set by `finish()`, bound by the HUD's summary `.sheet(item:)`. Not reset here:
    /// the HUD is torn down on return to `.plan`, so the coordinator goes with it.
    public var finishedRide: Ride?
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
    private var startedAt: Date?
    // Internal so a test can await the stream draining; not part of the public surface.
    var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    public init(kind: Ride.Kind,
                destinationName: String?,
                screen: any ScreenWakeControlling,
                activity: any RideActivityControlling) {
        self.kind = kind
        self.recorder = RideRecorder(kind: kind)
        self.destinationName = destinationName
        self.screen = screen
        self.activity = activity
    }

    public enum StartOutcome: Sendable { case started, permissionDenied }

    /// Gates on authorization, then starts the recorder, screen-wake, the Live Activity,
    /// and the stream + ticker tasks. A no-op returning `.started` if already recording.
    @discardableResult
    public func start(location: any LocationStreaming,
                      saving: any RideSaving,
                      units: DistanceUnits,
                      authorization: LocationAuthorization) -> StartOutcome {
        guard !recorder.isRecording else { return .started }
        switch authorization {
        case .denied, .restricted:
            return .permissionDenied
        case .authorized, .notDetermined:
            break
        }

        self.location = location
        self.saving = saving
        let now = Date()
        startedAt = now
        elapsed = 0
        recorder.start(at: now)
        screen.setKeepAwake(true)
        activity.start(kind: kind, startedAt: now, units: units, destinationName: destinationName)

        streamTask = Task { [weak self] in
            guard let stream = self?.location?.points() else { return }
            for await point in stream { self?.recorder.record(point) }
        }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.recorder.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt ?? Date())
                self.pushActivityUpdate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return .started
    }

    /// Pushes current stats + maneuver to the Live Activity. Factored out so a test can
    /// call it directly instead of waiting on the 0.5 s ticker. The activity throttles
    /// internally.
    func pushActivityUpdate() {
        activity.update(stats: recorder.stats, maneuver: maneuver)
    }

    /// Idempotent on `isRecording`: the End-ride button and a navigate arrival can both
    /// call this. Stops streaming, releases the screen, ends the activity, saves, and
    /// publishes the ride (even on a save failure, so the summary still shows).
    public func finish() {
        guard recorder.isRecording else { return }
        stopStreaming()
        screen.setKeepAwake(false)
        activity.end()
        let ride = recorder.end(at: Date(), destinationName: destinationName)
        do {
            try saving?.save(ride)
            saveFailed = false
        } catch {
            saveFailed = true
        }
        finishedRide = ride
    }

    /// Teardown for an abandoned (not finished) ride, called from `onDisappear`. Stops
    /// streaming and releases the screen. Does not save, publish, or end the activity,
    /// matching today's `onDisappear`.
    public func cancel() {
        stopStreaming()
        screen.setKeepAwake(false)
    }

    private func stopStreaming() {
        streamTask?.cancel(); streamTask = nil
        tickerTask?.cancel(); tickerTask = nil
        location?.stop()
    }
}
```

- [ ] **Step 4: Run the gate test to verify it passes**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: PASS.

- [ ] **Step 5: Add the remaining behavior tests**

Add inside the struct:

```swift
@Test func authorizedStartWiresSideEffects() throws {
    let screen = SpyScreenWake(); let activity = SpyRideActivity()
    let c = makeCoordinator(kind: .navigate, destinationName: "Church Brew Works",
                            screen: screen, activity: activity)
    let outcome = c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                          units: .imperial, authorization: .authorized)
    #expect(outcome == .started)
    #expect(c.isRecording == true)
    #expect(screen.keepAwakeCalls == [true])
    #expect(activity.started?.kind == .navigate)
    #expect(activity.started?.units == .imperial)
    #expect(activity.started?.destinationName == "Church Brew Works")
    c.cancel()
}

@Test func streamedPointsAccumulateStats() async throws {
    let c = makeCoordinator(screen: SpyScreenWake(), activity: SpyRideActivity())
    let provider = ScriptedLocationProvider([point(40.40, 0), point(40.41, 10), point(40.42, 20)])
    c.start(location: provider, saving: try RideStore.inMemory(), units: .metric, authorization: .authorized)
    await c.streamTask?.value
    #expect(c.track.count == 3)
    #expect(c.stats.distanceMeters > 0)
    c.cancel()
}

@Test func finishSavesEndsAndPublishes() async throws {
    let screen = SpyScreenWake(); let activity = SpyRideActivity()
    let store = try RideStore.inMemory()
    let c = makeCoordinator(screen: screen, activity: activity)
    c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
            saving: store, units: .metric, authorization: .authorized)
    await c.streamTask?.value
    c.finish()
    #expect(c.isRecording == false)
    #expect(c.finishedRide != nil)
    #expect(activity.ended == true)
    #expect(screen.keepAwakeCalls == [true, false])
    #expect(c.saveFailed == false)
    #expect(try store.allRides().count == 1)
}

@Test func finishIsIdempotent() async throws {
    let store = try RideStore.inMemory()
    let c = makeCoordinator(screen: SpyScreenWake(), activity: SpyRideActivity())
    c.start(location: ScriptedLocationProvider([]), saving: store, units: .metric, authorization: .authorized)
    c.finish()
    c.finish()
    #expect(try store.allRides().count == 1)
}

@Test func saveFailureSetsFlagButStillPublishes() async throws {
    let saving = ThrowingRideSaving()
    let c = makeCoordinator(screen: SpyScreenWake(), activity: SpyRideActivity())
    c.start(location: ScriptedLocationProvider([point(40.40, 0)]), saving: saving,
            units: .metric, authorization: .authorized)
    await c.streamTask?.value
    c.finish()
    #expect(c.saveFailed == true)
    #expect(c.finishedRide != nil)
    #expect(saving.saveCount == 1)
}

@Test func cancelBeforeFinishDoesNotSaveOrPublish() async throws {
    let screen = SpyScreenWake()
    let store = try RideStore.inMemory()
    let c = makeCoordinator(screen: screen, activity: SpyRideActivity())
    c.start(location: ScriptedLocationProvider([point(40.40, 0)]), saving: store,
            units: .metric, authorization: .authorized)
    await c.streamTask?.value
    c.cancel()
    #expect(c.finishedRide == nil)
    #expect(c.saveFailed == false)
    #expect(screen.keepAwakeCalls == [true, false])
    #expect(try store.allRides().isEmpty)
}

@Test func maneuverFlowsToActivityUpdate() throws {
    let activity = SpyRideActivity()
    let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
    c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
            units: .imperial, authorization: .authorized)
    let update = GuidanceUpdate(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave")
    c.maneuver = update
    c.pushActivityUpdate()
    #expect(activity.updates.last?.maneuver == update)
    c.cancel()
}
```

- [ ] **Step 6: Run the whole suite**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: PASS, 9 tests (the conformance test from Task 1 plus 8 here).

- [ ] **Step 7: Full package test run + lint**

Run: `cd AuraCore && swift test` (expect 124 tests: 115 prior + 9 new) and `./scripts/lint.sh` (expect 0 violations).

- [ ] **Step 8: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift \
        AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift
git commit -m "feat(core): add RideSessionCoordinator with Swift Testing suite

One AuraKit coordinator owns the ride lifecycle (recorder, location stream,
permission gate, screen-wake, Live Activity loop, save, finished-ride result)
behind the injected seams. Swift Testing suite covers the gate, start wiring,
streaming, finish/save, idempotency, save failure, cancel, and the maneuver push.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: App conformers + RideSettingsLink + rewire RideHUDView

This task introduces the app-side seam conformers (first used here), the shared settings-link helper, and rewires the free-ride HUD. After it, the app builds and the free-ride flow runs through the coordinator. `NavigateHUDView` still uses the old direct calls and still compiles (`RideScreen` is untouched until Task 5).

**Files:**
- Create: `Aura/Sources/Location/ScreenWakeController.swift`
- Create: `Aura/Sources/Location/RideSettingsLink.swift`
- Create: `Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

- [ ] **Step 1: Add the screen-wake conformer**

Create `Aura/Sources/Location/ScreenWakeController.swift`:

```swift
import UIKit
import AuraKit

/// Keeps the display awake while a ride records, so a handlebar-mounted phone stays
/// glanceable. The UIKit-backed conformer of `ScreenWakeControlling`; the coordinator
/// in AuraKit drives it through the seam.
@MainActor
final class ScreenWakeController: ScreenWakeControlling {
    func setKeepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }
}
```

- [ ] **Step 2: Add the shared settings-link helper**

Create `Aura/Sources/Location/RideSettingsLink.swift`:

```swift
import UIKit

/// Opens the system Settings app at this app's page, for the permission sheet's
/// "Open Settings" action. Shared by both ride HUDs.
@MainActor
enum RideSettingsLink {
    static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
```

- [ ] **Step 3: Add the Live Activity conformer**

Create `Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift`:

```swift
import AuraCore
import AuraKit

/// Conforms the ActivityKit-backed controller to the AuraKit seam. `update(stats:maneuver:)`
/// and `end()` already match; this adds the `start(kind:…)` overload that maps the
/// AuraCore `Ride.Kind` onto the app-target `RideActivityMode`.
extension RideLiveActivityController: RideActivityControlling {
    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?) {
        let mode: RideActivityMode = (kind == .navigate) ? .navigate : .freeRide
        start(mode: mode, startedAt: startedAt, units: units, destinationName: destinationName)
    }
}
```

- [ ] **Step 4: Rewire `RideHUDView`**

Replace the entire contents of `Aura/Sources/Ride/RideHUDView.swift` with:

```swift
import SwiftUI
import AuraCore
import AuraKit

struct RideHUDView: View {
    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location

    @State private var coordinator = RideSessionCoordinator(
        kind: .freeRide, destinationName: nil,
        screen: ScreenWakeController(), activity: RideLiveActivityController.shared)
    @State private var showPermission = false

    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottomTrailing) {
            RideMapView(track: coordinator.track)
            SpeedRail(stats: coordinator.stats, elapsed: coordinator.elapsed, units: settings.units)
                .padding(.trailing, AuraTheme.Spacing.lg).padding(.bottom, 90)
            controls
        }
        // Back-to-home affordance, shown before a ride starts so the screen can be
        // abandoned without having to start and then end a ride.
        .overlay(alignment: .topLeading) {
            if !coordinator.isRecording {
                backButton
                    .padding(.top, 8)   // sits in the safe area; no hardcoded status-bar inset
                    .padding(.leading, 16)
            }
        }
        // GPS signal chip — top-trailing so it doesn't collide with the top-leading back button.
        .overlay(alignment: .topTrailing) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.trailing, 16)
        }
        .background(AuraTheme.background)
        // Returning from the summary (or backing out) drops to the plan/tab shell,
        // mirroring NavigateHUDView.
        .sheet(item: $coordinator.finishedRide, onDismiss: { router.screen = .plan }) { ride in
            RideSummaryView(ride: ride, saveFailed: coordinator.saveFailed)
        }
        .sheet(isPresented: $showPermission) {
            LocationPermissionView(onOpenSettings: RideSettingsLink.open)
        }
        .onDisappear { coordinator.cancel() }
    }

    private var controls: some View {
        Button {
            coordinator.isRecording ? coordinator.finish() : startRide()
        } label: {
            Text(coordinator.isRecording ? "End ride" : "Start free ride")
        }
        // Primary lime when starting; destructive pink only for end-ride.
        .buttonStyle(coordinator.isRecording ? .ctaDestructive : .ctaPrimary)
        .padding(.horizontal, AuraTheme.Spacing.xxl).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var backButton: some View {
        Button {
            router.screen = .plan
        } label: {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.hudControl)
        .accessibilityLabel("Back to home")
    }

    private func startRide() {
        let outcome = coordinator.start(
            location: location, saving: rideStore, units: settings.units,
            authorization: location.authorization)
        if outcome == .permissionDenied { showPermission = true }
    }
}
```

Note what left: the per-tick `.task(id: recorder.isRecording)` loop, the `now`/`startDate`/`elapsed` machinery, the `streamTask`, the `endRide()`/`openSettings()` helpers, and the direct `RideScreen`/`RideLiveActivityController` calls. The coordinator owns all of it now.

- [ ] **Step 5: Build the app**

Delegate to the builder: `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED (app + AuraWidgets). If it reports a missing `MapboxAccessToken`, copy the `pk.…` token from the primary checkout into `Aura/Resources/MapboxAccessToken` and rebuild.

- [ ] **Step 6: Lint**

Run: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 7: Simulator smoke test (free ride)**

Delegate to the builder / ios-simulator tools: install and launch on the booted iPhone 17 / iOS 26.3 sim. Drive a free ride: tap "Start free ride", confirm the speed rail ticks and the button flips to "End ride", tap "End ride", confirm the summary sheet appears, dismiss it, confirm a return to the plan tab. Verify through the accessibility tree (`ui_describe_all`), not screenshots; if a pixel capture is needed and its md5 matches the prior frame, reboot the sim first.

- [ ] **Step 8: Commit**

```bash
git add Aura/Sources/Location/ScreenWakeController.swift \
        Aura/Sources/Location/RideSettingsLink.swift \
        Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift \
        Aura/Sources/Ride/RideHUDView.swift
git commit -m "refactor(app): route RideHUDView through RideSessionCoordinator

Adds the app-side seam conformers (ScreenWakeController, the
RideLiveActivityController RideActivityControlling extension) and a shared
RideSettingsLink, then collapses the free-ride HUD's lifecycle onto the
coordinator.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Rewire NavigateHUDView

The navigate HUD keeps its guidance, voice, audio session, and map. It gets a custom `init` so the coordinator's `destinationName` can come from `destination` (a `@State` default can't read another stored property). The appear `.task` keeps its front matter (mute, audio session, guidance callbacks) ahead of `coordinator.start(...)`.

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

- [ ] **Step 1: Rewire the recording and lifecycle wiring**

Replace the entire contents of `Aura/Sources/Ride/NavigateHUDView.swift` with:

```swift
import AVFoundation
import CoreLocation
import MapboxMaps
import AuraCore
import AuraKit
import SwiftUI

/// Navigate-mode HUD with real turn-by-turn guidance.
///
/// - Full-bleed dark Mapbox map with `followPuck` viewport and a static lime
///   polyline drawn from `route.geometry`.
/// - Turn card driven by a `GuidanceViewModel`, which consumes guidance events from a
///   `GuidanceSession` (Mapbox-backed in the app, scripted in tests). The HUD itself
///   imports no guidance SDK — only the map renderer.
/// - SpeedRail bottom-trailing with live speed and elapsed time.
/// - The ride lifecycle (record, screen-wake, Live Activity, save) is owned by
///   `RideSessionCoordinator`; this view keeps guidance, voice, and the map.
struct NavigateHUDView: View {
    let route: AuraCore.Route
    /// The place the rider chose in search, denormalized onto the saved ride for History.
    var destination: Place?

    @Environment(AppRouter.self) private var router
    @Environment(RideStore.self) private var rideStore
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationService.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Ride lifecycle

    @State private var coordinator: RideSessionCoordinator
    @State private var showPermission = false

    // MARK: Guidance

    /// Owns the guidance event stream and the turn-card state. Backed by Mapbox here;
    /// a `ScriptedGuidanceSession` drives the same model in tests.
    @State private var guidance = GuidanceViewModel(session: MapboxGuidanceSession())

    // MARK: Voice

    @State private var isMuted = false
    private let speechSynthesizer = AVSpeechSynthesizer()

    // MARK: Map

    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)

    init(route: AuraCore.Route, destination: Place? = nil) {
        self.route = route
        self.destination = destination
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .navigate, destinationName: destination?.name,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared))
    }

    // MARK: Body

    var body: some View {
        @Bindable var coordinator = coordinator
        ZStack(alignment: .bottom) {
            // Full-bleed map
            navigateMapView
                .ignoresSafeArea()

            // Speed stats — bottom-trailing mirror of RideHUDView
            SpeedRail(stats: coordinator.stats, elapsed: coordinator.elapsed, units: settings.units)
                .padding(.trailing, AuraTheme.Spacing.lg)
                .padding(.bottom, 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)

            // End-ride button
            endRideButton
        }
        // Turn card pinned below the status bar
        .overlay(alignment: .top) {
            TurnCardView(state: guidance.turn, reduceMotion: reduceMotion)
                .padding(.top, 8) // sits in the safe area; no hardcoded status-bar inset
                .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38),
                           value: guidance.turn)
        }
        // Mute toggle — top trailing, clear of notch
        .overlay(alignment: .topTrailing) {
            muteButton
                .padding(.top, 8)
                .padding(.trailing, 16)
        }
        // GPS signal chip — top leading, clear of the turn card (top-center) and mute button (top-trailing)
        .overlay(alignment: .topLeading) {
            GPSSignalChip(signal: location.signal)
                .padding(.top, 8).padding(.leading, 16)
        }
        // Rerouting cue — centered below the turn card (top 8 pt + ~80 pt card ≈ 88 pt;
        // 96 pt padding gives a comfortable gap). Shown only while guidance is rerouting.
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
        // Summary sheet: when dismissed, return to plan screen.
        .sheet(item: $coordinator.finishedRide, onDismiss: {
            router.screen = .plan
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
        .onDisappear {
            teardownGuidance()
            coordinator.cancel()
        }
    }

    // MARK: Map view (puck follow + live route polyline)

    private var navigateMapView: some View {
        Map(viewport: $viewport) {
            // Rider puck follows heading
            Puck2D(bearing: .heading)

            // Live route polyline: switches to the post-reroute geometry when available.
            // guidance.routeGeometry is updated by GuidanceViewModel on each reroute event.
            if (guidance.routeGeometry ?? route.geometry).count > 1 {
                PolylineAnnotationGroup {
                    PolylineAnnotation(
                        lineCoordinates: (guidance.routeGeometry ?? route.geometry).map {
                            CLLocationCoordinate2D(latitude: $0.latitude,
                                                   longitude: $0.longitude)
                        }
                    )
                    .lineColor(StyleColor(AuraTheme.routeUIColor))
                    .lineWidth(6)
                }
            }
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
    }

    // MARK: End-ride button

    private var endRideButton: some View {
        Button("End ride") {
            endRide()
        }
        .buttonStyle(.ctaDestructive)
        .padding(.horizontal, AuraTheme.Spacing.xxl)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Mute button

    private var muteButton: some View {
        Button {
            isMuted.toggle()
            if isMuted {
                speechSynthesizer.stopSpeaking(at: .immediate)
            }
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        // Active (muted) state shows lime; toggle trait + value convey state non-visually
        // since HUDControlButton signals "active" by color alone.
        .buttonStyle(.hudControl(active: isMuted))
        .accessibilityLabel("Mute voice guidance")
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isMuted ? "On" : "Off")
    }

    // MARK: Ride end (guidance teardown then coordinator finish)

    /// Idempotent through the coordinator: arrival and the End-ride button can both call
    /// this. Tears down guidance (view-owned) first, then finishes the ride.
    private func endRide() {
        teardownGuidance()
        coordinator.finish()
    }

    // MARK: Guidance teardown

    /// Stops the guidance session and releases the audio session. The Mapbox-specific
    /// teardown (subscriptions, free-drive) lives in `MapboxGuidanceSession.stop()`.
    private func teardownGuidance() {
        guidance.stop()
        speechSynthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Voice

    /// Configures the audio session so spoken turn prompts duck the rider's music
    /// politely instead of stopping it. `.voicePrompt` is the navigation-prompt mode.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }

    private func speakInstruction(_ text: String) {
        guard settings.voiceEnabled, !isMuted, !text.isEmpty else { return }
        speechSynthesizer.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speechSynthesizer.speak(utterance)
    }
}
```

What changed: the `recorder`, `streamTask`, `finishedRide`, `saveFailed`, `startDate`, `now`, `elapsed`, the `.task(id: recorder.isRecording)` Live Activity loop, the `startRide()`, and the private `openSettings()` are gone. `endRide()` is now `teardownGuidance(); coordinator.finish()`. The Live Activity start moved inside `coordinator.start`, and the maneuver is fed via `.onChange(of: guidance.lastUpdate)`.

- [ ] **Step 2: Build the app**

Delegate to the builder: `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Lint**

Run: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 4: Simulator smoke test (navigate)**

Plan a route to a destination, start the navigate HUD, confirm the turn card and speed rail update and the route line draws. End the ride (or let arrival end it on the scripted/sample route if reachable), confirm the summary sheet and the return to plan. Verify through the accessibility tree.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "refactor(app): route NavigateHUDView through RideSessionCoordinator

Collapses the navigate HUD's recording lifecycle onto the coordinator, keeping
guidance, voice, and the map view-owned. The maneuver feeds the Live Activity
via onChange(of: guidance.lastUpdate); endRide tears down guidance then finishes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Delete the RideScreen enum

Both HUDs now reach screen-wake through the coordinator's seam, so the `RideScreen` enum has no callers.

**Files:**
- Delete: `Aura/Sources/Location/RideScreen.swift`

- [ ] **Step 1: Confirm there are no remaining references**

Run: `grep -rn "RideScreen" Aura AuraCore`
Expected: no matches (the only file was `RideScreen.swift` itself).

- [ ] **Step 2: Delete the file**

```bash
git rm Aura/Sources/Location/RideScreen.swift
```

- [ ] **Step 3: Build + lint**

Delegate to the builder: `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`, then `./scripts/lint.sh`.
Expected: BUILD SUCCEEDED, 0 violations.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(app): remove the now-unused RideScreen enum

Screen-wake runs through ScreenWakeController behind the coordinator's seam;
RideScreen has no callers.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: ROADMAP update + final verification

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Mark the sub-project shipped**

In `docs/ROADMAP.md`, under "Wave 1 — Structural foundations", replace the **Ride-session coordinator** bullet with a SHIPPED entry that states: ride start and finish now route through one `RideSessionCoordinator` in `AuraKit`, reached through three injected `@MainActor` seams (`ScreenWakeControlling`, `RideActivityControlling`, `RideSaving`) so the lifecycle is unit-tested on the macOS host; both HUDs collapsed onto it; the duplicated permission gate, screen-wake, Live Activity loop, and `openSettings` are gone; `RideScreen` was removed. Note the new coordinator suite (8 cases) and that the next Wave 1 sub-projects are persistence then navigation. Update any "2 of 5" / sub-project-count phrasing to "3 of 5". Keep the prose plain and free of em dashes per the writing convention.

- [ ] **Step 2: Full verification sweep**

Delegate to the builder:
- `cd AuraCore && swift test` — expect all green, including the 9 new coordinator tests.
- `cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` — BUILD SUCCEEDED.
- `./scripts/lint.sh` — 0 violations.
- Re-confirm both simulator smoke flows if any HUD code changed since Tasks 3–4.

- [ ] **Step 3: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark the ride-session coordinator shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done criteria

- `RideSessionCoordinator` owns the full ride lifecycle behind the three seams; both HUDs are thin and call only `start`/`finish`/`cancel` plus the navigate maneuver sync.
- The Swift Testing suite covers the permission gate, start wiring, streaming, finish/save, idempotency, save failure, cancel, and the maneuver push, and `swift test` is green.
- The app and `AuraWidgets` build, SwiftLint is clean, and both ride flows are verified on the simulator.
- `RideScreen` is gone; `openSettings` exists once; `project.yml` is unchanged.
- The branch is ready to ship through a PR into `main` like #3 and #4 (the finishing-a-development-branch step handles the PR, CI wait, merge, and local reconcile, after asking first).
```
