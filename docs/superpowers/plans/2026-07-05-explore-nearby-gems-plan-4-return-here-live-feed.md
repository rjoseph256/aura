# Explore Nearby Gems — Plan 4 (return-here + live feed + arbitration + a11y) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the final slice of nearby-gem discovery: personal "return here" gems, a minimal OSM live feed, cross-source priority arbitration, and the deferred accessibility + Plan-3 minors.

**Architecture:** Pure logic lands in AuraCore (arbitration sort key, OSM→category mapping); provider/store/persistence seams in AuraKit (personal + live + composite providers, region cache, schema V5, `load()` deferral); UIKit/CoreLocation/SwiftUI concretes in the app target (mark-this-spot control + reverse-geocode, source-differentiated pins, a11y). Everything testable is timestamp-/clock-injected and driven by Swift Testing; app-target UI is build-verified then device-verified.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, SwiftData (+ CloudKit mirror), SwiftUI, CoreLocation (`CLGeocoder`, app target only), URLSession (OSM Overpass), Mapbox (app target only, unchanged here).

## Global Constraints

- **Swift 6 strict concurrency**, all targets. `GemDiscoveryStore` / `SavedPlacesStore` / `SeenGemStore` are `@MainActor @Observable`. Providers are `async` and `Sendable`. The engine is a pure `Sendable` struct.
- **The package (AuraCore + AuraKit) builds on a macOS host in CI.** No iOS-only API (`CLGeocoder`, `UIImpactFeedbackGenerator`, Mapbox SDK) may appear in AuraCore/AuraKit unguarded — those live in the app target. New AuraKit providers use only Foundation `URLSession` + SwiftData.
- **Timestamp-driven, never wall-clock in pure/logic paths.** The engine's and store's "now" is the location sample's timestamp; caches/timeouts take an injected clock or closure. No `Date()`, no `Task.sleep` as a test barrier.
- **ROH-13 CloudKit invariants** on every persisted attribute: a default present, no `.unique`, no relationships. Machine-checked by `SchemaInvariantTests`.
- **`Gem.id` is stable + source-namespaced:** `curated:<slug>` / `personal:<uuid>` / `osm:<type>/<id>`. Seen-matching and dedupe depend on stability.
- **Reuse `Geo.distance(_:_:)`** (`AuraCore/Sources/AuraCore/Geo/Coordinate.swift`) — never reimplement haversine.
- **Live gems never exceed Tier 2** (`min(category.defaultTier, .card)`); only curated + personal reach Tier 3.
- **OSM attribution:** any surfaced live gem carries an OpenStreetMap source label (ODbL requirement).
- Commit after every green step. App-target build/run is executed by the controller via the builder agent, never by the implementer.

---

## File Structure

**AuraCore (pure):**
- Modify `Sources/AuraCore/Gems/Gem.swift` — add `GemSource.priorityRank`.
- Modify `Sources/AuraCore/Gems/GemDiscoveryEngine.swift` — arbitration sort key.
- Create `Sources/AuraCore/Gems/OSMGemMapping.swift` — pure OSM tag → `GemCategory` / `Gem`.
- Modify `Sources/AuraCore/Models/SavedPlace.swift` — `resurface` field.
- Modify `Sources/AuraCore/Models/SavedPlacesLogic.swift` — carry `resurface`, `setResurface`, reconcile-OR.

**AuraKit (seams + persistence + providers):**
- Create `Sources/AuraKit/Persistence/RideSchemaV5.swift` — redeclared `SavedPlaceRecord` + `resurface`.
- Modify `Sources/AuraKit/Persistence/RideSchemaV3.swift` — move the `SavedPlaceRecord` typealias out.
- Modify `Sources/AuraKit/Persistence/RideMigrationPlan.swift` — V5 + `migrateV4toV5`.
- Modify `Sources/AuraKit/Persistence/SavedPlacesStore.swift` — `save(resurface:)`, `setResurface`, map `resurface`, `updateName(id:to:ifCurrentlyNamed:)`, conform `ResurfacePlacesReading`.
- Create `Sources/AuraKit/Gems/ResurfacePlacesReading.swift` — the seam.
- Create `Sources/AuraKit/Gems/PersonalGemProvider.swift`.
- Create `Sources/AuraKit/Gems/OSMOverpass.swift` — Overpass request builder + response decode (pure-ish, `URLSession`-injected).
- Create `Sources/AuraKit/Gems/LiveGemProvider.swift`.
- Create `Sources/AuraKit/Gems/GemRegionCache.swift` — `actor`.
- Create `Sources/AuraKit/Gems/CompositeGemProvider.swift`.
- Modify `Sources/AuraKit/Gems/GemDiscoveryStore.swift` — `load()` deferral, timestamp clock, `detourActive` snapshot.
- Modify `Sources/AuraKit/Gems/SeenGemStore.swift` — cache the id set, log on failure.
- Modify `Sources/AuraKit/Gems/Detour/GuidanceController.swift` — `cacheKey` cos(lat).

**App target (UI / iOS-only):**
- Modify `Aura/Sources/Ride/ControlCluster.swift` — mark-this-spot button.
- Modify `Aura/Sources/Ride/RideHUDView.swift` — wire mark-spot + geocode + toast/undo + store clock.
- Create `Aura/Sources/Ride/MarkSpotToast.swift` — confirmation + Undo.
- Create `Aura/Sources/Ride/ReverseGeocoder.swift` — `CLGeocoder` wrapper (app target).
- Modify `Aura/Sources/Ride/GemDetailSheet.swift` — "Save to return".
- Modify `Aura/Sources/Ride/GemPinView.swift` + `GemPeekCard.swift` — source styling, a11y, reduceMotion, OSM label.
- Modify `Aura/Sources/Plan/SavedPlaceRow.swift` — resurface indicator + "Stop returning here" menu.

**Tests:** alongside existing suites in `AuraCore/Tests/AuraCoreTests/` and `AuraCore/Tests/AuraKitTests/`.

---

## Phase A — Pure core (AuraCore)

### Task A1: `GemSource.priorityRank`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Gems/Gem.swift:8`
- Test: `AuraCore/Tests/AuraCoreTests/GemSourceTests.swift` (create)

