# Group-ride peer "feel" pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Peer dots glide smoothly between fixes (ROH-69) and riders are instantly distinguishable with a legible heading (ROH-72), on Aura's group-ride map.

**Architecture:** All motion/identity/geometry logic is pure value types in **AuraCore** (unit-tested with Swift Testing); the app target holds only SwiftUI + Mapbox. A `recordedAt`-keyed `PeerInterpolator` tweens each dot; a `TimelineView(.animation)` clock feeds interpolated coordinates to `MapViewAnnotation`. Identity is hue (`PeerPalette`) + disambiguated monogram (`RiderMonogram`); overlap is handled by screen-space `ClusterDeclutter`.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing (`@Test`/`#expect`), MapboxMaps v11, SwiftPM (AuraCore/AuraKit).

## Global Constraints

- **Pure logic in AuraCore only** — no `Date()`, no `Task.sleep`, no UIKit/SwiftUI/Mapbox in AuraCore types; inject all time. App target is untestable by the suite.
- **Swift 6 strict concurrency** — new AuraCore types are `Sendable` value types (`struct`/`enum`).
- **Swift Testing**, not XCTest — `import Testing`, `@Test func`, `#expect(...)`. Plain `struct XTests` (no `@Suite`), matching the existing GroupRide tests.
- **Do NOT modify** `LivePresenceState`, `RideSession`, `GroupRideSession`, the transport, or any DB/schema — reorder/stale handling lives in the render-only interpolator. No presence-semantics or cadence change (ROH-66 stays out of scope).
- **Reserved colours:** `AuraPalette.mint` (lime; route/accent) and `AuraPalette.amber` (warning/stopped) are **never** rider identity hues.
- **MapboxMaps v11:** map-content is `@MapContentBuilder`; Map-specific modifiers (`.allowOverlapWithPuck`) must precede generic `View` modifiers.
- **Reduce Motion:** dots still **glide** (linear); only the pulse and pointer-rotation are suppressed.
- **Reference spec:** `docs/superpowers/specs/2026-07-20-group-ride-peer-feel-design.md`.

---

## File structure

**AuraCore — new pure types (`AuraCore/Sources/AuraCore/GroupRide/`):**
- `PeerInterpolator.swift` — per-peer tween + `PeerInterpolators` collection.
- `PeerPalette.swift` — stable de-colliding index assignment.
- `RiderMonogram.swift` — collision-widening monogram assignment.
- `ClusterDeclutter.swift` — `Point2D` + screen-space cluster spread / tag-stack geometry.
- `GroupMapDots.swift` (modify) — leader-preserving `maxDots` cap.

**AuraCore — new tests (`AuraCore/Tests/AuraCoreTests/GroupRide/`):** one file per type above, plus a rider-palette test under `AuraCore/Tests/AuraCoreTests/`.

**App target:**
- `Aura/Sources/GroupRide/GroupRideMapOverlay.swift` (modify) — `PeerDotView` redesign.
- `Aura/Sources/GroupRide/PeerAnnotations.swift` (new) — shared TimelineView + interpolation + projection/declutter + memoised derivations.
- `Aura/Sources/Theme/AuraTheme.swift` (modify) + `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift` (modify) — rider palette tokens + `AuraTheme.riderPalette`.
- `Aura/Sources/Ride/NavigateHUDView.swift` + `Aura/Sources/Ride/RideMapView.swift` (modify) — adopt `PeerAnnotations`, drop `previousPeerCoordinates`.

---

## Task 1: `PeerInterpolator` + `PeerInterpolators` (AuraCore, pure)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/PeerInterpolator.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/PeerInterpolatorTests.swift`

**Interfaces:**
- Consumes: `Coordinate`, `Geo.distance`, `PeerBearing.heading`, `RidePeer` (all existing AuraCore).
- Produces:
  - `PeerInterpolator(config:)`; `mutating func commit(fix: Coordinate, recordedAt: Date, now: Date)`; `func position(at: Date) -> Coordinate`; `func bearing(at: Date) -> Double?`; `func isActive(at: Date) -> Bool`; `var didSnap: Bool`.
  - `PeerInterpolator.Config(minDuration:maxDuration:snapSilence:maxSpeed:coincidentMeters:)`.
  - `PeerInterpolators()`; `mutating func commit(peers: [RidePeer], now: Date)`; `func position(_ id: UUID, at: Date) -> Coordinate?`; `func bearing(_ id: UUID, at: Date) -> Double?`; `func anyActive(at: Date) -> Bool`.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import AuraCore

