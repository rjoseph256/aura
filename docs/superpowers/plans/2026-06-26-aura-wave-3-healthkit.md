# Wave 3 HealthKit cycling-workouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At ride finish, write an opted-in rider's completed ride to Apple Health as a cycling workout (distance + GPS route) through a new injected `WorkoutWriting` seam on `RideSessionCoordinator`.

**Architecture:** Pure mapping/gating (`WorkoutData`, `RideWorkoutGate`) in `AuraCore`; the `WorkoutWriting` protocol and a testable `CLLocation` route reconstruction in `AuraKit`; the HealthKit implementation (`WorkoutWriter`) in the `Aura` app target behind that protocol. The coordinator calls the seam fire-and-forget at the end of `finish()`, after the save, so HealthKit can never block or fail the ride save. A "Save rides to Health" Settings toggle is the opt-in and triggers the write-only authorization prompt on first enable.

**Tech Stack:** Swift 6.2 / Xcode 26, Swift Testing + XCTest, HealthKit (`HKWorkoutBuilder`, `HKWorkoutRouteBuilder`), CoreLocation, SwiftUI, XcodeGen.

## Global Constraints

- **Toolchain:** Swift 6.2 / Xcode 26; iPhone 17 / iOS 26.x simulator; SwiftLint 0.64.1 pinned, `--strict`.
- **Lint every task gate:** run `scripts/lint.sh` (whole-repo SwiftLint `--strict`) at every task, package tasks included. Watch the leak-prone rules: `line_length` ≤ 140, no `large_tuple` (avoid 3+ member tuples), `opening_brace` (no aligned multi-space before `{`).
- **CI-safety:** `AuraCore` and `AuraKit` build on the macOS CI host. No HealthKit symbol may appear in either package module. CoreLocation is allowed in `AuraKit` (it already depends on it). Every `HK*` symbol lives only in the `Aura` app target.
- **Layers:** `AuraCore` (pure), `AuraKit` (CoreLocation OK, no SwiftUI, no HealthKit), `Aura` app target (SwiftUI + Mapbox + HealthKit). UI-bound `@Observable` stores stay `@MainActor`. Prefer `static let` over `static var` for protocol/type statics.
- **Git hygiene:** NEVER `git add AuraCore/Package.resolved` (revert with `git checkout -- AuraCore/Package.resolved` if a build dirties it). Do NOT commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored). Stage only the files each task names.
- **XcodeGen:** an app-target file ADD/DELETE (including the new entitlements file) requires `cd Aura && xcodegen generate`. Package files under `AuraCore/Sources/**` are auto-globbed — no regen.
- **Theme:** mono-lime `AuraTheme`, no new palette. Lime accent on near-black; the Health row uses `heart.fill` tinted `AuraTheme.accent`.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File Structure

- `AuraCore/Sources/AuraCore/Health/WorkoutData.swift` (create) — pure value type + `init(from: Ride)` mapping.
- `AuraCore/Sources/AuraCore/Health/RideWorkoutGate.swift` (create) — pure write gate.
- `AuraCore/Tests/AuraCoreTests/WorkoutDataTests.swift` (create) — mapping + gate tests.
- `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift` (modify) — add `WorkoutWriting`.
- `AuraCore/Sources/AuraKit/Health/WorkoutRouteLocations.swift` (create) — `TrackPoint` → `CLLocation`.
- `AuraCore/Tests/AuraKitTests/WorkoutRouteLocationsTests.swift` (create) — reconstruction tests.
- `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (modify) — inject `workout:`, snapshot `saveToHealth`, call gate + seam in `finish()`.
- `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift` (modify) — `SpyWorkoutWriter` + write tests.
- `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift` (modify) — add `saveToHealth`.
- `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift` (modify) — toggle test.
- `Aura/Resources/Aura.entitlements` (create) — HealthKit entitlement.
- `Aura/project.yml` (modify) — `CODE_SIGN_ENTITLEMENTS` + resources exclude.
- `Aura/Resources/Info.plist` (modify) — `NSHealthUpdateUsageDescription`.
- `Aura/Sources/Health/WorkoutWriter.swift` (create) — the HealthKit shell.
- `Aura/Sources/Health/HealthAppLink.swift` (create) — opens the Health app.
- `Aura/Sources/Settings/HealthAccessRow.swift` (create) — the opt-in row + explainer.
- `Aura/Sources/Settings/SettingsView.swift` (modify) — drop in `HealthAccessRow`.
- `Aura/Sources/Ride/RideHUDView.swift` (modify) — inject `WorkoutWriter.shared`, pass `saveToHealth`.
- `Aura/Sources/Ride/NavigateHUDView.swift` (modify) — same.

---

### Task 1: AuraCore — `WorkoutData` mapping and `RideWorkoutGate`

**Files:**
- Create: `AuraCore/Sources/AuraCore/Health/WorkoutData.swift`
- Create: `AuraCore/Sources/AuraCore/Health/RideWorkoutGate.swift`
- Test: `AuraCore/Tests/AuraCoreTests/WorkoutDataTests.swift`

**Interfaces:**
- Consumes: `Ride`, `RideStats`, `TrackPoint` (existing `AuraCore` models).
- Produces:
  - `struct WorkoutData: Equatable, Sendable` with `let externalID: UUID, start: Date, end: Date, distanceMeters: Double, route: [TrackPoint]`, a memberwise `init`, and `init(from ride: Ride)`.
  - `enum RideWorkoutGate` with `static let minimumDistanceMeters: Double = 10` and `static func shouldWrite(ride: Ride, saveToHealthEnabled: Bool) -> Bool`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/WorkoutDataTests.swift`:

