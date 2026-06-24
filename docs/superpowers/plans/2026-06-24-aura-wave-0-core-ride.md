# Aura Wave 0 — Core Ride Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a recorded ride trustworthy: continuous accurate GPS recording (background-capable), a GPS-weak indicator, a permission-denied gate, and an off-route reroute cue.

**Architecture:** One `@Observable @MainActor LocationService` (AuraKit) replaces `LiveLocationProvider` + `CurrentLocationProvider`, built on iOS 17 `CLLocationUpdate.liveUpdates()` + `CLBackgroundActivitySession` under When-In-Use. Pure, CI-tested helpers in AuraCore do GPS classification/filtering and the reroute view-model transitions. The app injects the service through the environment; the two HUDs read it for streaming, signal, and authorization. Reroute extends the pure `GuidanceEvent` enum and is bridged from Mapbox in the app.

**Tech Stack:** Swift 6-style concurrency, SwiftUI (`@Observable`), CoreLocation (iOS 17 async APIs), Mapbox Navigation v3, XcodeGen, swift-snapshot-testing (already present), XCTest.

**Reference skills:** @superpowers:test-driven-development, @all-ios-skills:swift-concurrency, @all-ios-skills:swiftui-patterns, @all-ios-skills:ios-accessibility, @apple-platform-build-tools:builder (for app builds), @ios-build-verify (for simulator verification).

**Spec:** `docs/superpowers/specs/2026-06-24-aura-wave-0-core-ride-design.md`

---

## Conventions

- **Package tests:** `cd AuraCore && swift test` (add `--filter <Name>` for one suite). Runs in CI, no simulator.
- **App build:** delegate to the @apple-platform-build-tools:builder agent. Command it runs: `cd Aura && xcodegen generate && xcodebuild -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`. A bundled Mapbox token must be present (see `.mapbox-setup.md`).
- **Commits:** conventional, scope `core` for `AuraCore/Sources/AuraCore`, `app` for `Aura/`, `core` also for `AuraKit` (it ships in the package). End bodies with the `Co-Authored-By: Claude` trailer.
- **API-shape caveats:** the exact CoreLocation iOS-17 stream API and the Mapbox v3 reroute publisher are confirmed against the installed SDK during their tasks, not assumed. Where this plan shows SDK-touching code, treat it as the intended shape and adjust to the real signatures; the pure-Swift code is exact.

---

## File Structure

**Create:**
- `AuraCore/Sources/AuraCore/Geo/GPSSignal.swift` — `SignalQuality` enum + `GPSFix` classifier/filter (pure).
- `AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift` — `LocationAccuracyMode` enum (pure).
- `AuraCore/Tests/AuraCoreTests/GPSSignalTests.swift` — tests for the classifier/filter.
- `AuraCore/Sources/AuraKit/LocationService.swift` — the consolidated CoreLocation owner.
- `AuraCore/Sources/AuraKit/LocationAuthorization.swift` — `LocationAuthorization` enum + CL mapping.
- `AuraCore/Tests/AuraKitTests/LocationServiceTests.swift` — tests for `ingest` + auth mapping.
- `Aura/Sources/Location/RideScreen.swift` — idle-timer keep-awake helper (app).
- `Aura/Sources/Location/LocationPermissionView.swift` — denied/restricted explainer.
- `Aura/Sources/Ride/GPSSignalChip.swift` — the weak/lost HUD chip.

**Modify:**
- `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` — add `.rerouting` / `.rerouted` events.
- `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift` — `isRerouting` / `routeGeometry` state.
- `AuraCore/Tests/AuraKitTests/GuidanceViewModelTests.swift` — reroute transition tests.
- `Aura/Sources/AuraApp.swift` — create + inject `LocationService`.
- `Aura/Sources/Ride/RideHUDView.swift` — use injected service; gate; chip; screen-awake; accuracy mode.
- `Aura/Sources/Ride/NavigateHUDView.swift` — same, plus reroute cue + live polyline.
- `Aura/Sources/Routing/MapboxGuidanceSession.swift` — emit reroute events.
- `docs/ROADMAP.md` — move Wave 0 to shipped (with device caveat); drop Wave 1 location item.