struct PeerInterpolatorTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func c(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(latitude: lat, longitude: lon) }

    @Test func firstFixAppearsInPlace() {
        var i = PeerInterpolator()
        i.commit(fix: c(1, 1), recordedAt: t0, now: t0)
        #expect(i.position(at: t0) == c(1, 1))
        #expect(i.isActive(at: t0) == false)   // no tween on first fix
    }

    @Test func linearMidpointHalfwayThroughDuration() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        // second fix 2s later, ~22m east (0.0002° lon ≈ 11 m/s) — plausible, so it tweens
        i.commit(fix: c(0, 0.0002), recordedAt: t0 + 2, now: t0 + 2)
        let mid = i.position(at: t0 + 3)                    // 1s into a 2s tween
        #expect(abs(mid.longitude - 0.0001) < 1e-7)         // linear, not eased
        #expect(i.position(at: t0 + 4) == c(0, 0.0002))     // clamps at target
        #expect(i.position(at: t0 + 99) == c(0, 0.0002))    // holds (no overshoot)
        #expect(i.didSnap == false)
    }

    @Test func staleOrDuplicateRecordedAtIsIgnored() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0 + 10, now: t0 + 10)
        i.commit(fix: c(9, 9), recordedAt: t0 + 10, now: t0 + 11) // same recordedAt → ignore
        i.commit(fix: c(9, 9), recordedAt: t0 + 5,  now: t0 + 12) // older → ignore
        #expect(i.position(at: t0 + 20) == c(0, 0))
    }

    @Test func snapsAcrossLongSilence() {
        var i = PeerInterpolator(config: .init(snapSilence: 40))
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0, 0.001), recordedAt: t0 + 41, now: t0 + 41) // 41s > 40s → snap
        #expect(i.didSnap)
        #expect(i.position(at: t0 + 41) == c(0, 0.001)) // jumps, no glide
        #expect(i.bearing(at: t0 + 41) == nil)          // stale direction cleared
    }

    @Test func snapsOnImplausibleSpeedUsingRecordedAtGap() {
        // 2000m in 2s = 1000 m/s ≫ 25 → snap, even though gap is normal
        var i = PeerInterpolator(config: .init(maxSpeed: 25))
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0.02, 0), recordedAt: t0 + 2, now: t0 + 2) // ~2200m north
        #expect(i.didSnap)
    }

    @Test func bunchedArrivalsDoNotFalseSnap() {
        // fixes are 2s apart in recordedAt but arrive 0.05s apart in wall time.
        // Implied speed must use recordedAt gap (2s), not arrival gap.
        var i = PeerInterpolator(config: .init(maxSpeed: 25))
        i.commit(fix: c(0, 0),      recordedAt: t0,     now: t0 + 10.00)
        i.commit(fix: c(0, 0.0003), recordedAt: t0 + 2, now: t0 + 10.05) // ~33m over 2s ≈ 16 m/s
        #expect(i.didSnap == false)
    }

    @Test func coincidentFixDoesNotAnimate() {
        var i = PeerInterpolator()
        i.commit(fix: c(0, 0), recordedAt: t0, now: t0)
        i.commit(fix: c(0, 0), recordedAt: t0 + 2, now: t0 + 2) // heartbeat: same point, fresh time
        #expect(i.isActive(at: t0 + 2) == false)                // no idle tween
        #expect(i.didSnap == false)
    }

    @Test func angularLerpTakesShortArcAcrossNorth() {
        #expect(abs(PeerInterpolator.angularLerp(350, 10, 0.5) - 0) < 1e-9)   // +20°, not -340
        #expect(abs(PeerInterpolator.angularLerp(10, 350, 0.5) - 0) < 1e-9)
    }

    @Test func collectionCommitsPerPeerAndPrunesLeavers() {
        let a = UUID(), b = UUID()
        var set = PeerInterpolators()
        let p1 = RidePeer(userID: a, displayName: "A", coordinate: c(0, 0),
                          lastUpdate: t0, status: .riding)
        set.commit(peers: [p1], now: t0)
        #expect(set.position(a, at: t0) == c(0, 0))
        #expect(set.position(b, at: t0) == nil)
        set.commit(peers: [], now: t0 + 1)          // A left
        #expect(set.position(a, at: t0 + 1) == nil) // pruned
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --package-path AuraCore --filter PeerInterpolatorTests`
Expected: FAIL (types not defined).

- [ ] **Step 3: Implement `PeerInterpolator.swift`**

```swift
import Foundation

/// Renders a peer dot's position/bearing by tweening between successive fixes, so the dot
/// glides instead of teleporting once per broadcast (ROH-69). Pure and deterministic: all
/// time is injected. Keyed on each fix's `recordedAt` (sender-truthful, ~monotonic, the same
/// basis presence/`droppedTimeout` use) so snap-on-silence, duration, and the ROH-66 boundary
/// stay coherent, and stale/duplicate/heartbeat fixes are filtered by one guard.
public struct PeerInterpolator: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var minDuration: TimeInterval
        public var maxDuration: TimeInterval
        public var snapSilence: TimeInterval
        public var maxSpeed: Double
        public var coincidentMeters: Double
        public init(minDuration: TimeInterval = 0.5, maxDuration: TimeInterval = 8,
                    snapSilence: TimeInterval = 40, maxSpeed: Double = 25,
                    coincidentMeters: Double = 0.5) {
            self.minDuration = minDuration; self.maxDuration = maxDuration
            self.snapSilence = snapSilence; self.maxSpeed = maxSpeed
            self.coincidentMeters = coincidentMeters
        }
    }

    private let config: Config
    private var from: Coordinate
    private var to: Coordinate
    private var startWall: Date
    private var duration: TimeInterval
    private var fromBearing: Double?
    private var toBearing: Double?
    private var lastRecordedAt: Date?
    public private(set) var didSnap: Bool

    public init(config: Config = .init()) {
        self.config = config
        self.from = Coordinate(latitude: 0, longitude: 0)
        self.to = Coordinate(latitude: 0, longitude: 0)
        self.startWall = Date(timeIntervalSince1970: 0)
        self.duration = 0
        self.lastRecordedAt = nil
        self.didSnap = false
    }

    public mutating func commit(fix: Coordinate, recordedAt: Date, now: Date) {
        guard let last = lastRecordedAt else {                 // first fix: appear in place
            from = fix; to = fix; startWall = now; duration = 0
            fromBearing = nil; toBearing = nil
            lastRecordedAt = recordedAt; didSnap = false
            return
        }
        guard recordedAt > last else { return }                // stale / duplicate / unchanged
        let gap = recordedAt.timeIntervalSince(last)
        let origin = position(at: now)                         // freeze current rendered point
        let dist = Geo.distance(origin, fix)
        let implausible = gap > 0 && (dist / gap) > config.maxSpeed
        let silent = gap > config.snapSilence

        if silent || implausible {                             // teleport: no glide, no stale cone
            from = fix; to = fix; startWall = now; duration = 0
            fromBearing = nil; toBearing = nil
            didSnap = true
        } else if dist <= config.coincidentMeters {            // heartbeat / stationary: hold, no anim
            from = fix; to = fix; startWall = now; duration = 0
            didSnap = false                                    // bearings retained (hold last heading)
        } else {
            let heading = PeerBearing.heading(from: origin, to: fix)
            fromBearing = bearing(at: now) ?? heading
            toBearing = heading
            from = origin; to = fix; startWall = now
            duration = min(max(gap, config.minDuration), config.maxDuration)
            didSnap = false
        }
        lastRecordedAt = recordedAt
    }

    public func position(at now: Date) -> Coordinate {
        guard duration > 0 else { return to }
        let t = min(max(now.timeIntervalSince(startWall) / duration, 0), 1)   // linear + clamp
        return Coordinate(latitude: from.latitude + (to.latitude - from.latitude) * t,
                          longitude: from.longitude + (to.longitude - from.longitude) * t)
    }

    public func bearing(at now: Date) -> Double? {
        guard let toB = toBearing else { return fromBearing }
        guard let fromB = fromBearing, duration > 0 else { return toB }
        let t = min(max(now.timeIntervalSince(startWall) / duration, 0), 1)
        return PeerInterpolator.angularLerp(fromB, toB, t)
    }

    public func isActive(at now: Date) -> Bool {
        duration > 0 && now.timeIntervalSince(startWall) < duration
    }

    /// Shortest-arc interpolation between two compass bearings, handling the 0/360 seam.
    public static func angularLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let r = (a + delta * t).truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

/// The receiver's set of per-peer interpolators. Commit is per-peer and guarded, so a
/// different peer moving never resets another's tween. Prunes peers that have left.
public struct PeerInterpolators: Equatable, Sendable {
    private var byID: [UUID: PeerInterpolator]
    private let config: PeerInterpolator.Config
    public init(config: PeerInterpolator.Config = .init()) {
        self.byID = [:]; self.config = config
    }