```swift
import Testing
import Foundation
import AuraCore

@Suite struct WorkoutDataTests {
    private func stats(_ distance: Double) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: 0,
                  averageSpeedMetersPerSecond: 0, maxSpeedMetersPerSecond: 0,
                  elevationGainMeters: 0)
    }

    private func point(_ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0),
                   elevation: 250, timestamp: Date(timeIntervalSince1970: t))
    }

    private func ride(started: TimeInterval, endedAt: Date?, distance: Double?,
                      track: [TrackPoint] = []) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: started),
             endedAt: endedAt, track: track, stats: distance.map(stats),
             routeId: nil, destinationPlaceId: nil)
    }

    // MARK: WorkoutData(from:)

    @Test func mapsCoreFields() {
        let r = ride(started: 100, endedAt: Date(timeIntervalSince1970: 200),
                     distance: 4321, track: [point(100), point(200)])
        let data = WorkoutData(from: r)
        #expect(data.externalID == r.id)
        #expect(data.start == Date(timeIntervalSince1970: 100))
        #expect(data.end == Date(timeIntervalSince1970: 200))
        #expect(data.distanceMeters == 4321)
        #expect(data.route.count == 2)
    }

    @Test func endFallsBackToLastTrackTimestampWhenNoEndDate() {
        let r = ride(started: 100, endedAt: nil, distance: 50,
                     track: [point(100), point(175)])
        #expect(WorkoutData(from: r).end == Date(timeIntervalSince1970: 175))
    }

    @Test func endFallsBackToStartWhenNoEndDateAndNoTrack() {
        let r = ride(started: 100, endedAt: nil, distance: 50)
        #expect(WorkoutData(from: r).end == Date(timeIntervalSince1970: 100))
    }

    @Test func endIsClampedToStartOnClockSkew() {
        // endedAt earlier than startedAt must not yield end < start.
        let r = ride(started: 500, endedAt: Date(timeIntervalSince1970: 400), distance: 50)
        let data = WorkoutData(from: r)
        #expect(data.end == data.start)
    }

    @Test func distanceDefaultsToZeroWhenStatsMissing() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: nil)
        #expect(WorkoutData(from: r).distanceMeters == 0)
    }

    // MARK: RideWorkoutGate

    @Test func gateBlocksWhenDisabled() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: 1000)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: false) == false)
    }

    @Test func gateBlocksWhenNotEnded() {
        let r = ride(started: 0, endedAt: nil, distance: 1000)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == false)
    }

    @Test func gateBlocksBelowDistanceFloor() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: 9)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == false)
    }

    @Test func gateBlocksWhenStatsMissing() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: nil)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == false)
    }

    @Test func gateWritesWhenEnabledEndedAndOverFloor() {
        let r = ride(started: 0, endedAt: Date(timeIntervalSince1970: 10), distance: 10)
        #expect(RideWorkoutGate.shouldWrite(ride: r, saveToHealthEnabled: true) == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd AuraCore && swift test --filter WorkoutDataTests`
Expected: FAIL — `cannot find 'WorkoutData' in scope` / `cannot find 'RideWorkoutGate' in scope`.

- [ ] **Step 3: Write `WorkoutData`**

Create `AuraCore/Sources/AuraCore/Health/WorkoutData.swift`:

```swift
import Foundation

/// What to write to Health for one finished ride, framework-free so the mapping
/// is testable on the macOS CI host. The HealthKit-touching code lives in the app
/// target and consumes this value.
public struct WorkoutData: Equatable, Sendable {
    public let externalID: UUID
    public let start: Date
    public let end: Date
    public let distanceMeters: Double
    public let route: [TrackPoint]

    public init(externalID: UUID, start: Date, end: Date,
                distanceMeters: Double, route: [TrackPoint]) {
        self.externalID = externalID
        self.start = start
        self.end = end
        self.distanceMeters = distanceMeters
        self.route = route
    }

    /// Maps a finished ride. `end` falls back from `endedAt` to the last track
    /// timestamp to `startedAt`, then is clamped to `>= start` so a degenerate or
    /// clock-skewed ride can never produce `end < start` (which `HKWorkoutBuilder`
    /// rejects).
    public init(from ride: Ride) {
        let rawEnd = ride.endedAt ?? ride.track.last?.timestamp ?? ride.startedAt
        self.externalID = ride.id
        self.start = ride.startedAt
        self.end = max(rawEnd, ride.startedAt)
        self.distanceMeters = ride.stats?.distanceMeters ?? 0
        self.route = ride.track
    }
}
```

- [ ] **Step 4: Write `RideWorkoutGate`**

Create `AuraCore/Sources/AuraCore/Health/RideWorkoutGate.swift`:

```swift
import Foundation

/// Pure decision for whether a finished ride should be written to Health.
public enum RideWorkoutGate {
    /// Minimum recorded distance (meters) worth a Health workout. Keeps an
    /// accidental few-second ride from littering Health with junk.
    public static let minimumDistanceMeters: Double = 10

    public static func shouldWrite(ride: Ride, saveToHealthEnabled: Bool) -> Bool {
        guard saveToHealthEnabled else { return false }
        guard ride.endedAt != nil else { return false }
        return (ride.stats?.distanceMeters ?? 0) >= minimumDistanceMeters
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd AuraCore && swift test --filter WorkoutDataTests`
Expected: PASS (11 tests).

- [ ] **Step 6: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no `--strict` violations.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Health/WorkoutData.swift \
        AuraCore/Sources/AuraCore/Health/RideWorkoutGate.swift \
        AuraCore/Tests/AuraCoreTests/WorkoutDataTests.swift
git commit -m "feat(health): pure WorkoutData mapping and RideWorkoutGate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
```

---

### Task 2: AuraKit — `WorkoutWriting` seam and `CLLocation` route reconstruction

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift`
- Create: `AuraCore/Sources/AuraKit/Health/WorkoutRouteLocations.swift`
- Test: `AuraCore/Tests/AuraKitTests/WorkoutRouteLocationsTests.swift`

**Interfaces:**
- Consumes: `WorkoutData`, `TrackPoint` (from Task 1 / `AuraCore`).
- Produces:
  - `@MainActor public protocol WorkoutWriting: AnyObject { func writeWorkout(_ data: WorkoutData) }`.
  - `enum WorkoutRouteLocations` with `static let synthesizedHorizontalAccuracy: CLLocationAccuracy = 5` and `static func clLocations(from track: [TrackPoint]) -> [CLLocation]`.

- [ ] **Step 1: Confirm the full `CLLocation` initializer compiles on the macOS host**

This guards the plan's load-bearing "testable on CI" claim before writing the test. Add the helper file first (Step 3 content), then run `cd AuraCore && swift build`. If the designated initializer `CLLocation(coordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:)` does not compile on macOS, stop and report — do not proceed. (It is iOS/macOS common and expected to compile.)

- [ ] **Step 2: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/WorkoutRouteLocationsTests.swift`:

```swift
import Testing
import Foundation
import CoreLocation
import AuraCore
@testable import AuraKit

@Suite struct WorkoutRouteLocationsTests {
    private func point(_ lat: Double, _ lon: Double, elevation: Double?, _ t: TimeInterval)
        -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: lon), elevation: elevation,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    @Test func synthesizesPositiveHorizontalAccuracy() {
        let locs = WorkoutRouteLocations.clLocations(from: [point(40.4, -80.0, elevation: 250, 0)])
        #expect(locs.count == 1)
        #expect(locs[0].horizontalAccuracy > 0)
    }

    @Test func preservesOrderAndTimestamps() {
        let track = [point(40.40, -80.0, elevation: 250, 0),
                     point(40.41, -80.0, elevation: 251, 10),
                     point(40.42, -80.0, elevation: 252, 20)]
        let locs = WorkoutRouteLocations.clLocations(from: track)
        #expect(locs.map { $0.timestamp.timeIntervalSince1970 } == [0, 10, 20])
        #expect(locs[0].coordinate.latitude == 40.40)
    }

    @Test func altitudeAndVerticalAccuracyOnlyWhenElevationPresent() {
        let withEle = WorkoutRouteLocations.clLocations(from: [point(40.4, -80, elevation: 300, 0)])
        let without = WorkoutRouteLocations.clLocations(from: [point(40.4, -80, elevation: nil, 0)])
        #expect(withEle[0].altitude == 300)
        #expect(withEle[0].verticalAccuracy > 0)
        #expect(without[0].verticalAccuracy < 0)
    }

    @Test func dropsInvalidCoordinates() {
        let track = [point(40.4, -80, elevation: nil, 0),
                     point(200, 999, elevation: nil, 10)]
        #expect(WorkoutRouteLocations.clLocations(from: track).count == 1)
    }

    @Test func emptyTrackYieldsEmpty() {
        #expect(WorkoutRouteLocations.clLocations(from: []).isEmpty)
    }
}
```

- [ ] **Step 3: Write the route helper**

Create `AuraCore/Sources/AuraKit/Health/WorkoutRouteLocations.swift`:

```swift
import Foundation
import CoreLocation
import AuraCore

/// Reconstructs `CLLocation`s from a recorded track for `HKWorkoutRouteBuilder`.
/// Pure and CoreLocation-only, so it builds and tests on the macOS CI host; the
/// route builder itself (iOS-only HealthKit) consumes the result in the app target.
public enum WorkoutRouteLocations {
    /// The recorded track was accuracy-filtered at capture (Wave 0), but the per-fix
    /// horizontal accuracy was not retained on `TrackPoint`. The route builder rejects
    /// any location with `horizontalAccuracy <= 0`, so a positive value is synthesized.
    public static let synthesizedHorizontalAccuracy: CLLocationAccuracy = 5