**Delete (final task, after references move):**
- `AuraCore/Sources/AuraKit/LiveLocationProvider.swift`
- `Aura/Sources/Location/CurrentLocationProvider.swift`

---

## Task 1: GPS signal model (pure, AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Geo/GPSSignal.swift`
- Create: `AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GPSSignalTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// GPSSignalTests.swift
import XCTest
@testable import AuraCore

final class GPSSignalTests: XCTestCase {
    func test_quality_goodWhenAccurateAndFresh() {
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 8, age: 1), .good)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 20, age: 0), .good)
    }
    func test_quality_weakBetweenThresholds() {
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 35, age: 1), .weak)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 50, age: 1), .weak)
    }
    func test_quality_lostWhenInaccurateNegativeOrStale() {
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 80, age: 1), .lost)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: -1, age: 1), .lost)
        XCTAssertEqual(GPSFix.quality(horizontalAccuracy: 5, age: 30), .lost) // stale
    }
    func test_isAcceptable_rejectsNegativeAndTooInaccurate() {
        XCTAssertTrue(GPSFix.isAcceptable(horizontalAccuracy: 49))
        XCTAssertFalse(GPSFix.isAcceptable(horizontalAccuracy: 51))
        XCTAssertFalse(GPSFix.isAcceptable(horizontalAccuracy: -1))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter GPSSignalTests`
Expected: FAIL (no such type `GPSFix`).

- [ ] **Step 3: Write the implementation**

```swift
// GPSSignal.swift
import Foundation

/// How trustworthy the current GPS fix is, for the HUD indicator.
public enum SignalQuality: Sendable, Equatable {
    case good, weak, lost
}

/// Pure GPS-fix classification and filtering. No CoreLocation import — the service
/// passes in horizontal accuracy (meters) and fix age (seconds).
public enum GPSFix {
    /// At or under this horizontal accuracy (m), the fix is good.
    public static let goodAccuracy: Double = 20
    /// Over `goodAccuracy` and up to this, the fix is weak but still recorded.
    public static let weakAccuracy: Double = 50
    /// A fix older than this (s) is treated as lost regardless of accuracy.
    public static let maxAge: TimeInterval = 5

    /// Quality for the indicator: accuracy plus staleness.
    public static func quality(horizontalAccuracy: Double, age: TimeInterval) -> SignalQuality {
        guard horizontalAccuracy >= 0, age <= maxAge else { return .lost }
        if horizontalAccuracy <= goodAccuracy { return .good }
        if horizontalAccuracy <= weakAccuracy { return .weak }
        return .lost
    }

    /// Whether a fix may enter the recorded track. Accuracy-only (an accurate but
    /// slightly old fix is still worth recording); negative accuracy is an invalid fix.
    public static func isAcceptable(horizontalAccuracy: Double) -> Bool {
        horizontalAccuracy >= 0 && horizontalAccuracy <= weakAccuracy
    }
}
```

```swift
// LocationAccuracyMode.swift
import Foundation

/// Desired-accuracy tier. The service maps these to CoreLocation accuracy constants:
/// coarse when idle (battery), the cycling tier while recording.
public enum LocationAccuracyMode: Sendable, Equatable {
    case idle, navigating
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd AuraCore && swift test --filter GPSSignalTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/GPSSignal.swift AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift AuraCore/Tests/AuraCoreTests/GPSSignalTests.swift
git commit -m "feat(core): GPS signal-quality classifier and fix filter"
```

---

## Task 2: Reroute events + view-model state (AuraCore + AuraKit)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift` (the `GuidanceEvent` enum)
- Modify: `AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift`
- Test: `AuraCore/Tests/AuraKitTests/GuidanceViewModelTests.swift`

- [ ] **Step 1: Write the failing tests** (append to `GuidanceViewModelTests.swift`)

