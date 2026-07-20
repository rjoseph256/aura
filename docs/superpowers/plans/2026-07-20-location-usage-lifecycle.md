# Location Usage Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release the iOS background-location session (the blue "using location" pill) whenever the app is neither in a ride nor foreground-on-Home, add a coarse ambient tier for Home weather, and make the ride pipeline's teardown a synchronous guarantee.

**Architecture:** One `LocationService` gains three explicit tiers (`.idle`/`.ambient`/`.navigating`), each fully configured by `setMode`. Only `.navigating` arms a `CLBackgroundActivitySession` + background indicator. Home drives a continuous coarse ambient monitor (foreground + top-of-stack only) via a single-writer controller in `RootView` computed from `router.path`, `router.isRideActive`, `scenePhase`, and authorization — never from view appear/disappear. `current()` becomes a true one-shot on a dedicated `CLLocationManager`. Decision logic (tier selection, origin resolution) is extracted into pure functions so it is unit-testable on the macOS CI host; the iOS-only session/indicator behavior is device-verified.

**Tech Stack:** Swift 6, SwiftUI, CoreLocation, Swift Package (AuraCore/AuraKit) + app target (Aura), XCTest.

## Global Constraints

- **Swift 6 strict concurrency**; `LocationService` is `@MainActor @Observable`. CLLocation is not Sendable — extract `Coordinate` (Sendable) synchronously in any `nonisolated` delegate callback before hopping to the main actor.
- **macOS CI:** the package is built/tested on a macOS host. iOS-only CoreLocation APIs (`CLBackgroundActivitySession`, `showsBackgroundLocationIndicator`, `activityType`, `pausesLocationUpdatesAutomatically`, `authorizedWhenInUse`) MUST stay inside `#if os(iOS)`. `desiredAccuracy` / `distanceFilter` / `requestLocation` / `startUpdatingLocation` are cross-platform — keep them outside the guard.
- **Authorization unchanged:** stays When-In-Use. The first permission prompt must still originate from the ride path (`points()`); ambient is gated on `authorization == .authorized` and must never call `requestWhenInUseAuthorization` or start updates while `.notDetermined`.
- **No `RideSessionCoordinator` edits and no ride-HUD edits** (avoids collision with the ROH-81 branch). Ride-truth is read via `router.isRideActive`, already set by the HUDs.
- **SwiftLint clean** (`swiftlint --strict`), existing suite stays green, app builds.
- **Terminology:** the hard guarantee is about the **background pill**; the **foreground arrow** is acceptable while the app is open and locating.

---