    public static func clLocations(from track: [TrackPoint]) -> [CLLocation] {
        track.compactMap { point in
            let coordinate = CLLocationCoordinate2D(latitude: point.coordinate.latitude,
                                                    longitude: point.coordinate.longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            if let elevation = point.elevation {
                return CLLocation(
                    coordinate: coordinate, altitude: elevation,
                    horizontalAccuracy: synthesizedHorizontalAccuracy,
                    verticalAccuracy: synthesizedHorizontalAccuracy,
                    course: -1, speed: -1, timestamp: point.timestamp)
            }
            return CLLocation(
                coordinate: coordinate, altitude: 0,
                horizontalAccuracy: synthesizedHorizontalAccuracy,
                verticalAccuracy: -1,
                course: -1, speed: -1, timestamp: point.timestamp)
        }
    }
}
```

- [ ] **Step 4: Add the `WorkoutWriting` protocol**

Modify `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift` — append after the `RideSaving` extension:

```swift
/// Writes a finished ride to Apple Health as a cycling workout. The app conforms a
/// HealthKit-backed type; the package never imports HealthKit. Fire-and-forget: the
/// coordinator calls this and moves on, so a HealthKit failure cannot affect the save.
@MainActor
public protocol WorkoutWriting: AnyObject {
    func writeWorkout(_ data: WorkoutData)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd AuraCore && swift test --filter WorkoutRouteLocationsTests`
Expected: PASS (5 tests).

- [ ] **Step 6: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift \
        AuraCore/Sources/AuraKit/Health/WorkoutRouteLocations.swift \
        AuraCore/Tests/AuraKitTests/WorkoutRouteLocationsTests.swift
git commit -m "feat(health): WorkoutWriting seam and CLLocation route reconstruction

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
```

---

### Task 3: AuraKit — wire the seam into `RideSessionCoordinator`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `WorkoutWriting` (Task 2), `RideWorkoutGate` + `WorkoutData` (Task 1).
- Produces: `RideSessionCoordinator.init` gains `workout: (any WorkoutWriting)? = nil`; `start(...)` gains `saveToHealth: Bool = false`; `finish()` writes the workout when the gate passes.

- [ ] **Step 1: Write the failing tests**

Modify `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`. Add the spy double in the `// MARK: - Doubles` section (after `ThrowingRideSaving`):

```swift
@MainActor
final class SpyWorkoutWriter: WorkoutWriting {
    private(set) var written: [WorkoutData] = []
    func writeWorkout(_ data: WorkoutData) { written.append(data) }
}
```

Add these tests inside the `RideSessionCoordinatorTests` struct (before the closing brace):

```swift
@Test func finishWritesWorkoutWhenEnabledAndQualifies() async throws {
    let spy = SpyWorkoutWriter()
    let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                   screen: SpyScreenWake(), activity: SpyRideActivity(),
                                   workout: spy)
    c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
            saving: try RideStore.inMemory(), units: .metric,
            authorization: .authorized, saveToHealth: true)
    await c.streamTask?.value
    c.finish()
    #expect(spy.written.count == 1)
    #expect(spy.written.first?.externalID == c.finishedRide?.id)
}

@Test func finishDoesNotWriteWhenDisabled() async throws {
    let spy = SpyWorkoutWriter()
    let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                   screen: SpyScreenWake(), activity: SpyRideActivity(),
                                   workout: spy)
    c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
            saving: try RideStore.inMemory(), units: .metric,
            authorization: .authorized, saveToHealth: false)
    await c.streamTask?.value
    c.finish()
    #expect(spy.written.isEmpty)
}

@Test func finishDoesNotWriteBelowDistanceFloor() async throws {
    let spy = SpyWorkoutWriter()
    let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                   screen: SpyScreenWake(), activity: SpyRideActivity(),
                                   workout: spy)
    c.start(location: ScriptedLocationProvider([point(40.40, 0)]),
            saving: try RideStore.inMemory(), units: .metric,
            authorization: .authorized, saveToHealth: true)
    await c.streamTask?.value
    #expect(c.stats.distanceMeters < 10)  // guard the premise: one fix => under the floor
    c.finish()
    #expect(spy.written.isEmpty)
}

@Test func workoutWriteStillHappensWhenSaveFails() async throws {
    let spy = SpyWorkoutWriter()
    let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                   screen: SpyScreenWake(), activity: SpyRideActivity(),
                                   workout: spy)
    c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.41, 10)]),
            saving: ThrowingRideSaving(), units: .metric,
            authorization: .authorized, saveToHealth: true)
    await c.streamTask?.value
    c.finish()
    #expect(c.saveFailed == true)        // save threw
    #expect(c.finishedRide != nil)       // ride still published
    #expect(spy.written.count == 1)      // write runs after the save, unaffected
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: FAIL — `extra argument 'workout' in call` / `extra argument 'saveToHealth' in call`.

- [ ] **Step 3: Add the stored properties and init parameter**

Modify `RideSessionCoordinator.swift`. Add a stored property next to `activity`:

```swift
    private let activity: any RideActivityControlling
    private let workout: (any WorkoutWriting)?
```

Add the snapshot property next to the other stashed-at-start fields (near `private var startedAt: Date?`):

```swift
    private var saveToHealth = false
```

Update `init` to accept and store `workout` (defaulted, so existing call sites are unaffected):

```swift
    public init(kind: Ride.Kind,
                destinationName: String?,
                screen: any ScreenWakeControlling,
                activity: any RideActivityControlling,
                workout: (any WorkoutWriting)? = nil) {
        self.kind = kind
        self.recorder = RideRecorder(kind: kind)
        self.destinationName = destinationName
        self.screen = screen
        self.activity = activity
        self.workout = workout
    }
```

- [ ] **Step 4: Add the `saveToHealth` parameter to `start()` and snapshot it**

Change the `start(...)` signature to add the defaulted parameter:

```swift
    public func start(location: any LocationStreaming,
                      saving: any RideSaving,
                      units: DistanceUnits,
                      authorization: LocationAuthorization,
                      saveToHealth: Bool = false) -> StartOutcome {
```

Inside `start()`, where `self.location` and `self.saving` are assigned (after the authorization guard), add:

```swift
        self.location = location
        self.saving = saving
        self.saveToHealth = saveToHealth
```

- [ ] **Step 5: Call the gate and seam at the end of `finish()`**

In `finish()`, add after `finishedRide = ride` (the last line before the closing brace):

```swift
        finishedRide = ride
        if RideWorkoutGate.shouldWrite(ride: ride, saveToHealthEnabled: saveToHealth) {
            workout?.writeWorkout(WorkoutData(from: ride))
        }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: PASS (existing tests + 4 new).

- [ ] **Step 7: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 8: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift \
        AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift
git commit -m "feat(health): write workout from RideSessionCoordinator.finish behind the gate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
```

---

### Task 4: AuraCore — `saveToHealth` setting

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `SettingsStore.saveToHealth: Bool` (default `false`, persisted to `UserDefaults`).

- [ ] **Step 1: Write the failing test**

Add to `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift` inside `SettingsStoreTests`:

```swift
    func test_saveToHealth_defaultsOffAndPersists() {
        let s = freshStore()
        XCTAssertFalse(s.saveToHealth)
        s.saveToHealth = true
        XCTAssertTrue(s.saveToHealth)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd AuraCore && swift test --filter SettingsStoreTests`
Expected: FAIL — `value of type 'SettingsStore' has no member 'saveToHealth'`.

- [ ] **Step 3: Add the property**

Modify `SettingsStore.swift`. Add the stored property after `weeklyGoalMeters`:

```swift
    /// Opt-in: write finished rides to Apple Health as cycling workouts.
    public var saveToHealth: Bool { didSet { defaults.set(saveToHealth, forKey: Key.saveToHealth) } }
```

In `init`, after the `weeklyGoalMeters` seed:

```swift
        saveToHealth = defaults.object(forKey: Key.saveToHealth) as? Bool ?? false
```

In the `Key` enum, add:

```swift
        static let saveToHealth = "saveToHealth"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd AuraCore && swift test --filter SettingsStoreTests`
Expected: PASS.

- [ ] **Step 5: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Settings/SettingsStore.swift \
        AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift
git commit -m "feat(health): add saveToHealth opt-in to SettingsStore

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
```

---

### Task 5: App + project — HealthKit entitlement, Info.plist, XcodeGen

**Files:**
- Create: `Aura/Resources/Aura.entitlements`
- Modify: `Aura/project.yml`
- Modify: `Aura/Resources/Info.plist`

**Interfaces:**
- Produces: the `Aura` target builds with the HealthKit capability and the write usage string, ready for the HealthKit code in Tasks 6–7. No source files yet, so the app still builds with nothing HealthKit-referencing.

- [ ] **Step 1: Create the entitlements file**

> Deliberate deviation from the spec: the spec floats an XcodeGen `entitlements:` generator block, but a hand-authored, committed entitlements file referenced via `CODE_SIGN_ENTITLEMENTS` is simpler and avoids XcodeGen overwriting it on each regen. The file is a real source artifact (like `Info.plist`); the generated `Aura.xcodeproj` is still not committed.

Create `Aura/Resources/Aura.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.healthkit</key>
  <true/>
</dict>
</plist>
```

- [ ] **Step 2: Reference it from `project.yml` and exclude it from the resources copy**

Modify `Aura/project.yml`. In `targets.Aura.sources`, the `Resources` entry `excludes` list currently holds `Info.plist`, `MapboxAccessToken`, `sample-ride-pittsburgh.gpx`, `Fonts`. Add `Aura.entitlements`:

```yaml
      - path: Resources
        excludes:
          - Info.plist
          - MapboxAccessToken
          - sample-ride-pittsburgh.gpx
          - Fonts
          - Aura.entitlements
```

In `targets.Aura.settings.base`, add the entitlements build setting (alongside `INFOPLIST_FILE`):

```yaml
    settings:
      base:
        INFOPLIST_FILE: Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Resources/Aura.entitlements
        PRODUCT_BUNDLE_IDENTIFIER: app.aura.ios
        GENERATE_INFOPLIST_FILE: NO
        TARGETED_DEVICE_FAMILY: "1"
        SWIFT_VERSION: "6.0"
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
```

- [ ] **Step 3: Add the write usage string to Info.plist**

Modify `Aura/Resources/Info.plist`. After the `UIBackgroundModes` array (the `</array>` following `<string>location</string>`), add:

```xml
  <key>NSHealthUpdateUsageDescription</key>
  <string>Aura saves your finished rides to Health as cycling workouts, including distance and route.</string>
```

(No `NSHealthShareUsageDescription` — Aura requests write access only.)

- [ ] **Step 4: Regenerate the project**

Run: `cd Aura && xcodegen generate`
Expected: "Created project at .../Aura.xcodeproj".

- [ ] **Step 5: Build the app unsigned (proves the entitlement compiles in CI conditions)**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for the iPhone 17 / iOS 26 simulator with `CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED. (The entitlement is consumed at sign time, which is skipped, so an unsigned build still compiles.)

- [ ] **Step 6: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 7: Commit (do NOT commit the generated xcodeproj)**

```bash
git add Aura/Resources/Aura.entitlements Aura/project.yml Aura/Resources/Info.plist
git commit -m "build(health): add HealthKit entitlement and write usage string

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: App target — `WorkoutWriter` HealthKit shell

**Files:**
- Create: `Aura/Sources/Health/WorkoutWriter.swift`

**Interfaces:**
- Consumes: `WorkoutWriting`, `WorkoutData`, `WorkoutRouteLocations` (Tasks 1–2).
- Produces: `WorkoutWriter.shared` (a `@MainActor final class: WorkoutWriting`) with `requestAuthorization() async -> WorkoutWriter.AuthorizationResult` and `var isHealthDataAvailable: Bool`.

This task has no package unit test (HealthKit cannot compile in the package). It is verified by the app build gate here and the simulator run in Task 8.

- [ ] **Step 1: Write `WorkoutWriter`**

Create `Aura/Sources/Health/WorkoutWriter.swift`:

```swift
import Foundation
import HealthKit
import CoreLocation
import os
import AuraCore
import AuraKit

/// The HealthKit implementation of the `WorkoutWriting` seam. A shared singleton,
/// mirroring `RideLiveActivityController.shared`: the coordinator (injected at both
/// HUDs) and the Settings opt-in row use the same instance and one process-global
/// authorization. Fire-and-forget — a failure here never affects the ride save.
@MainActor
final class WorkoutWriter: WorkoutWriting {
    static let shared = WorkoutWriter()
    private init() {}

    enum AuthorizationResult { case authorized, denied, unavailable }

    private let healthStore = HKHealthStore()
    private let log = Logger(subsystem: "app.aura.ios", category: "HealthKit")

    private var shareTypes: Set<HKSampleType> {
        [HKWorkoutType.workoutType(),
         HKQuantityType(.distanceCycling),
         HKSeriesType.workoutRoute()]
    }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests write-only authorization for the cycling-workout types. Called from
    /// Settings when the rider turns the opt-in on. Honest about partial grants: the
    /// load-bearing `distanceCycling` share must also be authorized, not just the
    /// workout type, since HealthKit authorization is per-type.
    func requestAuthorization() async -> AuthorizationResult {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        do {
            try await healthStore.requestAuthorization(toShare: shareTypes, read: [])
        } catch {
            log.error("HealthKit authorization failed: \(error.localizedDescription)")
            return .unavailable
        }
        let workoutOK = healthStore.authorizationStatus(for: HKWorkoutType.workoutType())
            == .sharingAuthorized
        let distanceOK = healthStore.authorizationStatus(for: HKQuantityType(.distanceCycling))
            == .sharingAuthorized
        return (workoutOK && distanceOK) ? .authorized : .denied
    }

    // MARK: WorkoutWriting

    func writeWorkout(_ data: WorkoutData) {
        guard HKHealthStore.isHealthDataAvailable(),
              healthStore.authorizationStatus(for: HKWorkoutType.workoutType()) == .sharingAuthorized
        else { return }

        Task { await self.write(data) }
    }

    private func write(_ data: WorkoutData) async {
        do {
            let config = HKWorkoutConfiguration()
            config.activityType = .cycling
            config.locationType = .outdoor

            let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config,
                                           device: .local())
            try await builder.beginCollection(at: data.start)

            let distance = HKQuantity(unit: .meter(), doubleValue: max(0, data.distanceMeters))
            let sample = HKQuantitySample(type: HKQuantityType(.distanceCycling),
                                          quantity: distance, start: data.start, end: data.end)
            try await builder.add([sample])
            try await builder.addMetadata([HKMetadataKeyExternalUUID: data.externalID.uuidString])
            try await builder.endCollection(at: data.end)

            guard let workout = try await builder.finishWorkout() else {
                log.error("HealthKit finishWorkout returned nil")
                return
            }

            let locations = WorkoutRouteLocations.clLocations(from: data.route)
            guard !locations.isEmpty else { return }
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
            try await routeBuilder.insertRouteData(locations)
            try await routeBuilder.finishRoute(with: workout, metadata: nil)
        } catch {
            log.error("HealthKit workout write failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Regenerate the project (new app-target file)**

Run: `cd Aura && xcodegen generate`
Expected: project regenerated.

- [ ] **Step 3: Build the app**

Delegate to the builder subagent: build `Aura` for iPhone 17 / iOS 26 simulator with `CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED. If any HealthKit API name/signature is wrong (e.g. `add(_:)` vs `addMetadata(_:)`, builder init), fix against the `healthkit` skill and the Xcode 26 SDK, rebuild.

- [ ] **Step 4: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Health/WorkoutWriter.swift
git commit -m "feat(health): WorkoutWriter HealthKit shell (HKWorkoutBuilder + route)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: App target — Settings opt-in row, explainer, and HUD wiring

**Files:**
- Create: `Aura/Sources/Health/HealthAppLink.swift`
- Create: `Aura/Sources/Settings/HealthAccessRow.swift`
- Modify: `Aura/Sources/Settings/SettingsView.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `WorkoutWriter.shared` (Task 6), `SettingsStore.saveToHealth` (Task 4), `RideSessionCoordinator(workout:)` and `start(saveToHealth:)` (Task 3).
- Produces: the Settings opt-in UX and both HUDs injecting the writer and passing the toggle.

- [ ] **Step 1: Add the Health-app link helper**

Create `Aura/Sources/Health/HealthAppLink.swift`:

```swift
import UIKit

/// Opens the Health app so the rider can grant or revoke Aura's data access. The
/// Health sharing screen is not reliably deep-linkable, so this lands on Health's
/// home; `x-apple-health://` is the documented scheme.
enum HealthAppLink {
    @MainActor static func open() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url)
    }
}
```

- [ ] **Step 2: Add the opt-in row with the explainer**

Create `Aura/Sources/Settings/HealthAccessRow.swift`:

```swift
import SwiftUI
import AuraKit

/// The "Save rides to Health" Settings row. Owns the HealthKit authorization
/// interaction so `SettingsView` stays declarative and `AuraKit` stays HealthKit-free.
/// Turning the toggle on requests write authorization; a denial or an unavailable
/// store reverts the toggle and explains why, so the control never lies about whether
/// rides will actually save.
struct HealthAccessRow: View {
    @Environment(SettingsStore.self) private var settings
    @State private var showDenied = false
    @State private var showUnavailable = false