```swift
@MainActor
func test_rerouting_setsFlag_thenReroutedSwapsGeometryAndClears() async {
    let geo = [Coordinate(latitude: 40.1, longitude: -80.0),
               Coordinate(latitude: 40.2, longitude: -80.1)]
    let session = ScriptedGuidanceSession(script: [
        .rerouting,
        .rerouted(geo),
        .progress(GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn"))
    ])
    let vm = GuidanceViewModel(session: session)
    await vm.run(route: makeRoute())            // see note below
    XCTAssertEqual(vm.routeGeometry, geo)
    XCTAssertFalse(vm.isRerouting)           // cleared by .rerouted (and .progress)
}

@MainActor
func test_rerouting_withoutRerouted_leavesFlagSet() async {
    let session = ScriptedGuidanceSession(script: [.rerouting])
    let vm = GuidanceViewModel(session: session)
    await vm.run(route: makeRoute())
    XCTAssertTrue(vm.isRerouting)
    XCTAssertNil(vm.routeGeometry)
}
```

Note: `makeRoute()` is the existing private route helper in `GuidanceViewModelTests.swift`. Reuse it; match the file's existing style.

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter GuidanceViewModelTests`
Expected: FAIL (no `.rerouting` case / no `isRerouting`).

- [ ] **Step 3: Add the events** (in `GuidanceSession.swift`, extend `GuidanceEvent`)

```swift
    /// The engine started recalculating after the rider went off-route → show a cue.
    case rerouting
    /// A new route is available after a reroute → swap the drawn polyline.
    case rerouted([Coordinate])
```

- [ ] **Step 4: Add the state** (in `GuidanceViewModel.swift`)

Add stored properties near `lastUpdate`:

```swift
    /// True while the engine is recalculating after going off-route.
    public private(set) var isRerouting = false
    /// The live route shape after a reroute; the HUD draws this in place of the
    /// original `route.geometry`. `nil` until the first reroute.
    public private(set) var routeGeometry: [Coordinate]?
```

Add cases to the `switch event` in `run(route:)`:

```swift
            case .rerouting:
                isRerouting = true
            case .rerouted(let geometry):
                routeGeometry = geometry
                isRerouting = false
```

And in the existing `.progress` case, defensively clear the flag (a progress update means we are back on a route): add `isRerouting = false` as the first line of that case.

- [ ] **Step 5: Run to verify it passes**

Run: `cd AuraCore && swift test --filter GuidanceViewModelTests`
Expected: PASS (existing tests + 2 new).

- [ ] **Step 6: Full package test (no regressions)**

Run: `cd AuraCore && swift test`
Expected: PASS (all suites).

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift AuraCore/Sources/AuraKit/Guidance/GuidanceViewModel.swift AuraCore/Tests/AuraKitTests/GuidanceViewModelTests.swift
git commit -m "feat(core): reroute guidance events and view-model state"
```

---

## Task 3: Location authorization + ingest core (AuraKit)

This is the unit-testable heart of `LocationService`: the auth mapping and per-fix
filtering/classification, with no live CoreLocation stream.

**Files:**
- Create: `AuraCore/Sources/AuraKit/LocationAuthorization.swift`
- Create: `AuraCore/Sources/AuraKit/LocationService.swift` (minimal: state + `ingest`)
- Test: `AuraCore/Tests/AuraKitTests/LocationServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// LocationServiceTests.swift
import XCTest
import CoreLocation
@testable import AuraKit
@testable import AuraCore

@MainActor
final class LocationServiceTests: XCTestCase {
    func test_authorizationMapping() {
        XCTAssertEqual(LocationAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(LocationAuthorization(.denied), .denied)
        XCTAssertEqual(LocationAuthorization(.restricted), .restricted)
        XCTAssertEqual(LocationAuthorization(.authorizedWhenInUse), .authorized)
        XCTAssertEqual(LocationAuthorization(.authorizedAlways), .authorized)
    }

    func test_ingest_acceptsGoodFix_updatesSignal() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -79.99),
                             altitude: 250, horizontalAccuracy: 8, verticalAccuracy: 5,
                             timestamp: Date())
        let point = svc.ingest(loc, now: Date())
        XCTAssertNotNil(point)
        XCTAssertEqual(svc.signal, .good)
        XCTAssertEqual(point?.elevation, 250)
    }

    func test_ingest_dropsInaccurateFix_signalLost() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -79.99),
                             altitude: 0, horizontalAccuracy: 120, verticalAccuracy: 5,
                             timestamp: Date())
        XCTAssertNil(svc.ingest(loc, now: Date()))
        XCTAssertEqual(svc.signal, .lost)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter LocationServiceTests`