### Task 1: Three-tier `setMode` + `.ambient` mode

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift`
- Modify: `AuraCore/Sources/AuraKit/LocationService.swift:45-53` (`setMode`), add `mode` property near line 9
- Test: `AuraCore/Tests/AuraKitTests/LocationServiceTests.swift`

**Interfaces:**
- Produces: `enum LocationAccuracyMode { case idle, ambient, navigating }`; `LocationService.setMode(_:)` now sets `desiredAccuracy` + `distanceFilter` for every tier and iOS knobs per tier; `LocationService.mode: LocationAccuracyMode` (`private(set)`, observable-ignored).

- [ ] **Step 1: Add `.ambient` to the mode enum**

In `LocationAccuracyMode.swift`, replace the enum body:

```swift
/// Desired-accuracy / activity tier. The service maps these to CoreLocation:
/// `.idle` = released (coarse, no updates), `.ambient` = coarse continuous for
/// Home weather (foreground only, no background session/indicator), `.navigating`
/// = the cycling tier while recording (background session + indicator).
public enum LocationAccuracyMode: Sendable, Equatable {
    case idle, ambient, navigating
}
```

- [ ] **Step 2: Write the failing test**

Add to `LocationServiceTests.swift`:

```swift
func test_setMode_configuresManagerPerTier() {
    let svc = LocationService()

    svc.setMode(.idle)
    XCTAssertEqual(svc.mode, .idle)
    XCTAssertEqual(svc.manager.desiredAccuracy, kCLLocationAccuracyHundredMeters)
    XCTAssertEqual(svc.manager.distanceFilter, kCLDistanceFilterNone)

    svc.setMode(.ambient)
    XCTAssertEqual(svc.mode, .ambient)
    XCTAssertEqual(svc.manager.desiredAccuracy, kCLLocationAccuracyKilometer)
    XCTAssertEqual(svc.manager.distanceFilter, 500)

    svc.setMode(.navigating)
    XCTAssertEqual(svc.mode, .navigating)
    XCTAssertEqual(svc.manager.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
    XCTAssertEqual(svc.manager.distanceFilter, kCLDistanceFilterNone)

    #if os(iOS)
    XCTAssertTrue(svc.manager.showsBackgroundLocationIndicator)
    svc.setMode(.ambient)
    XCTAssertFalse(svc.manager.showsBackgroundLocationIndicator)
    #endif
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter LocationServiceTests/test_setMode_configuresManagerPerTier`
Expected: FAIL — `value of type 'LocationService' has no member 'mode'`.

- [ ] **Step 4: Implement `mode` + rewrite `setMode`**

In `LocationService.swift`, add the property after line 10 (`public private(set) var signal`):

```swift
    /// The current location tier. Drives which manager configuration is active and
    /// whether the background session/indicator is armed. Read by the RootView controller.
    public private(set) var mode: LocationAccuracyMode = .idle
```

Replace `setMode(_:)` (lines 45-53) with:

```swift
    /// Configure the shared manager for a tier. Sets EVERY relevant knob for EVERY tier
    /// so no setting (e.g. an ambient 500 m `distanceFilter`) can leak across a transition.
    /// Only `.navigating` arms the visible background indicator; the iOS-only knobs are
    /// guarded so the package still builds for macOS.
    public func setMode(_ mode: LocationAccuracyMode) {
        self.mode = mode
        switch mode {
        case .idle:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone
        case .ambient:
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            manager.distanceFilter = 500
        case .navigating:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = kCLDistanceFilterNone
        }
        #if os(iOS)
        manager.activityType = (mode == .idle) ? .other : .fitness
        manager.pausesLocationUpdatesAutomatically = (mode != .navigating)
        manager.showsBackgroundLocationIndicator = (mode == .navigating)
        #endif
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter LocationServiceTests`
Expected: PASS (all four tests).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift AuraCore/Sources/AuraKit/LocationService.swift AuraCore/Tests/AuraKitTests/LocationServiceTests.swift
git commit -m "feat(location): three-tier setMode with ambient tier (ROH-83)"
```

---

### Task 2: Pure tier-selection function

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift`
- Test: `AuraCore/Tests/AuraCoreTests/LocationAccuracyModeTests.swift` (create)

**Interfaces:**
- Produces: `LocationAccuracyMode.desired(isRideActive:isHomeForeground:authorized:) -> LocationAccuracyMode` — pure, no CoreLocation. The RootView controller (Task 7) uses it.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraCoreTests/LocationAccuracyModeTests.swift`:

```swift
import XCTest
@testable import AuraCore

final class LocationAccuracyModeTests: XCTestCase {
    func test_desired_rideAlwaysWins() {
        // A ride is active regardless of Home/foreground/auth -> navigating.
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: true, isHomeForeground: false, authorized: false), .navigating)
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: true, isHomeForeground: true, authorized: true), .navigating)
    }

    func test_desired_ambientOnlyWhenHomeForegroundAndAuthorized() {
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: true, authorized: true), .ambient)
    }

    func test_desired_idleOtherwise() {
        // Not on Home (pushed screen) -> idle.
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: false, authorized: true), .idle)
        // On Home but not authorized -> idle (never locate without permission).
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: true, authorized: false), .idle)
        // Backgrounded (isHomeForeground already folds scenePhase) -> idle.
        XCTAssertEqual(LocationAccuracyMode.desired(isRideActive: false, isHomeForeground: false, authorized: false), .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter LocationAccuracyModeTests`
Expected: FAIL — `type 'LocationAccuracyMode' has no member 'desired'`.

- [ ] **Step 3: Implement the pure function**

Append to `LocationAccuracyMode.swift`:

```swift
public extension LocationAccuracyMode {
    /// The tier the app should be in, given ride/home/authorization state. Pure so it is
    /// unit-testable without CoreLocation. `isHomeForeground` folds "Home is the top of the
    /// nav stack AND the app is foreground-active" into one flag at the call site.
    /// A ride always wins; ambient needs Home-foreground + authorization; otherwise idle.
    static func desired(isRideActive: Bool, isHomeForeground: Bool, authorized: Bool) -> LocationAccuracyMode {
        if isRideActive { return .navigating }
        if isHomeForeground && authorized { return .ambient }
        return .idle
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter LocationAccuracyModeTests`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/LocationAccuracyMode.swift AuraCore/Tests/AuraCoreTests/LocationAccuracyModeTests.swift
git commit -m "feat(location): pure desired-tier selection (ROH-83)"
```

---

### Task 3: `LocationFix`, `LocationPurpose`, and the pure origin resolver

**Files:**
- Create: `AuraCore/Sources/AuraCore/Geo/LocationOrigin.swift`
- Test: `AuraCore/Tests/AuraCoreTests/LocationOriginTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct LocationFix: Equatable, Sendable { let coordinate: Coordinate; let at: Date }`
  - `enum LocationPurpose: Sendable { case routing, coarse }`
  - `func resolveOrigin(cached: LocationFix?, ambient: LocationFix?, purpose: LocationPurpose, now: Date, freshness: TimeInterval = 30) -> Coordinate?` — returns a coordinate when one of the cheap sources is fresh enough for the purpose, else `nil` (caller then does a one-shot / fallback). Routing never accepts the coarse ambient sample.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraCoreTests/LocationOriginTests.swift`:

```swift
import XCTest
@testable import AuraCore

final class LocationOriginTests: XCTestCase {
    private let a = Coordinate(latitude: 40.44, longitude: -79.99)   // cached
    private let b = Coordinate(latitude: 40.45, longitude: -79.98)   // ambient
    private let now = Date(timeIntervalSince1970: 10_000)

    func test_freshCachedFix_alwaysWins() {
        let cached = LocationFix(coordinate: a, at: now.addingTimeInterval(-10))
        XCTAssertEqual(resolveOrigin(cached: cached, ambient: nil, purpose: .routing, now: now), a)
        XCTAssertEqual(resolveOrigin(cached: cached, ambient: nil, purpose: .coarse, now: now), a)
    }

    func test_staleCached_isIgnored() {
        let cached = LocationFix(coordinate: a, at: now.addingTimeInterval(-31))
        XCTAssertNil(resolveOrigin(cached: cached, ambient: nil, purpose: .routing, now: now))
    }

    func test_coarsePurpose_acceptsFreshAmbient() {
        let ambient = LocationFix(coordinate: b, at: now.addingTimeInterval(-5))
        XCTAssertEqual(resolveOrigin(cached: nil, ambient: ambient, purpose: .coarse, now: now), b)
    }

    func test_routingPurpose_neverAcceptsAmbient() {
        let ambient = LocationFix(coordinate: b, at: now)   // even perfectly fresh
        XCTAssertNil(resolveOrigin(cached: nil, ambient: ambient, purpose: .routing, now: now))
    }

    func test_staleAmbient_ignoredEvenForCoarse() {
        let ambient = LocationFix(coordinate: b, at: now.addingTimeInterval(-31))
        XCTAssertNil(resolveOrigin(cached: nil, ambient: ambient, purpose: .coarse, now: now))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter LocationOriginTests`
Expected: FAIL — `cannot find 'resolveOrigin' in scope`.

- [ ] **Step 3: Implement the types + resolver**

Create `AuraCore/Sources/AuraCore/Geo/LocationOrigin.swift`:

```swift
import Foundation

/// A coordinate plus the instant it was observed. `Equatable` so SwiftUI `.onChange`
/// can watch it; `Sendable` so it crosses actor boundaries from delegate callbacks.
public struct LocationFix: Equatable, Sendable {
    public let coordinate: Coordinate
    public let at: Date
    public init(coordinate: Coordinate, at: Date) {
        self.coordinate = coordinate
        self.at = at
    }
}

/// Why an origin is being requested. Routing needs a precise fix; coarse (weather) tolerates
/// the ~kilometre ambient sample.
public enum LocationPurpose: Sendable { case routing, coarse }

/// Pick a cheap origin without hitting the location hardware, or return nil so the caller
/// falls through to a one-shot request. A fresh precise cached fix always wins; the coarse
/// ambient sample is only acceptable for `.coarse` callers. "Fresh" = within `freshness` of `now`.
public func resolveOrigin(cached: LocationFix?,
                          ambient: LocationFix?,
                          purpose: LocationPurpose,
                          now: Date,
                          freshness: TimeInterval = 30) -> Coordinate? {
    func isFresh(_ fix: LocationFix) -> Bool { now.timeIntervalSince(fix.at) < freshness }
    if let cached, isFresh(cached) { return cached.coordinate }
    if purpose == .coarse, let ambient, isFresh(ambient) { return ambient.coordinate }
    return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter LocationOriginTests`
Expected: PASS (all five tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/LocationOrigin.swift AuraCore/Tests/AuraCoreTests/LocationOriginTests.swift
git commit -m "feat(location): LocationFix + pure origin resolver (ROH-83)"
```

---

### Task 4: Delegate infrastructure — one-shot manager, `lastKnown`, demultiplexed callbacks

**Files:**
- Modify: `AuraCore/Sources/AuraKit/LocationService.swift` (add fields near line 12-18; extend the delegate extension at lines 139-146)
- Test: `AuraCore/Tests/AuraKitTests/LocationServiceTests.swift`

**Interfaces:**
- Consumes: `LocationFix` (Task 3).
- Produces:
  - `LocationService.lastKnown: LocationFix?` (`private(set)`, observable) — most recent ambient fix.
  - private `oneShotManager: CLLocationManager` and `oneShotWaiters: [CheckedContinuation<Coordinate?, Never>]`.
  - `@MainActor func handleLocationUpdate(managerID:coordinate:timestamp:)` and `@MainActor func handleLocationFailure(managerID:)` — internal, called by the nonisolated delegate methods; also directly unit-testable.

- [ ] **Step 1: Write the failing test**

Add to `LocationServiceTests.swift`:

```swift
func test_ambientUpdate_setsLastKnown() {
    let svc = LocationService()
    let coord = Coordinate(latitude: 40.44, longitude: -79.99)
    let t = Date()
    // Simulate a fix arriving on the ambient (shared) manager.
    svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.manager), coordinate: coord, timestamp: t)
    XCTAssertEqual(svc.lastKnown, LocationFix(coordinate: coord, at: t))
}

func test_oneShotUpdate_doesNotTouchLastKnown() {
    let svc = LocationService()
    let coord = Coordinate(latitude: 1, longitude: 2)
    // A fix on the one-shot manager must NOT be recorded as the ambient lastKnown.
    svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.oneShotManager), coordinate: coord, timestamp: Date())
    XCTAssertNil(svc.lastKnown)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter LocationServiceTests/test_ambientUpdate_setsLastKnown`
Expected: FAIL — `has no member 'handleLocationUpdate'` / `'lastKnown'` / `'oneShotManager'`.

- [ ] **Step 3: Add fields**

In `LocationService.swift`, after the `manager` declaration (line 12) add:

```swift
    /// A dedicated manager for one-shot `current()` fixes, kept separate from the ambient
    /// `manager` so a one-shot and the continuous ambient monitor never share delegate state.
    @ObservationIgnored let oneShotManager = CLLocationManager()

    /// Most recent ambient (coarse, Home-foreground) fix. Drives weather refresh and the
    /// `.coarse` branch of `current()`. Nil until the ambient monitor delivers.
    public private(set) var lastKnown: LocationFix?

    /// Callers awaiting the current in-flight one-shot fix; resumed together (coalesced) when
    /// the one-shot manager delivers or fails, then cleared. Guarantees resume-exactly-once.
    @ObservationIgnored private var oneShotWaiters: [CheckedContinuation<Coordinate?, Never>] = []
```

In `init()` (after line 21 `manager.delegate = self`) add:

```swift
        oneShotManager.delegate = self
```

- [ ] **Step 4: Add the main-actor handlers + rewrite the delegate extension**

Add these methods inside the `LocationService` class body (e.g. after `stop()`):

```swift
    /// Route a delegate fix to the right consumer by manager identity: the one-shot manager
    /// resumes every coalesced `current()` waiter; any other manager (the ambient `manager`)
    /// records `lastKnown`. Internal so unit tests can drive it without a device.
    @MainActor func handleLocationUpdate(managerID: ObjectIdentifier, coordinate: Coordinate, timestamp: Date) {
        if managerID == ObjectIdentifier(oneShotManager) {
            let waiters = oneShotWaiters; oneShotWaiters = []
            waiters.forEach { $0.resume(returning: coordinate) }
        } else {
            lastKnown = LocationFix(coordinate: coordinate, at: timestamp)
        }
    }

    /// A one-shot failure resumes every waiter with nil (they fall back). Ambient failures are ignored.
    @MainActor func handleLocationFailure(managerID: ObjectIdentifier) {
        guard managerID == ObjectIdentifier(oneShotManager) else { return }
        let waiters = oneShotWaiters; oneShotWaiters = []
        waiters.forEach { $0.resume(returning: nil) }
    }
```

Replace the delegate extension (lines 139-146) with:

```swift
extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        // Snapshot the Sendable status synchronously so the non-Sendable manager `m`
        // never crosses into the main-actor Task (Swift 6 region isolation).
        let status = m.authorizationStatus
        Task { @MainActor in self.authorization = LocationAuthorization(status) }
    }

    nonisolated public func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Extract Sendable values synchronously; CLLocation is not Sendable.
        guard let loc = locations.last else { return }
        let coord = Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        let ts = loc.timestamp
        let id = ObjectIdentifier(m)
        Task { @MainActor in self.handleLocationUpdate(managerID: id, coordinate: coord, timestamp: ts) }
    }

    nonisolated public func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let id = ObjectIdentifier(m)
        Task { @MainActor in self.handleLocationFailure(managerID: id) }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter LocationServiceTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/LocationService.swift AuraCore/Tests/AuraKitTests/LocationServiceTests.swift