**Interfaces:**
- Produces: `GemSource.priorityRank: Int` — `personal → 0`, `curated → 1`, `live → 2` (lower = higher priority). Consumed by A2 (engine) and C6 (composite dedupe).

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("GemSource priority")
struct GemSourceTests {
    @Test func personalOutranksCuratedOutranksLive() {
        #expect(GemSource.personal.priorityRank < GemSource.curated.priorityRank)
        #expect(GemSource.curated.priorityRank < GemSource.live.priorityRank)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GemSourceTests`
Expected: FAIL — `value of type 'GemSource' has no member 'priorityRank'`.

- [ ] **Step 3: Implement**

In `Gem.swift`, replace the `GemSource` line with:
```swift
public enum GemSource: String, Codable, Sendable {
    case curated, personal, live

    /// Cross-source arbitration order: personal (your own) beats curated beats live.
    /// Lower is higher priority. Used by the engine's surfacing pick and composite dedupe.
    public var priorityRank: Int {
        switch self {
        case .personal: return 0
        case .curated: return 1
        case .live: return 2
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter GemSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/Gems/Gem.swift AuraCore/Tests/AuraCoreTests/GemSourceTests.swift
git commit -m "feat(gems): GemSource.priorityRank for cross-source arbitration (ROH-60)"
```

---

### Task A2: Source-priority arbitration in `decide`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Gems/GemDiscoveryEngine.swift:45-48`
- Test: `AuraCore/Tests/AuraCoreTests/GemDiscoveryEngineArbitrationTests.swift` (create)

**Interfaces:**
- Consumes: `GemSource.priorityRank` (A1).
- Produces: `decide` now picks by `(source.priorityRank ↑, tier ↓, distance ↑)`. No signature change.

- [ ] **Step 1: Write the failing test** (a farther personal-T3 must beat a nearer curated-T3; and the shipped tier/distance behavior is preserved)
```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("Engine cross-source arbitration")
struct GemDiscoveryEngineArbitrationTests {
    private let origin = Coordinate(latitude: 40.44, longitude: -79.99)
    private func at(_ meters: Double) -> Coordinate {
        Coordinate(latitude: origin.latitude + meters / 111_320.0, longitude: origin.longitude)
    }
    private func gem(_ id: String, _ source: GemSource, _ tier: GemTier, _ c: Coordinate) -> Gem {
        Gem(id: id, name: id, coordinate: c, category: .viewpoint, tier: tier, source: source)
    }

    @Test func fartherPersonalT3BeatsNearerCuratedT3() {
        let engine = GemDiscoveryEngine()
        var state = DiscoveryState()
        let candidates = [
            gem("curated:a", .curated, .cardHaptic, at(50)),
            gem("personal:b", .personal, .cardHaptic, at(200)),
        ]
        let decision = engine.decide(from: candidates, at: origin, now: Date(timeIntervalSince1970: 1000), state: &state)
        #expect(decision.activeSurfacing?.id == "personal:b")
    }

    @Test func higherTierStillWinsAcrossSources() {
        let engine = GemDiscoveryEngine()
        var state = DiscoveryState()
        // curated T3 vs live T2 → curated (higher tier and higher source rank both agree)
        let candidates = [
            gem("live:x", .live, .card, at(30)),
            gem("curated:y", .curated, .cardHaptic, at(120)),
        ]
        let decision = engine.decide(from: candidates, at: origin, now: Date(timeIntervalSince1970: 1000), state: &state)
        #expect(decision.activeSurfacing?.id == "curated:y")
    }

    @Test func sameSourceSameTierBreaksByNearest() {
        let engine = GemDiscoveryEngine()
        var state = DiscoveryState()
        let candidates = [
            gem("curated:far", .curated, .card, at(200)),
            gem("curated:near", .curated, .card, at(40)),
        ]
        let decision = engine.decide(from: candidates, at: origin, now: Date(timeIntervalSince1970: 1000), state: &state)
        #expect(decision.activeSurfacing?.id == "curated:near")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GemDiscoveryEngineArbitrationTests`
Expected: FAIL — `fartherPersonalT3BeatsNearerCuratedT3` picks `curated:a` (current tier-then-nearest).

- [ ] **Step 3: Implement** — replace the pick block (lines 45-48):
```swift
        // Cross-source arbitration: personal > curated > live (source rank),
        // then highest tier, then nearest. Makes a personal-T3 beat a curated-T3
        // deterministically instead of falling through to distance.
        let picked = eligible.sorted { lhs, rhs in
            let lr = lhs.0.source.priorityRank, rr = rhs.0.source.priorityRank
            if lr != rr { return lr < rr }
            if lhs.0.tier != rhs.0.tier { return lhs.0.tier > rhs.0.tier }
            return lhs.1 < rhs.1
        }.first?.0
```

- [ ] **Step 4: Run to verify it passes** (and no regression)

Run: `swift test --package-path AuraCore --filter GemDiscoveryEngine`
Expected: PASS (arbitration suite + the existing engine suite).

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/Gems/GemDiscoveryEngine.swift AuraCore/Tests/AuraCoreTests/GemDiscoveryEngineArbitrationTests.swift
git commit -m "feat(gems): source-priority arbitration in decide (ROH-60)"
```

---

### Task A3: `OSMGemMapping` — pure OSM tag → gem

**Files:**
- Create: `AuraCore/Sources/AuraCore/Gems/OSMGemMapping.swift`
- Test: `AuraCore/Tests/AuraCoreTests/OSMGemMappingTests.swift`

**Interfaces:**
- Produces:
  - `OSMGemMapping.category(for tags: [String: String]) -> GemCategory?` — maps OSM tags to a category, `nil` if unmapped.
  - `OSMGemMapping.gem(id: String, name: String?, coordinate: Coordinate, tags: [String: String]) -> Gem?` — builds a `.live` gem with `tier = min(category.defaultTier, .card)`, `name` defaulting to the category's display noun when absent; `nil` when the category is unmapped. Consumed by C4 (`LiveGemProvider`).

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("OSM gem mapping")
struct OSMGemMappingTests {
    private let c = Coordinate(latitude: 40.44, longitude: -79.99)

    @Test func mapsKnownTagsToCategories() {
        #expect(OSMGemMapping.category(for: ["tourism": "viewpoint"]) == .viewpoint)
        #expect(OSMGemMapping.category(for: ["amenity": "drinking_water"]) == .water)
        #expect(OSMGemMapping.category(for: ["natural": "spring"]) == .water)
        #expect(OSMGemMapping.category(for: ["leisure": "park"]) == .park)
        #expect(OSMGemMapping.category(for: ["amenity": "cafe"]) == .cafe)
        #expect(OSMGemMapping.category(for: ["tourism": "artwork"]) == .mural)
        #expect(OSMGemMapping.category(for: ["historic": "monument"]) == .historic)
        #expect(OSMGemMapping.category(for: ["tourism": "attraction"]) == .landmark)
    }

    @Test func unmappedTagsReturnNil() {
        #expect(OSMGemMapping.category(for: ["shop": "supermarket"]) == nil)
        #expect(OSMGemMapping.category(for: [:]) == nil)
        #expect(OSMGemMapping.gem(id: "osm:node/1", name: "Foo", coordinate: c, tags: ["shop": "supermarket"]) == nil)
    }

    @Test func liveGemNeverExceedsTierCard() {
        // viewpoint defaults to .cardHaptic (T3) but live must cap at .card (T2).
        let g = OSMGemMapping.gem(id: "osm:node/2", name: "Grandview", coordinate: c, tags: ["tourism": "viewpoint"])
        #expect(g?.tier == .card)
        #expect(g?.source == .live)
        #expect(g?.photoAsset == nil)
    }

    @Test func namelessGemFallsBackToCategoryNoun() {
        let g = OSMGemMapping.gem(id: "osm:node/3", name: nil, coordinate: c, tags: ["amenity": "cafe"])
        #expect(g?.name == "Café")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter OSMGemMappingTests`
Expected: FAIL — no such type `OSMGemMapping`.

- [ ] **Step 3: Implement**
```swift
import Foundation

/// Pure OSM-tag → gem mapping for the live feed. No networking: `LiveGemProvider`
/// parses Overpass JSON and calls these. Unmapped tags are dropped (nil), never surfaced.
public enum OSMGemMapping {
    /// First matching rule wins. Kept deliberately small — scenic/outdoor gems, not commerce.
    public static func category(for tags: [String: String]) -> GemCategory? {
        if tags["tourism"] == "viewpoint" { return .viewpoint }
        if tags["amenity"] == "drinking_water" || tags["natural"] == "spring" { return .water }
        if tags["leisure"] == "park" { return .park }
        if tags["amenity"] == "cafe" { return .cafe }
        if tags["tourism"] == "artwork" { return .mural }
        if tags["historic"] != nil { return .historic }
        if tags["tourism"] == "attraction" { return .landmark }
        return nil
    }

    /// Display noun when an element has no `name` tag.
    private static func noun(_ category: GemCategory) -> String {
        switch category {
        case .viewpoint: return "Viewpoint"
        case .water: return "Water"
        case .park: return "Park"
        case .cafe: return "Café"
        case .mural: return "Mural"
        case .climb: return "Climb"
        case .historic: return "Historic site"
        case .landmark: return "Landmark"
        }
    }

    public static func gem(id: String, name: String?, coordinate: Coordinate,
                           tags: [String: String]) -> Gem? {
        guard let category = category(for: tags) else { return nil }
        let tier: GemTier = min(category.defaultTier, .card)   // live caps at Tier 2
        return Gem(id: id, name: name ?? noun(category), coordinate: coordinate,
                   category: category, tier: tier, source: .live, photoAsset: nil, why: nil)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter OSMGemMappingTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/Gems/OSMGemMapping.swift AuraCore/Tests/AuraCoreTests/OSMGemMappingTests.swift
git commit -m "feat(gems): pure OSM tag→gem mapping, live tier capped at card (ROH-60)"
```

---

### Task A4: `SavedPlace.resurface` + logic carry-through

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Models/SavedPlace.swift`
- Modify: `AuraCore/Sources/AuraCore/Models/SavedPlacesLogic.swift`
- Test: `AuraCore/Tests/AuraCoreTests/SavedPlacesResurfaceTests.swift`

**Interfaces:**
- Produces:
  - `SavedPlace.resurface: Bool` (new stored property; default `false` in both inits).
  - `SavedPlacesLogic.setResurface(id:_ on:in:) -> [SavedPlace]`.
  - `reconciled` now preserves `resurface == true` if **either** duplicate is flagged.
  - `add(...)` keeps an existing place's `resurface` on re-save; a re-save that requests resurface sets it true.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlace resurface")
struct SavedPlacesResurfaceTests {
    private func place(_ id: UUID, _ lat: Double, resurface: Bool, _ saved: TimeInterval) -> SavedPlace {
        SavedPlace(id: id, name: "P", subtitle: nil,
                   coordinate: Coordinate(latitude: lat, longitude: -79.99),
                   category: .custom, kind: .favorite, savedAt: Date(timeIntervalSince1970: saved),
                   resurface: resurface)
    }

    @Test func defaultsFalse() {
        let p = SavedPlace(name: "P", subtitle: nil,
                           coordinate: Coordinate(latitude: 1, longitude: 2),
                           category: .custom, kind: .favorite, savedAt: .init(timeIntervalSince1970: 0))
        #expect(p.resurface == false)
    }

    @Test func setResurfaceTogglesById() {
        let id = UUID()
        let list = [place(id, 40.0, resurface: false, 1)]
        let on = SavedPlacesLogic.setResurface(id: id, true, in: list)
        #expect(on.first?.resurface == true)
        let off = SavedPlacesLogic.setResurface(id: id, false, in: on)
        #expect(off.first?.resurface == false)
    }

    @Test func reconcileKeepsResurfaceIfEitherDuplicateFlagged() {
        let id = UUID()
        // Same id, the NEWER save has resurface=false, but an older flagged one must not silently demote it.
        let list = [place(id, 40.0, resurface: true, 1), place(id, 40.0, resurface: false, 2)]
        let out = SavedPlacesLogic.reconciled(list)
        #expect(out.count == 1)
        #expect(out.first?.resurface == true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter SavedPlacesResurfaceTests`
Expected: FAIL — `SavedPlace` has no `resurface`.

- [ ] **Step 3: Implement**

In `SavedPlace.swift`: add `public var resurface: Bool` after `savedAt`; add `resurface: Bool = false` to the memberwise init (last param) and set `self.resurface = resurface`; in the `init(place:...)` convenience add `resurface: Bool = false` and forward it. The `place` computed property is unchanged (Place has no resurface).

In `SavedPlacesLogic.swift`:
- In `add(...)`, the re-save branch keeps `updated.resurface` as-is (do not clear it). (No code change needed if you don't touch it — but add a `resurface` parameter is **not** required here; resurface is set via `setResurface` / the store's `save(resurface:)`. Leave `add` mapping resurface through by not resetting it.)
- Add:
```swift
    /// Flips the resurface flag for one place by id; leaves the rest untouched.
    public static func setResurface(id: UUID, _ on: Bool, in list: [SavedPlace]) -> [SavedPlace] {
        list.map { item in
            guard item.id == id else { return item }
            var next = item
            next.resurface = on
            return next
        }
    }
```
- In `reconciled(...)`, after computing `byID` (the newest-by-savedAt winner per id) but before `byKey`, OR-in the resurface flag from all same-id entries so a newer non-flagged save can't drop it:
```swift
        var byID: [UUID: SavedPlace] = [:]
        for item in list where (byID[item.id].map { $0.savedAt <= item.savedAt } ?? true) {
            byID[item.id] = item
        }
        // Preserve resurface across a CloudKit merge: if any same-id copy was flagged, keep it.
        for id in byID.keys where list.contains(where: { $0.id == id && $0.resurface }) {
            byID[id]?.resurface = true
        }
```
(Leave the `byKey`/home logic unchanged.)

- [ ] **Step 4: Run to verify it passes** (and the existing SavedPlaces suites still pass)

Run: `swift test --package-path AuraCore --filter SavedPlaces`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraCore/Models/SavedPlace.swift AuraCore/Sources/AuraCore/Models/SavedPlacesLogic.swift AuraCore/Tests/AuraCoreTests/SavedPlacesResurfaceTests.swift
git commit -m "feat(places): SavedPlace.resurface + reconcile-OR + setResurface (ROH-60)"
```

---

## Phase B — Persistence (AuraKit): schema V5

### Task B1: `RideSchemaV5` + migration + typealias repoint

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV5.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV3.swift:48` (remove the typealias line)
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift:9-13,49-51`
- Test: `AuraCore/Tests/AuraKitTests/SchemaV5MigrationTests.swift`

**Interfaces:**
- Produces: `RideSchemaV5.SavedPlaceRecord` (V3 fields + `resurface: Bool = false`), and `public typealias SavedPlaceRecord = RideSchemaV5.SavedPlaceRecord`. `RideMigrationPlan` gains `migrateV4toV5` (lightweight). Consumed by B2 (store mapping), B3 (invariant test), and all `SavedPlaceRecord` users (unchanged via typealias).

**Why redeclare (not mutate V3's class):** `RideSchemaV3.SavedPlaceRecord` is referenced by both V3 and V4 `models`. Mutating it to add `resurface` would retroactively change what V3/V4 mean, so the V4→V5 lightweight stage would see no delta. V5 declares its **own** `SavedPlaceRecord` (same entity name, +1 attribute) so the two schemas genuinely differ and the lightweight add is well-defined. V5 is the only schema in the live container, so there is no entity-name collision at runtime.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@Suite("Schema V5 migration")
struct SchemaV5MigrationTests {
    @Test func existingPlaceMigratesWithResurfaceFalse() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aura-v5-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        // Open at V4, insert a place (no resurface column), close.
        do {
            let v4 = try ModelContainer(
                for: RideSchemaV2.RideRecord.self, RideSchemaV3.SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self,
                configurations: ModelConfiguration(url: url))
            let ctx = ModelContext(v4)
            ctx.insert(RideSchemaV3.SavedPlaceRecord(
                SavedPlace(name: "Old", subtitle: nil,
                           coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
                           category: .custom, kind: .favorite, savedAt: Date(timeIntervalSince1970: 5))))
            try ctx.save()
        }

        // Reopen through the migration plan → V5; the place gains resurface == false.
        let v5 = try ModelContainer(
            for: RideSchemaV2.RideRecord.self, SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: url))
        let records = try ModelContext(v5).fetch(FetchDescriptor<SavedPlaceRecord>())
        #expect(records.count == 1)
        #expect(records.first?.resurface == false)
        #expect(records.first?.name == "Old")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter SchemaV5MigrationTests`
Expected: FAIL — `RideSchemaV5` / `SavedPlaceRecord.resurface` don't exist.

- [ ] **Step 3: Implement**

Create `RideSchemaV5.swift`:
```swift
import Foundation
import SwiftData
import AuraCore

/// V5 adds `resurface` to `SavedPlaceRecord`. Redeclared here (not mutated in V3) so the
/// V4→V5 delta is a real, well-defined single-attribute add. CloudKit rules hold: default
/// on every attribute, no `.unique`, no relationships. Date default is the fixed sentinel.
public enum RideSchemaV5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(5, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideSchemaV2.RideRecord.self, SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self]
    }

    @Model
    public final class SavedPlaceRecord {
        public var id: UUID = UUID()
        public var name: String = ""
        public var subtitle: String?
        public var latitude: Double = 0
        public var longitude: Double = 0
        public var categoryRaw: String = "custom"
        public var kindRaw: String = "favorite"
        public var savedAt: Date = Date(timeIntervalSince1970: 0)
        public var resurface: Bool = false

        public init(_ value: SavedPlace) {
            id = value.id
            name = value.name
            subtitle = value.subtitle
            latitude = value.coordinate.latitude
            longitude = value.coordinate.longitude
            categoryRaw = value.category.rawValue
            kindRaw = value.kind.rawValue
            savedAt = value.savedAt
            resurface = value.resurface
        }

        /// nil when raws come from a newer app version this build can't read.
        public var value: SavedPlace? {
            guard let category = Place.Category(rawValue: categoryRaw),
                  let kind = SavedPlace.Kind(rawValue: kindRaw) else { return nil }
            return SavedPlace(id: id, name: name, subtitle: subtitle,
                              coordinate: Coordinate(latitude: latitude, longitude: longitude),
                              category: category, kind: kind, savedAt: savedAt, resurface: resurface)
        }
    }
}

public typealias SavedPlaceRecord = RideSchemaV5.SavedPlaceRecord
```

In `RideSchemaV3.swift`, delete the last line `public typealias SavedPlaceRecord = RideSchemaV3.SavedPlaceRecord`. (The class stays; only the typealias moves to V5.)

In `RideMigrationPlan.swift`:
```swift
    public static var schemas: [any VersionedSchema.Type] {
        [RideSchemaV1.self, RideSchemaV2.self, RideSchemaV3.self, RideSchemaV4.self, RideSchemaV5.self]
    }

    public static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5]
    }
```
and add after `migrateV3toV4`:
```swift
    /// Adding one defaulted attribute to SavedPlaceRecord is lightweight — no data transform.
    public static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: RideSchemaV4.self,
        toVersion: RideSchemaV5.self)
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter SchemaV5MigrationTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Persistence/RideSchemaV5.swift AuraCore/Sources/AuraKit/Persistence/RideSchemaV3.swift AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift AuraCore/Tests/AuraKitTests/SchemaV5MigrationTests.swift
git commit -m "feat(persistence): schema V5 adds SavedPlaceRecord.resurface + lightweight migration (ROH-60)"
```

---

### Task B2: `SchemaInvariantTests` → V5 (ROH-13 guard)

**Files:**
- Modify: `AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift:11-39`

**Interfaces:**
- Consumes: `RideSchemaV5` (B1).

- [ ] **Step 1: Update the test to guard V5**

Change `entities` to `Schema(versionedSchema: RideSchemaV5.self).entities` (update the comment to say "including SavedPlaceRecord.resurface (V5)"), and rename `v4ContainsAllModels` → `v5ContainsAllModels` (the model-name set is unchanged: `["RideRecord", "SavedPlaceRecord", "SeenGemRecord"]`). Add an explicit resurface-default assertion:
```swift
    @Test func resurfaceDefaultsFalse() {
        let saved = entities.first { $0.name == "SavedPlaceRecord" }
        let attr = saved?.attributes.first { $0.name == "resurface" }
        #expect(attr != nil)
        #expect(attr?.isOptional == true || attr?.defaultValue != nil)
    }
```

- [ ] **Step 2: Run to verify it passes** (V5 attributes all defaulted/optional; resurface present)

Run: `swift test --package-path AuraCore --filter SchemaInvariant`
Expected: PASS.

- [ ] **Step 3: Commit**
```bash
git add AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift
git commit -m "test(persistence): schema-invariant guard targets V5 + resurface default (ROH-60)"
```

---

### Task B3: `SavedPlacesStore` resurface persistence + `updateName` + `setResurface`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Persistence/SavedPlacesStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/SavedPlacesStoreResurfaceTests.swift`

**Interfaces:**
- Produces:
  - `SavedPlacesStore.save(_ place: Place, subtitle: String?, resurface: Bool) -> SaveOutcome` (add a defaulted `resurface: Bool = false` param; existing callers unaffected).
  - `SavedPlacesStore.setResurface(id: UUID, _ on: Bool)`.
  - `SavedPlacesStore.updateName(id: UUID, to name: String, ifCurrentlyNamed current: String)` — renames **only if** the stored name still equals `current` (backfill guard; a user rename wins). Consumed by E-phase geocode backfill.
  - `resurface` written in the `persist` upsert path.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
@Suite("SavedPlacesStore resurface")
struct SavedPlacesStoreResurfaceTests {
    private func store() throws -> SavedPlacesStore {
        let c = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return SavedPlacesStore(container: c, now: { Date(timeIntervalSince1970: 10) })
    }
    private func place(_ name: String) -> Place {
        Place(id: UUID(), name: name, subtitle: nil,
              coordinate: Coordinate(latitude: 40.44, longitude: -79.99), category: .custom)
    }

    @Test func saveWithResurfacePersistsFlag() throws {
        let s = try store()
        _ = s.save(place("Spot"), subtitle: nil, resurface: true)
        #expect(s.places.first?.resurface == true)
    }

    @Test func setResurfaceTogglesOff() throws {
        let s = try store()
        guard case let .saved(saved) = s.save(place("Spot"), subtitle: nil, resurface: true) else {
            Issue.record("not saved"); return
        }
        s.setResurface(id: saved.id, false)
        #expect(s.places.first { $0.id == saved.id }?.resurface == false)
    }

    @Test func updateNameOnlyIfStillProvisional() throws {
        let s = try store()
        guard case let .saved(saved) = s.save(place("Marked spot"), subtitle: nil, resurface: true) else {
            Issue.record("not saved"); return
        }
        // A user rename lands first.
        s.rename(id: saved.id, to: "Best viewpoint")
        // Async geocode backfill tries to set the real name, but must NOT clobber the user edit.
        s.updateName(id: saved.id, to: "Overlook Park", ifCurrentlyNamed: "Marked spot")
        #expect(s.places.first { $0.id == saved.id }?.name == "Best viewpoint")
        // If still provisional, backfill applies.
        guard case let .saved(two) = s.save(place("Marked spot"), subtitle: nil, resurface: true) else {
            Issue.record("not saved"); return
        }
        s.updateName(id: two.id, to: "River Trail", ifCurrentlyNamed: "Marked spot")
        #expect(s.places.first { $0.id == two.id }?.name == "River Trail")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter SavedPlacesStoreResurfaceTests`
Expected: FAIL — `save(_:subtitle:resurface:)`, `setResurface`, `updateName` missing.

- [ ] **Step 3: Implement**

In `SavedPlacesStore.swift`:
- Change `save` signature to `save(_ place: Place, subtitle: String?, resurface: Bool = false) -> SaveOutcome`. After the `.added(list)` persist, if `resurface`, apply `setResurface` on the just-saved id: capture `saved`, then `if resurface { persist(SavedPlacesLogic.setResurface(id: saved.id, true, in: places)) }` and re-lookup. (Simplest: after `persist(list)` and lookup `saved`, if `resurface && !saved.resurface { persist(SavedPlacesLogic.setResurface(id: saved.id, true, in: places)); return .saved(savedPlace(for: place) ?? saved) }`.)
- Add:
```swift
    public func setResurface(id: UUID, _ on: Bool) {
        persist(SavedPlacesLogic.setResurface(id: id, on, in: places))
    }

    /// Backfills a name (reverse-geocode result) only if the stored name is still the
    /// provisional string — so a user rename made before the geocode returns is never lost.
    public func updateName(id: UUID, to name: String, ifCurrentlyNamed current: String) {
        guard places.first(where: { $0.id == id })?.name == current else { return }
        rename(id: id, to: name)
    }
```
- In `persist(...)`'s upsert loop add `record.resurface = value.resurface` alongside the other field writes. (The insert branch already carries it via `SavedPlaceRecord(value)` = V5 init.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter SavedPlacesStoreResurfaceTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Persistence/SavedPlacesStore.swift AuraCore/Tests/AuraKitTests/SavedPlacesStoreResurfaceTests.swift
git commit -m "feat(places): store resurface persistence + backfill-safe updateName (ROH-60)"
```

---

## Phase C — Providers (AuraKit)

### Task C1: `ResurfacePlacesReading` seam + `SavedPlacesStore` conformance

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/ResurfacePlacesReading.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/SavedPlacesStore.swift` (conform)
- Test: `AuraCore/Tests/AuraKitTests/ResurfacePlacesReadingTests.swift`

**Interfaces:**
- Produces:
  - `protocol ResurfacePlacesReading: Sendable { @MainActor func resurfacePlaces() -> [SavedPlace] }`.
  - `SavedPlacesStore: ResurfacePlacesReading` returning `places.filter(\.resurface)`. Consumed by C2 (`PersonalGemProvider`).

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
@Suite("Resurface reading seam")
struct ResurfacePlacesReadingTests {
    @Test func returnsOnlyFlaggedPlaces() throws {
        let c = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = SavedPlacesStore(container: c, now: { Date(timeIntervalSince1970: 1) })
        _ = store.save(Place(id: UUID(), name: "Keep", subtitle: nil,
                             coordinate: Coordinate(latitude: 40.0, longitude: -79.0), category: .custom),
                       subtitle: nil, resurface: true)
        _ = store.save(Place(id: UUID(), name: "Plain", subtitle: nil,
                             coordinate: Coordinate(latitude: 41.0, longitude: -79.0), category: .custom),
                       subtitle: nil, resurface: false)
        let reading: any ResurfacePlacesReading = store
        #expect(reading.resurfacePlaces().map(\.name) == ["Keep"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter ResurfacePlacesReadingTests`
Expected: FAIL — no `ResurfacePlacesReading`.

- [ ] **Step 3: Implement**

`ResurfacePlacesReading.swift`:
```swift
import Foundation
import AuraCore

/// Read seam over the saved-places store for the gem layer: the resurface-flagged
/// places that behave as Tier-3 personal gems. `@MainActor` because the store is.
public protocol ResurfacePlacesReading: Sendable {
    @MainActor func resurfacePlaces() -> [SavedPlace]
}
```
In `SavedPlacesStore.swift`, add:
```swift
extension SavedPlacesStore: ResurfacePlacesReading {
    public func resurfacePlaces() -> [SavedPlace] { places.filter(\.resurface) }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter ResurfacePlacesReadingTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/ResurfacePlacesReading.swift AuraCore/Sources/AuraKit/Persistence/SavedPlacesStore.swift AuraCore/Tests/AuraKitTests/ResurfacePlacesReadingTests.swift
git commit -m "feat(gems): ResurfacePlacesReading seam over SavedPlacesStore (ROH-60)"
```

---

### Task C2: `PersonalGemProvider`

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/PersonalGemProvider.swift`
- Test: `AuraCore/Tests/AuraKitTests/PersonalGemProviderTests.swift`

**Interfaces:**
- Consumes: `ResurfacePlacesReading` (C1), `Place.Category` → `GemCategory` mapping (define inline; see below).
- Produces: `PersonalGemProvider(reading:)` conforming `GemProviding`. `gems(near:)` returns all resurface places as `.personal` Tier-3 gems, `id = "personal:<uuid>"`, ignoring `near:` (small set; engine gates proximity).

**Place.Category → GemCategory:** map obvious ones (`park→park`, `cafe→cafe`, `viewpoint→viewpoint` if present) else default `.landmark` (T3-worthy, since it's the rider's own pick). Keep a small `private static func gemCategory(_:) -> GemCategory` in the provider.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

private struct StubReading: ResurfacePlacesReading {
    let places: [SavedPlace]
    @MainActor func resurfacePlaces() -> [SavedPlace] { places }
}

@MainActor
@Suite("PersonalGemProvider")
struct PersonalGemProviderTests {
    @Test func mapsResurfacePlacesToTier3PersonalGems() async {
        let id = UUID()
        let reading = StubReading(places: [
            SavedPlace(id: id, name: "My overlook", subtitle: nil,
                       coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
                       category: .custom, kind: .favorite, savedAt: .init(timeIntervalSince1970: 1),
                       resurface: true)
        ])
        let provider = PersonalGemProvider(reading: reading)
        let gems = await provider.gems(near: Coordinate(latitude: 0, longitude: 0))
        #expect(gems.count == 1)
        #expect(gems.first?.id == "personal:\(id.uuidString)")
        #expect(gems.first?.source == .personal)
        #expect(gems.first?.tier == .cardHaptic)
        #expect(gems.first?.name == "My overlook")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter PersonalGemProviderTests`
Expected: FAIL — no `PersonalGemProvider`.

- [ ] **Step 3: Implement**
```swift
import Foundation
import AuraCore

/// Turns resurface-flagged saved places into Tier-3 `.personal` gems. Ignores `near:` —
/// the set is small and the engine's proximity gate handles range.
public struct PersonalGemProvider: GemProviding {
    private let reading: any ResurfacePlacesReading
    public init(reading: any ResurfacePlacesReading) { self.reading = reading }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        let places = await reading.resurfacePlaces()
        return places.map { place in
            Gem(id: "personal:\(place.id.uuidString)", name: place.name,
                coordinate: place.coordinate, category: Self.gemCategory(place.category),
                tier: .cardHaptic, source: .personal, photoAsset: nil, why: nil)
        }
    }

    private static func gemCategory(_ c: Place.Category) -> GemCategory {
        switch c {
        case .park: return .park
        case .cafe: return .cafe
        default: return .landmark   // the rider's own pick — always Tier-3-worthy
        }
    }
}
```
(If `Place.Category` has no `.park`/`.cafe` cases, map only what exists and default `.landmark`. The implementer verifies the enum's cases in `AuraCore/Sources/AuraCore/Models/Place.swift`.)

Note: `await reading.resurfacePlaces()` hops to the main actor (the method is `@MainActor`); this is the single explicit hop the arch review required.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter PersonalGemProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/PersonalGemProvider.swift AuraCore/Tests/AuraKitTests/PersonalGemProviderTests.swift
git commit -m "feat(gems): PersonalGemProvider maps resurface places to Tier-3 gems (ROH-60)"
```

---

### Task C3: `OSMOverpass` request + decode

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/OSMOverpass.swift`
- Test: `AuraCore/Tests/AuraKitTests/OSMOverpassTests.swift`

**Interfaces:**
- Produces:
  - `OSMOverpass.query(near: Coordinate, radiusMeters: Double) -> String` — the Overpass QL string (nodes with the mapped keys around the point).
  - `OSMOverpass.request(near:radiusMeters:endpoint:) -> URLRequest`.
  - `OSMOverpass.elements(from data: Data) -> [(id: String, name: String?, coordinate: Coordinate, tags: [String: String])]` — decodes the Overpass JSON `elements` array (nodes only), building `id = "osm:node/<id>"`. Consumed by C4.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite("OSM Overpass")
struct OSMOverpassTests {
    @Test func queryBoundsToRadiusAndKeys() {
        let q = OSMOverpass.query(near: Coordinate(latitude: 40.44, longitude: -79.99), radiusMeters: 1200)
        #expect(q.contains("around:1200,40.44,-79.99"))
        #expect(q.contains("[out:json]"))
        #expect(q.contains("tourism"))
    }

    @Test func decodesNodesWithTags() {
        let json = """
        {"elements":[
          {"type":"node","id":42,"lat":40.44,"lon":-79.99,"tags":{"tourism":"viewpoint","name":"Grandview"}},
          {"type":"node","id":43,"lat":40.45,"lon":-79.98,"tags":{"amenity":"cafe"}},
          {"type":"way","id":99,"tags":{"leisure":"park"}}
        ]}
        """.data(using: .utf8)!
        let els = OSMOverpass.elements(from: json)
        #expect(els.count == 2)   // way dropped (no lat/lon)
        #expect(els[0].id == "osm:node/42")
        #expect(els[0].name == "Grandview")
        #expect(els[0].tags["tourism"] == "viewpoint")
        #expect(els[1].name == nil)
    }

    @Test func malformedDataYieldsEmpty() {
        #expect(OSMOverpass.elements(from: Data("nonsense".utf8)).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter OSMOverpassTests`
Expected: FAIL — no `OSMOverpass`.

- [ ] **Step 3: Implement**
```swift
import Foundation
import AuraCore

/// Overpass QL request building + JSON decode for the live feed. No networking here —
/// `LiveGemProvider` performs the URLSession call and feeds `elements(from:)`.
public enum OSMOverpass {
    public static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Nodes carrying any of the mapped keys within `radiusMeters` of the point.
    public static func query(near c: Coordinate, radiusMeters: Double) -> String {
        let r = Int(radiusMeters)
        let lat = c.latitude, lon = c.longitude
        let filters = ["tourism", "leisure", "amenity", "natural", "historic"]
            .map { "node[\($0)](around:\(r),\(lat),\(lon));" }
            .joined()
        return "[out:json][timeout:10];(\(filters));out center 60;"
    }

    public static func request(near c: Coordinate, radiusMeters: Double,
                               endpoint: URL = defaultEndpoint) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data("data=\(query(near: c, radiusMeters: radiusMeters))".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return req
    }

    public static func elements(from data: Data) -> [(id: String, name: String?, coordinate: Coordinate, tags: [String: String])] {
        struct Response: Decodable { let elements: [Element] }
        struct Element: Decodable { let type: String; let id: Int; let lat: Double?; let lon: Double?; let tags: [String: String]? }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return resp.elements.compactMap { e in
            guard let lat = e.lat, let lon = e.lon else { return nil }   // nodes only (ways lack lat/lon here)
            let tags = e.tags ?? [:]
            return (id: "osm:\(e.type)/\(e.id)", name: tags["name"],
                    coordinate: Coordinate(latitude: lat, longitude: lon), tags: tags)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter OSMOverpassTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/OSMOverpass.swift AuraCore/Tests/AuraKitTests/OSMOverpassTests.swift
git commit -m "feat(gems): Overpass query builder + JSON decode (ROH-60)"
```

---

### Task C4: `LiveGemProvider` (URLSession-injected)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/LiveGemProvider.swift`
- Test: `AuraCore/Tests/AuraKitTests/LiveGemProviderTests.swift`

**Interfaces:**
- Consumes: `OSMOverpass` (C3), `OSMGemMapping` (A3).
- Produces: `LiveGemProvider(session:radiusMeters:endpoint:)` conforming `GemProviding`. `gems(near:)` performs the Overpass POST, maps elements→gems (dropping unmapped), and returns `[]` on **any** error/non-200/decodefail. Consumed by C6 (composite).

**Test transport:** a `URLProtocol` stub registered on an ephemeral `URLSession`.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var status: Int = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("LiveGemProvider")
struct LiveGemProviderTests {
    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test func decodesLiveGemsCappedAtTier2() async {
        StubURLProtocol.status = 200
        StubURLProtocol.body = """
        {"elements":[{"type":"node","id":7,"lat":40.44,"lon":-79.99,"tags":{"tourism":"viewpoint","name":"Grandview"}}]}
        """.data(using: .utf8)!
        let provider = LiveGemProvider(session: session())
        let gems = await provider.gems(near: Coordinate(latitude: 40.44, longitude: -79.99))
        #expect(gems.count == 1)
        #expect(gems.first?.tier == .card)
        #expect(gems.first?.source == .live)
        #expect(gems.first?.id == "osm:node/7")
    }

    @Test func serverErrorYieldsEmpty() async {
        StubURLProtocol.status = 503
        StubURLProtocol.body = Data()
        let provider = LiveGemProvider(session: session())
        let gems = await provider.gems(near: Coordinate(latitude: 40.44, longitude: -79.99))
        #expect(gems.isEmpty)
    }

    @Test func unmappedElementsDropped() async {
        StubURLProtocol.status = 200
        StubURLProtocol.body = """
        {"elements":[{"type":"node","id":8,"lat":40.44,"lon":-79.99,"tags":{"shop":"bakery"}}]}
        """.data(using: .utf8)!
        let provider = LiveGemProvider(session: session())
        #expect(await provider.gems(near: Coordinate(latitude: 40.44, longitude: -79.99)).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter LiveGemProviderTests`
Expected: FAIL — no `LiveGemProvider`.

- [ ] **Step 3: Implement**
```swift
import Foundation
import AuraCore

/// OSM Overpass live feed. Pure URLSession (no Mapbox), so it lives in AuraKit and is
/// unit-testable. Any failure — offline, non-200, decode error — yields `[]`; discovery
/// silently falls back to curated + personal. Live gems are photoless and ≤ Tier 2.
public struct LiveGemProvider: GemProviding {
    private let session: URLSession
    private let radiusMeters: Double
    private let endpoint: URL

    public init(session: URLSession = .shared, radiusMeters: Double = 1500,
                endpoint: URL = OSMOverpass.defaultEndpoint) {
        self.session = session
        self.radiusMeters = radiusMeters
        self.endpoint = endpoint
    }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        let request = OSMOverpass.request(near: coordinate, radiusMeters: radiusMeters, endpoint: endpoint)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        return OSMOverpass.elements(from: data).compactMap {
            OSMGemMapping.gem(id: $0.id, name: $0.name, coordinate: $0.coordinate, tags: $0.tags)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter LiveGemProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/LiveGemProvider.swift AuraCore/Tests/AuraKitTests/LiveGemProviderTests.swift
git commit -m "feat(gems): LiveGemProvider over OSM Overpass, empty on any failure (ROH-60)"
```

---

### Task C5: `GemRegionCache` (actor)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/GemRegionCache.swift`
- Test: `AuraCore/Tests/AuraKitTests/GemRegionCacheTests.swift`

**Interfaces:**
- Produces: `actor GemRegionCache` with `func gems(near: Coordinate, now: Date, fetch: @Sendable () async -> [Gem]) async -> [Gem]`. Caches by a ~2 km grid cell + a staleness window (default 600 s, injected). Cache hit (same cell, fresh) → returns cached without calling `fetch`; miss (new cell or stale) → calls `fetch`, stores, returns. Clock is the injected `now`. Consumed by C6/D-phase where live is wrapped.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@Suite("GemRegionCache")
struct GemRegionCacheTests {
    private func g(_ id: String) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
            category: .cafe, tier: .card, source: .live)
    }
    private let p = Coordinate(latitude: 40.44, longitude: -79.99)

    @Test func hitWithinCellAndWindowSkipsFetch() async {
        let cache = GemRegionCache(cellMeters: 2000, stalenessSeconds: 600)
        let calls = Counter()
        _ = await cache.gems(near: p, now: Date(timeIntervalSince1970: 0)) { await calls.bump(); return [g("a")] }
        let second = await cache.gems(near: p, now: Date(timeIntervalSince1970: 100)) { await calls.bump(); return [g("b")] }
        #expect(second.map(\.id) == ["a"])          // served from cache
        #expect(await calls.value == 1)
    }

    @Test func staleWindowRefetches() async {
        let cache = GemRegionCache(cellMeters: 2000, stalenessSeconds: 600)
        let calls = Counter()
        _ = await cache.gems(near: p, now: Date(timeIntervalSince1970: 0)) { await calls.bump(); return [g("a")] }
        let second = await cache.gems(near: p, now: Date(timeIntervalSince1970: 700)) { await calls.bump(); return [g("b")] }
        #expect(second.map(\.id) == ["b"])
        #expect(await calls.value == 2)
    }

    @Test func differentCellRefetches() async {
        let cache = GemRegionCache(cellMeters: 2000, stalenessSeconds: 600)
        let calls = Counter()
        _ = await cache.gems(near: p, now: Date(timeIntervalSince1970: 0)) { await calls.bump(); return [g("a")] }
        let far = Coordinate(latitude: 41.5, longitude: -79.99)
        _ = await cache.gems(near: far, now: Date(timeIntervalSince1970: 10)) { await calls.bump(); return [g("b")] }
        #expect(await calls.value == 2)
    }
}

actor Counter { private(set) var value = 0; func bump() { value += 1 } }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GemRegionCacheTests`
Expected: FAIL — no `GemRegionCache`.

- [ ] **Step 3: Implement**
```swift
import Foundation
import AuraCore

/// Region cache for the live feed: refetch only when the rider leaves the current cell or
/// the entry goes stale. Actor-isolated; the clock is injected (`now`), never wall-clock.
public actor GemRegionCache {
    private struct Entry { let cell: Cell; let at: Date; let gems: [Gem] }
    private struct Cell: Equatable { let x: Int; let y: Int }

    private let cellMeters: Double
    private let stalenessSeconds: TimeInterval
    private var entry: Entry?

    public init(cellMeters: Double = 2000, stalenessSeconds: TimeInterval = 600) {
        self.cellMeters = cellMeters
        self.stalenessSeconds = stalenessSeconds
    }

    public func gems(near coordinate: Coordinate, now: Date,
                     fetch: @Sendable () async -> [Gem]) async -> [Gem] {
        let cell = self.cell(for: coordinate)
        if let e = entry, e.cell == cell, now.timeIntervalSince(e.at) < stalenessSeconds {
            return e.gems
        }
        let gems = await fetch()
        entry = Entry(cell: cell, at: now, gems: gems)
        return gems
    }

    private func cell(for c: Coordinate) -> Cell {
        // ~metersPerDegree lat; lon scaled by cos(lat) so cells are roughly square.
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cos(c.latitude * .pi / 180)
        return Cell(x: Int((c.longitude * mPerDegLon / cellMeters).rounded()),
                    y: Int((c.latitude * mPerDegLat / cellMeters).rounded()))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter GemRegionCacheTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/GemRegionCache.swift AuraCore/Tests/AuraKitTests/GemRegionCacheTests.swift
git commit -m "feat(gems): GemRegionCache (cell+staleness, injected clock) (ROH-60)"
```

---

### Task C6: `CompositeGemProvider` (merge + two-pass dedupe + live timeout)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Gems/CompositeGemProvider.swift`
- Test: `AuraCore/Tests/AuraKitTests/CompositeGemProviderTests.swift`

**Interfaces:**
- Consumes: `GemSource.priorityRank` (A1), `Geo.distance`.
- Produces: `CompositeGemProvider(local: [any GemProviding], live: any GemProviding, dedupeMeters: Double = 25, timeout: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) })` conforming `GemProviding`. `gems(near:)` fans out `local` providers concurrently + `live` raced against `timeout` (on timeout, live contributes `[]`), then **two-pass dedupe**: (1) exact `Gem.id`, higher `priorityRank` wins; (2) coordinate cluster within `dedupeMeters`, higher-priority member wins. Consumed by D-phase store wiring.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

private struct FixedProvider: GemProviding {
    let gems: [Gem]
    func gems(near coordinate: Coordinate) async -> [Gem] { gems }
}
private struct NeverProvider: GemProviding {
    func gems(near coordinate: Coordinate) async -> [Gem] {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } // never resumes
        return []
    }
}

@Suite("CompositeGemProvider")
struct CompositeGemProviderTests {
    private let p = Coordinate(latitude: 40.44, longitude: -79.99)
    private func g(_ id: String, _ src: GemSource, _ c: Coordinate) -> Gem {
        Gem(id: id, name: id, coordinate: c, category: .cafe, tier: .card, source: src)
    }
    private func near(_ meters: Double) -> Coordinate {
        Coordinate(latitude: p.latitude + meters / 111_320.0, longitude: p.longitude)
    }

    @Test func unionsSources() async {
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("curated:a", .curated, near(300))]),
                    FixedProvider(gems: [g("personal:b", .personal, near(600))])],
            live: FixedProvider(gems: [g("osm:node/c", .live, near(900))]))
        let ids = Set((await composite.gems(near: p)).map(\.id))
        #expect(ids == ["curated:a", "personal:b", "osm:node/c"])
    }

    @Test func dedupesSameIdKeepingHigherPriority() async {
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("dup", .curated, p)]),
                    FixedProvider(gems: [g("dup", .personal, p)])],
            live: FixedProvider(gems: []))
        let gems = await composite.gems(near: p)
        #expect(gems.count == 1)
        #expect(gems.first?.source == .personal)
    }

    @Test func dedupesNearbyDifferentIdsKeepingHigherPriority() async {
        // A personal save and an OSM POI ~10 m apart = same physical spot, different ids.
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("personal:x", .personal, p)])],
            live: FixedProvider(gems: [g("osm:node/y", .live, near(10))]))
        let gems = await composite.gems(near: p)
        #expect(gems.count == 1)
        #expect(gems.first?.source == .personal)
    }

    @Test func slowLiveTimesOutWithoutBlocking() async {
        let composite = CompositeGemProvider(
            local: [FixedProvider(gems: [g("curated:a", .curated, p)])],
            live: NeverProvider(),
            timeout: { /* fire immediately */ })
        let gems = await composite.gems(near: p)
        #expect(gems.map(\.id) == ["curated:a"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter CompositeGemProviderTests`
Expected: FAIL — no `CompositeGemProvider`.

- [ ] **Step 3: Implement**
```swift
import Foundation
import AuraCore

/// Fans out to the local providers (personal, curated) concurrently plus the live provider
/// raced against a timeout, then dedupes. A slow/offline Overpass never blocks the map:
/// on timeout, live contributes []. Dedupe is two-pass — exact id, then coordinate cluster —
/// with personal > curated > live winning collisions.
public struct CompositeGemProvider: GemProviding {
    private let local: [any GemProviding]
    private let live: any GemProviding
    private let dedupeMeters: Double
    private let timeout: @Sendable () async -> Void

    public init(local: [any GemProviding], live: any GemProviding, dedupeMeters: Double = 25,
                timeout: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) }) {
        self.local = local
        self.live = live
        self.dedupeMeters = dedupeMeters
        self.timeout = timeout
    }

    public func gems(near coordinate: Coordinate) async -> [Gem] {
        async let localGems: [Gem] = withTaskGroup(of: [Gem].self) { group in
            for provider in local { group.addTask { await provider.gems(near: coordinate) } }
            var all: [Gem] = []
            for await part in group { all += part }
            return all
        }
        async let liveGems: [Gem] = {
            await withTaskGroup(of: [Gem]?.self) { group in
                group.addTask { await live.gems(near: coordinate) }
                group.addTask { await timeout(); return nil }   // nil = timed out
                for await first in group { group.cancelAll(); return first ?? [] }
                return []
            }
        }()
        return Self.dedupe(await localGems + liveGems, within: dedupeMeters)
    }

    /// Pass 1: exact id, higher priority wins. Pass 2: cluster within `meters`, higher priority wins.
    static func dedupe(_ gems: [Gem], within meters: Double) -> [Gem] {
        var byID: [String: Gem] = [:]
        for gem in gems {
            if let existing = byID[gem.id], existing.source.priorityRank <= gem.source.priorityRank { continue }
            byID[gem.id] = gem
        }
        var kept: [Gem] = []
        for gem in byID.values.sorted(by: { $0.source.priorityRank < $1.source.priorityRank }) {
            if kept.contains(where: { Geo.distance($0.coordinate, gem.coordinate) <= meters }) { continue }
            kept.append(gem)
        }
        return kept
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter CompositeGemProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/CompositeGemProvider.swift AuraCore/Tests/AuraKitTests/CompositeGemProviderTests.swift
git commit -m "feat(gems): CompositeGemProvider merge + two-pass dedupe + live timeout (ROH-60)"
```

---

## Phase D — Store wiring (AuraKit)

### Task D1: `GemDiscoveryStore.load()` deferral + timestamp clock + detour snapshot

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift:39-63`
- Test: `AuraCore/Tests/AuraKitTests/GemDiscoveryStoreLoadTests.swift`

**Interfaces:**
- Produces: `load()` no longer queries at (0,0); the store loads **once** on the first `update(at:now:)` with a real coordinate. `update` snapshots `detourActive()` once. No public signature change (the HUD keeps calling `update` via `RideDiscoverySink`).

**Design:** add `private var didLoad = false`. `update(at:now:)` sets `riderCoordinate`, and if `!didLoad` triggers a `Task { await load() }` (or loads synchronously by fetching candidates lazily). Because `update` is sync and `load` is async, restructure: `update` records the coordinate + fires a one-time `Task { await self.load() }`; `load` uses `riderCoordinate` (now non-nil), fetches candidates, seeds seen, then re-runs the decision at the current coordinate/now. To keep the current-sample decision deterministic, thread the sample `now` into load via a stored `private var lastNow`.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

private actor CallLog { private(set) var coords: [Coordinate] = []; func add(_ c: Coordinate) { coords.append(c) } }
private struct RecordingProvider: GemProviding {
    let log: CallLog
    let gems: [Gem]
    func gems(near coordinate: Coordinate) async -> [Gem] { await log.add(coordinate); return gems }
}
private struct NoSeen: SeenGemStoring { func seenGemIDs() -> Set<String> { [] }; func markSeen(_ id: String, at date: Date) {} }
private struct NoHaptic: GemHapticPlaying { func playGemSurfaced() {} }

@MainActor
@Suite("GemDiscoveryStore load deferral")
struct GemDiscoveryStoreLoadTests {
    @Test func neverQueriesBeforeFirstFix() async {
        let log = CallLog()
        let store = GemDiscoveryStore(provider: RecordingProvider(log: log, gems: []),
                                      seen: NoSeen(), haptics: NoHaptic())
        // No update() yet → load must not have queried Null Island.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await log.coords.isEmpty)
    }

    @Test func loadsOnceAtFirstRealCoordinate() async {
        let log = CallLog()
        let p = Coordinate(latitude: 40.44, longitude: -79.99)
        let store = GemDiscoveryStore(provider: RecordingProvider(log: log, gems: []),
                                      seen: NoSeen(), haptics: NoHaptic())
        store.update(at: p, now: Date(timeIntervalSince1970: 1))
        store.update(at: p, now: Date(timeIntervalSince1970: 2))
        try? await Task.sleep(for: .milliseconds(50))
        let coords = await log.coords
        #expect(coords.count == 1)                 // exactly one load
        #expect(coords.first?.latitude == 40.44)   // never (0,0)
    }
}
```
(Note: the 50 ms sleeps here await a *Task-triggered async load* settling — this is a settle-await, acceptable; the store logic itself stays timestamp-driven.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GemDiscoveryStoreLoadTests`
Expected: FAIL — current `load()` queries (0,0) and isn't auto-triggered.

- [ ] **Step 3: Implement** — rewrite the load/update region:
```swift
    private var didLoad = false

    /// Loads the candidate set for the current rider coordinate. A no-op until the first
    /// fix — coordinate-filtering providers (live/personal) must never be queried at (0,0).
    /// Triggered once from `update(at:now:)`; safe to call again (guarded by `didLoad`).
    public func load() async {
        guard let origin = riderCoordinate else { return }
        candidates = await provider.gems(near: origin)
        seenIDs = seen.seenGemIDs()
        state = DiscoveryState(seenBefore: seenIDs)
        if let now = lastNow { evaluate(at: origin, now: now) }
    }

    private var lastNow: Date?

    public func update(at coordinate: Coordinate, now: Date) {
        riderCoordinate = coordinate
        lastNow = now
        if !didLoad {
            didLoad = true
            Task { await load() }
        }
        evaluate(at: coordinate, now: now)
    }

    private func evaluate(at coordinate: Coordinate, now: Date) {
        let detouring = detourActive()   // snapshot once — no mid-update re-entrancy flip
        guard !isSuppressed else { visiblePins = []; activeCard = nil; return }
        let decision = engine.decide(from: candidates, at: coordinate, now: now, state: &state)
        visiblePins = decision.visiblePins
        if let gem = decision.activeSurfacing {
            seenIDs.insert(gem.id)
            seen.markSeen(gem.id, at: now)
            if !detouring {
                activeCard = gem
                if gem.tier == .cardHaptic { haptics.playGemSurfaced() }
            }
        }
    }
```
Remove the old `load()` body and the old `update` body. Delete any existing external `load()` call sites that assumed pre-fix loading (search `\.load()` in the app target; the HUD should rely on the auto-trigger — if the HUD calls `store.load()` in `.task`, that call becomes a guarded no-op until the first fix, which is fine; leave it or remove it in Task E-wiring).

- [ ] **Step 4: Run to verify it passes** (+ existing store suite)

Run: `swift test --package-path AuraCore --filter GemDiscoveryStore`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/GemDiscoveryStore.swift AuraCore/Tests/AuraKitTests/GemDiscoveryStoreLoadTests.swift
git commit -m "feat(gems): defer load() past first fix + timestamp-driven + detour snapshot (ROH-60)"
```

---

### Task D2: `SeenGemStore` in-memory cache + logged failure

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Gems/SeenGemStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/SeenGemStoreTests.swift` (create or extend)

**Interfaces:**
- Produces: `SeenGemStore` caches its id set in memory (seeded at init), so `markSeen` no longer re-fetches per call; a save failure is logged (`assertionFailure` in debug), not silently swallowed. Behavior (idempotent insert) unchanged.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
@Suite("SeenGemStore cache")
struct SeenGemStoreTests {
    @Test func marksAndReadsBackWithoutDuplicating() throws {
        let c = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = SeenGemStore(container: c)
        store.markSeen("curated:a", at: Date(timeIntervalSince1970: 1))
        store.markSeen("curated:a", at: Date(timeIntervalSince1970: 2))   // idempotent
        #expect(store.seenGemIDs() == ["curated:a"])
    }
}
```

- [ ] **Step 2: Run to verify it fails or passes**

Run: `swift test --package-path AuraCore --filter SeenGemStoreTests`
Expected: PASS behaviorally today (idempotent). This task hardens internals; if the test already passes, proceed to Step 3 as a refactor guarded by the green test.

- [ ] **Step 3: Implement**
```swift
@MainActor
public final class SeenGemStore: SeenGemStoring {
    private let context: ModelContext
    private var cached: Set<String>

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        let records = (try? context.fetch(FetchDescriptor<SeenGemRecord>())) ?? []
        self.cached = Set(records.map(\.gemID))
    }

    public func seenGemIDs() -> Set<String> { cached }

    public func markSeen(_ gemID: String, at date: Date) {
        guard !cached.contains(gemID) else { return }
        context.insert(SeenGemRecord(gemID: gemID, firstSeenAt: date))
        do { try context.save(); cached.insert(gemID) }
        catch { assertionFailure("SeenGemStore save failed for \(gemID): \(error)") }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter SeenGemStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/SeenGemStore.swift AuraCore/Tests/AuraKitTests/SeenGemStoreTests.swift
git commit -m "refactor(gems): SeenGemStore caches id set + logs save failures (ROH-60)"
```

---

## Phase E — App target (UI, iOS-only)

> App-target tasks: the implementer **writes + commits only**. The controller runs the app build via the builder agent after each task (or a batch), never the implementer. No unit tests for pure SwiftUI; these are build-verified then device-verified. Each task must still `git commit`.

### Task E1: `ReverseGeocoder` (CLGeocoder wrapper)

**Files:**
- Create: `Aura/Sources/Ride/ReverseGeocoder.swift`

**Interfaces:**
- Produces: `enum ReverseGeocoder { static func name(for coordinate: Coordinate) async -> String? }` using `CLGeocoder.reverseGeocodeLocation`, returning a short place name (name ?? thoroughfare ?? locality), `nil` on failure/offline. iOS-only; app target.

- [ ] **Step 1: Implement**
```swift
import Foundation
import CoreLocation
import AuraCore

/// App-target reverse-geocode for auto-naming a marked spot. Best-effort: nil on
/// failure/offline (the caller keeps the provisional name). CoreLocation is iOS-only,
/// so this stays out of the package.
enum ReverseGeocoder {
    static func name(for coordinate: Coordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return placemark.name ?? placemark.thoroughfare ?? placemark.locality
    }
}
```

- [ ] **Step 2: Commit**
```bash
git add Aura/Sources/Ride/ReverseGeocoder.swift
git commit -m "feat(ride): app-target CLGeocoder reverse-geocode wrapper (ROH-60)"
```
- [ ] **Step 3:** Controller build-verify (builder agent) after E3.

---

### Task E2: `MarkSpotToast` (confirmation + Undo)

**Files:**
- Create: `Aura/Sources/Ride/MarkSpotToast.swift`

**Interfaces:**
- Produces: a small SwiftUI overlay view `MarkSpotToast(message: String, onUndo: () -> Void, onDismiss: () -> Void)` — a pill with "Spot saved" + an "Undo" button; auto-dismisses after ~4 s (respecting Reduce Motion for its transition). Styled with `AuraTheme`. Consumed by E3 (RideHUDView).

- [ ] **Step 1: Implement** — a self-dismissing pill (mirror `GemPeekCard`'s self-dismiss + AuraTheme tokens; read that file for the pattern). Include:
  - `@Environment(\.accessibilityReduceMotion) private var reduceMotion`
  - transition `.opacity` when `reduceMotion`, else `.move(edge:.top).combined(with:.opacity)`.
  - VoiceOver: the toast is one element labeled "Spot saved. Double-tap Undo to remove."; the Undo button is a child action.
  - a `.task`/timer that calls `onDismiss()` after 4 s.

- [ ] **Step 2: Commit**
```bash
git add Aura/Sources/Ride/MarkSpotToast.swift
git commit -m "feat(ride): mark-spot confirmation toast with Undo (ROH-60)"
```

---

### Task E3: Cockpit mark-this-spot control + wiring

**Files:**
- Modify: `Aura/Sources/Ride/ControlCluster.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift`

**Interfaces:**
- Consumes: `SavedPlacesStore.save(_:subtitle:resurface:)` (B3), `SavedPlacesStore.updateName(...)` (B3), `ReverseGeocoder` (E1), `MarkSpotToast` (E2), `GemDiscoveryStore.riderCoordinate` (D1).
- Produces: a "mark this spot" button in the cockpit that is **not adjacent to End Ride**, disabled until `riderCoordinate != nil`; tapping saves a resurface place + fires a soft haptic + shows `MarkSpotToast`.

- [ ] **Step 1: Implement**
  - `ControlCluster`: add an `onMarkSpot: (() -> Void)?` (nil-hideable) parameter and render a button (SF Symbol `mappin.and.ellipse`) **separated** from the End-Ride button — put mark-spot at the top of the cluster (recenter/mark grouped) with End Ride visually spaced below (extra spacing / divider), so a fat-finger for End never lands on mark. Disable when `onMarkSpot == nil`.
  - `RideHUDView`: build a `SavedPlacesStore` (env or lazily like the gem store); pass `onMarkSpot` that:
    1. guards `let coordinate = gemStore.riderCoordinate`.
    2. `let outcome = savedPlacesStore.save(Place(id: UUID(), name: "Marked spot", subtitle: nil, coordinate: coordinate, category: .custom), subtitle: nil, resurface: true)`.
    3. on `.saved(place)`: fire `HapticPlayer.shared` soft impact; set `@State markToast = ToastState(id: place.id)`; kick off `Task { if let name = await ReverseGeocoder.name(for: coordinate) { savedPlacesStore.updateName(id: place.id, to: name, ifCurrentlyNamed: "Marked spot") } }`.
    4. on `.full`: show the existing "saved places full" affordance.
  - Overlay `MarkSpotToast` when `markToast != nil`, with `onUndo: { savedPlacesStore.delete(id: place.id); markToast = nil }` and `onDismiss: { markToast = nil }`.
  - Feed the store's clock: ensure `RideDiscoverySink` still feeds `update(at:now: point.timestamp)` (unchanged) — the D1 store auto-loads on first fix, so remove any eager `store.load()` in `.task` if present (or leave it; it's now a guarded no-op).

- [ ] **Step 2: Commit**
```bash
git add Aura/Sources/Ride/ControlCluster.swift Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(ride): one-tap mark-this-spot control (separated from End Ride) + geocode backfill (ROH-60)"
```
- [ ] **Step 3:** Controller build-verify (builder agent): app compiles for the sim.

---

### Task E4: `GemDetailSheet` "Save to return"

**Files:**
- Modify: `Aura/Sources/Ride/GemDetailSheet.swift`

**Interfaces:**
- Consumes: `SavedPlacesStore` (B3).
- Produces: a "Save to return" button (below "why", above "Take me there") that saves the gem's coordinate/name as a resurface place; idempotent — if already saved-as-resurface (match by `SavedPlaceKey`) it reads "Saved to return" and is disabled.

- [ ] **Step 1: Implement**
  - Add `onSaveToReturn: () -> Void` and `isSavedToReturn: Bool` inputs to `GemDetailSheet`.
  - Render the button between the `why` block and the "Take me there" CTA; when `isSavedToReturn`, show a checkmark label "Saved to return" (disabled).
  - In `RideHUDView`'s detail-sheet presentation, wire `onSaveToReturn` to `savedPlacesStore.save(Place(id: UUID(), name: gem.name, subtitle: nil, coordinate: gem.coordinate, category: .custom), subtitle: nil, resurface: true)` and compute `isSavedToReturn` from `savedPlacesStore.isSaved(...)` on that coordinate.

- [ ] **Step 2: Commit**
```bash
git add Aura/Sources/Ride/GemDetailSheet.swift Aura/Sources/Ride/RideHUDView.swift
git commit -m "feat(ride): GemDetailSheet Save-to-return creates a Tier-3 resurface place (ROH-60)"
```
- [ ] **Step 3:** Controller build-verify.

---

### Task E5: Source-differentiated pins/cards + OSM label + a11y

**Files:**
- Modify: `Aura/Sources/Ride/GemPinView.swift`
- Modify: `Aura/Sources/Ride/GemPeekCard.swift`

**Interfaces:**
- Produces: pin/card styling keyed on `Gem.source` — curated/personal full-strength; **live** quieter (dimmer/hollow) + an OSM source label on the peek card (ODbL attribution). Plus the deferred a11y items.

- [ ] **Step 1: Implement**
  - `GemPinView`: branch styling on `gem.source == .live` (lower opacity / hollow fill / a small "map" glyph) vs curated/personal (current full-strength). Remove any `@Environment(\.colorSchemeContrast)`-conditional hairline — use a fixed `.standard`-width stroke.
  - Gate every gem `.animation(...)` on `@Environment(\.accessibilityReduceMotion)` (no animation when true; state still changes).
  - `GemPeekCard`: when `gem.source == .live`, show a small footnote label "via OpenStreetMap". Announce the card **politely** (`.accessibilityAddTraits(.updatesFrequently)` is wrong here — instead post a polite announcement or rely on the durable pin; ensure the card is not the sole accessible element). Compose the card as one VoiceOver element (name + category + distance) with the durable pin remaining independently focusable.

- [ ] **Step 2: Commit**
```bash
git add Aura/Sources/Ride/GemPinView.swift Aura/Sources/Ride/GemPeekCard.swift
git commit -m "feat(ride): source-differentiated gem pins/cards + OSM attribution + reduceMotion/hairline a11y (ROH-60)"
```
- [ ] **Step 3:** Controller build-verify.

---

### Task E6: Saved Places resurface indicator + "Stop returning here" menu

**Files:**
- Modify: `Aura/Sources/Plan/SavedPlaceRow.swift`

**Interfaces:**
- Consumes: `SavedPlace.resurface` (A4), `SavedPlacesStore.setResurface(id:_:)` (B3).
- Produces: a subtle gem indicator + hint ("Resurfaces when you ride past") when `resurface == true`, and a menu item **"Stop returning here"** (and, when off, "Return here") in addition to a swipe action; both call `setResurface`.

- [ ] **Step 1: Implement**
  - In `SavedPlaceRow`, when `saved.resurface`, render a small gem glyph + subtitle hint.
  - Add to the row's existing menu (the ellipsis): `if saved.resurface { Button("Stop returning here", systemImage: "mappin.slash") { onSetResurface(false) } } else { Button("Return here", systemImage: "mappin.and.ellipse") { onSetResurface(true) } }`.
  - Add a matching leading/trailing swipe action.
  - Thread `onSetResurface: (Bool) -> Void` from the list container down to the row, wired to `savedPlacesStore.setResurface(id: saved.id, $0)`.

- [ ] **Step 2: Commit**
```bash
git add Aura/Sources/Plan/SavedPlaceRow.swift
git commit -m "feat(places): resurface indicator + Stop-returning-here menu/swipe in Saved Places (ROH-60)"
```
- [ ] **Step 3:** Controller build-verify.

---

## Phase F — Plan-3 minors

### Task F1: `GuidanceController.cacheKey` cos(lat) scaling

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Gems/Detour/GuidanceController.swift:108-113`
- Test: `AuraCore/Tests/AuraKitTests/GuidanceCacheKeyTests.swift` (create; the method is `private` — either make it `internal` for `@testable` or test via observable caching behavior. Prefer marking it `internal`.)

**Interfaces:**
- Produces: `cacheKey` longitude quantization scaled by `cos(lat)` so the ~25 m grid holds east–west at latitude (the comment becomes true).

- [ ] **Step 1: Write the failing test** (make `cacheKey` `internal`; verify two points ~25 m apart east–west at 40° share a key, and a point far east does not)
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite("Guidance cacheKey")
struct GuidanceCacheKeyTests {
    @Test func longitudeQuantizationScalesByCosLat() {
        let controller = GuidanceController(/* existing required deps — mirror an existing GuidanceController test's setup */)
        let a = Coordinate(latitude: 40.0, longitude: -79.9900)
        let b = Coordinate(latitude: 40.0, longitude: -79.9899)   // ~8.5 m east at 40°
        #expect(controller.cacheKey("g", a) == controller.cacheKey("g", b))
        let far = Coordinate(latitude: 40.0, longitude: -79.9800)  // ~850 m east
        #expect(controller.cacheKey("g", a) != controller.cacheKey("g", far))
    }
}
```
(The implementer copies the `GuidanceController` init from an existing test in the AuraKitTests detour suite.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter GuidanceCacheKeyTests`
Expected: FAIL (either doesn't compile until `internal`, or the far point currently collides/does not as expected).

- [ ] **Step 3: Implement** — change `cacheKey` to scale longitude by `cos(lat)`:
```swift
    func cacheKey(_ gemID: String, _ origin: Coordinate) -> String {
        // ~25 m quantization: ~0.00025° lat; longitude scaled by cos(lat) so the cell
        // stays ~square east–west at higher latitudes.
        let latQuantum = 0.00025
        let lat = (origin.latitude / latQuantum).rounded()
        let lonScale = max(cos(origin.latitude * .pi / 180), 0.01)
        let lng = (origin.longitude * lonScale / latQuantum).rounded()
        return "\(gemID)@\(Int(lat)),\(Int(lng))"
    }
```
(Drop `private` → `internal`. Keep the existing call sites unchanged.)

- [ ] **Step 4: Run to verify it passes** (+ existing detour suite unaffected)

Run: `swift test --package-path AuraCore --filter Guidance`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add AuraCore/Sources/AuraKit/Gems/Detour/GuidanceController.swift AuraCore/Tests/AuraKitTests/GuidanceCacheKeyTests.swift
git commit -m "fix(detour): cacheKey scales longitude by cos(lat) as documented (ROH-60)"
```

---

### Task F2: `networkRecovered` end-to-end test

**Files:**
- Test: `AuraCore/Tests/AuraKitTests/GuidanceNetworkRecoveryTests.swift` (create)
- Possibly Modify: `GuidanceController.swift` only if a seam is missing to drive the recovery deterministically.

**Interfaces:**
- Consumes: the existing `GuidanceController` offline/`headingOnly` path + `probeNetworkRecovery` fix-count throttle.
- Produces: an e2e test: start guidance → routing fails (offline) → controller enters `headingOnly` → feed the throttle's worth of fixes with the routing seam now succeeding → controller upgrades to full guidance.

- [ ] **Step 1: Read the detour suite** to learn the existing `GuidanceController` test doubles (`DetourRouting` stub, `HeadingProviding` stub, the `awaitState { }` helper from Plan 3). Reuse them — do **not** invent new sleep-based barriers.

- [ ] **Step 2: Write the test** — model it on the existing offline test, but flip the routing stub from failing to succeeding after N fixes and assert the phase upgrades. Use the `awaitState`/`pendingRoutingTask` helper for synchronization, never wall-clock `Task.sleep` as a barrier.
```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite("Guidance network recovery")
struct GuidanceNetworkRecoveryTests {
    @Test func headingOnlyUpgradesToFullGuidanceOnRecovery() async {
        // 1. Build a GuidanceController with a routing stub that FAILS initially (mirror the
        //    existing offline test's construction + the awaitState helper).
        // 2. Request a detour → assert phase == .headingOnly.
        // 3. Flip the stub to SUCCEED; feed `probeNetworkRecovery`'s throttle count of rider updates.
        // 4. await the controller's pendingRoutingTask (awaitState) → assert phase == .guiding.
    }
}
```
(The implementer fills the body using the concrete doubles found in Step 1; the assertions above are the contract.)

- [ ] **Step 3: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter GuidanceNetworkRecovery`
Expected: PASS (deterministic, no flake under the full suite).

- [ ] **Step 4: Commit**
```bash
git add AuraCore/Tests/AuraKitTests/GuidanceNetworkRecoveryTests.swift
git commit -m "test(detour): e2e networkRecovered headingOnly→guiding upgrade (ROH-60)"
```

---

## Phase G — Integration, whole-branch, device

### Task G1: Full package test + app build

- [ ] Controller runs `swift test --package-path AuraCore` (all suites green) via the builder agent.
- [ ] Controller runs the app build (`xcodegen generate` if needed + `xcodebuild` for the sim) via the builder agent; resolve any app-target integration gaps (env-injected `SavedPlacesStore`, closures wired).
- [ ] Commit any integration fixups.

### Task G2: Opus whole-branch review → PR → device-verify

- [ ] Opus whole-branch review (separate skill invocation).
- [ ] Open PR; ensure CI (AuraCore tests, App build, pgTAP, SwiftLint --strict) is green.
- [ ] Device-verify on the real iPhone via the route-playback recipe: (a) live-feed pins appear outside the curated metro; (b) mark-this-spot → toast + Undo, resurface place behaves as a Tier-3 gem next pass; (c) **Plan-3 tails**: hand-feel detour arrival + turn haptics (AirPods off); airplane-mode a detour → offline compass pointer rotates + "Offline · approximate direction" affordance + recovery/upgrade; (d) decide CTA vertical padding 8 vs 14 on device and apply.

---

## Self-Review

**Spec coverage:** resurface field + V5 (A4/B1/B2/B3) ✓; mark-this-spot + geocode + toast/undo (E1/E2/E3) ✓; Save-to-return (E4) ✓; Saved-Places indicator+toggle (E6) ✓; PersonalGemProvider (C2) + seam (C1) ✓; LiveGemProvider/OSM (C3/C4) + region cache (C5) ✓; CompositeGemProvider dedupe+timeout (C6) ✓; load() deferral + timestamp (D1) ✓; arbitration (A1/A2) ✓; a11y hairline/reduceMotion/VoiceOver + source differentiation (E5) ✓; cacheKey (F1) + networkRecovered (F2) ✓; device-verify tails (G2) ✓.

**Reconciliation coverage:** arbitration explicit tuple (A2) ✓; coordinate-proximity dedupe (C6) ✓; composite timeout (C6) ✓; load-once + sample-timestamp (D1) ✓; V5 redeclare (B1) ✓; backfill-safe updateName (B3, wired E3) ✓; mark-spot separated + Undo (E2/E3) ✓; source differentiation + OSM attribution (E5) ✓; resurface menu (E6) ✓; detour snapshot (D1) + SeenGemStore hardening (D2) ✓. Deferred by judgment call: cross-ride resurface throttle (documented in spec).

**Type consistency:** `save(_:subtitle:resurface:)`, `setResurface(id:_:)`, `updateName(id:to:ifCurrentlyNamed:)`, `resurfacePlaces()`, `priorityRank`, `OSMGemMapping.gem(id:name:coordinate:tags:)`, `CompositeGemProvider(local:live:dedupeMeters:timeout:)`, `GemRegionCache.gems(near:now:fetch:)` — names are consistent across producer/consumer blocks.

**Placeholder scan:** app-target UI steps (E-phase) intentionally describe integration against files the implementer reads (SwiftUI, no unit test), but every logic/persistence/provider task carries complete code + exact test + commands. F2's test body is a contract with a documented reason (reuses existing test doubles the implementer must read).
