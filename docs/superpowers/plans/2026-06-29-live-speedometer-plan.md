# Live Speedometer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the HUD's average-speed dial (and the Live Activity speed) with a lightly-smoothed current speed sourced from `CLLocation.speed`, with a position-delta fallback.

**Architecture:** Capture Doppler speed onto an optional `TrackPoint` field (Codable-safe, no schema migration). A pure `SpeedSmoother` (time-aware EMA) and a pure instantaneous-speed helper live in AuraCore. `RideRecorder` feeds them per point and publishes `currentSpeedMetersPerSecond`; the coordinator passes it through to the HUD and the Live Activity seam.

**Tech Stack:** Swift 6, SwiftUI, CoreLocation, SwiftData (unchanged), Swift Testing.

## Global Constraints

- Swift 6; `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` on app + extension targets.
- AuraCore + AuraKit build and test on the macOS CI host: no CoreLocation/UIKit in pure logic. `SpeedSmoother` and the instantaneous-speed helper are in **AuraCore**.
- No new persisted schema version. The new `TrackPoint` field is **optional** so legacy JSON track blobs decode with it nil.
- Every existing `TrackPoint(...)` call site must compile unchanged (trailing parameter defaulted to `nil`).
- Mono-lime `AuraTheme` untouched — this is a value rebind, not a redesign.
- `cd AuraCore && swift test` and CI's 3 jobs stay green.

---

### Task 1: `SpeedSmoother` (pure, AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Stats/SpeedSmoother.swift`
- Test: `AuraCore/Tests/AuraCoreTests/SpeedSmootherTests.swift`

**Interfaces:**
- Produces: `struct SpeedSmoother` with `init(timeConstant: TimeInterval = 2.5)`, `mutating func add(_ speed: Double, at time: Date) -> Double`, `var value: Double { get }`, `mutating func reset()`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraCore

struct SpeedSmootherTests {
    @Test func firstSampleSeedsDirectly() {
        var s = SpeedSmoother()
        #expect(s.add(10, at: Date(timeIntervalSince1970: 0)) == 10)
        #expect(s.value == 10)
    }

    @Test func convergesTowardStepInput() {
        var s = SpeedSmoother(timeConstant: 2.5)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = s.add(0, at: t0)
        // Feed a 10 m/s step at 1 s intervals; after ~3 time-constants it is close to 10.
        var v = 0.0
        for i in 1...10 { v = s.add(10, at: Date(timeIntervalSince1970: Double(i))) }
        #expect(v > 9.5)
        // And it is responsive: one 1 s step already moves a meaningful fraction.
        var s2 = SpeedSmoother(timeConstant: 2.5)
        _ = s2.add(0, at: t0)
        let after1s = s2.add(10, at: Date(timeIntervalSince1970: 1))
        #expect(after1s > 2.5 && after1s < 6)   // alpha = 1 - e^(-1/2.5) ≈ 0.33
    }

    @Test func nonPositiveDtReplacesWithoutNaN() {
        var s = SpeedSmoother()
        _ = s.add(5, at: Date(timeIntervalSince1970: 10))
        let v = s.add(8, at: Date(timeIntervalSince1970: 10)) // dt == 0
        #expect(v == 8)
        #expect(!v.isNaN)
    }

    @Test func negativeSampleIgnored() {
        var s = SpeedSmoother()
        _ = s.add(7, at: Date(timeIntervalSince1970: 0))
        let v = s.add(-1, at: Date(timeIntervalSince1970: 1))
        #expect(v == 7)
    }

