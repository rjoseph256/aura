# Explore Nearby Gems — Plan 1: Gems on the map

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Curated gems appear as ambient pins on the free-ride map, updating as the rider moves, suppressed during group rides.

**Architecture:** A pure, timestamp-driven `GemDiscoveryEngine` + `Gem` value types in AuraCore; a `GemProviding` seam with a package-bundled `CuratedGemProvider` and an `@Observable GemDiscoveryStore` in AuraKit; the `RideSessionCoordinator` forwards each location fix to an injected discovery sink; `RideMapView` renders `GemPinView` annotations from `store.visiblePins`. This slice is Tier-agnostic (every gem is a plain pin) — tiers, cards, haptics, detail, the detour, personal markers, the live feed, and V4 persistence land in later plans.

**Tech Stack:** Swift 6, SwiftUI, MapboxMaps v11, Swift Testing, SwiftData (unchanged this slice). AuraCore + AuraKit are an SPM package that builds and tests on the macOS host.

**Spec:** `docs/superpowers/specs/2026-07-04-explore-nearby-gems-design.md`

**Sequenced plans (this is Plan 1 of 4):**
1. **Gems on the map** (this doc) — curated pins, engine proximity/cap, store, coordinator sink, map layer.
2. Tiers + peek cards + detail sheet + seen-memory (`SeenGemRecord`, V4 migration, tier/cooldown/one-at-a-time engine rules, seen-state pin styling).
3. The detour — `GuidanceController` on the coordinator (detach-on-arrive), slim overlay, offline heading.
4. Personal "return here" (`resurface` flag, V4) + minimal live feed + priority arbitration + accessibility pass.

## Global Constraints

- Swift 6 language mode, all targets. Data-race safety must hold.
- SwiftLint passes `--strict` (the CI gate).
- AuraCore/AuraKit compile and test on the **macOS host**: no unguarded iOS-only APIs (CoreLocation `CLBackgroundActivitySession`/`CLHeading`, UIKit) in package code — `#if os(iOS)`-guard any that are unavoidable. Pure gem logic uses none.
- The `GemDiscoveryEngine` contains **no `Date()`/timers**: its "now" is the timestamp of the location sample it is given.
- Signature accent is `AuraPalette.mint` / `AuraTheme.accent`; dark surfaces from `AuraPalette`. No new colors.
- `Gem.id` is a **stable, source-namespaced `String`** (`"curated:<slug>"`, later `"personal:<uuid>"`, `"osm:<id>"`).
- Sentence case in any UI copy; no ALL CAPS labels beyond existing cockpit instrument style.

---

### Task 1: `Gem` value types (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Gems/Gem.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GemTests.swift`

**Interfaces:**
- Produces:
  - `enum GemTier: Int, Codable, Sendable, Comparable { case pin = 1, card = 2, cardHaptic = 3 }`
  - `enum GemSource: String, Codable, Sendable { case curated, personal, live }`
  - `enum GemCategory: String, Codable, Sendable, CaseIterable { case viewpoint, water, park, cafe, mural, climb, historic, landmark; var defaultTier: GemTier; var arrivalRadiusMeters: Double }`
  - `struct Gem: Identifiable, Codable, Equatable, Sendable { let id: String; let name: String; let coordinate: Coordinate; let category: GemCategory; let tier: GemTier; let source: GemSource; let photoAsset: String?; let why: String? }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraCore

@Suite struct GemTests {
    @Test func tierIsComparable() {
        #expect(GemTier.pin < GemTier.card)
        #expect(GemTier.cardHaptic > GemTier.card)
    }

    @Test func categoryCarriesDefaultTierAndArrivalRadius() {
        #expect(GemCategory.viewpoint.defaultTier == .cardHaptic)
        #expect(GemCategory.cafe.defaultTier == .pin)
        #expect(GemCategory.viewpoint.arrivalRadiusMeters > GemCategory.cafe.arrivalRadiusMeters)
    }

    @Test func gemRoundTripsThroughCodable() throws {
        let gem = Gem(id: "curated:grandview-overlook", name: "Grandview overlook",
                      coordinate: Coordinate(latitude: 40.43, longitude: -80.0),
                      category: .viewpoint, tier: .cardHaptic, source: .curated,
                      photoAsset: "grandview", why: "City skyline from the incline.")
        let data = try JSONEncoder().encode(gem)
        let decoded = try JSONDecoder().decode(Gem.self, from: data)
        #expect(decoded == gem)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter GemTests`