Expected: FAIL (types missing).

- [ ] **Step 3: Implement the auth enum**

```swift
// LocationAuthorization.swift
import CoreLocation

/// The location-permission states the UI distinguishes.
public enum LocationAuthorization: Sendable, Equatable {
    case notDetermined, denied, restricted, authorized

    public init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        default: self = .notDetermined
        }
    }
}
```

- [ ] **Step 4: Implement the minimal service (state + ingest only)**

```swift
// LocationService.swift  (streaming/auth-request/background added in Task 4)
import Foundation
import CoreLocation
import Observation
import AuraCore

@Observable
@MainActor
public final class LocationService: NSObject, LocationStreaming {
    public private(set) var authorization: LocationAuthorization = .notDetermined
    public private(set) var signal: SignalQuality = .good

    @ObservationIgnored let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        authorization = LocationAuthorization(manager.authorizationStatus)
    }

    /// Classify + filter one fix. Updates `signal`; returns a TrackPoint only if the
    /// fix is acceptable for the recorded track. Pure logic, unit-tested.
    func ingest(_ location: CLLocation, now: Date) -> TrackPoint? {
        let age = now.timeIntervalSince(location.timestamp)
        signal = GPSFix.quality(horizontalAccuracy: location.horizontalAccuracy, age: age)
        guard GPSFix.isAcceptable(horizontalAccuracy: location.horizontalAccuracy) else { return nil }
        return TrackPoint(
            coordinate: Coordinate(latitude: location.coordinate.latitude,
                                   longitude: location.coordinate.longitude),
            elevation: location.altitude,
            timestamp: location.timestamp)
    }

    // Placeholder protocol conformance — real bodies land in Task 4.
    public func points() -> AsyncStream<TrackPoint> { AsyncStream { $0.finish() } }
    public func stop() {}
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.authorization = LocationAuthorization(m.authorizationStatus) }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd AuraCore && swift test --filter LocationServiceTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/LocationAuthorization.swift AuraCore/Sources/AuraKit/LocationService.swift AuraCore/Tests/AuraKitTests/LocationServiceTests.swift
git commit -m "feat(core): LocationService auth mapping and fix-ingest core"
```

---

## Task 4: LocationService streaming shell (AuraKit)

Wire the real stream, background session, authorization request, accuracy mode, and
one-shot `current()`. This is the thin SDK shell; it is verified on the simulator, not
unit-tested. **Confirm the iOS-17 API shapes against the installed SDK before finalizing.**

**Files:**
- Modify: `AuraCore/Sources/AuraKit/LocationService.swift`

- [ ] **Step 1: Replace the placeholder `points()` / `stop()` and add `current()` / `setMode(_:)`.**

Intended shape (adjust to real signatures; consult @all-ios-skills:swift-concurrency for the async stream bridging):

```swift
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var continuation: AsyncStream<TrackPoint>.Continuation?
    @ObservationIgnored private var mode: LocationAccuracyMode = .idle

    public func setMode(_ mode: LocationAccuracyMode) {
        self.mode = mode
        manager.desiredAccuracy = (mode == .navigating)
            ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
        #if os(iOS)
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        #endif
    }

    public func points() -> AsyncStream<TrackPoint> {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        setMode(.navigating)
        backgroundSession = CLBackgroundActivitySession()   // keeps updates in background
        let (stream, continuation) = AsyncStream<TrackPoint>.makeStream()
        self.continuation = continuation
        updatesTask = Task { @MainActor in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let loc = update.location, let point = ingest(loc, now: Date()) {
                        continuation.yield(point)
                    } else if #available(iOS 18, *), update.locationUnavailable {
                        signal = .lost   // iOS 18+ explicit signal; ingest()'s age path covers iOS 17
                    }
                }
            } catch {}
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        return stream
    }

    public func stop() {
        updatesTask?.cancel(); updatesTask = nil
        backgroundSession?.invalidate(); backgroundSession = nil
        continuation?.finish(); continuation = nil
        setMode(.idle)
    }

    /// One-shot origin for the plan/preview, with a Pittsburgh fallback. Folds in what
    /// CurrentLocationProvider did. Never throws, resolves quickly.
    public func current() async -> Coordinate {
        let fallback = Coordinate(latitude: 40.4406, longitude: -79.9959)
        if let loc = manager.location, -loc.timestamp.timeIntervalSinceNow < 30 {
            return Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        }
        switch manager.authorizationStatus {
        case .denied, .restricted: return fallback
        default: break
        }
        // Best-effort single fix via liveUpdates with a short timeout; fall back otherwise.
        return await withTaskGroup(of: Coordinate?.self) { group in
            group.addTask { @MainActor in
                if let u = try? await CLLocationUpdate.liveUpdates().first(where: { $0.location != nil }),
                   let l = u.location {
                    return Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
                }
                return nil
            }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }
```