git commit -m "feat(location): dedicated one-shot manager + demuxed delegate + lastKnown (ROH-83)"
```

---

### Task 5: True one-shot `current(for:)`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/LocationService.swift` (rewrite `current()` lines 106-122; delete `firstLiveCoordinate()` lines 124-136)
- Test: `AuraCore/Tests/AuraKitTests/LocationServiceTests.swift`

**Interfaces:**
- Consumes: `resolveOrigin`, `LocationPurpose`, `LocationFix` (Task 3); `oneShotManager`, `oneShotWaiters`, `lastKnown` (Task 4).
- Produces: `LocationService.current(for purpose: LocationPurpose = .routing) async -> Coordinate`. Callers: `RoutePreviewView` (default `.routing`), `HomeView` (`.coarse`, wired in Task 8).

- [ ] **Step 1: Write the failing test**

Add to `LocationServiceTests.swift`:

```swift
func test_current_deniedAuthorization_returnsFallbackWithoutHanging() async {
    let svc = LocationService()
    // Fresh service on macOS/sim test host is not authorized; the denied/undetermined path
    // must resolve to the Pittsburgh fallback via the timeout race, never hang.
    let origin = await svc.current(for: .routing)
    XCTAssertEqual(origin.latitude, 40.4406, accuracy: 0.0001)
    XCTAssertEqual(origin.longitude, -79.9959, accuracy: 0.0001)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter LocationServiceTests/test_current_deniedAuthorization_returnsFallbackWithoutHanging`