    @Test func resetZeroes() {
        var s = SpeedSmoother()
        _ = s.add(9, at: Date(timeIntervalSince1970: 0))
        s.reset()
        #expect(s.value == 0)
        // After reset the next sample seeds again.
        #expect(s.add(4, at: Date(timeIntervalSince1970: 1)) == 4)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd AuraCore && swift test --filter SpeedSmootherTests`
Expected: FAIL (no such type `SpeedSmoother`).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Time-aware exponential moving average for the live speed readout. Pure and
/// deterministic so it unit-tests on the macOS CI host. `alpha = 1 - exp(-dt / tau)`
/// adapts to irregular GPS sample spacing; the first sample seeds the value directly.
public struct SpeedSmoother {
    private let timeConstant: TimeInterval
    private var smoothed: Double = 0
    private var lastTime: Date?
    private var seeded = false

    public init(timeConstant: TimeInterval = 2.5) {
        self.timeConstant = timeConstant > 0 ? timeConstant : 2.5
    }

    public var value: Double { smoothed }

    /// Feed one instantaneous sample (m/s). Negative samples are ignored (the value
    /// holds). Returns the new smoothed value.
    @discardableResult
    public mutating func add(_ speed: Double, at time: Date) -> Double {
        guard speed >= 0 else { return smoothed }
        defer { lastTime = time }
        guard seeded, let last = lastTime else {
            seeded = true
            smoothed = speed
            return smoothed
        }
        let dt = time.timeIntervalSince(last)
        guard dt > 0 else { smoothed = speed; return smoothed }
        let alpha = 1 - exp(-dt / timeConstant)
        smoothed += alpha * (speed - smoothed)
        return smoothed
    }

    public mutating func reset() {
        smoothed = 0
        lastTime = nil
        seeded = false
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter SpeedSmootherTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Stats/SpeedSmoother.swift AuraCore/Tests/AuraCoreTests/SpeedSmootherTests.swift
git commit -m "feat(core): time-aware SpeedSmoother for live speed readout"
```

---

### Task 2: `TrackPoint.speedMetersPerSecond` optional field

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Geo/TrackPoint.swift`
- Test: `AuraCore/Tests/AuraCoreTests/TrackPointSpeedCodableTests.swift`

**Interfaces:**
- Produces: `TrackPoint.speedMetersPerSecond: Double?`; `init(coordinate:elevation:timestamp:speedMetersPerSecond:)` with the new param defaulted `nil`.

- [ ] **Step 1: Write the failing tests** (persistence safety is the point)

```swift
import Testing
import Foundation
@testable import AuraCore

struct TrackPointSpeedCodableTests {
    @Test func roundTripsSpeed() throws {
        let p = TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0),
                           elevation: 100, timestamp: Date(timeIntervalSince1970: 0),
                           speedMetersPerSecond: 7.5)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(TrackPoint.self, from: data)
        #expect(back.speedMetersPerSecond == 7.5)
    }

    @Test func legacyBlobWithoutSpeedDecodesNil() throws {
        // A track encoded before this field existed: no "speedMetersPerSecond" key.
        let legacy = """
        {"coordinate":{"latitude":40.44,"longitude":-80.0},"elevation":100,"timestamp":0}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(TrackPoint.self, from: legacy)
        #expect(back.speedMetersPerSecond == nil)
        #expect(back.coordinate.latitude == 40.44)
    }

    @Test func defaultInitOmitsSpeed() {
        let p = TrackPoint(coordinate: .init(latitude: 0, longitude: 0),
                           elevation: nil, timestamp: Date(timeIntervalSince1970: 0))
        #expect(p.speedMetersPerSecond == nil)
    }
}
```

> Confirmed: `Coordinate` is `Codable` with keys `latitude`/`longitude`, and `TrackPoint.timestamp` (a `Date`) default-encodes as a number — so the hand-written legacy JSON above is valid. This test goes in **`AuraCoreTests`** (`@testable import AuraCore`).

- [ ] **Step 2: Run to verify they fail**

Run: `cd AuraCore && swift test --filter TrackPointSpeedCodableTests`
Expected: FAIL (extra arg `speedMetersPerSecond`).

- [ ] **Step 3: Implement** — add the field and parameter (default `nil`, trailing):

```swift
public struct TrackPoint: Equatable, Codable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?   // meters above sea level
    public var timestamp: Date
    /// Instantaneous Doppler speed (m/s) from CLLocation.speed when valid; nil for
    /// GPX/simulated points, reconstructed Health-route points, or fixes without one.
    public var speedMetersPerSecond: Double?

    public init(coordinate: Coordinate, elevation: Double?, timestamp: Date,
                speedMetersPerSecond: Double? = nil) {
        self.coordinate = coordinate
        self.elevation = elevation
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
    }
}
```

- [ ] **Step 4: Run to verify pass + full AuraCore suite (nothing else broke)**

Run: `cd AuraCore && swift test --filter TrackPointSpeedCodableTests && swift test`
Expected: PASS; whole suite green.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/TrackPoint.swift AuraCore/Tests/AuraCoreTests/TrackPointSpeedCodableTests.swift
git commit -m "feat(core): optional speedMetersPerSecond on TrackPoint (Codable-safe)"
```

---

### Task 3: Instantaneous-speed helper (pure, AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Stats/InstantaneousSpeed.swift`
- Test: `AuraCore/Tests/AuraCoreTests/InstantaneousSpeedTests.swift`

**Interfaces:**
- Consumes: `TrackPoint`, `Geo.distance(_:_:)`.
- Produces: `enum InstantaneousSpeed { static func between(previous: TrackPoint?, current: TrackPoint) -> Double }`. Returns Doppler speed when `current.speedMetersPerSecond` is set; else position-delta from `previous`; else 0.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraCore

struct InstantaneousSpeedTests {
    private func pt(_ lat: Double, _ lon: Double, _ t: TimeInterval, speed: Double? = nil) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: t),
                   speedMetersPerSecond: speed)
    }

    @Test func prefersDopplerWhenPresent() {
        let prev = pt(40.0, -80.0, 0)
        let curr = pt(40.001, -80.0, 1, speed: 6.0)   // delta would be ~111 m/s
        #expect(InstantaneousSpeed.between(previous: prev, current: curr) == 6.0)
    }

    @Test func fallsBackToPositionDelta() {
        let prev = pt(40.0, -80.0, 0)
        let curr = pt(40.0001, -80.0, 5)              // ~11.1 m over 5 s ≈ 2.2 m/s
        let v = InstantaneousSpeed.between(previous: prev, current: curr)
        #expect(v > 1.8 && v < 2.6)
    }

    @Test func firstPointIsZero() {
        #expect(InstantaneousSpeed.between(previous: nil, current: pt(40, -80, 0)) == 0)
    }

    @Test func zeroDtIsZeroWhenNoDoppler() {
        let prev = pt(40.0, -80.0, 3)
        let curr = pt(40.0001, -80.0, 3)              // dt == 0, no Doppler
        #expect(InstantaneousSpeed.between(previous: prev, current: curr) == 0)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd AuraCore && swift test --filter InstantaneousSpeedTests`
Expected: FAIL (no such type).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The per-fix instantaneous speed feeding the live readout: the CLLocation Doppler
/// value when present, otherwise a position-delta from the previous fix so simulated /
/// GPX rides and Doppler-less fixes still animate. Pure; unit-tested on CI.
public enum InstantaneousSpeed {
    public static func between(previous: TrackPoint?, current: TrackPoint) -> Double {
        if let doppler = current.speedMetersPerSecond, doppler >= 0 { return doppler }
        guard let previous else { return 0 }
        let dt = current.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return 0 }
        return Geo.distance(previous.coordinate, current.coordinate) / dt
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter InstantaneousSpeedTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Stats/InstantaneousSpeed.swift AuraCore/Tests/AuraCoreTests/InstantaneousSpeedTests.swift
git commit -m "feat(core): InstantaneousSpeed helper (Doppler with position-delta fallback)"
```

---

### Task 4: Capture Doppler speed in `LocationService.ingest()`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/LocationService.swift:27-36`
- Test: `AuraCore/Tests/AuraKitTests/LocationServiceIngestTests.swift` (extend if it exists; else create)

**Interfaces:**
- Consumes: `TrackPoint(... speedMetersPerSecond:)` from Task 2.

- [ ] **Step 1: Write/extend the failing test**

First check for an existing ingest test: `grep -rl "ingest" AuraCore/Tests`. Add to it if present, otherwise create:

```swift
import Testing
import Foundation
import CoreLocation
@testable import AuraKit

@MainActor
struct LocationServiceIngestTests {
    @Test func capturesValidDopplerSpeed() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -80.0),
                             altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: 8.0, timestamp: Date())
        let point = svc.ingest(loc, now: Date())
        #expect(point?.speedMetersPerSecond == 8.0)
    }

    @Test func dropsInvalidSpeedToNil() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -80.0),
                             altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: -1, timestamp: Date())
        let point = svc.ingest(loc, now: Date())
        #expect(point != nil)
        #expect(point?.speedMetersPerSecond == nil)
    }

    // A stopped rider reports speed 0 (valid) — it must be captured as 0.0, NOT dropped
    // to nil. This pins the `>= 0` guard so a later refactor to `> 0` can't silently
    // break stopped-rider decay-to-zero on the dial.
    @Test func capturesZeroSpeed() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -80.0),
                             altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: 0, timestamp: Date())
        #expect(svc.ingest(loc, now: Date())?.speedMetersPerSecond == 0.0)
    }
}
```

> CI note: this is the suite's only direct `CLLocation(coordinate:altitude:horizontalAccuracy:verticalAccuracy:course:speed:timestamp:)` construction. That designated initializer is available on the macOS CoreLocation host, so it compiles under `swift test` — but it is new surface, so run the AuraKit suite to confirm before moving on.

> Confirmed: the test target is **`AuraKitTests`**; `ingest` is package-internal so `@testable import AuraKit` reaches it; CoreLocation imports on the macOS host. `RideRecorderSpeedTests` (Task 5) also lives in `AuraKitTests`.

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter LocationServiceIngestTests`
Expected: FAIL (speed not captured).

- [ ] **Step 3: Implement** — in `ingest`, set the field:

```swift
func ingest(_ location: CLLocation, now: Date) -> TrackPoint? {
    let age = now.timeIntervalSince(location.timestamp)
    signal = GPSFix.quality(horizontalAccuracy: location.horizontalAccuracy, age: age)
    guard GPSFix.isAcceptable(horizontalAccuracy: location.horizontalAccuracy) else { return nil }
    return TrackPoint(
        coordinate: Coordinate(latitude: location.coordinate.latitude,
                               longitude: location.coordinate.longitude),
        elevation: location.altitude,
        timestamp: location.timestamp,
        speedMetersPerSecond: location.speed >= 0 ? location.speed : nil)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter LocationServiceIngestTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/LocationService.swift AuraCore/Tests/AuraKitTests/LocationServiceIngestTests.swift
git commit -m "feat(kit): capture CLLocation Doppler speed into TrackPoint"
```

---

### Task 5: `RideRecorder.currentSpeedMetersPerSecond`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideRecorder.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideRecorderSpeedTests.swift`

**Interfaces:**
- Consumes: `SpeedSmoother` (Task 1), `InstantaneousSpeed` (Task 3).
- Produces: `RideRecorder.currentSpeedMetersPerSecond: Double` (`private(set)`), reset by `start(at:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraKit
@testable import AuraCore

@MainActor
struct RideRecorderSpeedTests {
    private func pt(_ lat: Double, _ t: TimeInterval, speed: Double?) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: -80.0),
                   elevation: nil, timestamp: Date(timeIntervalSince1970: t),
                   speedMetersPerSecond: speed)
    }

    @Test func tracksDopplerSpeed() {
        let r = RideRecorder()
        r.start(at: Date(timeIntervalSince1970: 0))
        r.record(pt(40.000, 0, speed: 9))
        r.record(pt(40.001, 1, speed: 9))
        r.record(pt(40.002, 2, speed: 9))
        #expect(r.currentSpeedMetersPerSecond > 5)   // converging toward 9
        #expect(r.currentSpeedMetersPerSecond <= 9)
    }

    @Test func decaysTowardZeroWhenStopped() {
        let r = RideRecorder()
        r.start(at: Date(timeIntervalSince1970: 0))
        for i in 0...4 { r.record(pt(40.0 + Double(i) * 0.001, Double(i), speed: 10)) }
        let moving = r.currentSpeedMetersPerSecond
        for i in 5...12 { r.record(pt(40.005, Double(i), speed: 0)) } // parked: speed 0
        #expect(r.currentSpeedMetersPerSecond < moving)
        #expect(r.currentSpeedMetersPerSecond < 2)
    }

    @Test func startResetsSpeed() {
        let r = RideRecorder()
        r.start(at: Date(timeIntervalSince1970: 0))
        r.record(pt(40.0, 0, speed: 8))
        r.record(pt(40.001, 1, speed: 8))
        #expect(r.currentSpeedMetersPerSecond > 0)
        r.start(at: Date(timeIntervalSince1970: 100))
        #expect(r.currentSpeedMetersPerSecond == 0)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd AuraCore && swift test --filter RideRecorderSpeedTests`
Expected: FAIL (no such property).

- [ ] **Step 3: Implement** — add smoother + previous-point state to `RideRecorder`:

```swift
public private(set) var currentSpeedMetersPerSecond: Double = 0

private var smoother = SpeedSmoother()
private var lastPoint: TrackPoint?
```

In `start(at:)` add:
```swift
smoother.reset()
currentSpeedMetersPerSecond = 0
lastPoint = nil
```

In `record(_:)` (after `track.append(point)` / stats recompute), add:
```swift
let instant = InstantaneousSpeed.between(previous: lastPoint, current: point)
currentSpeedMetersPerSecond = smoother.add(instant, at: point.timestamp)
lastPoint = point
```
Feed the smoother with **`point.timestamp`** (GPS time), NOT `Date()` — this keeps GPX/sim
replay deterministic and matches the tests. Do not switch it to wall-clock.

- [ ] **Step 4: Run to verify pass + full suite**

Run: `cd AuraCore && swift test --filter RideRecorderSpeedTests && swift test`
Expected: PASS; whole suite green.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideRecorder.swift AuraCore/Tests/AuraKitTests/RideRecorderSpeedTests.swift
git commit -m "feat(kit): RideRecorder publishes smoothed currentSpeedMetersPerSecond"
```

---

### Task 6: Coordinator passthrough + bind the HUD dial

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (passthrough)
- Modify: `AuraCore/Sources/AuraKit/Formatting/SpeedRailVoice.swift` (current-speed value)
- Modify: `Aura/Sources/Ride/SpeedRail.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift:21`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:80`

**Interfaces:**
- Consumes: `RideRecorder.currentSpeedMetersPerSecond` (Task 5).
- Produces: `RideSessionCoordinator.currentSpeedMetersPerSecond: Double`; `SpeedRail` initializer gains `currentSpeedMetersPerSecond: Double`.

App-target SwiftUI is not in `swift test`; it is verified by the app `xcodebuild` job and reviewer reading. No new unit test here beyond the `SpeedRailVoice` change.

- [ ] **Step 1: Add the `SpeedRailVoice` test (this part IS in CI)**

In **`AuraCore/Tests/AuraKitTests/SpeedRailVoiceTests.swift`** the two existing tests
`speedValue_imperial` (call at line 16) and `speedValue_metric` (call at line 22)
currently pass a `RideStats` via the `stats(...)` helper to the OLD overload. The
signature change to a `Double` will make them **fail to compile and break the whole
suite**, so they MUST be rewritten in this step (not just added to). The `stats(...)`
helper stays — `statsLabel_*` tests still use it.

Rewrite both, and add the new current-speed assertion (`DistanceUnits` cases are
`.imperial`/`.metric`):

```swift
@Test func speedValue_imperial() {
    // 10.728 m/s ≈ 24 mph
    #expect(SpeedRailVoice.speedValue(10.728, units: .imperial) == "24 miles per hour")
}

@Test func speedValue_metric() {
    // 6.6667 m/s = 24 km/h
    #expect(SpeedRailVoice.speedValue(6.6667, units: .metric) == "24 kilometers per hour")
}

@Test func speedValue_roundsLikeTheDial() {
    // 8.94 m/s ≈ 20.0 mph — the current-speed value the HUD now speaks.
    #expect(SpeedRailVoice.speedValue(8.94, units: .imperial) == "20 miles per hour")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter SpeedRailVoice`
Expected: FAIL (current overload takes `RideStats`).

- [ ] **Step 3: Implement**

`SpeedRailVoice.speedValue` — change to take the current speed value:
```swift
public static func speedValue(_ metersPerSecond: Double, units: DistanceUnits) -> String {
    let formatter = RideStatsFormatter(units: units)
    return "\(formatter.speedValue(metersPerSecond)) \(formatter.speedUnitSpoken)"
}
```

`RideSessionCoordinator` — add beside `stats`/`track`:
```swift
public var currentSpeedMetersPerSecond: Double { recorder.currentSpeedMetersPerSecond }
```

`SpeedRail` — add a stored property and rebind the hero + a11y value:
```swift
let currentSpeedMetersPerSecond: Double
...
SpeedReadout(value: fmt.speedValue(currentSpeedMetersPerSecond),
             unit: fmt.speedUnit.uppercased())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Speed")
    .accessibilityValue(SpeedRailVoice.speedValue(currentSpeedMetersPerSecond, units: units))
```
Update the line-22 comment (no longer a "slow-moving average"): "the live current speed re-announces alone".

`RideHUDView.swift:21`:
```swift
SpeedRail(stats: coordinator.stats, elapsed: coordinator.elapsed,
          currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
          units: settings.units)
```

`NavigateHUDView.swift:80-81`:
```swift
SpeedRail(stats: coordinator.stats, elapsed: coordinator.elapsed,
          currentSpeedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
          units: settings.units, layout: .speedOnly)
```

> Property order in the `SpeedRail` struct must match the memberwise init usage (Swift synthesizes args in declaration order). Place `currentSpeedMetersPerSecond` so the call sites above compile; adjust labels to whatever final order is chosen — keep all call sites consistent.

- [ ] **Step 4: Verify**

Run: `cd AuraCore && swift test --filter SpeedRailVoice` (PASS), then the app build (Task brief: delegate to the build agent) `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO`.
Expected: tests PASS; app builds.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift AuraCore/Sources/AuraKit/Formatting/SpeedRailVoice.swift AuraCore/Tests Aura/Sources/Ride/SpeedRail.swift Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(app): HUD speed dial reads live current speed, not ride average"
```

---

### Task 7: Live Activity parity (current speed on the seam)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift:17` (protocol)
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:107-109` (`pushActivityUpdate`)
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController.swift:64-88` (the `update` body — signature + the `speedMetersPerSecond:` map — lives HERE in the main file)
- Aware (no edit): `Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift` declares the `RideActivityControlling` conformance but only implements `start(kind:…)`; it does NOT reference `update`, so it needs no change once the `update` body in the main file matches the new protocol signature. Listed so the conformance split is accounted for.
- Modify: the `SpyRideActivity` test double in **`AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`** — the `updates` tuple type at **line 219** (`[(stats:maneuver:)]` → add `currentSpeedMetersPerSecond`), the `func update(stats:maneuver:)` at **line 224**, and the existing `maneuverFlowsToActivityUpdate` assertion at **line 142** (its tuple access must match the new shape).

**Interfaces:**
- Consumes: `RideRecorder.currentSpeedMetersPerSecond`.
- Produces: `RideActivityControlling.update(stats:currentSpeedMetersPerSecond:maneuver:)`.

- [ ] **Step 1: Update the seam + test double, write/adjust the failing test**

Change the protocol:
```swift
func update(stats: RideStats, currentSpeedMetersPerSecond: Double, maneuver: GuidanceUpdate?)
```

In `RideSessionCoordinatorTests.swift`, update `SpyRideActivity`:
- line 219: `private(set) var updates: [(stats: RideStats, currentSpeedMetersPerSecond: Double, maneuver: GuidanceUpdate?)] = []`
- line 224: `func update(stats: RideStats, currentSpeedMetersPerSecond: Double, maneuver: GuidanceUpdate?) { updates.append((stats, currentSpeedMetersPerSecond, maneuver)) }`
- line 142 (`maneuverFlowsToActivityUpdate`): fix the tuple access to the new shape (e.g. `.last?.maneuver`).

Add a new assertion that the forwarded `currentSpeedMetersPerSecond` matches `coordinator.currentSpeedMetersPerSecond` after recording two Doppler points and calling `pushActivityUpdate()` directly (the existing tests already use this direct-call pattern).

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter RideSession`
Expected: FAIL (signature mismatch / new assertion).

- [ ] **Step 3: Implement**

`pushActivityUpdate()`:
```swift
func pushActivityUpdate() {
    activity.update(stats: recorder.stats,
                    currentSpeedMetersPerSecond: recorder.currentSpeedMetersPerSecond,
                    maneuver: maneuver)
}
```

`RideLiveActivityController.update(...)`: take the new param and map it:
```swift
func update(stats: RideStats, currentSpeedMetersPerSecond: Double, maneuver: GuidanceUpdate?) {
    ...
    let state = RideActivityAttributes.ContentState(
        distanceMeters: stats.distanceMeters,
        speedMetersPerSecond: currentSpeedMetersPerSecond,   // was stats.averageSpeedMetersPerSecond
        elevationGainMeters: stats.elevationGainMeters,
        turnInstruction: instruction,
        turnDistanceMeters: maneuver?.distanceToManeuverMeters)
    ...
}
```

- [ ] **Step 4: Run to verify pass + full suite + app build**

Run: `cd AuraCore && swift test` (PASS), then app build (delegate to build agent) as in Task 6.
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift Aura/Sources/LiveActivity/RideLiveActivityController.swift AuraCore/Tests
git commit -m "feat(app): Live Activity speed reads live current speed for HUD parity"
```

---

## Self-Review

- **Spec coverage:** TrackPoint field (T2), ingest capture (T4), SpeedSmoother (T1), instantaneous helper (T3), recorder current speed (T5), coordinator + dial rebind + voice (T6), Live Activity parity (T7). All spec sections covered.
- **Persistence safety:** T2 asserts a legacy blob decodes nil; no schema version added.
- **macOS CI:** T1/T2/T3 pure AuraCore; T4/T5 AuraKit with CoreLocation only in T4 (importable on macOS); no UIKit/WidgetKit in tested code.
- **Type consistency:** `currentSpeedMetersPerSecond: Double` used uniformly across recorder → coordinator → SpeedRail/HUD/seam. `SpeedRailVoice.speedValue` takes a `Double` everywhere after T6. `InstantaneousSpeed.between(previous:current:)` and `SpeedSmoother.add(_:at:)` signatures stable across T5.
- **Call-site safety:** new `TrackPoint` param defaulted `nil`; `SpeedRail` new param requires updating both HUD call sites (done in T6).
- **Open confirmations flagged inline:** `Coordinate` Codable key shape (T2), AuraKit test target name + CoreLocation import (T4), `DistanceUnits` case spelling (T6), existing activity-update test double location (T7).