Notes for the implementer:
- `CLLocationUpdate.liveUpdates()` and `CLBackgroundActivitySession` are iOS 17+, but `update.locationUnavailable` / `update.authorizationDenied` are **iOS 18+** (verified against the installed SDK). Guard them with `if #available(iOS 18, *)`. The deployment target is iOS 17.0, so on iOS 17 rely on `ingest()`'s staleness path (a fix older than `maxAge` classifies as `.lost`); these properties are an enhancement, not a dependency.
- The `CLBackgroundActivitySession` grants background delivery here, replacing the old `allowsBackgroundLocationUpdates = true` flag, so the new service does not set that flag. The "location" background mode is already in `Info.plist`; no entitlements file is needed.
- Keep `showsBackgroundLocationIndicator` honest: if a `CLLocationManager`-based indicator is needed alongside the activity session, set `manager.showsBackgroundLocationIndicator = true`.

- [ ] **Step 2: Confirm the package still builds and tests pass**

Run: `cd AuraCore && swift test`
Expected: PASS (the ingest tests still pass; the shell compiles).

- [ ] **Step 3: Commit**

```bash
git add AuraCore/Sources/AuraKit/LocationService.swift
git commit -m "feat(core): LocationService live stream, background session, one-shot current()"
```

---

## Task 5: Inject the service + screen-awake helper (app)

**Files:**
- Create: `Aura/Sources/Location/RideScreen.swift`
- Modify: `Aura/Sources/AuraApp.swift`

- [ ] **Step 1: Add the screen-awake helper**

```swift
// RideScreen.swift
import UIKit

/// Keeps the display awake while a ride records, so a handlebar-mounted phone stays
/// glanceable. Display concern, kept out of the location layer. Reset on every end path.
@MainActor
enum RideScreen {
    static func keepAwake(_ on: Bool) {
        UIApplication.shared.isIdleTimerDisabled = on
    }
}
```

- [ ] **Step 2: Inject `LocationService` in `AuraApp`**

In `AuraApp.swift`: add `@State private var location = LocationService()` next to the other `@State` stores, and add `.environment(location)` to `RootView()` alongside the existing `.environment(...)` calls.

- [ ] **Step 3: Build the app (delegate to builder agent)**

Use @apple-platform-build-tools:builder to run the app build command (see Conventions).
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Location/RideScreen.swift Aura/Sources/AuraApp.swift
git commit -m "feat(app): inject LocationService and add screen-awake helper"
```

---

## Task 6: GPS-weak chip (app)

**Files:**
- Create: `Aura/Sources/Ride/GPSSignalChip.swift`

- [ ] **Step 1: Build the chip**

```swift
// GPSSignalChip.swift
import SwiftUI
import AuraCore

/// Small HUD chip surfacing weak/lost GPS. Hidden when good. Composed VoiceOver label.
struct GPSSignalChip: View {
    let signal: SignalQuality

