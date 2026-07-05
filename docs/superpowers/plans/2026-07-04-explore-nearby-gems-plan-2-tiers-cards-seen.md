# Explore Nearby Gems — Plan 2: Tiers, peek cards, detail sheet, seen-memory

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the ambient gem pins from Plan 1 into a tiered active layer — a self-dismissing peek card (Tier 2) and a card+haptic (Tier 3) as you approach a gem, a tap-through detail sheet, seen-styled pins, and cross-ride memory so a gem peeks at most once ever.

**Architecture:** Extend the pure `GemDiscoveryEngine` with a timestamp-driven `decide(...)` that emits an optional active surfacing (approach radius + tier gate + cooldown + don't-repeat + seen-goes-quiet + highest-tier/nearest selection), threading a `DiscoveryState`. Persist the cross-ride seen set as a new `SeenGemRecord` SwiftData model (schema V4, lightweight migration) behind a `SeenGemStoring` seam. `GemDiscoveryStore` gains `now`-threaded updates, publishes `activeCard`/`selectedGem`/`seenIDs`, fires a `GemHapticPlaying` seam for Tier 3, and writes on surface. The app adds `GemPeekCard`, `GemDetailSheet`, tap+seen styling on `GemPinView`, wired in `RideHUDView`.

**Tech Stack:** Swift 6, SwiftUI, MapboxMaps v11, Swift Testing, SwiftData. AuraCore/AuraKit build + test on the macOS host.

**Spec:** `docs/superpowers/specs/2026-07-04-explore-nearby-gems-design.md`. **Builds on Plan 1** (merged to main `cbaad1c`): `Gem`/`GemTier`/`GemCategory`, `GemDiscoveryEngine.visiblePins`, `GemProviding`/`CuratedGemProvider`, `GemDiscoveryStore`, `RideDiscoverySink`, `GemPinView` + `RideMapView` gem layer.

**Sequenced plans (this is Plan 2 of 4):** 1 = gems on the map ✅ shipped (PR #71). **2 = tiers + peek cards + detail + seen-memory** (this doc). 3 = the detour (`GuidanceController`). 4 = personal "return here" + minimal live feed + priority arbitration + a11y.

## Global Constraints

- Swift 6 language mode, all targets; data-race safe. SwiftLint `--strict` is the CI gate.
- AuraCore/AuraKit compile + test on the **macOS host** — no unguarded iOS-only APIs (UIKit haptics live in the app target only).
- `GemDiscoveryEngine` stays **pure and timestamp-driven**: its "now" is the passed `Date` (the location sample's `timestamp`); no `Date()`/timers inside.
- **Only curated + personal gems reach Tier 3.** Personal + live are Plan 4, so Plan 2's tiers come from the curated seed's authored `tier` field. Live feed is NOT in this plan.
- **Tier 1 pins never actively surface** (no card, no haptic). Tier 2 → peek card. Tier 3 → peek card + haptic.
- **Seen-goes-quiet:** a gem that has actively surfaced (this ride or any prior ride) is pin-only thereafter. Persisted per `Gem.id`.
- `SeenGemRecord` honors the ROH-13 CloudKit-mirror invariants: every attribute has a default, no `.unique`, no relationships.
- Signature accent `AuraTheme.accent` (mint); dark surfaces from `AuraTheme`/`AuraPalette`. Sentence case in copy.
- Run all `git`/`swift test`/build commands from the repo root (`/Users/rohunjoseph/projects/biking-app/.claude/worktrees/friendly-proskuriakova-ccd923`).
- Package tests: `swift test --package-path AuraCore [--filter <Suite>]`. App builds are controller-run via the builder agent (implementers do not run xcodebuild or spawn subagents).

---

### Task 1: Active-surfacing decision in the engine (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Gems/DiscoveryState.swift`
- Modify: `AuraCore/Sources/AuraCore/Gems/GemDiscoveryEngine.swift`
- Test: `AuraCore/Tests/AuraCoreTests/GemDiscoveryDecisionTests.swift`

**Interfaces:**
- Consumes: `Gem`, `GemTier`, `Coordinate`, `Geo.distance`, existing `GemDiscoveryEngine.visiblePins(from:at:)`.
- Produces:
  - `struct DiscoveryState: Sendable { var surfacedThisRide: Set<String>; var lastActiveAt: Date?; let seenBefore: Set<String>; init(seenBefore: Set<String> = []) }`
  - `struct DiscoveryDecision: Sendable, Equatable { let visiblePins: [Gem]; let activeSurfacing: Gem? }`
  - `GemDiscoveryEngine.init(proximityRadiusMeters:pinCap:approachRadiusMeters:cooldownSeconds:)` (new defaulted params `approachRadiusMeters: Double = 250`, `cooldownSeconds: TimeInterval = 75`)
  - `func decide(from candidates: [Gem], at location: Coordinate, now: Date, state: inout DiscoveryState) -> DiscoveryDecision`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite struct GemDiscoveryDecisionTests {
    private let here = Coordinate(latitude: 40.4406, longitude: -79.9959)
    private func gem(_ id: String, _ lat: Double, tier: GemTier) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: lat, longitude: -79.9959),
            category: .park, tier: tier, source: .curated)
    }
    // ~ meters north of `here` per 0.0001 lat ≈ 11.1 m
    private func near(_ id: String, meters: Double, tier: GemTier) -> Gem {
        gem(id, 40.4406 + meters / 111_320.0, tier: tier)
    }
    private let engine = GemDiscoveryEngine(proximityRadiusMeters: 1500, pinCap: 10,
                                            approachRadiusMeters: 250, cooldownSeconds: 75)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func surfacesTier2WithinApproachRadius() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here, now: t0, state: &state)
        #expect(d.activeSurfacing?.id == "a")
        #expect(state.surfacedThisRide.contains("a"))
        #expect(state.lastActiveAt == t0)
    }

    @Test func tier1PinsNeverActivelySurface() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("p", meters: 50, tier: .pin)], at: here, now: t0, state: &state)
        #expect(d.activeSurfacing == nil)
        #expect(d.visiblePins.map(\.id) == ["p"]) // still a visible pin
    }

    @Test func respectsApproachRadius() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("far", meters: 800, tier: .cardHaptic)], at: here, now: t0, state: &state)
        #expect(d.activeSurfacing == nil)          // outside 250 m approach…
        #expect(d.visiblePins.map(\.id) == ["far"]) // …but inside 1500 m pin radius
    }

    @Test func cooldownBlocksASecondSurfacingTooSoon() {
        var state = DiscoveryState()
        _ = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here, now: t0, state: &state)
        let d = engine.decide(from: [near("b", meters: 120, tier: .card)], at: here,
                              now: t0.addingTimeInterval(30), state: &state)
        #expect(d.activeSurfacing == nil)           // 30 s < 75 s cooldown
        let later = engine.decide(from: [near("b", meters: 120, tier: .card)], at: here,
                                  now: t0.addingTimeInterval(80), state: &state)
        #expect(later.activeSurfacing?.id == "b")   // 80 s ≥ cooldown
    }

    @Test func doesNotRepeatWithinRideOrAcrossRides() {
        var seen = DiscoveryState(seenBefore: ["b"])
        let d1 = engine.decide(from: [near("b", meters: 100, tier: .card)], at: here, now: t0, state: &seen)
        #expect(d1.activeSurfacing == nil)          // seen on a prior ride → quiet
        var fresh = DiscoveryState()
        _ = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here, now: t0, state: &fresh)
        let again = engine.decide(from: [near("a", meters: 100, tier: .card)], at: here,
                                  now: t0.addingTimeInterval(200), state: &fresh)
        #expect(again.activeSurfacing == nil)       // already surfaced this ride
    }

    @Test func picksHighestTierThenNearest() {
        var state = DiscoveryState()
        let d = engine.decide(from: [near("card-close", meters: 40, tier: .card),
                                     near("haptic-far", meters: 200, tier: .cardHaptic),
                                     near("haptic-near", meters: 150, tier: .cardHaptic)],
                              at: here, now: t0, state: &state)
        #expect(d.activeSurfacing?.id == "haptic-near") // highest tier, nearest of that tier
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter GemDiscoveryDecisionTests`
Expected: FAIL — `cannot find 'DiscoveryState'` / `extra argument 'now'`.

- [ ] **Step 3: Write minimal implementation**

`DiscoveryState.swift`:

```swift
import Foundation

/// Mutable per-ride discovery memory + the immutable cross-ride seen set.
/// `seenBefore` is seeded from persistence at ride start and never mutates during the ride.
public struct DiscoveryState: Sendable {
    public var surfacedThisRide: Set<String>
    public var lastActiveAt: Date?
    public let seenBefore: Set<String>

    public init(seenBefore: Set<String> = []) {
        self.surfacedThisRide = []
        self.lastActiveAt = nil
        self.seenBefore = seenBefore
    }
}

/// What the engine decided for one location sample: the visible pins, and at most
/// one gem to actively surface (peek card / haptic) right now.
public struct DiscoveryDecision: Sendable, Equatable {
    public let visiblePins: [Gem]
    public let activeSurfacing: Gem?
    public init(visiblePins: [Gem], activeSurfacing: Gem?) {
        self.visiblePins = visiblePins
        self.activeSurfacing = activeSurfacing
    }
}
```

Replace `GemDiscoveryEngine.swift` with (keeps `visiblePins`, adds config + `decide`):

```swift
import Foundation

/// Pure, timestamp-driven discovery logic. `visiblePins` is the ambient layer;
/// `decide` adds the active layer (one tier-gated, cooldown-spaced peek at a time).
public struct GemDiscoveryEngine: Sendable {
    public let proximityRadiusMeters: Double
    public let pinCap: Int
    public let approachRadiusMeters: Double
    public let cooldownSeconds: TimeInterval

    public init(proximityRadiusMeters: Double = 1500, pinCap: Int = 10,
                approachRadiusMeters: Double = 250, cooldownSeconds: TimeInterval = 75) {
        self.proximityRadiusMeters = proximityRadiusMeters
        self.pinCap = pinCap
        self.approachRadiusMeters = approachRadiusMeters
        self.cooldownSeconds = cooldownSeconds
    }

    /// Gems within `proximityRadiusMeters` of `location`, nearest first, capped to `pinCap`.
    public func visiblePins(from candidates: [Gem], at location: Coordinate) -> [Gem] {
        candidates
            .map { ($0, Geo.distance($0.coordinate, location)) }
            .filter { $0.1 <= proximityRadiusMeters }
            .sorted { $0.1 < $1.1 }
            .prefix(pinCap)
            .map(\.0)
    }

    /// Visible pins plus, if one is earned, a single gem to actively surface. Mutates
    /// `state` (records the surfaced id + `now`) only when it returns a non-nil surfacing.
    public func decide(from candidates: [Gem], at location: Coordinate,
                       now: Date, state: inout DiscoveryState) -> DiscoveryDecision {
        let pins = visiblePins(from: candidates, at: location)

        if let last = state.lastActiveAt, now.timeIntervalSince(last) < cooldownSeconds {
            return DiscoveryDecision(visiblePins: pins, activeSurfacing: nil)
        }

        let eligible = candidates
            .filter { $0.tier >= .card }
            .filter { !state.seenBefore.contains($0.id) && !state.surfacedThisRide.contains($0.id) }
            .map { ($0, Geo.distance($0.coordinate, location)) }
            .filter { $0.1 <= approachRadiusMeters }

        // Highest tier wins; nearest breaks the tie.
        let picked = eligible.sorted {
            $0.0.tier != $1.0.tier ? $0.0.tier > $1.0.tier : $0.1 < $1.1
        }.first?.0

        if let gem = picked {
            state.surfacedThisRide.insert(gem.id)
            state.lastActiveAt = now
        }
        return DiscoveryDecision(visiblePins: pins, activeSurfacing: picked)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter GemDiscoveryDecisionTests` then `swift test --package-path AuraCore`
Expected: new suite passes; existing `GemDiscoveryEngineTests` still green (the `visiblePins` API is unchanged).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Gems/DiscoveryState.swift AuraCore/Sources/AuraCore/Gems/GemDiscoveryEngine.swift AuraCore/Tests/AuraCoreTests/GemDiscoveryDecisionTests.swift
git commit -m "feat(gems): engine active-surfacing decision (tier/approach/cooldown/seen)"
```

---

### Task 2: `SeenGemRecord` schema V4 + `SeenGemStoring` seam (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV4.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift` (point the container schema at V4)
- Create: `AuraCore/Sources/AuraKit/Gems/SeenGemStoring.swift`
- Create: `AuraCore/Sources/AuraKit/Gems/SeenGemStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/SeenGemStoreTests.swift`

**Interfaces:**
- Produces:
  - `RideSchemaV4` (VersionedSchema, version 4.0.0) with models `[RideSchemaV2.RideRecord, RideSchemaV3.SavedPlaceRecord, SeenGemRecord]`
  - `@Model SeenGemRecord { var gemID: String = ""; var firstSeenAt: Date = <sentinel> }`, `typealias SeenGemRecord = RideSchemaV4.SeenGemRecord`
  - `RideMigrationPlan.migrateV3toV4` (lightweight)
  - `@MainActor protocol SeenGemStoring { func seenGemIDs() -> Set<String>; func markSeen(_ gemID: String, at date: Date) }`
  - `@MainActor final class SeenGemStore: SeenGemStoring { init(container: ModelContainer) }`

> First **read** `RideSchemaV3.swift`, `RideMigrationPlan.swift`, and `RideStore.swift`. Follow the existing **V2→V3** pattern exactly: V3 added `SavedPlaceRecord` as a *lightweight* migration (`MigrationStage.lightweight`). V4 adds `SeenGemRecord` the same way. In `RideStore.swift`, whichever `Schema`/`VersionedSchema` the `ModelContainer` is currently built from must be updated to `RideSchemaV4` (and `RideMigrationPlan` already gets the new stage). Mirror `SavedPlacesStore.swift` for the store shape (it holds a `ModelContainer`, opens a `ModelContext`, fetches/inserts). Match the real APIs; if anything differs from this sketch, follow the file.

- [ ] **Step 1: Create the schema, migration, and seam**

`RideSchemaV4.swift`:

```swift
import Foundation
import SwiftData
import AuraCore

/// V4 adds `SeenGemRecord` beside the unchanged V2 `RideRecord` and V3 `SavedPlaceRecord`
/// — adding a model type is a lightweight migration. CloudKit rules hold: a default on every
/// attribute, no `.unique`, no relationships. The Date default is the fixed sentinel.
public enum RideSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideSchemaV2.RideRecord.self, RideSchemaV3.SavedPlaceRecord.self, SeenGemRecord.self]
    }

    @Model
    public final class SeenGemRecord {
        public var gemID: String = ""
        public var firstSeenAt: Date = Date(timeIntervalSince1970: 0)
        public init(gemID: String, firstSeenAt: Date) {
            self.gemID = gemID
            self.firstSeenAt = firstSeenAt
        }
    }
}

public typealias SeenGemRecord = RideSchemaV4.SeenGemRecord
```

In `RideMigrationPlan.swift`: add `RideSchemaV4.self` to the `schemas` array, append `migrateV3toV4` to `stages`, and define:

```swift
    /// Adding a model type is lightweight — no data transform.
    public static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: RideSchemaV3.self,
        toVersion: RideSchemaV4.self)
```

In `RideStore.swift`: change the `Schema(versionedSchema:)` / container construction that currently references `RideSchemaV3` to `RideSchemaV4` (keep `migrationPlan: RideMigrationPlan.self`).

`SeenGemStoring.swift`:

```swift
import Foundation

/// Cross-ride record of which gem ids have actively surfaced (peeked). Seeds the engine's
/// `seenBefore` and is written the moment a gem surfaces, so a mid-ride crash can't un-see it.
@MainActor
public protocol SeenGemStoring {
    func seenGemIDs() -> Set<String>
    func markSeen(_ gemID: String, at date: Date)
}
```

`SeenGemStore.swift`:

```swift
import Foundation
import SwiftData

/// SwiftData-backed `SeenGemStoring`. Mirrors `SavedPlacesStore`'s container/context shape.
@MainActor
public final class SeenGemStore: SeenGemStoring {
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    public func seenGemIDs() -> Set<String> {
        let records = (try? context.fetch(FetchDescriptor<SeenGemRecord>())) ?? []
        return Set(records.map(\.gemID))
    }

    public func markSeen(_ gemID: String, at date: Date) {
        guard !seenGemIDs().contains(gemID) else { return }
        context.insert(SeenGemRecord(gemID: gemID, firstSeenAt: date))
        try? context.save()
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import Foundation
import SwiftData
@testable import AuraKit

@MainActor
@Suite struct SeenGemStoreTests {
    private func inMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: SeenGemRecord.self, configurations: config)
    }

    @Test func marksAndReadsBackSeenIDs() throws {
        let store = SeenGemStore(container: try inMemoryContainer())
        #expect(store.seenGemIDs().isEmpty)
        store.markSeen("curated:grandview-overlook", at: Date(timeIntervalSince1970: 10))
        store.markSeen("curated:point-state-park", at: Date(timeIntervalSince1970: 20))
        #expect(store.seenGemIDs() == ["curated:grandview-overlook", "curated:point-state-park"])
    }

    @Test func markSeenIsIdempotent() throws {
        let store = SeenGemStore(container: try inMemoryContainer())
        store.markSeen("g", at: Date(timeIntervalSince1970: 1))
        store.markSeen("g", at: Date(timeIntervalSince1970: 2))
        #expect(store.seenGemIDs() == ["g"])
    }

    @Test func recordHasCloudKitSafeDefaults() {
        // ROH-13 invariant: a no-arg-constructible record with defaults, no .unique.
        let r = SeenGemRecord(gemID: "x", firstSeenAt: Date(timeIntervalSince1970: 0))
        #expect(r.gemID == "x")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path AuraCore --filter SeenGemStoreTests`
Expected: FAIL — `cannot find 'SeenGemStore'` / `SeenGemRecord`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter SeenGemStoreTests` then `swift test --package-path AuraCore`
Expected: new suite passes; existing persistence/migration suites still green (V3→V4 is additive/lightweight).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideSchemaV4.swift AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift AuraCore/Sources/AuraKit/Persistence/RideStore.swift AuraCore/Sources/AuraKit/Gems/SeenGemStoring.swift AuraCore/Sources/AuraKit/Gems/SeenGemStore.swift AuraCore/Tests/AuraKitTests/SeenGemStoreTests.swift
git commit -m "feat(gems): SeenGemRecord schema V4 + SeenGemStoring seam"
```

---

### Task 3: Extend `GemDiscoveryStore` — active card, haptic, seen-memory (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/GemHapticPlaying.swift`
- Modify: `AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift`
- Modify: `AuraCore/Tests/AuraKitTests/GemDiscoveryStoreTests.swift` (existing Plan-1 tests — update to the new init + `update(at:now:)`)
- Test: `AuraCore/Tests/AuraKitTests/GemDiscoveryStoreActiveTests.swift`

**Interfaces:**
- Consumes: `GemDiscoveryEngine.decide`, `DiscoveryState`, `SeenGemStoring` (Task 2), `GemProviding`, `TrackPoint`.
- Produces:
  - `@MainActor protocol GemHapticPlaying { func playGemSurfaced() }`
  - `GemDiscoveryStore.init(provider:engine:seen:haptics:)` — new required params `seen: any SeenGemStoring`, `haptics: any GemHapticPlaying`
  - published `activeCard: Gem?`, `selectedGem: Gem?`, `seenIDs: Set<String>`, `riderCoordinate: Coordinate?`
  - `func update(at coordinate: Coordinate, now: Date)` (replaces `update(at:)`)
  - `func dismissActiveCard()`, `func select(_ gem: Gem)`, `func clearSelection()`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite struct GemDiscoveryStoreActiveTests {
    private struct StubProvider: GemProviding {
        let gems: [Gem]
        func gems(near coordinate: Coordinate) async -> [Gem] { gems }
    }
    private final class InMemorySeen: SeenGemStoring {
        var ids: Set<String> = []
        func seenGemIDs() -> Set<String> { ids }
        func markSeen(_ gemID: String, at date: Date) { ids.insert(gemID) }
    }
    private final class SpyHaptics: GemHapticPlaying {
        var count = 0
        func playGemSurfaced() { count += 1 }
    }
    private let here = Coordinate(latitude: 40.4406, longitude: -79.9959)
    private func near(_ id: String, meters: Double, tier: GemTier) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: 40.4406 + meters / 111_320.0, longitude: -79.9959),
            category: .park, tier: tier, source: .curated)
    }

    @Test func surfacesCardAndFiresHapticForTier3() async {
        let haptics = SpyHaptics()
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("v", meters: 80, tier: .cardHaptic)]),
                                      seen: InMemorySeen(), haptics: haptics)
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(store.activeCard?.id == "v")
        #expect(haptics.count == 1)
    }

    @Test func tier2SurfacesCardWithoutHaptic() async {
        let haptics = SpyHaptics()
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("p", meters: 80, tier: .card)]),
                                      seen: InMemorySeen(), haptics: haptics)
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(store.activeCard?.id == "p")
        #expect(haptics.count == 0)
    }

    @Test func writesSeenOnSurface() async {
        let seen = InMemorySeen()
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("v", meters: 80, tier: .cardHaptic)]),
                                      seen: seen, haptics: SpyHaptics())
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(seen.ids.contains("v"))
    }

    @Test func seenBeforeSuppressesTheCard() async {
        let seen = InMemorySeen(); seen.ids = ["v"]
        let store = GemDiscoveryStore(provider: StubProvider(gems: [near("v", meters: 80, tier: .cardHaptic)]),
                                      seen: seen, haptics: SpyHaptics())
        await store.load()
        store.update(at: here, now: Date(timeIntervalSince1970: 100))
        #expect(store.activeCard == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path AuraCore --filter GemDiscoveryStoreActiveTests`
Expected: FAIL — `extra arguments 'seen', 'haptics'` / `cannot find 'GemHapticPlaying'`.

- [ ] **Step 3: Write the seam and rewrite the store**

`GemHapticPlaying.swift`:

```swift
import Foundation

/// A one-shot "a gem surfaced" haptic. App-target impl uses UIKit generators; tests spy on it.
@MainActor
public protocol GemHapticPlaying {
    func playGemSurfaced()
}
```

Rewrite `GemDiscoveryStore.swift`:

```swift
import Foundation
import Observation
import AuraCore

/// Holds the candidate gem set (loaded once) and, as the rider moves, republishes the ambient
/// pins plus the active layer: at most one self-dismissing peek card / haptic per approach.
/// Suppressed while a group ride is active. Solo by construction (see RideHUDView).
@MainActor
@Observable
public final class GemDiscoveryStore {
    public private(set) var visiblePins: [Gem] = []
    public private(set) var activeCard: Gem?
    public private(set) var seenIDs: Set<String> = []
    public private(set) var riderCoordinate: Coordinate?
    public var selectedGem: Gem?
    public var isSuppressed = false {
        didSet { if isSuppressed { visiblePins = []; activeCard = nil } }
    }

    private let provider: any GemProviding
    private let engine: GemDiscoveryEngine
    private let seen: any SeenGemStoring
    private let haptics: any GemHapticPlaying
    private var candidates: [Gem] = []
    private var state = DiscoveryState()

    public init(provider: any GemProviding, engine: GemDiscoveryEngine = .init(),
                seen: any SeenGemStoring, haptics: any GemHapticPlaying) {
        self.provider = provider
        self.engine = engine
        self.seen = seen
        self.haptics = haptics
    }

    public func load() async {
        // The (0,0) fallback origin is only safe because the curated provider ignores `near:`.
        // A coordinate-filtering provider (the future live feed) must defer load() until the
        // first fix has set `riderCoordinate`, or this queries gems near Null Island.
        let origin = riderCoordinate ?? Coordinate(latitude: 0, longitude: 0)
        candidates = await provider.gems(near: origin)
        seenIDs = seen.seenGemIDs()
        state = DiscoveryState(seenBefore: seenIDs)
        if let coordinate = riderCoordinate { update(at: coordinate, now: Date(timeIntervalSince1970: 0)) }
    }

    public func update(at coordinate: Coordinate, now: Date) {
        riderCoordinate = coordinate
        guard !isSuppressed else { visiblePins = []; activeCard = nil; return }
        let decision = engine.decide(from: candidates, at: coordinate, now: now, state: &state)
        visiblePins = decision.visiblePins
        if let gem = decision.activeSurfacing {
            activeCard = gem
            seenIDs.insert(gem.id)
            seen.markSeen(gem.id, at: now)
            if gem.tier == .cardHaptic { haptics.playGemSurfaced() }
        }
    }

    public func dismissActiveCard() { activeCard = nil }
    public func select(_ gem: Gem) { selectedGem = gem }
    public func clearSelection() { selectedGem = nil }
}

extension GemDiscoveryStore: RideDiscoverySink {
    public func rideDidUpdateLocation(_ point: TrackPoint) {
        update(at: point.coordinate, now: point.timestamp)
    }
}
```

Update the existing `GemDiscoveryStoreTests.swift`: pass the new deps and the `now:` arg. Add the same private `InMemorySeen`/`SpyHaptics` helpers (or a shared test helper file), construct with `seen: InMemorySeen(), haptics: SpyHaptics()`, and change `store.update(at: c)` calls to `store.update(at: c, now: Date(timeIntervalSince1970: 0))`. The Plan-1 assertions (`visiblePins`, suppression) stay valid.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path AuraCore --filter GemDiscoveryStore` then `swift test --package-path AuraCore`
Expected: both store suites pass; full package green (the `RideSessionCoordinatorDiscoveryTests` `SpySink` is unaffected — it doesn't call the store).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Gems/GemHapticPlaying.swift AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift AuraCore/Tests/AuraKitTests/GemDiscoveryStoreTests.swift AuraCore/Tests/AuraKitTests/GemDiscoveryStoreActiveTests.swift
git commit -m "feat(gems): store surfaces active card + Tier-3 haptic + writes seen"
```

---

### Task 4: `GemPeekCard` (app target)

**Files:**
- Create: `Aura/Sources/Ride/GemPeekCard.swift`
- Test: (UI — verified by the controller build in Task 7)

**Interfaces:**
- Consumes: `Gem`, `GemCategory` (and `GemPinView.symbol(for:)` — factor the SF-symbol map so both can use it; see below).
- Produces: `GemPeekCard(gem: Gem, distanceText: String, onTap: () -> Void, onDismiss: () -> Void)` — a self-dismissing card with a minimum visible floor of 6 seconds.

- [ ] **Step 1: Create the card**

Factor the category→SF-symbol map out of `GemPinView` so it isn't duplicated. In `GemPinView.swift`, change `private static func symbol` to `static func symbol` (internal), so `GemPeekCard` can call `GemPinView.symbol(for:)`.

```swift
import SwiftUI
import AuraCore

/// A soft, self-dismissing peek that rises for a Tier-2/3 gem. The pin remains on the map
/// as the durable object; this card is a shortcut. Visible for at least `minVisible` seconds
/// so a rider can reach it, then recedes on its own. Tapping it opens the detail sheet.
struct GemPeekCard: View {
    let gem: Gem
    let distanceText: String
    let onTap: () -> Void
    let onDismiss: () -> Void

    private let minVisible: Duration = .seconds(6)
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: GemPinView.symbol(for: gem.category))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AuraTheme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AuraTheme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(gem.name).font(.headline).foregroundStyle(AuraTheme.textPrimary)
                    Text(distanceText).font(.subheadline).foregroundStyle(AuraTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18).fill(AuraTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AuraTheme.hairline(), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(gem.name), \(distanceText)"))
        .accessibilityHint(Text("Opens details"))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: gem.id) {
            dismissTask?.cancel()
            try? await Task.sleep(for: minVisible)
            if !Task.isCancelled { onDismiss() }
        }
    }
}
```

> If `AuraTheme.hairline()` / `AuraTheme.surface` / `AuraTheme.textPrimary` have slightly different names, match the real `AuraTheme` (read `Aura/Sources/Theme/AuraTheme.swift`). Use the existing tokens; introduce none.

- [ ] **Step 2: Commit**

```bash
git add Aura/Sources/Ride/GemPeekCard.swift Aura/Sources/Ride/GemPinView.swift
git commit -m "feat(gems): self-dismissing GemPeekCard"
```

---

### Task 5: `GemDetailSheet` (app target)

**Files:**
- Create: `Aura/Sources/Ride/GemDetailSheet.swift`

**Interfaces:**
- Consumes: `Gem`, `GemCategory`, `GemPinView.symbol(for:)`.
- Produces: `GemDetailSheet(gem: Gem, distanceText: String)` — name, category, distance, a photo if `gem.photoAsset` resolves, and the `why` line. **No "Take me there" button** — that CTA and the detour arrive in Plan 3.

- [ ] **Step 1: Create the sheet**

```swift
import SwiftUI
import AuraCore

/// The expanded view for a gem, opened by tapping its pin or peek card. Info only in Plan 2;
/// the "Take me there" CTA + the guided detour land in Plan 3.
struct GemDetailSheet: View {
    let gem: Gem
    let distanceText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: GemPinView.symbol(for: gem.category))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AuraTheme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(AuraTheme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(gem.name).font(.title3.weight(.semibold)).foregroundStyle(AuraTheme.textPrimary)
                    Text("\(gem.category.rawValue.capitalized) · \(distanceText)")
                        .font(.subheadline).foregroundStyle(AuraTheme.textSecondary)
                }
            }
            if let asset = gem.photoAsset, UIImage(named: asset) != nil {
                Image(asset).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if let why = gem.why {
                Text(why).font(.body).foregroundStyle(AuraTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Aura/Sources/Ride/GemDetailSheet.swift
git commit -m "feat(gems): GemDetailSheet (info view, no CTA yet)"
```

---

### Task 6: Tappable + seen-styled pins (app target)

**Files:**
- Modify: `Aura/Sources/Ride/GemPinView.swift` (add `isSeen` styling + tap)
- Modify: `Aura/Sources/Ride/RideMapView.swift` (pass `seenIDs` + an `onSelectGem` closure into the gem layer)

**Interfaces:**
- Consumes: `Gem`, `GemDiscoveryStore.seenIDs`.
- Produces: `GemPinView(gem: Gem, isSeen: Bool, onTap: () -> Void)`; `RideMapView` gains `var seenGemIDs: Set<String> = []` and `var onSelectGem: (Gem) -> Void = { _ in }`.

- [ ] **Step 1: Add seen styling + tap to `GemPinView`**

```swift
struct GemPinView: View {
    let gem: Gem
    var isSeen: Bool = false
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            Image(systemName: GemPinView.symbol(for: gem.category))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSeen ? AuraTheme.accent : AuraTheme.onAccent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isSeen ? AuraTheme.surface : AuraTheme.accent))
                .overlay(Circle().stroke(isSeen ? AuraTheme.accent.opacity(0.6)
                                                : AuraTheme.background.opacity(0.6),
                                         lineWidth: isSeen ? 1.5 : 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(gem.name))
        .accessibilityHint(Text("Opens details"))
    }

    static func symbol(for category: GemCategory) -> String { /* unchanged switch from Plan 1 */ }
}
```

(Keep the existing `symbol(for:)` switch body exactly; only its visibility changed to `static` in Task 4.)

- [ ] **Step 2: Wire the map layer**

In `RideMapView.swift` add the inputs beside `gems`:

```swift
    var seenGemIDs: Set<String> = []
    var onSelectGem: (Gem) -> Void = { _ in }
```

and in the gem `ForEvery` block, build the pin with the new args:

```swift
            ForEvery(gems, id: \.id) { gem in
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(latitude: gem.coordinate.latitude,
                                                                     longitude: gem.coordinate.longitude)) {
                    GemPinView(gem: gem, isSeen: seenGemIDs.contains(gem.id)) { onSelectGem(gem) }
                }
                .allowOverlapWithPuck(true)
            }
```

- [ ] **Step 3: Build (controller)**

Delegate to the builder agent: "Build the Aura scheme for the iPhone 17 simulator; report BUILD SUCCEEDED or the first error." (Note: the app won't fully wire until Task 7 — but `GemPinView`/`RideMapView`/`GemPeekCard`/`GemDetailSheet` must compile.)

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/GemPinView.swift Aura/Sources/Ride/RideMapView.swift
git commit -m "feat(gems): tappable + seen-styled gem pins"
```

---

### Task 7: Wire the active layer into `RideHUDView` (app target)

**Files:**
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

**Interfaces:**
- Consumes: `GemDiscoveryStore` (new init `provider:seen:haptics:`), `SeenGemStore`, `GemHapticPlayer` (below), `GemPeekCard`, `GemDetailSheet`, `RideMapView(seenGemIDs:onSelectGem:)`.
- Produces: `GemHapticPlayer: GemHapticPlaying` (app target, UIKit generator).

- [ ] **Step 1: Create the app-target haptic player**

Create `Aura/Sources/Ride/GemHapticPlayer.swift`:

```swift
import UIKit
import AuraKit

/// UIKit-backed `GemHapticPlaying` — a soft impact when a gem surfaces.
@MainActor
final class GemHapticPlayer: GemHapticPlaying {
    private let generator = UIImpactFeedbackGenerator(style: .soft)
    func playGemSurfaced() { generator.impactOccurred() }
}
```

- [ ] **Step 2: Wire the store + card + sheet in `RideHUDView`**

Replace the Plan-1 `gems` store declaration (the commented `@State private var gems = GemDiscoveryStore(provider: CuratedGemProvider())`) with the new init, seeding the `SeenGemStore` from the app's `RideStore` container (read the file for how `rideStore`/its `container` is referenced):

```swift
        // Free rides are solo by construction — group rides use NavigateHUDView +
        // GroupRideSession, never this HUD — so gem discovery is never suppressed here.
        @State private var gems = GemDiscoveryStore(
            provider: CuratedGemProvider(),
            seen: SeenGemStore(container: RideStore.shared.container), // match the real RideStore accessor
            haptics: GemHapticPlayer())
```

> `RideStore.shared.container` is a sketch — use the actual `ModelContainer` the app already builds (the same one `RideHUDView` passes to `coordinator.start(saving:)`). If `rideStore` is injected via `@Environment`, construct the `SeenGemStore` in `.task`/`onAppear` instead and hold it in `@State`. Match the file; do not introduce a second container.

Pass seen + selection into the map (extend the Task-1-of-Plan-1 `RideMapView(...)` call):

```swift
        RideMapView(track: coordinator.track, gems: gems.visiblePins,
                    seenGemIDs: gems.seenIDs, onSelectGem: { gems.select($0) },
                    viewport: $viewport)
```

Overlay the peek card near the bottom (above the cockpit), driven by `gems.activeCard`:

```swift
        .overlay(alignment: .bottom) {
            if let gem = gems.activeCard {
                GemPeekCard(gem: gem, distanceText: gems.distanceText(to: gem),
                            onTap: { gems.select(gem); gems.dismissActiveCard() },
                            onDismiss: { gems.dismissActiveCard() })
                    .padding(.horizontal, 12).padding(.bottom, 120)
            }
        }
        .animation(.snappy, value: gems.activeCard?.id)
        .sheet(item: $gems.selectedGem) { gem in
            GemDetailSheet(gem: gem, distanceText: gems.distanceText(to: gem))
        }
```

Add a small distance formatter to `GemDiscoveryStore` (AuraKit) so both the card and sheet share it — append to the store:

```swift
    /// Distance from the rider to a gem, formatted (e.g. "0.4 mi" / "650 m"). Empty if no fix yet.
    public func distanceText(to gem: Gem) -> String {
        guard let here = riderCoordinate else { return "" }
        let meters = Geo.distance(gem.coordinate, here)
        return MetersFormatter.short(meters) // reuse the app's existing distance formatter
    }
```

> `MetersFormatter.short` is a sketch — reuse whatever distance formatter Aura already uses in the cockpit/summary (grep for the mi/km formatting; e.g. `RideStatsFormatter`). If it lives in the app target, compute the string in `RideHUDView` and pass it in instead of adding `distanceText` to the store. Match reality; add no new formatting logic if one exists.

The `.freeRide` auto-start already forwards fixes to `gems` (Plan 1's `discoverySink: gems`), and the store now threads `point.timestamp` as `now` — so no change to `coordinator.start(...)` is needed.

- [ ] **Step 3: Build + on-device smoke (controller)**

Delegate to the builder agent: "Build the Aura scheme for iPhone 17; then boot the sim, set location to 40.4419,-80.0089, start an Explore free ride, and report: (a) does a gem pin render, (b) as the rider nears a curated gem does a peek card rise from the bottom, (c) does tapping a pin or card open the detail sheet. Use the accessibility tree to confirm the card + sheet." (Sim can't prove the Tier-3 haptic — that's a device-verify item.)

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/GemHapticPlayer.swift AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift
git commit -m "feat(gems): peek card + detail sheet + seen pins wired into the free-ride HUD"
```

---

## Self-review notes

- **Spec coverage (this slice):** tiered surfacing pin/card/card+haptic (§ The experience), one-at-a-time + cooldown + don't-repeat + seen-goes-quiet (§ Rhythm, § Pacing — engine `decide`), persistent tappable pins + card min-floor (§ engage, Task 4/6), seen-state pin styling (§ Memory, Task 6), cross-ride seen persistence via `SeenGemRecord`/V4 (§ Persistence, Task 2), Tier-3 haptic via a seam (Task 3/7), detail sheet (§ engage — info only; the "Take me there" CTA + detour are explicitly Plan 3). Deferred here and named in the plan list: the detour (Plan 3), personal markers + live feed + priority arbitration + full a11y audit + per-category arrival radii wiring (Plan 3/4).
- **Type consistency:** `DiscoveryState`/`DiscoveryDecision`, `decide(from:at:now:state:)`, `SeenGemStoring.seenGemIDs()/markSeen(_:at:)`, `GemHapticPlaying.playGemSurfaced()`, `GemDiscoveryStore.init(provider:engine:seen:haptics:)` + `update(at:now:)` + `activeCard`/`selectedGem`/`seenIDs`/`riderCoordinate`/`dismissActiveCard()`/`select(_:)`, `GemPinView(gem:isSeen:onTap:)` + `static symbol(for:)`, `GemPeekCard(gem:distanceText:onTap:onDismiss:)`, `GemDetailSheet(gem:distanceText:)`, `RideMapView.seenGemIDs`/`onSelectGem` are used identically across the tasks that define and consume them.
- **Persistence risk called out:** Task 2's V3→V4 container-schema update in `RideStore.swift` is the one integration edit that isn't fully code-shown (the file wasn't read while authoring) — the task instructs reading it and following the V2→V3 lightweight pattern verbatim. Flag for the adversarial plan review + the implementer.
- **Known deferrable minors carried from Plan 1** (roll-up, address when touched): drop the unused `import Foundation` in the engine (Task 1 touches that file — drop it there); `.climb` glyph is generic; `arrivalRadiusMeters` values want a product look before Plan 3 wires arrival detection.