Expected: FAIL — `current` has no `for:` parameter (extra-argument error).

- [ ] **Step 3: Rewrite `current()` and delete `firstLiveCoordinate()`**

Replace `current()` (lines 106-122) with:

```swift
    /// One-shot origin for plan/preview and Home weather, with a Pittsburgh fallback. Never
    /// throws and never opens a continuous stream. Resolution: a fresh precise cached fix wins;
    /// a `.coarse` caller may take a fresh ambient fix; otherwise a single `requestLocation()`
    /// on the dedicated one-shot manager, bounded by a timeout, then the fallback.
    public func current(for purpose: LocationPurpose = .routing) async -> Coordinate {
        let fallback = Coordinate(latitude: 40.4406, longitude: -79.9959)
        let now = Date()
        let cached = manager.location.map {
            LocationFix(coordinate: Coordinate(latitude: $0.coordinate.latitude,
                                               longitude: $0.coordinate.longitude), at: $0.timestamp)
        }
        if let resolved = resolveOrigin(cached: cached, ambient: lastKnown, purpose: purpose, now: now) {
            return resolved
        }
        switch manager.authorizationStatus {
        case .denied, .restricted: return fallback
        default: break
        }
        return await firstOneShotCoordinate() ?? fallback
    }

    /// Await a single fix from the dedicated one-shot manager, bounded by `timeout`. Coalesces
    /// concurrent callers onto one `requestLocation()`; all waiters resume together — from the
    /// delegate on success/failure (Task 4), or from the timeout below, whichever fires first.
    /// Resume is exactly-once per waiter: whichever path runs first empties `oneShotWaiters` on
    /// the main actor, so the other sees an empty list and resumes nobody. The timeout task is
    /// never cancelled (avoids the Swift 6.2 cancel-while-sleeping abort); it just clears stragglers.
    /// NOTE: do NOT wrap this in a `withTaskGroup` timeout race — `withCheckedContinuation` ignores
    /// cancellation, so a parked waiter would keep the group's implicit await-all alive past the
    /// timeout and hang `current()`. The timeout must live inside the continuation, as here.
    private func firstOneShotCoordinate(timeout: TimeInterval = 3) async -> Coordinate? {
        await withCheckedContinuation { (cont: CheckedContinuation<Coordinate?, Never>) in
            oneShotWaiters.append(cont)
            guard oneShotWaiters.count == 1 else { return }   // coalesce: a request is already in flight
            oneShotManager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                let waiters = self.oneShotWaiters
                self.oneShotWaiters = []
                waiters.forEach { $0.resume(returning: nil) }
            }
        }
    }
```