Expected: FAIL — `cannot find 'Gem' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum GemTier: Int, Codable, Sendable, Comparable {
    case pin = 1, card = 2, cardHaptic = 3
    public static func < (lhs: GemTier, rhs: GemTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum GemSource: String, Codable, Sendable { case curated, personal, live }

public enum GemCategory: String, Codable, Sendable, CaseIterable {
    case viewpoint, water, park, cafe, mural, climb, historic, landmark

    public var defaultTier: GemTier {
        switch self {
        case .viewpoint, .mural, .landmark: return .cardHaptic
        case .park, .water, .climb, .historic: return .card
        case .cafe: return .pin
        }
    }

    /// How close (meters) counts as "arrived" for this kind of place.
    public var arrivalRadiusMeters: Double {
        switch self {
        case .cafe, .mural, .landmark: return 30
        case .water, .historic: return 45
        case .park, .viewpoint, .climb: return 70
        }
    }
}

public struct Gem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let category: GemCategory
    public let tier: GemTier
    public let source: GemSource
    public let photoAsset: String?
    public let why: String?

    public init(id: String, name: String, coordinate: Coordinate,
                category: GemCategory, tier: GemTier, source: GemSource,
                photoAsset: String? = nil, why: String? = nil) {
        self.id = id; self.name = name; self.coordinate = coordinate
        self.category = category; self.tier = tier; self.source = source
        self.photoAsset = photoAsset; self.why = why
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path AuraCore --filter GemTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/Gem.swift AuraCore/Tests/AuraCoreTests/GemTests.swift
git commit -m "feat(gems): Gem value types (tier, source, category, model)"
```

---

### Task 2: `GemDiscoveryEngine` — proximity + nearest-N cap (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Gems/GemGeo.swift`
- Create: `AuraCore/Sources/AuraCore/Gems/GemDiscoveryEngine.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GemDiscoveryEngineTests.swift`

**Interfaces:**
- Consumes: `Gem`, `Coordinate` (Task 1 / existing).
- Produces:
  - `enum GemGeo { static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double }`
  - `struct GemDiscoveryEngine: Sendable { init(proximityRadiusMeters: Double = 1500, pinCap: Int = 10); func visiblePins(from candidates: [Gem], at location: Coordinate) -> [Gem] }`

> Note: if AuraCore already exposes a great-circle distance (check `RideStats`/`RideRecorder` distance accumulation), reuse it in `GemGeo` instead of duplicating the haversine.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import AuraCore