    public mutating func commit(peers: [RidePeer], now: Date) {
        var live = Set<UUID>()
        for peer in peers {
            guard let coord = peer.coordinate, let recordedAt = peer.lastUpdate else { continue }
            live.insert(peer.userID)
            var interp = byID[peer.userID] ?? PeerInterpolator(config: config)
            interp.commit(fix: coord, recordedAt: recordedAt, now: now)
            byID[peer.userID] = interp
        }
        byID = byID.filter { live.contains($0.key) }
    }

    public func position(_ id: UUID, at now: Date) -> Coordinate? { byID[id]?.position(at: now) }
    public func bearing(_ id: UUID, at now: Date) -> Double? { byID[id]?.bearing(at: now) }
    public func anyActive(at now: Date) -> Bool { byID.values.contains { $0.isActive(at: now) } }
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test --package-path AuraCore --filter PeerInterpolatorTests`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/GroupRide/PeerInterpolator.swift AuraCore/Tests/AuraCoreTests/GroupRide/PeerInterpolatorTests.swift
git commit -m "feat(roh-69): PeerInterpolator — recordedAt-keyed peer dot tween"
```

---

## Task 2: `PeerPalette` (AuraCore, pure)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/PeerPalette.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/PeerPaletteTests.swift`

**Interfaces:**
- Produces: `PeerPalette.assign(userIDs: [UUID], paletteCount: Int) -> [UUID: Int]` — stable per-user index in `0..<paletteCount`, distinct within the set when count allows.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import AuraCore

struct PeerPaletteTests {
    @Test func indicesAreInRange() {
        let ids = (0..<5).map { _ in UUID() }
        let m = PeerPalette.assign(userIDs: ids, paletteCount: 6)
        #expect(m.count == 5)
        #expect(m.values.allSatisfy { (0..<6).contains($0) })
    }