Delete `firstLiveCoordinate()` (old lines 124-136) entirely.

- [ ] **Step 4: Run the whole package test suite**

Run: `swift test --package-path AuraCore --filter LocationServiceTests`
Expected: PASS. (The denied-path test returns the fallback within ~3s.)

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/LocationService.swift AuraCore/Tests/AuraKitTests/LocationServiceTests.swift
git commit -m "feat(location): true one-shot current(for:) on dedicated manager (ROH-83)"
```

---

### Task 6: Ambient monitor + `releaseNonRide`, and harden ride teardown

**Files:**
- Modify: `AuraCore/Sources/AuraKit/LocationService.swift` (add ambient methods; edit `points()` onTermination lines 84-88; verify `stop()` lines 92-100)
- Test: `AuraCore/Tests/AuraKitTests/LocationServiceTests.swift`

**Interfaces:**
- Consumes: `setMode`, `mode` (Task 1).
- Produces:
  - `LocationService.startAmbient()` — gated on `authorization == .authorized` and `mode != .navigating`.
  - `LocationService.releaseNonRide()` — stops the ambient monitor + one-shot; **no-op while `.navigating`** (never touches the ride pipeline).

- [ ] **Step 1: Write the failing test**

Add to `LocationServiceTests.swift`:

```swift
func test_startAmbient_noopsWhenNotAuthorized() {
    let svc = LocationService()   // fresh -> notDetermined
    svc.startAmbient()
    XCTAssertEqual(svc.mode, .idle, "ambient must not start without authorization")
}