    var body: some View {
        if signal != .good {
            Label(signal == .lost ? "GPS lost" : "GPS weak",
                  systemImage: "location.slash.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(signal == .lost ? "GPS signal lost" : "GPS signal weak")
        }
    }
}
```

- [ ] **Step 2: Build the app**

Use @apple-platform-build-tools:builder.
Expected: build succeeds (view compiles; not yet placed).

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/GPSSignalChip.swift
git commit -m "feat(app): GPS-weak HUD chip component"
```

---

## Task 7: Permission explainer + free-ride HUD rewire (app)

**Files:**
- Create: `Aura/Sources/Location/LocationPermissionView.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

- [ ] **Step 1: Build the explainer**

```swift
// LocationPermissionView.swift
import SwiftUI

/// Shown when the rider tries to start a ride without location permission. Explains why
/// and deep-links to Settings. Presented as a sheet from the HUDs.
struct LocationPermissionView: View {
    var onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "location.slash")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(AuraTheme.cyan)
            Text("Location needed to ride")
                .font(.title2.weight(.bold)).foregroundStyle(AuraTheme.text)
            Text("Aura records your route and follows you on the map. Turn on location access in Settings to start a ride.")
                .font(.subheadline).foregroundStyle(AuraTheme.muted)
                .multilineTextAlignment(.center)
            Button("Open Settings") { onOpenSettings() }
                .font(.headline).foregroundStyle(.black)
                .padding(.vertical, 14).frame(maxWidth: .infinity)
                .background(AuraTheme.auroraGradient, in: Capsule())
            Button("Not now") { dismiss() }
                .font(.subheadline).foregroundStyle(AuraTheme.muted)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuraTheme.bg)
    }
}
```

- [ ] **Step 2: Rewire `RideHUDView`**

- Replace the `makeProvider: () -> LocationStreaming` property and its use with `@Environment(LocationService.self) private var location`.
- Add `@State private var showPermission = false`.
- In `startRide()`: guard on authorization first:

```swift
    private func startRide() {
        switch location.authorization {
        case .denied, .restricted:
            showPermission = true
            return
        default:
            break
        }
        startDate = Date()
        recorder.start(at: startDate!)
        RideScreen.keepAwake(true)
        RideLiveActivityController.shared.start(
            mode: .freeRide, startedAt: startDate!, units: settings.units, destinationName: nil)
        streamTask = Task { @MainActor in
            for await point in location.points() { recorder.record(point) }
        }
    }
```

- In `endRide()`: add `RideScreen.keepAwake(false)` and call `location.stop()` instead of `provider?.stop()`. Remove the `provider`/`makeProvider` state.
- Add the chip to the overlay (e.g. top-trailing under the safe area): `GPSSignalChip(signal: location.signal)`.
- Add the permission sheet: `.sheet(isPresented: $showPermission) { LocationPermissionView(onOpenSettings: { openSettings() }) }` where `openSettings()` opens `UIApplication.openSettingsURLString`.
- Update the call site in `AuraApp.RootView` free-ride branch: `RideHUDView()` (no closure).

- [ ] **Step 3: Build the app**

Use @apple-platform-build-tools:builder.
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Location/LocationPermissionView.swift Aura/Sources/Ride/RideHUDView.swift Aura/Sources/AuraApp.swift
git commit -m "feat(app): permission gate, GPS chip, and LocationService wiring in free-ride HUD"
```

---

## Task 8: Navigate HUD rewire (app)

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

- [ ] **Step 1: Mirror Task 7 in `NavigateHUDView`**

- Replace the direct `LiveLocationProvider()` in `startRide()` with the injected `@Environment(LocationService.self) private var location`; stream from `location.points()`; remove the `provider` state.
- Gate the `.task` ride-start on authorization (present the same permission sheet; if denied, do not start recording or guidance).
- `RideScreen.keepAwake(true)` on start, `false` on every end path; `location.stop()` in `endRide()`.
- Add `GPSSignalChip(signal: location.signal)` to the overlay (placed clear of the turn card and mute button).

- [ ] **Step 2: Build the app**