    var body: some View {
        @Bindable var settings = settings
        HStack(spacing: AuraTheme.Spacing.md) {
            Image(systemName: "heart.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)
                .frame(width: 26)
            Text("Save rides to Health").foregroundStyle(AuraTheme.textPrimary)
            Spacer()
            Toggle("", isOn: $settings.saveToHealth)
                .labelsHidden().tint(AuraTheme.accent)
                .accessibilityLabel("Save rides to Health")
        }
        .onChange(of: settings.saveToHealth) { _, isOn in
            guard isOn else { return }
            Task {
                switch await WorkoutWriter.shared.requestAuthorization() {
                case .authorized: break
                case .denied: settings.saveToHealth = false; showDenied = true
                case .unavailable: settings.saveToHealth = false; showUnavailable = true
                }
            }
        }
        .alert("Couldn't turn on Health", isPresented: $showDenied) {
            Button("Open Health") { HealthAppLink.open() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Aura doesn't have permission to save rides to Health. "
                 + "You can turn it on in the Health app under Sharing.")
        }
        .alert("Health unavailable", isPresented: $showUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device can’t save rides to Health.")
        }
    }
}
```

- [ ] **Step 3: Drop the row into SettingsView**

Modify `Aura/Sources/Settings/SettingsView.swift`. In the `Section("Ride")`, after the "Voice guidance" `row(...) { Toggle … }` block and before the "Weekly goal" row, add:

```swift
                HealthAccessRow()
```

- [ ] **Step 4: Inject the writer and pass the toggle in `RideHUDView`**

Modify `Aura/Sources/Ride/RideHUDView.swift`. Change the coordinator `@State` initializer (currently lines 11–13):

```swift
    @State private var coordinator = RideSessionCoordinator(
        kind: .freeRide, destinationName: nil,
        screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
        workout: WorkoutWriter.shared)
```

In `startRide()`, pass `saveToHealth`:

```swift
        let outcome = coordinator.start(
            location: location, saving: rideStore, units: settings.units,
            authorization: location.authorization, saveToHealth: settings.saveToHealth)
```

- [ ] **Step 5: Inject the writer and pass the toggle in `NavigateHUDView`**

Modify `Aura/Sources/Ride/NavigateHUDView.swift`. Change the coordinator construction in `init` (currently lines 55–57):

```swift
        _coordinator = State(initialValue: RideSessionCoordinator(
            kind: .navigate, destinationName: destination?.name,
            screen: ScreenWakeController(), activity: RideLiveActivityController.shared,
            workout: WorkoutWriter.shared))
```

In the start call (currently lines 146–148), pass `saveToHealth`:

```swift
            let outcome = coordinator.start(
                location: location, saving: rideStore, units: settings.units,
                authorization: location.authorization, saveToHealth: settings.saveToHealth)
```

- [ ] **Step 6: Regenerate the project (new app-target files)**

Run: `cd Aura && xcodegen generate`
Expected: project regenerated.

- [ ] **Step 7: Build the app**

Delegate to the builder subagent: build `Aura` for iPhone 17 / iOS 26 simulator with `CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Lint the whole repo**

Run: `scripts/lint.sh`
Expected: no violations.

- [ ] **Step 9: Commit**

```bash
git add Aura/Sources/Health/HealthAppLink.swift \
        Aura/Sources/Settings/HealthAccessRow.swift \
        Aura/Sources/Settings/SettingsView.swift \
        Aura/Sources/Ride/RideHUDView.swift \
        Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(health): Save-to-Health Settings opt-in and HUD wiring

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Simulator verification and holistic review

**Files:** none (verification only).

This is the real-result check a clean build cannot give. Use the iPhone 17 / iOS 26 simulator. Prefer the accessibility tree over screenshots; if a screenshot's md5 matches the prior frame, reboot the simulator (shutdown + boot) before trusting pixels. Install the freshly built `.app` from the authoritative `TARGET_BUILD_DIR` (`cd Aura && xcodebuild -showBuildSettings … | grep TARGET_BUILD_DIR`), not by mtime.

- [ ] **Step 1: Authorization prompt appears**

Launch the app, go to Settings, turn on "Save rides to Health". Confirm the HealthKit authorization sheet appears (it does on the simulator). Grant all. Confirm the toggle stays on.

- [ ] **Step 2: An opted-in finished ride writes a cycling workout**

Start a free ride (the simulated GPX ride), let it record a non-trivial distance, end it. Open the Health app on the simulator → Browse → Workouts (or Summary), and confirm one Cycling workout with the expected distance and duration, and that the workout shows a route/map. Read it back via the a11y tree or screenshots. Confirm exactly one workout was written (idempotency — not two).

- [ ] **Step 3: Opt-out path writes nothing and never breaks the save**

Turn the toggle off. Ride and finish. Confirm the ride still saves and shows its summary, and no new workout appears in Health.

- [ ] **Step 4: Denied path reverts the toggle and explains**

Reset the simulator's Health permissions (or use a fresh simulator), turn the toggle on, and deny in the sheet. Confirm the toggle reverts to off and the explainer alert appears with the "Open Health" action. Confirm a subsequent ride still saves normally.

- [ ] **Step 5: Holistic review**

Run a final holistic review of the whole diff on the most capable model (correctness, concurrency, CI-safety, theme, copy). Address any blocking finding.

- [ ] **Step 6: Record results**

No commit. Capture the verification outcomes for the PR body / final report. If any step cannot be completed in the simulator, note it explicitly rather than claiming success.

---

### Task 9: ROADMAP update

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Mark Wave 3 item 1 shipped**

Modify `docs/ROADMAP.md`. In the "Wave 3 — Near-term features" section, update the HealthKit bullet to SHIPPED with a one-paragraph summary in the same voice as the Wave 1/2 shipped bullets: the `WorkoutWriting` seam on `RideSessionCoordinator.finish()`, the pure `WorkoutData`/`RideWorkoutGate` mapping and gate, the `CLLocation` route reconstruction, the write-only authorization at toggle-on with the revert-on-denial explainer, the entitlement, and that distance + GPS route ship while active energy is a deferred fast-follow. Note the next Wave 3 piece is haptics. Run the wording through the `humanizer` lens.

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark Wave 3 HealthKit cycling-workouts shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** write scope (distance + route, no energy) → Tasks 1, 2, 6. Seam shape + fire-and-forget after save → Tasks 2, 3. Authorize at intent + revert on denial + explainer → Tasks 6, 7. Write-only share set → Task 6. Idempotency (single-shot + external UUID) → Tasks 1, 3, 6. Entitlement via XcodeGen + write usage string + unsigned-CI tolerance → Task 5. CI-safety (pure split, no HealthKit in package) → Tasks 1–4. Settings toggle → Tasks 4, 7. Accessibility of the row → Task 7. Testing (pure suites + sim verification + holistic review) → Tasks 1–3, 8. ROADMAP → Task 9. All spec sections map to a task.

**Placeholder scan:** every code step contains full code; no TBD/TODO; commands have expected output. Task 8 is verification-only by nature and lists concrete observable checks, not vague ones.

**Type consistency:** `WorkoutData` fields and `init(from:)` are identical across Tasks 1, 3, 6. `RideWorkoutGate.shouldWrite(ride:saveToHealthEnabled:)` matches between Tasks 1 and 3. `WorkoutWriting.writeWorkout(_:)` matches between Tasks 2, 3, 6. `RideSessionCoordinator.init(... workout:)` and `start(... saveToHealth:)` match between Task 3 and Task 7's call sites. `WorkoutWriter.shared` / `.requestAuthorization()` / `AuthorizationResult` match between Tasks 6 and 7. `SettingsStore.saveToHealth` matches between Tasks 4 and 7. `WorkoutRouteLocations.clLocations(from:)` matches between Tasks 2 and 6.

## Notes for the implementer

- The two BLOCKER fixes from spec review are baked in: the `end = max(rawEnd, start)` clamp lives in `WorkoutData(from:)` (Task 1), and the route is finished against the non-nil `HKWorkout` returned by `finishWorkout()` (Task 6).
- HealthKit cannot compile in the package, so the only safety net for `WorkoutWriter` is the app build (Task 6) and the simulator run (Task 8). If an API name differs in the Xcode 26 SDK, correct it against the `healthkit` skill rather than guessing.
- Keep `AuraCore/Package.resolved` out of every commit (the `git checkout --` line after package commits handles a build that dirties it).