func test_releaseNonRide_isNoopWhileNavigating() {
    let svc = LocationService()
    svc.setMode(.navigating)      // pretend a ride is configuring the manager
    svc.releaseNonRide()
    XCTAssertEqual(svc.mode, .navigating, "releaseNonRide must never tear down the ride pipeline")
}

func test_releaseNonRide_stopsAmbient() {
    let svc = LocationService()
    svc.setMode(.ambient)         // simulate ambient running
    svc.releaseNonRide()
    XCTAssertEqual(svc.mode, .idle)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter LocationServiceTests/test_startAmbient_noopsWhenNotAuthorized`
Expected: FAIL — `has no member 'startAmbient'`.

- [ ] **Step 3: Implement ambient + releaseNonRide**

Add to the `LocationService` class body (after `stop()`):

```swift
    /// Start the coarse, foreground-only ambient monitor used for Home weather. Gated on real
    /// authorization so it never triggers the permission prompt (that stays on the ride path)
    /// and never runs unauthorized. No background session, indicator off (see `setMode`). No-op
    /// if a ride owns the manager.
    public func startAmbient() {
        guard authorization == .authorized, mode != .navigating else { return }
        setMode(.ambient)
        manager.startUpdatingLocation()
    }

    /// Release all NON-ride location: stop the ambient monitor and drop any pending one-shot.
    /// A no-op while navigating so it can be called freely from the app lifecycle controller
    /// without ever interrupting a recording ride.
    public func releaseNonRide() {
        guard mode != .navigating else { return }
        manager.stopUpdatingLocation()
        setMode(.idle)
    }
```

- [ ] **Step 4: Harden ride teardown — drop the async self-stop race**

In `points()`, delete the `continuation.onTermination` block (lines 84-88):

```swift
        continuation.onTermination = { [weak self] _ in
            // onTermination fires off the main actor when the consumer drops the
            // stream; hop back in to tear down the manager state.
            Task { @MainActor in self?.stop() }
        }
```

Rationale to record in the commit: teardown is now explicit and synchronous via `stop()` (called by the coordinator on finish/cancel and by `.onDisappear`). The delayed async self-stop could land after the controller re-armed `.ambient` and clobber it. `stop()` (lines 92-100) already cancels the task, invalidates+nils the background session, finishes the continuation, and calls `setMode(.idle)` synchronously — leave that body unchanged.

- [ ] **Step 5: Add a ride-teardown regression test**

Add to `LocationServiceTests.swift`:

```swift
func test_stop_releasesToIdle() {
    let svc = LocationService()
    svc.setMode(.navigating)
    svc.stop()
    XCTAssertEqual(svc.mode, .idle)
    #if os(iOS)
    XCTAssertFalse(svc.manager.showsBackgroundLocationIndicator)
    #endif
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter LocationServiceTests`
Expected: PASS (all tests).

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraKit/LocationService.swift AuraCore/Tests/AuraKitTests/LocationServiceTests.swift
git commit -m "feat(location): ambient monitor + releaseNonRide; drop onTermination self-stop race (ROH-83)"
```

---

### Task 7: RootView single-writer tier controller

**Files:**
- Modify: `Aura/Sources/AuraApp.swift` (`RootView`, lines 78-142)

**Interfaces:**
- Consumes: `LocationAccuracyMode.desired(...)` (Task 2); `LocationService.startAmbient()`/`releaseNonRide()` (Task 6); `router.path`, `router.isRideActive`, `scenePhase`, `location.authorization`.

This task is UI wiring — verified by build + the device checklist, not a unit test.

- [ ] **Step 1: Add the LocationService environment to `RootView`**

After line 82 (`@Environment(SettingsStore.self) private var settings`) add:

```swift
    @Environment(LocationService.self) private var location
```

- [ ] **Step 2: Add the controller method**

Inside `RootView`, add:

```swift
    /// Single writer for the non-ride location tier. Computes the desired tier from explicit
    /// app state (never from view appear/disappear, which is unreliable on this retained nav
    /// root) and applies it. The ride pipeline owns `.navigating` via the coordinator, so this
    /// yields entirely while a ride is active.
    private func syncLocationActivity() {
        let isHomeForeground = router.path.isEmpty && scenePhase == .active
        switch LocationAccuracyMode.desired(isRideActive: router.isRideActive,
                                            isHomeForeground: isHomeForeground,
                                            authorized: location.authorization == .authorized) {
        case .ambient: location.startAmbient()
        case .idle: location.releaseNonRide()
        case .navigating: break   // owned by the ride pipeline
        }
    }
```

- [ ] **Step 3: Wire the observers**

Merge into the existing `scenePhase` handler (line 131-133) and add the other triggers. Replace lines 131-133 with:

```swift
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { WidgetRefresh.reload(rideStore: rideStore, settings: settings) }
            syncLocationActivity()
        }
        .onChange(of: router.path) { _, _ in syncLocationActivity() }
        .onChange(of: router.isRideActive) { _, _ in syncLocationActivity() }
        .onChange(of: location.authorization) { _, _ in syncLocationActivity() }
        .task { syncLocationActivity() }
```

- [ ] **Step 4: Build the app to verify it compiles**

Delegate to the builder subagent (apple-platform-build-tools:builder): "Build the Aura app scheme for the iOS simulator; report only success or the first error."
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/AuraApp.swift
git commit -m "feat(location): RootView single-writer tier controller (ROH-83)"
```

---

### Task 8: Home weather — coarse purpose + refresh-on-move

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift` (`refreshWeather` line 142; add an `.onChange` near lines 63-64)

**Interfaces:**
- Consumes: `LocationService.current(for:)` (Task 5), `LocationService.lastKnown` (Task 4).

This task is UI wiring — verified by build + the device checklist.

- [ ] **Step 1: Use the coarse purpose for weather**

In `refreshWeather()` (line 142) change:

```swift
        await weather.refresh(near: location.current(), now: Date())
```
to:
```swift
        await weather.refresh(near: location.current(for: .coarse), now: Date())
```

- [ ] **Step 2: Refresh weather as the ambient fix moves**

After line 64 (`.onChange(of: location.authorization) { Task { await refreshWeather() } }`) add:

```swift
        // The ambient monitor publishes a new coarse fix roughly every 500 m (distanceFilter);
        // refresh weather when it changes so the greeting tracks the rider without a continuous
        // high-power locate.
        .onChange(of: location.lastKnown) { Task { await refreshWeather() } }
```

- [ ] **Step 3: Confirm the routing caller is untouched**

Verify `RoutePreviewView.swift:294` still reads `await location.current()` (defaults to `.routing`). No edit needed — the default preserves a fine origin. Do not change it.

- [ ] **Step 4: Build the app to verify it compiles**

Delegate to the builder subagent: "Build the Aura app scheme for the iOS simulator; report only success or the first error."
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Home/HomeView.swift
git commit -m "feat(location): Home weather uses coarse one-shot + refresh on ambient move (ROH-83)"
```

---

### Task 9: Whole-package verification, lint, and Linear update

**Files:** none (verification only).

- [ ] **Step 1: Run the full package test suite**

Run: `swift test --package-path AuraCore`
Expected: PASS, no regressions. Record the pass count.

- [ ] **Step 2: Lint (strict, matches CI)**

Run: `swiftlint --strict` from the repo root (or via the builder subagent if the binary isn't on PATH).
Expected: no violations. Fix any and re-run.

- [ ] **Step 3: Build the app for the simulator**

Delegate to the builder subagent: "Build the Aura app for the iOS simulator and run the AuraUITests smoke suite if quick; report success or first error."
Expected: build succeeds.

- [ ] **Step 4: Move ROH-83 to In Review**

Update the Linear issue ROH-83 status to "In Review" once the PR/branch is ready, with a note that the fix is code-complete and pending on-device verification of the pill behavior.

- [ ] **Step 5: No code commit** (verification task). If lint fixes were needed, commit them:

```bash
git add -A
git commit -m "chore(location): lint + suite pass for location lifecycle (ROH-83)"
```

---

## Device-verification checklist (post-merge, needs the physical iPhone)

Not automatable here — carry these from the spec into the on-device pass:

- [ ] Capture (Console/Instruments) which session is alive when the pill persists — confirm Pipeline A vs B vs the Mapbox puck provider.
- [ ] Background pill is off within seconds of ending a ride and returning to Home.
- [ ] Background pill does not appear while idle on Home (foreground arrow only, from ambient).
- [ ] No background pill survives force-quit when no ride is active.
- [ ] No background pill (or arrow) while sitting in Settings / History with no ride.
- [ ] In-ride recording + pill behavior unchanged during a live ride.
- [ ] Mapbox puck provider is not left running after a ride ends.
- [ ] Home weather resolves and updates as the rider moves ~500 m.
- [ ] First permission prompt still appears at ride start, not on first Home load.