@Suite struct GemDiscoveryEngineTests {
    private func gem(_ id: String, _ lat: Double, _ lng: Double) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: lng),
            category: .park, tier: .card, source: .curated)
    }
    private let here = Coordinate(latitude: 40.4406, longitude: -79.9959) // Pittsburgh

    @Test func dropsGemsOutsideTheProximityRadius() {
        let engine = GemDiscoveryEngine(proximityRadiusMeters: 1000, pinCap: 10)
        let near = gem("near", 40.4410, -79.9959)     // ~45 m
        let far  = gem("far", 40.5000, -79.9959)      // ~6.6 km
        let pins = engine.visiblePins(from: [near, far], at: here)
        #expect(pins.map(\.id) == ["near"])
    }

    @Test func capsToNearestN() {
        let engine = GemDiscoveryEngine(proximityRadiusMeters: 5000, pinCap: 2)
        let gems = [gem("d3", 40.4460, -79.9959), gem("d1", 40.4411, -79.9959),
                    gem("d2", 40.4430, -79.9959)]
        let pins = engine.visiblePins(from: gems, at: here)
        #expect(pins.map(\.id) == ["d1", "d2"]) // nearest two, sorted by distance
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter GemDiscoveryEngineTests`
Expected: FAIL — `cannot find 'GemDiscoveryEngine' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GemGeo.swift`:

```swift
import Foundation

public enum GemGeo {
    /// Great-circle distance in meters (haversine).
    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
```

`GemDiscoveryEngine.swift`:

```swift
import Foundation

/// Pure, timestamp-driven discovery logic. This slice implements only the ambient
/// layer: which gems are visible as pins near a location, capped to the nearest N.
public struct GemDiscoveryEngine: Sendable {
    public let proximityRadiusMeters: Double
    public let pinCap: Int

    public init(proximityRadiusMeters: Double = 1500, pinCap: Int = 10) {
        self.proximityRadiusMeters = proximityRadiusMeters
        self.pinCap = pinCap
    }

    /// Gems within `proximityRadiusMeters` of `location`, nearest first, capped to `pinCap`.
    public func visiblePins(from candidates: [Gem], at location: Coordinate) -> [Gem] {
        candidates
            .map { ($0, GemGeo.distanceMeters($0.coordinate, location)) }
            .filter { $0.1 <= proximityRadiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(pinCap)
            .map(\.0)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path AuraCore --filter GemDiscoveryEngineTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/GemGeo.swift AuraCore/Sources/AuraCore/Gems/GemDiscoveryEngine.swift AuraCore/Tests/AuraCoreTests/GemDiscoveryEngineTests.swift
git commit -m "feat(gems): discovery engine proximity + nearest-N pin cap"
```

---

### Task 3: `GemProviding` seam + `CuratedGemProvider` (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/GemProviding.swift`
- Create: `AuraCore/Sources/AuraKit/Gems/CuratedGemProvider.swift`
- Create: `AuraCore/Sources/AuraKit/Resources/gems.json`
- Modify: `AuraCore/Package.swift` (add the resource to the AuraKit target)
- Test: `AuraCore/Tests/AuraKitTests/CuratedGemProviderTests.swift`

**Interfaces:**
- Consumes: `Gem`, `Coordinate` (AuraCore).
- Produces:
  - `protocol GemProviding: Sendable { func gems(near coordinate: Coordinate) async -> [Gem] }`
  - `struct CuratedGemProvider: GemProviding { init(bundle: Bundle = .module) }`

- [ ] **Step 1: Create the seed resource and register it**

Create `AuraCore/Sources/AuraKit/Resources/gems.json`:

```json
[
  { "id": "curated:grandview-overlook", "name": "Grandview overlook",
    "coordinate": { "latitude": 40.4392, "longitude": -80.0155 },
    "category": "viewpoint", "tier": 3, "source": "curated",
    "photoAsset": "gem-grandview", "why": "The classic skyline view from Mt. Washington." },
  { "id": "curated:point-state-park", "name": "Point State Park",
    "coordinate": { "latitude": 40.4419, "longitude": -80.0089 },
    "category": "park", "tier": 2, "source": "curated",
    "photoAsset": "gem-point-park", "why": "Where the three rivers meet." },
  { "id": "curated:randyland", "name": "Randyland",
    "coordinate": { "latitude": 40.4568, "longitude": -80.0074 },
    "category": "mural", "tier": 3, "source": "curated",
    "photoAsset": "gem-randyland", "why": "A courtyard of color in the Mexican War Streets." }
]
```

In `AuraCore/Package.swift`, on the `AuraKit` target add:

```swift
resources: [.process("Sources/AuraKit/Resources/gems.json")]
```

(If the target already has a `resources:` array, append the entry; keep the existing path style used by the target.)

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import AuraCore
@testable import AuraKit

@Suite struct CuratedGemProviderTests {
    @Test func loadsAndDecodesTheBundledSeed() async {
        let gems = await CuratedGemProvider().gems(near: Coordinate(latitude: 40.44, longitude: -80.0))
        #expect(gems.count >= 3)
        #expect(gems.contains { $0.id == "curated:grandview-overlook" && $0.tier == .cardHaptic })
        #expect(gems.allSatisfy { $0.source == .curated })
    }

    @Test func dropsMalformedEntriesRatherThanThrowing() async {
        let bad = #"[{"id":"ok","name":"Ok","coordinate":{"latitude":1,"longitude":2},"category":"park","tier":2,"source":"curated"},{"id":"bad","name":"Bad","coordinate":{"latitude":1,"longitude":2},"category":"NOT_A_CATEGORY","tier":2,"source":"curated"}]"#
        let gems = CuratedGemProvider.decode(Data(bad.utf8))
        #expect(gems.map(\.id) == ["ok"])
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter CuratedGemProviderTests`
Expected: FAIL — `cannot find 'CuratedGemProvider' in scope`.

- [ ] **Step 4: Write minimal implementation**

`GemProviding.swift`:

```swift
import Foundation
import AuraCore

public protocol GemProviding: Sendable {
    /// Candidate gems relevant near `coordinate`. Curated returns its whole (small) set.
    func gems(near coordinate: Coordinate) async -> [Gem]
}
```

`CuratedGemProvider.swift`:

```swift
import Foundation
import AuraCore

/// Loads the hand-curated gem set bundled with the package. Malformed entries are
/// dropped, never fatal — a stale or partially-bad bundle must not crash a ride.
public struct CuratedGemProvider: GemProviding {
    private let bundle: Bundle

    public init(bundle: Bundle = .module) { self.bundle = bundle }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        guard let url = bundle.url(forResource: "gems", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return Self.decode(data)
    }

    /// Lenient array decode: each element decoded independently, invalid ones dropped.
    public static func decode(_ data: Data) -> [Gem] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(Gem.self, from: elementData)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path AuraCore --filter CuratedGemProviderTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Gems/ AuraCore/Sources/AuraKit/Resources/gems.json AuraCore/Package.swift AuraCore/Tests/AuraKitTests/CuratedGemProviderTests.swift
git commit -m "feat(gems): GemProviding seam + bundled CuratedGemProvider"
```

---

### Task 4: `GemDiscoveryStore` (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/GemDiscoveryStoreTests.swift`

**Interfaces:**
- Consumes: `GemProviding` (Task 3), `GemDiscoveryEngine`, `Gem`, `Coordinate`.
- Produces:
  - `@MainActor @Observable final class GemDiscoveryStore { init(provider: any GemProviding, engine: GemDiscoveryEngine = .init()); private(set) var visiblePins: [Gem]; var isSuppressed: Bool; func load() async; func update(at coordinate: Coordinate) }`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AuraCore
@testable import AuraKit

@MainActor
@Suite struct GemDiscoveryStoreTests {
    private struct StubProvider: GemProviding {
        let gems: [Gem]
        func gems(near coordinate: Coordinate) async -> [Gem] { gems }
    }
    private func gem(_ id: String, _ lat: Double) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: -80.0),
            category: .park, tier: .card, source: .curated)
    }

    @Test func publishesNearbyPinsAfterLoadAndUpdate() async {
        let store = GemDiscoveryStore(provider: StubProvider(gems: [gem("a", 40.4411), gem("b", 40.60)]),
                                      engine: GemDiscoveryEngine(proximityRadiusMeters: 1000, pinCap: 10))
        await store.load()
        store.update(at: Coordinate(latitude: 40.4406, longitude: -79.9959))
        #expect(store.visiblePins.map(\.id) == ["a"])
    }

    @Test func suppressedStorePublishesNoPins() async {
        let store = GemDiscoveryStore(provider: StubProvider(gems: [gem("a", 40.4406)]))
        await store.load()
        store.isSuppressed = true
        store.update(at: Coordinate(latitude: 40.4406, longitude: -79.9959))
        #expect(store.visiblePins.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter GemDiscoveryStoreTests`
Expected: FAIL — `cannot find 'GemDiscoveryStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import Observation
import AuraCore

/// Holds the candidate gem set (loaded once) and republishes the visible pins as the
/// rider moves. Suppressed while a group ride is active (peer dots own the map budget).
@MainActor
@Observable
public final class GemDiscoveryStore {
    public private(set) var visiblePins: [Gem] = []
    public var isSuppressed = false {
        didSet { if isSuppressed { visiblePins = [] } }
    }

    private let provider: any GemProviding
    private let engine: GemDiscoveryEngine
    private var candidates: [Gem] = []
    private var lastCoordinate: Coordinate?

    public init(provider: any GemProviding, engine: GemDiscoveryEngine = .init()) {
        self.provider = provider
        self.engine = engine
    }

    public func load() async {
        let origin = lastCoordinate ?? Coordinate(latitude: 0, longitude: 0)
        candidates = await provider.gems(near: origin)
        if let coordinate = lastCoordinate { update(at: coordinate) }
    }

    public func update(at coordinate: Coordinate) {
        lastCoordinate = coordinate
        guard !isSuppressed else { visiblePins = []; return }
        visiblePins = engine.visiblePins(from: candidates, at: coordinate)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path AuraCore --filter GemDiscoveryStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift AuraCore/Tests/AuraKitTests/GemDiscoveryStoreTests.swift
git commit -m "feat(gems): GemDiscoveryStore publishes nearby pins, group-suppressible"
```

---

### Task 5: Coordinator forwards location fixes to a discovery sink (AuraKit)

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:66-104` (add param + forward in stream loop)
- Create: `AuraCore/Sources/AuraKit/RideSession/RideDiscoverySink.swift`
- Modify: `AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift` (conform to `RideDiscoverySink`)
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorDiscoveryTests.swift`

**Interfaces:**
- Consumes: `TrackPoint`, `LocationStreaming`, `RideSaving` (existing test doubles).
- Produces:
  - `@MainActor protocol RideDiscoverySink: AnyObject { func rideDidUpdateLocation(_ point: TrackPoint) }`
  - `start(...)` gains `discoverySink: (any RideDiscoverySink)? = nil` (appended after `groupSink`).
  - `GemDiscoveryStore: RideDiscoverySink` — `rideDidUpdateLocation` calls `update(at: point.coordinate)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AuraCore
@testable import AuraKit

@MainActor
@Suite struct RideSessionCoordinatorDiscoveryTests {
    final class SpySink: RideDiscoverySink {
        var coordinates: [Coordinate] = []
        func rideDidUpdateLocation(_ point: TrackPoint) { coordinates.append(point.coordinate) }
    }

    @Test func forwardsEachLocationFixToTheDiscoverySink() async {
        let point = TrackPoint(coordinate: Coordinate(latitude: 40.44, longitude: -80.0),
                               elevation: nil, timestamp: Date())
        let location = StubLocationStreaming(points: [point])   // existing test double
        let coordinator = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                                 screen: NoopScreenWake(), activity: NoopRideActivity())
        let sink = SpySink()
        coordinator.start(location: location, saving: NoopRideSaving(), units: .metric,
                          authorization: .authorized, discoverySink: sink)
        await coordinator.streamTask?.value
        #expect(sink.coordinates == [point.coordinate])
    }
}
```

> Reuse whatever existing AuraKit test doubles the `RideSessionCoordinator` tests already use for `LocationStreaming`/`RideSaving`/`ScreenWakeControlling`/`RideActivityControlling` (see `AuraCore/Tests/AuraKitTests/` for the exact names; substitute them for the placeholder `Stub…`/`Noop…` names above).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter RideSessionCoordinatorDiscoveryTests`
Expected: FAIL — `extra argument 'discoverySink'` / `cannot find 'RideDiscoverySink'`.

- [ ] **Step 3: Write minimal implementation**

Create `RideDiscoverySink.swift`:

```swift
import AuraCore

/// A per-ride observer of live location fixes, injected at `start()` (mirrors `GroupLocationSink`).
@MainActor
public protocol RideDiscoverySink: AnyObject {
    func rideDidUpdateLocation(_ point: TrackPoint)
}
```

In `RideSessionCoordinator.swift`: add a stored `private var discoverySink: (any RideDiscoverySink)?`, add the parameter to `start(...)` after `groupSink`:

```swift
                      groupSink: (any GroupLocationSink)? = nil,
                      discoverySink: (any RideDiscoverySink)? = nil) -> StartOutcome {
```

Stash it beside `groupSink` (`self.discoverySink = discoverySink`), and inside the stream loop after the `groupSink` call add:

```swift
                self.discoverySink?.rideDidUpdateLocation(point)
```

In `stopStreaming()`, add `discoverySink = nil` beside `groupSink = nil`.

In `GemDiscoveryStore.swift`, add conformance:

```swift
extension GemDiscoveryStore: RideDiscoverySink {
    public func rideDidUpdateLocation(_ point: TrackPoint) { update(at: point.coordinate) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter RideSessionCoordinatorDiscoveryTests`
Then the full package: `swift test --package-path AuraCore`
Expected: PASS (new test + no regressions).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/RideSession/ AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift AuraCore/Tests/AuraKitTests/RideSessionCoordinatorDiscoveryTests.swift
git commit -m "feat(gems): coordinator forwards location fixes to a discovery sink"
```

---

### Task 6: `GemPinView` + gem layer in `RideMapView` (app target)

**Files:**
- Create: `Aura/Sources/Ride/GemPinView.swift`
- Modify: `Aura/Sources/Ride/RideMapView.swift:10-63` (add `gems` param + gem annotation layer)

**Interfaces:**
- Consumes: `Gem`, `GemCategory` (AuraCore).
- Produces: `RideMapView` gains `var gems: [Gem] = []`; renders one `GemPinView` per gem.

- [ ] **Step 1: Add the `gems` parameter and layer to `RideMapView`**

Add the stored property beside the other `RideMapView` inputs (after `selfProgress`):

```swift
    var gems: [Gem] = []
```

Inside `body`'s `Map(viewport:)` builder, after the `ForEvery(peers…)` block, add:

```swift
            ForEvery(gems, id: \.id) { gem in
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(latitude: gem.coordinate.latitude,
                                                                     longitude: gem.coordinate.longitude)) {
                    GemPinView(gem: gem)
                }
                .allowOverlapWithPuck(true)
            }
```

- [ ] **Step 2: Create `GemPinView`**

```swift
import SwiftUI
import AuraCore

/// A single ambient gem pin on the ride map. Tier styling, seen-state, and tap
/// handling arrive in Plan 2; this slice is a plain category-glyph marker.
struct GemPinView: View {
    let gem: Gem

    var body: some View {
        Image(systemName: Self.symbol(for: gem.category))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AuraTheme.onAccent)
            .frame(width: 30, height: 30)
            .background(Circle().fill(AuraTheme.accent))
            .overlay(Circle().stroke(AuraTheme.background.opacity(0.6), lineWidth: 2))
            .accessibilityLabel(Text(gem.name))
    }

    private static func symbol(for category: GemCategory) -> String {
        switch category {
        case .viewpoint: return "mountain.2.fill"
        case .water: return "drop.fill"
        case .park: return "tree.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .mural: return "paintpalette.fill"
        case .climb: return "arrow.up.forward"
        case .historic: return "building.columns.fill"
        case .landmark: return "star.fill"
        }
    }
}
```

- [ ] **Step 3: Build the app to verify it compiles**

Delegate to the builder agent (apple-platform-build-tools:builder): "Build the Aura app scheme for the iPhone 17 simulator; report success or the first error."
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/GemPinView.swift Aura/Sources/Ride/RideMapView.swift
git commit -m "feat(gems): GemPinView + gem annotation layer in RideMapView"
```

---

### Task 7: Wire discovery into the free-ride HUD (app target)

**Files:**
- Modify: `Aura/Sources/Ride/RideHUDView.swift` (own a `GemDiscoveryStore`, load it, pass it as the coordinator's `discoverySink`, feed `RideMapView(gems:)`)

**Interfaces:**
- Consumes: `GemDiscoveryStore`, `CuratedGemProvider` (AuraKit); `RideMapView.gems` (Task 6); `RideSessionCoordinator.start(…, discoverySink:)` (Task 5).

- [ ] **Step 1: Own and load the store, wire it to the coordinator and map**

In `RideHUDView`, add the store as owned state:

```swift
    @State private var gems = GemDiscoveryStore(provider: CuratedGemProvider())
```

Where the view calls `coordinator.start(...)` (the auto-start on appear, ~line 60), pass the store as the discovery sink:

```swift
        coordinator.start(location: location, saving: rideStore, units: settings.units,
                          authorization: authorization, discoverySink: gems)
```

(Keep every existing argument exactly as-is; only add `discoverySink: gems`.)

Load the curated set once, on the same appear path:

```swift
        .task { await gems.load() }
```

Pass the visible pins to the map (the `RideMapView(...)` call in this view):

```swift
        RideMapView(track: coordinator.track, gems: gems.visiblePins, viewport: $viewport)
```

(Preserve the existing `RideMapView` arguments; add only `gems: gems.visiblePins`.)

- [ ] **Step 2: Build the app**

Delegate to the builder agent: "Build the Aura app scheme for the iPhone 17 simulator; report success or the first error."
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Smoke-check in the simulator**

Delegate to the builder agent: "Boot the iPhone 17 simulator, install and launch Aura, set the simulator location to 40.4419,-80.0089 (Point State Park, Pittsburgh), tap Explore to start a free ride, and report whether a gem pin renders on the map." (Curated seed gems are in Pittsburgh; without a Pittsburgh location none will be in range — set the sim location first.)
Expected: at least one gem pin visible near the rider.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(gems): free-ride HUD shows curated gem pins as you ride"
```

---

### Task 8: Suppress discovery during group rides (app target)

**Files:**
- Modify: `Aura/Sources/Ride/RideHUDView.swift` (set `gems.isSuppressed` when a group session is present)

**Interfaces:**
- Consumes: `GemDiscoveryStore.isSuppressed` (Task 4); the view's existing group-ride context (the same value that decides whether `groupSink` is passed to `start()`).

- [ ] **Step 1: Suppress when the ride is a group ride**

In `RideHUDView`, wherever the group session / group sink is known (the same condition that supplies `groupSink` to `coordinator.start`), set suppression before loading:

```swift
        gems.isSuppressed = (groupSink != nil)
```

Place this on the appear path, immediately before `coordinator.start(...)`. If this HUD never carries a group session (group rides use a separate surface), add the line anyway guarding the invariant — it is a cheap, correct no-op for the solo path and documents the gate.

- [ ] **Step 2: Build the app**

Delegate to the builder agent: "Build the Aura app scheme for the iPhone 17 simulator; report success or the first error."
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Full package test + lint gate**

Run: `swift test --package-path AuraCore`
Expected: PASS (all suites).
Delegate to the builder agent: "Run SwiftLint --strict on the repo and report any violations."
Expected: no violations.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(gems): suppress gem discovery during group rides"
```

---

## Self-review notes

- **Spec coverage (this slice):** ambient pins (§ Rhythm/ambient), proximity + nearest-N cap (§ Pacing, § engine), curated provider + bundled seed (§ Data), group-ride gating (§ Group rides), coordinator sink integration (§ Discovery store), timestamp-driven pure engine (§ Global Constraints). Deferred to Plans 2–4 and explicitly out of this slice: tiers/cards/haptics, detail sheet, seen-memory + `SeenGemRecord`/V4, the detour/`GuidanceController`, personal markers + `resurface`, the live feed, priority arbitration, full accessibility, backgrounding pause. These are named in the sequenced-plans list so no requirement is silently dropped.
- **Type consistency:** `GemDiscoveryEngine.visiblePins(from:at:)`, `GemProviding.gems(near:)`, `GemDiscoveryStore.update(at:)` / `.load()` / `.isSuppressed`, `RideDiscoverySink.rideDidUpdateLocation(_:)`, and `RideMapView.gems` are used identically across the tasks that define and consume them.
- **Placeholders:** none — every step carries real code or an exact command. The one deliberate substitution note (Task 5's existing test-double names) points the implementer at the real doubles rather than inventing new ones.