Use @apple-platform-build-tools:builder.
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(app): LocationService wiring, permission gate, GPS chip in navigate HUD"
```

---

## Task 9: Mapbox reroute bridge (app)

**Files:**
- Modify: `Aura/Sources/Routing/MapboxGuidanceSession.swift`

**Confirm the Mapbox Navigation v3 reroute publisher before wiring (per the Terrain-RGB lesson — a clean build is not proof it fires).**

- [ ] **Step 1: Find the reroute signal**

In the Mapbox v3 API (`nav.navigation()` / the rerouting controller), locate the publisher that fires when rerouting starts and when a new route is set. Confirm names and payloads against the installed SDK (grep the SDK or check headers). Capture findings in the commit message.

- [ ] **Step 2: Emit the events**

Subscribe alongside the existing `routeProgress` / `waypointsArrival` / `voiceInstructions` sinks:
- On reroute start: `continuation.yield(.rerouting)`.
- On new route available: decode the new route shape to `[Coordinate]` and `continuation.yield(.rerouted(coords))`.

Keep the `.receive(on: DispatchQueue.main)` pattern consistent with the existing sinks.

- [ ] **Step 3: Build the app**

Use @apple-platform-build-tools:builder.
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Routing/MapboxGuidanceSession.swift
git commit -m "feat(app): bridge Mapbox reroute into rerouting/rerouted guidance events"
```

---

## Task 10: Navigate polyline redraw + reroute cue (app)

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

- [ ] **Step 1: Draw from the live geometry**

In `navigateMapView`, draw the polyline from `guidance.routeGeometry ?? route.geometry` instead of `route.geometry`. Keep the single route color (note: this is still the hardcoded green; the token bridge is a Wave 2 item, leave a `// TODO(Wave 2): route color token` comment).

- [ ] **Step 2: Add the reroute cue**

Add a small "Rerouting…" pill (reduce-motion-aware, consistent with the turn card styling) shown while `guidance.isRerouting`, placed so it does not collide with the turn card or the GPS chip.

- [ ] **Step 3: Build the app**

Use @apple-platform-build-tools:builder.
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(app): redraw navigate polyline on reroute and show rerouting cue"
```

---

## Task 11: Remove old providers, verify, update roadmap

**Files:**
- Delete: `AuraCore/Sources/AuraKit/LiveLocationProvider.swift`
- Delete: `Aura/Sources/Location/CurrentLocationProvider.swift`
- Modify: remaining references found by grep (today: `RoutePreviewView.swift:~243` calls `CurrentLocationProvider.shared.current()`; `AuraApp.swift:~83` constructs `LiveLocationProvider()`) → route to the injected `LocationService`. Use grep as the source of truth rather than this list.
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Delete the old providers and fix references**

Grep for `LiveLocationProvider` and `CurrentLocationProvider` and route all call sites to the injected `LocationService`. The `LocationStreaming` protocol stays (SimulatedLocationProvider still conforms).

Run: `cd /Users/rohunjoseph/projects/biking-app/.claude/worktrees/blissful-ishizaka-a6814e && grep -rn "LiveLocationProvider\|CurrentLocationProvider" --include="*.swift" . | grep -v /.build/`
Expected: only the deletions remain (no live references).

- [ ] **Step 2: Full package tests**

Run: `cd AuraCore && swift test`
Expected: PASS (target ~110 tests: prior 105 + GPS + auth/ingest + reroute).

- [ ] **Step 3: App build + simulator verification**

Use @apple-platform-build-tools:builder to build, then @ios-build-verify to:
- Launch on iPhone 17 sim, simulate a location/route, start a free ride and a navigate ride.
- Confirm: recording works, the GPS chip appears under simulated poor accuracy, the permission explainer shows when location is denied (reset sim privacy), and (if the reroute publisher was confirmed in Task 9) the rerouting cue + polyline swap on a simulated off-route.
- Capture the accessibility tree / screenshots as evidence.

- [ ] **Step 4: Update the roadmap**

In `docs/ROADMAP.md`: move Wave 0 items to "Shipped" with a note that locked-screen recording is configured but device-unverified; remove the Wave 1 "consolidate the location layer" bullet (done here); correct the audit section's "request Always" phrasing to the When-In-Use + `CLBackgroundActivitySession` model. Keep edits truthful about what was sim-verified vs not.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(app): remove legacy location providers; docs(roadmap): Wave 0 shipped"
```

---

## Definition of done

- All package tests pass (`cd AuraCore && swift test`).
- App builds clean for the iPhone 17 simulator.
- Free ride and navigate ride record on the simulator; GPS chip, permission gate, and (if confirmed) reroute cue behave.
- No references to the deleted providers remain.
- Roadmap updated truthfully, with the locked-screen device caveat called out.
- Code-review loop (per subagent-driven-development) passed before final merge.
```