    @Test func assignmentIsStablePerUser() {
        let ids = (0..<4).map { _ in UUID() }
        let a = PeerPalette.assign(userIDs: ids, paletteCount: 6)
        let b = PeerPalette.assign(userIDs: ids.shuffled(), paletteCount: 6)
        for id in ids { #expect(a[id] == b[id]) } // order-independent, id-stable
    }

    @Test func noCollisionsWhenCountAllows() {
        let ids = (0..<6).map { _ in UUID() }
        let m = PeerPalette.assign(userIDs: ids, paletteCount: 8)
        #expect(Set(m.values).count == ids.count) // all distinct
    }

    @Test func moreUsersThanColoursWrapsGracefully() {
        let ids = (0..<10).map { _ in UUID() }
        let m = PeerPalette.assign(userIDs: ids, paletteCount: 6)
        #expect(m.count == 10)
        #expect(m.values.allSatisfy { (0..<6).contains($0) })
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --package-path AuraCore --filter PeerPaletteTests`
Expected: FAIL.

- [ ] **Step 3: Implement `PeerPalette.swift`**

```swift
import Foundation

/// Assigns each rider a stable palette index. Hash-based so a rider keeps their colour across
/// rides; a deterministic de-collision pass (probe to the next free slot, users in sorted
/// order) makes a single ride's riders distinct when the palette is large enough. UI-free:
/// returns an index the app maps to `AuraTheme.riderPalette`.
public enum PeerPalette {
    public static func assign(userIDs: [UUID], paletteCount: Int) -> [UUID: Int] {
        guard paletteCount > 0 else { return [:] }
        var result: [UUID: Int] = [:]
        var taken = Set<Int>()
        for id in userIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let base = stableHash(id) % paletteCount
            var idx = base
            if taken.count < paletteCount {                 // room to de-collide
                var probe = 0
                while taken.contains(idx) && probe < paletteCount {
                    probe += 1
                    idx = (base + probe) % paletteCount
                }
            }
            result[id] = idx
            taken.insert(idx)
        }
        return result
    }

    /// Deterministic, platform-stable hash (FNV-1a over the UUID bytes) — `Hashable`'s hash is
    /// per-process-seeded and would not be stable across launches/rides.
    private static func stableHash(_ id: UUID) -> Int {
        var h: UInt64 = 1_469_598_103_934_665_603
        withUnsafeBytes(of: id.uuid) { bytes in
            for b in bytes { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        }
        return Int(h & 0x7FFF_FFFF)
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `swift test --package-path AuraCore --filter PeerPaletteTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/GroupRide/PeerPalette.swift AuraCore/Tests/AuraCoreTests/GroupRide/PeerPaletteTests.swift
git commit -m "feat(roh-72): PeerPalette — stable de-colliding rider colour index"
```

---

## Task 3: `RiderMonogram` (AuraCore, pure)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/RiderMonogram.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/RiderMonogramTests.swift`

**Interfaces:**
- Produces: `RiderMonogram.assign(names: [UUID: String]) -> [UUID: String]` — 1 char normally; colliding first-initials widen to the shortest distinguishing 2-char form.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import AuraCore

struct RiderMonogramTests {
    @Test func uniqueInitialsStaySingleChar() {
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Mara", b: "Devon"])
        #expect(m[a] == "M"); #expect(m[b] == "D")
    }

    @Test func sharedInitialWidensBothColliders() {
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam Rivera", b: "Sara Lee"])
        #expect(m[a] == "SR")   // first + last-word initial
        #expect(m[b] == "SL")
        #expect(m[a] != m[b])
    }

    @Test func singleWordCollisionUsesFirstTwoLetters() {
        let a = UUID(), b = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam", b: "Sid"])
        #expect(m[a] == "SA"); #expect(m[b] == "SI")
    }

    @Test func nonColliderKeepsOneCharWhenOthersCollide() {
        let a = UUID(), b = UUID(), c = UUID()
        let m = RiderMonogram.assign(names: [a: "Sam", b: "Sid", c: "Priya"])
        #expect(m[c] == "P")    // untouched
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --package-path AuraCore --filter RiderMonogramTests`
Expected: FAIL.

- [ ] **Step 3: Implement `RiderMonogram.swift`**

```swift
import Foundation

/// A short, colour-independent per-rider label for the map dot. Normally the first letter
/// (today's behaviour); when two riders in the ride share a first initial, only the colliding
/// ones widen to the shortest distinguishing form — so two close riders whose names start with
/// the same letter are still tell-apart-able (and it works for colour-blind riders).
public enum RiderMonogram {
    public static func assign(names: [UUID: String]) -> [UUID: String] {
        let firsts = names.mapValues { firstLetter($0) }
        var counts: [String: Int] = [:]
        for v in firsts.values { counts[v, default: 0] += 1 }
        var result: [UUID: String] = [:]
        for (id, name) in names {
            let f = firsts[id] ?? ""
            result[id] = (counts[f] ?? 0) > 1 ? widened(name) : f
        }
        return result
    }

    private static func firstLetter(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private static func widened(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(separator: " ")
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(trimmed.prefix(2)).uppercased()
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `swift test --package-path AuraCore --filter RiderMonogramTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/GroupRide/RiderMonogram.swift AuraCore/Tests/AuraCoreTests/GroupRide/RiderMonogramTests.swift
git commit -m "feat(roh-72): RiderMonogram — disambiguated colour-independent dot label"
```

---

## Task 4: `ClusterDeclutter` (AuraCore, pure)

**Files:**
- Create: `AuraCore/Sources/AuraCore/GroupRide/ClusterDeclutter.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/ClusterDeclutterTests.swift`

**Interfaces:**
- Produces:
  - `struct Point2D: Equatable, Sendable { var x, y: Double }`
  - `struct DeclutterOffset: Equatable, Sendable { var dx, dy: Double }`
  - `ClusterDeclutter.resolve(points: [Point2D], radius: Double, spread: Double) -> [DeclutterOffset]` — one offset per input index (order preserved); singletons get `.zero`; overlapping points spread evenly around their cluster centroid.
  - `ClusterDeclutter.clustered(points: [Point2D], radius: Double) -> [Bool]` — which points share a cluster (drives which tags show).

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import AuraCore

struct ClusterDeclutterTests {
    func p(_ x: Double, _ y: Double) -> ClusterDeclutter.Point2D { .init(x: x, y: y) }

    @Test func nonOverlappingPointsGetNoOffset() {
        let offs = ClusterDeclutter.resolve(points: [p(0, 0), p(100, 100)], radius: 24, spread: 18)
        #expect(offs == [.init(dx: 0, dy: 0), .init(dx: 0, dy: 0)])
        #expect(ClusterDeclutter.clustered(points: [p(0, 0), p(100, 100)], radius: 24) == [false, false])
    }

    @Test func twoOverlappingPointsSpreadApart() {
        let pts = [p(0, 0), p(4, 0)]                 // 4px apart, within radius
        let offs = ClusterDeclutter.resolve(points: pts, radius: 24, spread: 18)
        #expect(offs[0] != .init(dx: 0, dy: 0))
        #expect(offs[1] != .init(dx: 0, dy: 0))
        // final positions land ~2*spread apart
        let f0 = (pts[0].x + offs[0].dx, pts[0].y + offs[0].dy)
        let f1 = (pts[1].x + offs[1].dx, pts[1].y + offs[1].dy)
        let d = ((f0.0 - f1.0) * (f0.0 - f1.0) + (f0.1 - f1.1) * (f0.1 - f1.1)).squareRoot()
        #expect(abs(d - 36) < 1.0)                   // 2 * spread(18)
        #expect(ClusterDeclutter.clustered(points: pts, radius: 24) == [true, true])
    }

    @Test func resultIsDeterministicForSameInput() {
        let pts = [p(1, 1), p(3, 1), p(2, 2)]
        #expect(ClusterDeclutter.resolve(points: pts, radius: 24, spread: 18)
                == ClusterDeclutter.resolve(points: pts, radius: 24, spread: 18))
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --package-path AuraCore --filter ClusterDeclutterTests`
Expected: FAIL.

- [ ] **Step 3: Implement `ClusterDeclutter.swift`**

```swift
import Foundation

/// Screen-space overlap handling for peer dots. Given projected dot centres, it groups those
/// that overlap and returns a per-dot offset that fans a cluster evenly around its centroid so
/// stacked riders separate. Pure geometry (no Mapbox/UIKit): the app projects coordinates to
/// points, applies the offsets as an animated `.offset`, and animates transitions so dots don't
/// pop as riders drift together. Input order is preserved (caller keys by `userID`).
public enum ClusterDeclutter {
    public struct Point2D: Equatable, Sendable {
        public var x: Double; public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public struct DeclutterOffset: Equatable, Sendable {
        public var dx: Double; public var dy: Double
        public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
        public static let zero = DeclutterOffset(dx: 0, dy: 0)
    }

    /// Union points within `radius` of each other (transitive) into clusters, preserving order.
    private static func clusters(_ points: [Point2D], radius: Double) -> [[Int]] {
        var parent = Array(points.indices)
        func find(_ i: Int) -> Int { var r = i; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        for i in points.indices {
            for j in (i + 1)..<points.count {
                let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                if (dx * dx + dy * dy).squareRoot() < radius { union(i, j) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in points.indices { groups[find(i), default: []].append(i) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    public static func clustered(points: [Point2D], radius: Double) -> [Bool] {
        var flags = Array(repeating: false, count: points.count)
        for group in clusters(points, radius: radius) where group.count > 1 {
            for i in group { flags[i] = true }
        }
        return flags
    }

    public static func resolve(points: [Point2D], radius: Double, spread: Double) -> [DeclutterOffset] {
        var offsets = Array(repeating: DeclutterOffset.zero, count: points.count)
        for group in clusters(points, radius: radius) where group.count > 1 {
            let cx = group.map { points[$0].x }.reduce(0, +) / Double(group.count)
            let cy = group.map { points[$0].y }.reduce(0, +) / Double(group.count)
            let step = 2 * Double.pi / Double(group.count)
            for (k, idx) in group.enumerated() {                    // group is sorted → stable
                let angle = step * Double(k) - Double.pi / 2         // start at top, clockwise
                let tx = cx + spread * cos(angle)
                let ty = cy + spread * sin(angle)
                offsets[idx] = DeclutterOffset(dx: tx - points[idx].x, dy: ty - points[idx].y)
            }
        }
        return offsets
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `swift test --package-path AuraCore --filter ClusterDeclutterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/GroupRide/ClusterDeclutter.swift AuraCore/Tests/AuraCoreTests/GroupRide/ClusterDeclutterTests.swift
git commit -m "feat(roh-72): ClusterDeclutter — screen-space dot spread geometry"
```

---

## Task 5: `GroupMapDots` leader-preserving cap (AuraCore)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GroupRide/GroupMapDotsTests.swift` (extend)

**Interfaces:**
- Produces: `GroupMapDots.visiblePeers(peers:selfUserID:maxDots:) -> [RidePeer]` — existing filter, then a leader-preserving cap (keeps the highest-`progressMeters` peer + the rest by existing order) at `maxDots` (default 7). Existing 2-arg calls keep working via the default.

- [ ] **Step 1: Write failing tests (append to `GroupMapDotsTests`)**

```swift
    @Test func capKeepsLeaderWhenOverBudget() {
        let leader = UUID()
        var peers: [RidePeer] = (0..<9).map {
            RidePeer(userID: UUID(), displayName: "\($0)",
                     coordinate: Coordinate(latitude: 0, longitude: Double($0)),
                     progressMeters: Double($0), status: .riding)
        }
        // leader = furthest along, placed so a naive prefix would drop it
        peers.append(RidePeer(userID: leader, displayName: "L",
                              coordinate: Coordinate(latitude: 1, longitude: 1),
                              progressMeters: 9_999, status: .riding))
        let visible = GroupMapDots.visiblePeers(peers: peers, selfUserID: nil, maxDots: 7)
        #expect(visible.count == 7)
        #expect(visible.contains { $0.userID == leader })
    }

    @Test func underBudgetIsUnchangedOrder() {
        let peers = [
            RidePeer(userID: UUID(), displayName: "A",
                     coordinate: Coordinate(latitude: 0, longitude: 0), status: .riding),
            RidePeer(userID: UUID(), displayName: "B",
                     coordinate: Coordinate(latitude: 0, longitude: 1), status: .riding)
        ]
        #expect(GroupMapDots.visiblePeers(peers: peers, selfUserID: nil) == peers)
    }
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --package-path AuraCore --filter GroupMapDotsTests`
Expected: FAIL (extra `maxDots:` arg not present).

- [ ] **Step 3: Modify `visiblePeers`**

Replace the existing method with:

```swift
    public static func visiblePeers(peers: [RidePeer], selfUserID: UUID?,
                                    maxDots: Int = 7) -> [RidePeer] {
        let visible = peers.filter { $0.userID != selfUserID && $0.coordinate != nil }
        guard visible.count > maxDots else { return visible }
        // Runaway roster: keep the leader (furthest along) + fill the rest in existing order.
        let leaderID = visible.max { ($0.progressMeters ?? -.infinity) < ($1.progressMeters ?? -.infinity) }?.userID
        var kept = visible.filter { $0.userID == leaderID }
        for peer in visible where peer.userID != leaderID {
            if kept.count == maxDots { break }
            kept.append(peer)
        }
        return kept
    }
```

- [ ] **Step 4: Run, verify pass**

Run: `swift test --package-path AuraCore --filter GroupMapDotsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/GroupRide/GroupMapDots.swift AuraCore/Tests/AuraCoreTests/GroupRide/GroupMapDotsTests.swift
git commit -m "feat(roh-69): GroupMapDots leader-preserving dot cap"
```

---

## Task 6: Rider palette tokens + distinctness gate (AuraCore + AuraTheme)

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift` (add rider tokens)
- Modify: `Aura/Sources/Theme/AuraTheme.swift` (add `riderPalette: [Color]`)
- Test: `AuraCore/Tests/AuraCoreTests/RiderPaletteTests.swift`

**Interfaces:**
- Produces: `AuraPalette.riderHues: [RGBColor]` (the pure tokens); `AuraTheme.riderPalette: [Color]` (SwiftUI, index-aligned). `AuraTheme.riderColor(_ index: Int) -> Color` (wraps).

- [ ] **Step 1: Write failing tests — the distinctness/contrast/CVD gate**

```swift
import Testing
import Foundation
@testable import AuraCore

struct RiderPaletteTests {
    // CIELAB ΔE (76) between two sRGB colours.
    func deltaE(_ a: RGBColor, _ b: RGBColor) -> Double {
        let la = lab(a), lb = lab(b)
        let dl = la.0 - lb.0, da = la.1 - lb.1, db = la.2 - lb.2
        return (dl * dl + da * da + db * db).squareRoot()
    }
    func lab(_ c: RGBColor) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.red), g = lin(c.green), b = lin(c.blue)
        let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
        let y =  r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
    // Crude deuteranopia simulation (project onto the confusion axis) for a distinctness floor.
    func deuter(_ c: RGBColor) -> RGBColor {
        RGBColor(red: 0.625 * c.red + 0.375 * c.green,
                 green: 0.700 * c.red + 0.300 * c.green,
                 blue: 0.300 * c.green + 0.700 * c.blue)
    }

    @Test func atLeastFourRiderHues() {
        #expect(AuraPalette.riderHues.count >= 4)
    }

    @Test func riderHuesExcludeReservedTokens() {
        for h in AuraPalette.riderHues {
            #expect(h != AuraPalette.mint)   // lime = route/accent
            #expect(h != AuraPalette.amber)  // amber = warning/stopped
        }
    }

    @Test func riderHuesReadOnDarkBackground() {
        for h in AuraPalette.riderHues {
            #expect(WCAGContrast.ratio(h, AuraPalette.nearBlack) >= 3.0)
        }
    }

    @Test func riderHuesAreMutuallyDistinctInNormalAndDeuteranopia() {
        let hues = AuraPalette.riderHues
        for i in hues.indices {
            for j in (i + 1)..<hues.count {
                #expect(deltaE(hues[i], hues[j]) >= 20)                         // normal vision
                #expect(deltaE(deuter(hues[i]), deuter(hues[j])) >= 12)         // red-green CVD floor
            }
        }
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --package-path AuraCore --filter RiderPaletteTests`
Expected: FAIL (`riderHues` undefined).

- [ ] **Step 3: Add `riderHues` to `AuraPalette.swift`**

Add near the other tokens (values chosen to vary in BOTH hue and lightness so they separate under red-green CVD; exclude mint/amber):

```swift
    // MARK: - Rider identity palette (ROH-72)
    // Muted terrain tones that read as one Aura family on dark terrain, deliberately spanning
    // a wide lightness range so red-green colour-blind riders can still tell them apart. Never
    // includes `mint` (route/accent) or `amber` (warning/stopped). Guarded by RiderPaletteTests
    // (ΔE distinctness in normal + simulated deuteranopia, and contrast on `nearBlack`).
    public static let riderHues: [RGBColor] = [
        RGBColor(red: 0.204, green: 0.706, blue: 0.792),  // teal    #34B4CA
        RGBColor(red: 0.435, green: 0.549, blue: 0.941),  // blue    #6F8CF0
        RGBColor(red: 0.706, green: 0.514, blue: 0.855),  // violet  #B483DA
        RGBColor(red: 0.851, green: 0.396, blue: 0.353),  // rust    #D9655A
        RGBColor(red: 0.902, green: 0.573, blue: 0.729),  // rose    #E692BA
        RGBColor(red: 0.812, green: 0.741, blue: 0.545)   // sand    #CFBD8B
    ]
```

- [ ] **Step 4: Run the gate; tune only if a pair fails**

Run: `swift test --package-path AuraCore --filter RiderPaletteTests`
Expected: PASS. If a specific pair fails the ΔE floor, adjust the lighter/darker of the two by nudging its lightness (scale all three RGB components toward 0 or 1 by ~0.08) and re-run — the test is the acceptance gate. Do not add mint/amber.

- [ ] **Step 5: Add `riderPalette` to `AuraTheme.swift`**

Add in the color-roles section:

```swift
    // MARK: - Rider identity palette (ROH-72)
    /// Index-aligned with `AuraPalette.riderHues`; `PeerPalette.assign` returns the index.
    static let riderPalette: [Color] = AuraPalette.riderHues.map(rgb)
    static func riderColor(_ index: Int) -> Color {
        riderPalette.isEmpty ? accent : riderPalette[((index % riderPalette.count) + riderPalette.count) % riderPalette.count]
    }
```

- [ ] **Step 6: Verify the app target still builds (delegate to builder)**

Dispatch the `apple-platform-build-tools:builder` agent: "Build the Aura app scheme for the iPhone 17 simulator; report only pass/fail + first error." Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Theme/AuraPalette.swift Aura/Sources/Theme/AuraTheme.swift AuraCore/Tests/AuraCoreTests/RiderPaletteTests.swift
git commit -m "feat(roh-72): rider identity palette tokens + ΔE/CVD distinctness gate"
```

> **Build-time design note:** exact hues are provisional. During Task 7/8 review, sanity-check them on the real terrain style with `impeccable` + Xcode's Color Blindness simulator; any change must keep `RiderPaletteTests` green.

---

## Task 7: `PeerDotView` redesign (app — build-verified)

**Files:**
- Modify: `Aura/Sources/GroupRide/GroupRideMapOverlay.swift`

**Interfaces:**
- Consumes: `AuraTheme.riderColor(_:)`, `PeerStatus`.
- Produces: `PeerDotView(monogram:displayName:status:identityColor:isSelf:bearing:pulsePhase:showsNameTag:reduceMotion:)` — a single persistent marker: upright round head (identity hue + monogram + status treatment) with a rotating outlined heading pointer that retracts to a plain disc when `bearing == nil`. `monogram` labels the disc; `displayName` is the name-tag text. `pulsePhase: Double` (0…1, clock-driven) and `reduceMotion: Bool` are injected so the view holds no animation `@State`.

Verification for this task is **compile + on-device** (app target is not unit-tested).

- [ ] **Step 1: Rewrite `PeerDotView`** (replace the whole struct; keep the `Triangle` shape, add an outlined pointer)

```swift
struct PeerDotView: View {
    let monogram: String
    let displayName: String
    let status: PeerStatus
    let identityColor: Color
    let isSelf: Bool
    /// Degrees clockwise from north; nil retracts the pointer to a plain disc.
    let bearing: Double?
    /// 0…1 pulse phase driven by the frame clock (nil/constant under Reduce Motion → no pulse).
    let pulsePhase: Double
    let showsNameTag: Bool
    let reduceMotion: Bool

    private static let discDiameter: CGFloat = 22
    private static let pointerLength: CGFloat = 14

    private var headColor: Color {
        if isSelf { return AuraTheme.textPrimary }
        switch status {
        case .riding, .stopped, .awaiting: return identityColor      // identity hue preserved
        case .dropped: return identityColor.opacity(0.45)            // ghost
        }
    }
    private var isHollow: Bool { status == .awaiting }
    private var showsPointer: Bool { bearing != nil && status == .riding }

    var body: some View {
        VStack(spacing: AuraTheme.Spacing.xs) {
            if showsNameTag { nameTag }
            ZStack {
                pulseRing
                pointer
                head
                statusBadge
            }
            .frame(width: Self.discDiameter + Self.pointerLength,
                   height: Self.discDiameter + Self.pointerLength)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(monogram), \(statusAccessibilityLabel)"))
    }

    // Pulse is a pure function of the injected phase — no @State, so it survives status morphs
    // and is simply absent under Reduce Motion (phase held constant by the host).
    @ViewBuilder private var pulseRing: some View {
        if status == .riding && !reduceMotion {
            let grow = 6 + 12 * pulsePhase
            Circle().stroke(headColor.opacity(0.5 * (1 - pulsePhase)), lineWidth: 2)
                .frame(width: Self.discDiameter + grow, height: Self.discDiameter + grow)
        } else if status == .riding {
            Circle().stroke(headColor.opacity(0.4), lineWidth: 2)     // static RM ring
                .frame(width: Self.discDiameter + 8, height: Self.discDiameter + 8)
        }
    }

    // Bold, dark-outlined pointer; rotates with bearing. Only the pointer rotates — the head
    // (monogram) never spins, so it stays legible.
    @ViewBuilder private var pointer: some View {
        if showsPointer, let bearing {
            Triangle()
                .fill(headColor)
                .overlay(Triangle().stroke(AuraTheme.background, lineWidth: 1.5))
                .frame(width: 12, height: Self.pointerLength)
                .offset(y: -(Self.discDiameter / 2 + Self.pointerLength / 2 - 2))
                .rotationEffect(.degrees(reduceMotion ? bearing.rounded() : bearing))
        }
    }

    private var head: some View {
        ZStack {
            Circle().fill(isHollow ? Color.clear : headColor)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            Circle().strokeBorder(isHollow ? headColor : AuraTheme.background, lineWidth: 1.5)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            Text(monogram)
                .font(.system(size: monogram.count > 1 ? 8 : 10, weight: .bold, design: .rounded))
                .foregroundStyle(isHollow ? headColor : AuraTheme.onAccent)
        }
    }

    // High-area, glanceable status glyph (pause / no-signal), overlaid on the head corner.
    @ViewBuilder private var statusBadge: some View {
        switch status {
        case .stopped:
            badge(systemName: "pause.fill", tint: AuraTheme.warning)
        case .dropped:
            badge(systemName: "wifi.slash", tint: AuraTheme.textSecondary)
        case .riding, .awaiting:
            EmptyView()
        }
    }
    private func badge(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(tint)
            .padding(2)
            .background(Circle().fill(AuraTheme.background))
            .offset(x: Self.discDiameter / 2 - 2, y: -Self.discDiameter / 2 + 2)
    }

    private var nameTag: some View {
        Text(displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AuraTheme.textPrimary)
            .padding(.horizontal, AuraTheme.Spacing.xs).padding(.vertical, 2)
            .background(AuraTheme.surface.opacity(0.85), in: Capsule())
    }

    private var statusAccessibilityLabel: String {
        if isSelf { return "you" }
        switch status {
        case .riding: return "riding"; case .stopped: return "stopped"
        case .dropped: return "no signal"; case .awaiting: return "waiting to start"
        }
    }
}
```

- [ ] **Step 2: Update the `#Preview`** (and any preview in this file) to the new `PeerDotView` signature so the file compiles — supply `monogram:`, `displayName:`, `identityColor: AuraTheme.riderColor(0)`, `pulsePhase: 0.5`, `reduceMotion: false`.

- [ ] **Step 3: Build the app (delegate to builder)**

Dispatch `apple-platform-build-tools:builder`: "Build the Aura app scheme for the iPhone 17 simulator; report pass/fail + first error." Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/GroupRide/GroupRideMapOverlay.swift
git commit -m "feat(roh-72): PeerDotView — identity head + rotating pointer + glyph status"
```

---

## Task 8: `PeerAnnotations` sub-view (app — build-verified)

**Files:**
- Create: `Aura/Sources/GroupRide/PeerAnnotations.swift`

**Interfaces:**
- Consumes: `PeerInterpolators`, `PeerPalette`, `RiderMonogram`, `ClusterDeclutter`, `GroupMapDots`, `AuraTheme.riderColor`, `PeerDotView`, MapboxMaps.
- Produces: `PeerAnnotations` — a `@MapContentBuilder`-returning view fragment usable inside both hosts' `Map { }`. It owns interpolation `@State`, the TimelineView-driven frame values, and memoised per-set derivations.

This task wires the pure pieces together. Because `MapViewAnnotation` lives inside `Map { }`, the frame clock is realised by driving a `@State` `frameDate` from a `TimelineView` sibling OR (fallback) a display-tick `Task`; the memoised derivations are recomputed only on `.onChange(of:)` of the peer set, not per frame.

- [ ] **Step 1: Implement `PeerAnnotations.swift`**

```swift
import SwiftUI
import MapboxMaps
import AuraCore

/// Renders the live peer dots for a group ride: smooth interpolation (ROH-69) + distinct
/// identity/heading (ROH-72). Owns the per-peer interpolators and all memoised derivations so
/// the 30fps frame path only rebuilds ≤7 annotations. Shared by NavigateHUDView and RideMapView.
struct PeerAnnotations: MapContent {
    let peers: [RidePeer]
    let selfUserID: UUID?
    let nameMap: [UUID: String]
    /// Interpolated display state, recomputed each frame by the host (see `PeerAnnotationsLayer`).
    let frame: PeerFrame

    var body: some MapContent {
        ForEvery(frame.dots, id: \.userID) { dot in
            MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                latitude: dot.coordinate.latitude, longitude: dot.coordinate.longitude)) {
                PeerDotView(monogram: dot.monogram, displayName: dot.displayName,
                            status: dot.status,
                            identityColor: AuraTheme.riderColor(dot.colorIndex),
                            isSelf: false, bearing: dot.bearing,
                            pulsePhase: frame.pulsePhase, showsNameTag: dot.showsNameTag,
                            reduceMotion: frame.reduceMotion)
                    .offset(x: dot.offset.dx, y: dot.offset.dy)
                    .animation(.easeInOut(duration: 0.25), value: dot.offset)
            }
            .allowOverlapWithPuck(true)
        }
    }
}

/// A single dot's fully-resolved render state for one frame.
struct PeerDot: Identifiable, Equatable {
    var userID: UUID
    var coordinate: Coordinate
    var bearing: Double?
    var status: PeerStatus
    var colorIndex: Int
    var monogram: String
    var displayName: String
    var showsNameTag: Bool
    var offset: ClusterDeclutter.DeclutterOffset
    var id: UUID { userID }
}

struct PeerFrame: Equatable {
    var dots: [PeerDot]
    var pulsePhase: Double
    var reduceMotion: Bool
}
```

> **Note on projection:** `ClusterDeclutter` needs screen points. In the host layer below, project
> each interpolated coordinate with the map's `MapProxy`/`mapboxMap.point(for:)`. If a proxy is not
> reachable from the content builder in this Mapbox v11 setup, degrade gracefully: pass
> `offset = .zero` and compute `showsNameTag` from `GroupMapDots`/leader only (declutter then reduces
> to hue+monogram+z-order, still a valid state), and revisit projection wiring during device verify.

- [ ] **Step 2: Implement the host layer that owns the clock + memoisation**

Add to the same file — the view both hosts embed, which produces a `PeerFrame` and hands it to `Map { PeerAnnotations(...) }` via a binding-like closure. Because Mapbox's `Map` takes content directly, the host computes `PeerFrame` in the enclosing SwiftUI view and passes it down:

```swift
/// Drives interpolation + memoised derivations for the peer dots and exposes a `PeerFrame`.
/// The host view keeps one of these in `@State` and calls `advance` from a `TimelineView`.
@Observable
final class PeerAnnotationModel {
    private var interpolators = PeerInterpolators()
    // Memoised per peer-set change (NOT per frame):
    private var visible: [RidePeer] = []
    private var colorIndex: [UUID: Int] = [:]
    private var monograms: [UUID: String] = [:]
    private var displayNames: [UUID: String] = [:]
    private var leaderID: UUID?

    /// Recompute the set-derived data. Call from `.onChange(of: peers)` only.
    func updateSet(peers: [RidePeer], selfUserID: UUID?, nameMap: [UUID: String], now: Date) {
        visible = GroupMapDots.visiblePeers(peers: peers, selfUserID: selfUserID)
        let ids = visible.map(\.userID)
        displayNames = Dictionary(uniqueKeysWithValues:
            visible.map { ($0.userID, nameMap[$0.userID] ?? $0.displayName) })
        colorIndex = PeerPalette.assign(userIDs: ids, paletteCount: AuraTheme.riderPalette.count)
        monograms = RiderMonogram.assign(names: displayNames)
        leaderID = visible.max { ($0.progressMeters ?? -.infinity) < ($1.progressMeters ?? -.infinity) }?.userID
        interpolators.commit(peers: visible, now: now)
    }

    var reduceMotion = false

    /// Build the frame for wall-clock `now`. `project` maps a coordinate to a screen point (nil
    /// if unavailable → no declutter). Pure-ish; cheap for ≤7 dots.
    func frame(now: Date, project: (Coordinate) -> ClusterDeclutter.Point2D?) -> PeerFrame {
        let coords = visible.compactMap { p in interpolators.position(p.userID, at: now).map { (p, $0) } }
        let points = coords.map { project($0.1) }
        let declutterInput = points.map { $0 ?? .init(x: 0, y: 0) }
        let canDeclutter = points.allSatisfy { $0 != nil }
        let offsets = canDeclutter
            ? ClusterDeclutter.resolve(points: declutterInput, radius: 26, spread: 18)
            : Array(repeating: .zero, count: coords.count)
        let clustered = canDeclutter
            ? ClusterDeclutter.clustered(points: declutterInput, radius: 26)
            : Array(repeating: false, count: coords.count)

        let dots: [PeerDot] = coords.enumerated().map { i, pc in
            let (peer, coord) = pc
            let bearing = reduceMotion ? interpolators.bearing(peer.userID, at: now)?.rounded()
                                       : interpolators.bearing(peer.userID, at: now)
            return PeerDot(userID: peer.userID, coordinate: coord, bearing: bearing,
                           status: peer.status, colorIndex: colorIndex[peer.userID] ?? 0,
                           monogram: monograms[peer.userID] ?? "?",
                           displayName: displayNames[peer.userID] ?? peer.displayName,
                           showsNameTag: peer.userID == leaderID || clustered[i],
                           offset: offsets[i])
        }
        // Pulse phase: triangle wave, ~1.1s up / down; held at 0 under Reduce Motion.
        let phase = reduceMotion ? 0 : abs((now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 1.1) - 1)
        return PeerFrame(dots: dots, pulsePhase: 1 - phase, reduceMotion: reduceMotion)
    }

    func anyActive(now: Date) -> Bool { interpolators.anyActive(at: now) }
}
```

> The host (Task 9) wraps its `Map` in `TimelineView(.animation(paused: !model.anyActive(now:) ))`,
> reads `model.frame(now: context.date, project:)` each tick, and passes the resulting
> `PeerAnnotations(... frame:)` into `Map { }`. `updateSet` is called from `.onChange(of: peers)`.
> `project` uses the map's `point(for:)`; if unreachable in this Mapbox setup, pass `{ _ in nil }`
> (declutter degrades per the note in Step 1) and finish projection wiring during device verify.

- [ ] **Step 3: Build the app (delegate to builder)**

Dispatch `apple-platform-build-tools:builder`: "Build the Aura app scheme for the iPhone 17 simulator; report pass/fail + first error." Expected: build succeeds. Resolve any Mapbox `MapContent`/`@Observable` wiring errors so it compiles.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/GroupRide/PeerAnnotations.swift
git commit -m "feat(roh-69,roh-72): PeerAnnotations — interpolation clock + declutter + identity"
```

---

## Task 9: Wire both hosts + remove `previousPeerCoordinates` (app — build-verified)

**Files:**
- Modify: `Aura/Sources/Ride/RideMapView.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`

**Interfaces:**
- Consumes: `PeerAnnotationModel`, `PeerAnnotations`, `PeerFrame`.

- [ ] **Step 1: `RideMapView`** — replace the inline peer `ForEvery` and `previousPeerCoordinates`.

Add `@State private var peerModel = PeerAnnotationModel()` and `@Environment(\.accessibilityReduceMotion) private var reduceMotion`. Delete `@State private var previousPeerCoordinates` and its `.onChange(of: peers)` updater and the `leaderID` computed property (now in the model). Wrap the `Map` in a `TimelineView`:

```swift
var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !peerModel.anyActive(now: Date()))) { context in
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            routeRibbon
            detourPolyline
            PeerAnnotations(peers: peers, selfUserID: selfUserID, nameMap: nameMap,
                            frame: peerModel.frame(now: context.date, project: projectPoint))
            gemAnnotations   // extract the existing gem ForEvery into this @MapContentBuilder var
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        .ignoresSafeArea()
    }
    .onAppear { peerModel.reduceMotion = reduceMotion }
    .onChange(of: reduceMotion) { peerModel.reduceMotion = $1 }
    .onChange(of: peers) { peerModel.updateSet(peers: peers, selfUserID: selfUserID, nameMap: nameMap, now: Date()) }
}

/// Projects a coordinate to a screen point for declutter. Wire to the Mapbox proxy during the
/// build; return nil until then (declutter degrades to hue+monogram — see PeerAnnotations note).
private func projectPoint(_ c: Coordinate) -> ClusterDeclutter.Point2D? { nil }
```

Extract the existing gem `ForEvery` (lines ~68–74) into a `@MapContentBuilder private var gemAnnotations: some MapContent`.

- [ ] **Step 2: `NavigateHUDView`** — same treatment on its `Map` (lines ~255–282): remove `previousPeerCoordinates` + its `.onChange`, add a `peerModel`, wrap the group-dot block in `PeerAnnotations` fed by `peerModel.frame`, drive `updateSet` from `.onChange(of: groupSession?.peers)`, wrap the `Map` in the same `TimelineView(.animation(paused:))`. Guard the whole block on `if let groupSession`.

- [ ] **Step 3: Build the app (delegate to builder)**

Dispatch `apple-platform-build-tools:builder`: "Build the Aura app scheme for the iPhone 17 simulator; report pass/fail + first error." Expected: build succeeds.

- [ ] **Step 4: Wire real projection** — replace `projectPoint` in both hosts with the Mapbox `point(for:)` call (v11: via the map proxy / `mapboxMap`). If the proxy is genuinely unreachable from this position, leave `nil` (degraded declutter) and record it as a device-verify follow-up. Build again.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/RideMapView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-69,roh-72): adopt PeerAnnotations in both map hosts"
```

---

## Task 10: Full verification + device batch

**Files:** none (verification only).

- [ ] **Step 1: Full AuraCore test suite**

Run: `swift test --package-path AuraCore`
Expected: all pass (existing + new PeerInterpolator/PeerPalette/RiderMonogram/ClusterDeclutter/GroupMapDots/RiderPalette tests).

- [ ] **Step 2: SwiftLint strict**

Run: `swiftlint --strict` (from repo root; pinned 0.64.1)
Expected: no violations. Fix any (line length, type body length — split with same-file extensions as `GroupRideSession` does).

- [ ] **Step 3: App build + full test (delegate to builder)**

Dispatch `apple-platform-build-tools:builder`: "Build the Aura app + run the app/unit test targets on the iPhone 17 simulator; report pass/fail + failures." Expected: green.

- [ ] **Step 4: Record the device-verify batch** in `.superpowers/sdd/DEVICE-VERIFY-BATCH.md` (create/append). Acceptance is a real two-phone ride:
  - Dots **glide** smoothly between fixes (no per-broadcast hop); verify at foreground (2s) and after backgrounding one phone (6s).
  - After a long stop / dead-zone, the reappearing dot **snaps** (no glide across the gap).
  - Two riders are **instantly tell-apart-able** even when close and even sharing a first initial (distinct hue + monogram; discs spread when stacked; tags don't occlude).
  - **Heading** is obvious (bold outlined pointer, calm rotation — flag if fidgety → fall back to bolder static cone per spec §7).
  - **Reduce Motion** on: dots still glide (linear), pulse + pointer-spin suppressed.
  - No hitching (Release build); confirm the TimelineView doesn't fight map pan/zoom/rotate (if it does, switch to the display-tick fallback, spec §3.5).
  - Solo ride unaffected.

- [ ] **Step 5: Final commit if any lint/build fixes were needed**

```bash
git add -A && git commit -m "chore(roh-69,roh-72): lint + build fixes; record device-verify batch"
```

---

## Self-review notes (coverage)

- ROH-69 interpolation §3 → Tasks 1, 8, 9. Snap/duration/bearing/first-fix/heartbeat all in Task 1 tests.
- ROH-72 identity §4 → Tasks 2 (palette), 3 (monogram), 6 (hues+gate), 7 (dot). Overlap §4.4 → Task 4 + Task 8/9 projection. Cap §4.7 → Task 5. RM §4.6 → Tasks 7/8/9.
- ROH-66 boundary §6 → no presence/transport files touched (Global Constraints); coherence via `recordedAt` in Task 1.
- Device-first acceptance §7 → Task 10 batch.
- **Known integration risk carried into build:** Mapbox v11 screen projection from the content builder (Task 8 note / Task 9 Step 4) and TimelineView-vs-gesture (Task 10) — both have defined degraded/fallback paths so a task can't hard-block.
