# Saved Places Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A rider saves a destination once (Home or a favorite) and reaches it in
two taps from the plan screen, synced per-record through the existing CloudKit
container. Spec: `docs/superpowers/specs/2026-07-01-saved-places-design.md`.

**Architecture:** Pure value type + invariant logic + matcher in `AuraCore`;
`SavedPlaceRecord` added to the SwiftData schema as `RideSchemaV3` (lightweight
stage) with a `@MainActor @Observable` `SavedPlacesStore` in `AuraKit`; app-target
UI on `RoutePreviewView` (star + Set-as-Home moment), `PlanView` (Saved section,
Recents filter), and `DestinationSearchView` (pinned matches while typing).

**Tech Stack:** Swift 6, SwiftData (+CloudKit private db mirror), SwiftUI, Swift
Testing for new suites, XcodeGen, SwiftLint `--strict`.

## Global Constraints

- Execute on a fresh branch off updated local `main` (branch-reuse caused a
  ROADMAP conflict once; don't repeat it). Suggested: `claude/saved-places`.
- `AuraCore` sources: no UIKit/SwiftUI/SwiftData/Mapbox imports. `AuraKit`: no
  UIKit/SwiftUI; SwiftData allowed (RideStore precedent). Both must build on the
  macOS CI host: `cd AuraCore && swift test`.
- New test suites use Swift Testing (`import Testing`, `@Test`, `#expect`).
  Core-layer suites (Tasks 1-4) live in `AuraCore/Tests/AuraCoreTests/`;
  kit-layer suites that import AuraKit (Tasks 5-6) live in
  `AuraCore/Tests/AuraKitTests/` — `AuraCoreTests` does not depend on AuraKit
  and cannot import it.
- CloudKit model rules (all enforced by Task 5's guard tests): every attribute
  optional or defaulted, no `@Attribute(.unique)`, no relationships. Date
  defaults use the fixed epoch sentinel, never `.now` (see `RideSchemaV2`
  comment).
- No `Date()` inside pure `AuraCore` logic — inject `now:` parameters.
- SwiftLint `--strict` gates: line length warn 140 / error 200; run
  `swiftlint lint --strict` from the repo root before each commit.
- App builds: regenerate the project first (`cd Aura && xcodegen generate`),
  then `xcodebuild -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build`.
  Prefer delegating build/test/simulator steps to the
  `apple-platform-build-tools:builder` agent to keep logs out of context.
- Commit conventions: `feat(core):` / `feat(kit):` / `feat(app):` /
  `test(...)` / `docs(roadmap):`, present tense, with the standard co-author
  trailer.
- UI copy is exact: "Save place", "Saved"/"Not saved", "Set as Home",
  "Previous Home kept as a favorite", "Saved places is full. Remove one to
  save another.", section headers "Saved" / "Recents".

---

### Task 1: `SavedPlace` value type + `Place.subtitle`

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/SavedPlace.swift`
- Modify: `AuraCore/Sources/AuraCore/Models/Place.swift` (add `subtitle`)
- Test: `AuraCore/Tests/AuraCoreTests/SavedPlaceTests.swift`

**Interfaces:**
- Consumes: `Place`, `Coordinate` (existing).
- Produces: `SavedPlace` (`id: UUID`, `name: String`, `subtitle: String?`,
  `coordinate: Coordinate`, `category: Place.Category`, `kind: SavedPlace.Kind`
  (`.home`/`.favorite`), `savedAt: Date`); `SavedPlace.init(place:subtitle:kind:savedAt:)`;
  `var place: Place` (carries the saved `id`, `isSaved: true`);
  `Place.subtitle: String?` (new optional field, defaults nil).

- [ ] **Step 1: Write the failing tests**

```swift
// AuraCore/Tests/AuraCoreTests/SavedPlaceTests.swift
import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlace")
struct SavedPlaceTests {
    private let coordinate = Coordinate(latitude: 40.4406, longitude: -79.9959)

    @Test func initFromPlaceCarriesFields() {
        let place = Place(name: "Trace Brewing", coordinate: coordinate, category: .brewery)
        let saved = SavedPlace(place: place, subtitle: "4312 Main St, Pittsburgh",
                               kind: .favorite, savedAt: Date(timeIntervalSince1970: 100))
        #expect(saved.id == place.id)
        #expect(saved.name == "Trace Brewing")
        #expect(saved.subtitle == "4312 Main St, Pittsburgh")
        #expect(saved.coordinate == coordinate)
        #expect(saved.category == .brewery)
        #expect(saved.kind == .favorite)
    }

    @Test func placeConversionSetsIsSavedAndKeepsID() {
        let saved = SavedPlace(id: UUID(), name: "Home base", subtitle: nil,
                               coordinate: coordinate, category: .address,
                               kind: .home, savedAt: .init(timeIntervalSince1970: 0))
        let place = saved.place
        #expect(place.id == saved.id)
        #expect(place.isSaved)
        #expect(place.name == "Home base")
        #expect(place.subtitle == nil)
    }

    @Test func placeDecodesLegacyJSONWithoutSubtitle() throws {
        // Recents persisted before this change have no `subtitle` key.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Point State Park",
         "coordinate":{"latitude":40.4418,"longitude":-80.0134},
         "category":"trailhead","isSaved":false}
        """.data(using: .utf8)!
        let place = try JSONDecoder().decode(Place.self, from: json)
        #expect(place.subtitle == nil)
    }

    @Test func savedPlaceRoundTripsThroughJSON() throws {
        let saved = SavedPlace(id: UUID(), name: "Cafe", subtitle: "Butler St",
                               coordinate: coordinate, category: .custom,
                               kind: .favorite, savedAt: Date(timeIntervalSince1970: 42))
        let data = try JSONEncoder().encode(saved)
        let back = try JSONDecoder().decode(SavedPlace.self, from: data)
        #expect(back == saved)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --filter SavedPlaceTests`
Expected: compile FAILURE — `SavedPlace` not defined, `Place` has no `subtitle`.

- [ ] **Step 3: Implement**

Add to `Place` (keep every existing member; `subtitle` sits after `name`):

```swift
// In Place.swift, inside Place:
public var subtitle: String?
```

and extend the memberwise init with `subtitle: String? = nil` (defaulted, so no
call site changes):

```swift
public init(id: UUID = UUID(), name: String, subtitle: String? = nil,
            coordinate: Coordinate, category: Category, isSaved: Bool = false) {
    self.id = id; self.name = name; self.subtitle = subtitle
    self.coordinate = coordinate; self.category = category; self.isSaved = isSaved
}
```

`subtitle` is optional, so legacy JSON (recents) decodes with `nil` — no custom
`Codable` needed.

```swift
// AuraCore/Sources/AuraCore/Models/SavedPlace.swift
import Foundation

/// A rider-saved destination: Home or a favorite. Persisted as
/// `SavedPlaceRecord` (AuraKit) and mirrored per-record through CloudKit.
public struct SavedPlace: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case home, favorite
    }

    public var id: UUID
    public var name: String
    /// The search result's address/context line, shown in lists for provenance.
    public var subtitle: String?
    public var coordinate: Coordinate
    public var category: Place.Category
    public var kind: Kind
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, subtitle: String?,
                coordinate: Coordinate, category: Place.Category,
                kind: Kind, savedAt: Date) {
        self.id = id; self.name = name; self.subtitle = subtitle
        self.coordinate = coordinate; self.category = category
        self.kind = kind; self.savedAt = savedAt
    }

    /// Save a picked place. Keeps the place's id so a row pushed back into
    /// navigation matches by id, not just coordinate.
    public init(place: Place, subtitle: String? = nil,
                kind: Kind = .favorite, savedAt: Date) {
        self.init(id: place.id, name: place.name,
                  subtitle: subtitle ?? place.subtitle,
                  coordinate: place.coordinate, category: place.category,
                  kind: kind, savedAt: savedAt)
    }

    /// The navigable place, flagged saved.
    public var place: Place {
        Place(id: id, name: name, subtitle: subtitle,
              coordinate: coordinate, category: category, isSaved: true)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter SavedPlaceTests`
Expected: 4 tests PASS. Then run the full suite (`swift test`) — the `Place`
init change is source-compatible, everything stays green.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models/SavedPlace.swift \
        AuraCore/Sources/AuraCore/Models/Place.swift \
        AuraCore/Tests/AuraCoreTests/SavedPlaceTests.swift
git commit -m "feat(core): SavedPlace value type + Place.subtitle"
```

---

### Task 2: `SavedPlaceKey` rounded-coordinate identity

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/SavedPlaceKey.swift`
- Test: `AuraCore/Tests/AuraCoreTests/SavedPlaceKeyTests.swift`

**Interfaces:**
- Produces: `SavedPlaceKey: Hashable, Sendable` with `init(_ coordinate:
  Coordinate)` — latitude/longitude rounded to 5 decimals (~1.1 m) as `Int`
  micro-degree buckets (`latE5`, `lonE5`).

- [ ] **Step 1: Write the failing tests**

```swift
// AuraCore/Tests/AuraCoreTests/SavedPlaceKeyTests.swift
import Testing
@testable import AuraCore

@Suite("SavedPlaceKey")
struct SavedPlaceKeyTests {
    @Test func identicalCoordinatesShareKey() {
        let a = SavedPlaceKey(Coordinate(latitude: 40.4406, longitude: -79.9959))
        let b = SavedPlaceKey(Coordinate(latitude: 40.4406, longitude: -79.9959))
        #expect(a == b)
    }

    @Test func subMeterJitterSharesKey() {
        // 6th-decimal noise (~0.1 m) must not defeat identity — the two Mapbox
        // resolution paths are not guaranteed bit-identical.
        let a = SavedPlaceKey(Coordinate(latitude: 40.440601, longitude: -79.995899))
        let b = SavedPlaceKey(Coordinate(latitude: 40.440599, longitude: -79.995901))
        #expect(a == b)
    }

    @Test func distinctPlacesDiffer() {
        let a = SavedPlaceKey(Coordinate(latitude: 40.4406, longitude: -79.9959))
        let b = SavedPlaceKey(Coordinate(latitude: 40.4418, longitude: -80.0134))
        #expect(a != b)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --filter SavedPlaceKeyTests`
Expected: compile FAILURE — `SavedPlaceKey` not defined.

- [ ] **Step 3: Implement**

```swift
// AuraCore/Sources/AuraCore/Models/SavedPlaceKey.swift
import Foundation

/// Identity for "is this spot already saved": coordinates bucketed at 5
/// decimal places (~1.1 m). Never compare raw Doubles across Mapbox code
/// paths — the RouteRanker sourceIndex fix is the precedent.
public struct SavedPlaceKey: Hashable, Sendable {
    public let latE5: Int
    public let lonE5: Int

    public init(_ coordinate: Coordinate) {
        latE5 = Int((coordinate.latitude * 100_000).rounded())
        lonE5 = Int((coordinate.longitude * 100_000).rounded())
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter SavedPlaceKeyTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models/SavedPlaceKey.swift \
        AuraCore/Tests/AuraCoreTests/SavedPlaceKeyTests.swift
git commit -m "feat(core): rounded-coordinate SavedPlaceKey identity"
```

---

### Task 3: `SavedPlacesLogic` invariants + reconcile

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/SavedPlacesLogic.swift`
- Test: `AuraCore/Tests/AuraCoreTests/SavedPlacesLogicTests.swift`

**Interfaces:**
- Consumes: `SavedPlace`, `SavedPlaceKey`, `Place` (Tasks 1-2).
- Produces (all static, all pure):
  - `SavedPlacesLogic.maxCount: Int` (50)
  - `enum AddOutcome: Equatable { case added([SavedPlace]), full }`
  - `add(_ place: Place, subtitle: String?, to list: [SavedPlace], now: Date) -> AddOutcome`
  - `remove(id: UUID, from list: [SavedPlace]) -> [SavedPlace]`
  - `rename(id: UUID, to name: String, in list: [SavedPlace]) -> [SavedPlace]`
  - `setHome(id: UUID, in list: [SavedPlace], now: Date) -> [SavedPlace]`
  - `removeHome(id: UUID, in list: [SavedPlace]) -> [SavedPlace]`
  - `reconciled(_ list: [SavedPlace]) -> [SavedPlace]` (sorted: Home first,
    then `savedAt` descending)
  - `saved(matching place: Place, in list: [SavedPlace]) -> SavedPlace?`
  - `isSaved(_ place: Place, in list: [SavedPlace]) -> Bool`

- [ ] **Step 1: Write the failing tests**

```swift
// AuraCore/Tests/AuraCoreTests/SavedPlacesLogicTests.swift
import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlacesLogic")
struct SavedPlacesLogicTests {
    private func coord(_ lat: Double, _ lon: Double) -> Coordinate {
        Coordinate(latitude: lat, longitude: lon)
    }
    private func favorite(_ name: String, lat: Double, lon: Double,
                          savedAt: TimeInterval, kind: SavedPlace.Kind = .favorite) -> SavedPlace {
        SavedPlace(name: name, subtitle: nil, coordinate: coord(lat, lon),
                   category: .custom, kind: kind,
                   savedAt: Date(timeIntervalSince1970: savedAt))
    }
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func addAppendsAsFavorite() {
        let place = Place(name: "Trace", coordinate: coord(40.44, -79.99), category: .brewery)
        guard case let .added(list) = SavedPlacesLogic.add(place, subtitle: "Butler St",
                                                           to: [], now: now) else {
            Issue.record("expected .added"); return
        }
        #expect(list.count == 1)
        #expect(list[0].kind == .favorite)
        #expect(list[0].subtitle == "Butler St")
        #expect(list[0].savedAt == now)
    }

    @Test func addAtSameKeyReplacesAdoptingNewName() {
        let existing = favorite("Old Name", lat: 40.44060, lon: -79.99590, savedAt: 1)
        let place = Place(name: "New Name", coordinate: coord(40.440601, -79.995899),
                          category: .custom)
        guard case let .added(list) = SavedPlacesLogic.add(place, subtitle: "New St",
                                                           to: [existing], now: now) else {
            Issue.record("expected .added"); return
        }
        #expect(list.count == 1)
        #expect(list[0].name == "New Name")        // collapse adopts newest name
        #expect(list[0].subtitle == "New St")
        #expect(list[0].id == existing.id)          // identity is stable
        #expect(list[0].kind == existing.kind)      // kind survives a re-save
    }

    @Test func addRefusesBeyondCap() {
        let full = (0..<SavedPlacesLogic.maxCount).map {
            favorite("P\($0)", lat: 40.0 + Double($0) * 0.001, lon: -79.9, savedAt: Double($0))
        }
        let place = Place(name: "One more", coordinate: coord(41.0, -79.0), category: .custom)
        #expect(SavedPlacesLogic.add(place, subtitle: nil, to: full, now: now) == .full)
    }

    @Test func reSaveAtCapIsNotRefused() {
        // Replacing an existing key must not trip the cap.
        let full = (0..<SavedPlacesLogic.maxCount).map {
            favorite("P\($0)", lat: 40.0 + Double($0) * 0.001, lon: -79.9, savedAt: Double($0))
        }
        let place = Place(name: "P0 renamed", coordinate: coord(40.0, -79.9), category: .custom)
        guard case .added = SavedPlacesLogic.add(place, subtitle: nil, to: full, now: now) else {
            Issue.record("re-save at cap must succeed"); return
        }
    }

    @Test func setHomeDemotesPreviousAndRefreshesItsSavedAt() {
        let oldHome = favorite("Old home", lat: 40.1, lon: -79.1, savedAt: 1, kind: .home)
        let target = favorite("New home", lat: 40.2, lon: -79.2, savedAt: 2)
        let list = SavedPlacesLogic.setHome(id: target.id, in: [oldHome, target], now: now)
        let home = list.first { $0.kind == .home }
        let demoted = list.first { $0.id == oldHome.id }
        #expect(home?.id == target.id)
        #expect(demoted?.kind == .favorite)
        #expect(demoted?.savedAt == now)   // surfaces at top of favorites
    }

    @Test func removeHomeMakesFavorite() {
        let home = favorite("Home", lat: 40.1, lon: -79.1, savedAt: 1, kind: .home)
        let list = SavedPlacesLogic.removeHome(id: home.id, in: [home])
        #expect(list[0].kind == .favorite)
    }

    @Test func renameTrimsAndIgnoresEmpty() {
        let item = favorite("Old", lat: 40.1, lon: -79.1, savedAt: 1)
        #expect(SavedPlacesLogic.rename(id: item.id, to: "  New  ", in: [item])[0].name == "New")
        #expect(SavedPlacesLogic.rename(id: item.id, to: "   ", in: [item])[0].name == "Old")
    }

    @Test func reconciledDropsIDDoublesKeepingNewest() {
        let id = UUID()
        var a = favorite("A", lat: 40.1, lon: -79.1, savedAt: 1); a.id = id
        var b = favorite("A latest", lat: 40.1, lon: -79.1, savedAt: 9); b.id = id
        let list = SavedPlacesLogic.reconciled([a, b])
        #expect(list.count == 1)
        #expect(list[0].name == "A latest")
    }

    @Test func reconciledCollapsesKeyDoublesKeepingNewest() {
        let a = favorite("First", lat: 40.44060, lon: -79.99590, savedAt: 1)
        let b = favorite("Second", lat: 40.440601, lon: -79.995899, savedAt: 9)
        let list = SavedPlacesLogic.reconciled([a, b])
        #expect(list.count == 1)
        #expect(list[0].name == "Second")
    }

    @Test func reconciledKeepsSingleNewestHomeAndSortsHomeFirst() {
        let homeA = favorite("Home A", lat: 40.1, lon: -79.1, savedAt: 5, kind: .home)
        let homeB = favorite("Home B", lat: 40.2, lon: -79.2, savedAt: 9, kind: .home)
        let fav = favorite("Fav", lat: 40.3, lon: -79.3, savedAt: 99)
        let list = SavedPlacesLogic.reconciled([fav, homeA, homeB])
        #expect(list.filter { $0.kind == .home }.count == 1)
        #expect(list[0].kind == .home)
        #expect(list[0].name == "Home B")           // newest savedAt wins Home
        #expect(list[1].name == "Fav")              // favorites by savedAt desc
    }

    @Test func savedMatchingByIDThenKey() {
        let saved = favorite("Cafe", lat: 40.44060, lon: -79.99590, savedAt: 1)
        // Fresh UUID (search mints one) but jittered-same coordinate → key match.
        let searchPick = Place(name: "Cafe", coordinate: coord(40.440601, -79.995899),
                               category: .custom)
        #expect(SavedPlacesLogic.saved(matching: searchPick, in: [saved])?.id == saved.id)
        #expect(SavedPlacesLogic.isSaved(searchPick, in: [saved]))
        let elsewhere = Place(name: "Cafe", coordinate: coord(41.0, -79.0), category: .custom)
        #expect(!SavedPlacesLogic.isSaved(elsewhere, in: [saved]))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --filter SavedPlacesLogicTests`
Expected: compile FAILURE — `SavedPlacesLogic` not defined.

- [ ] **Step 3: Implement**

```swift
// AuraCore/Sources/AuraCore/Models/SavedPlacesLogic.swift
import Foundation

/// Every saved-places invariant, pure: the store persists what these return.
public enum SavedPlacesLogic {
    public static let maxCount = 50

    public enum AddOutcome: Equatable {
        case added([SavedPlace])
        case full
    }

    /// Adds as a favorite. Re-saving an existing spot (same key) replaces it,
    /// adopting the newest name/subtitle while keeping id and kind — and is
    /// exempt from the cap.
    public static func add(_ place: Place, subtitle: String?,
                           to list: [SavedPlace], now: Date) -> AddOutcome {
        let key = SavedPlaceKey(place.coordinate)
        if let index = list.firstIndex(where: {
            $0.id == place.id || SavedPlaceKey($0.coordinate) == key
        }) {
            var updated = list[index]
            updated.name = place.name
            updated.subtitle = subtitle ?? place.subtitle ?? updated.subtitle
            updated.coordinate = place.coordinate
            updated.category = place.category
            updated.savedAt = now
            var next = list
            next[index] = updated
            return .added(next)
        }
        guard list.count < maxCount else { return .full }
        return .added(list + [SavedPlace(place: place, subtitle: subtitle,
                                         kind: .favorite, savedAt: now)])
    }

    public static func remove(id: UUID, from list: [SavedPlace]) -> [SavedPlace] {
        list.filter { $0.id != id }
    }

    /// Trims whitespace; an empty result is a no-op (the UI also guards).
    public static func rename(id: UUID, to name: String,
                              in list: [SavedPlace]) -> [SavedPlace] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        return list.map { item in
            guard item.id == id else { return item }
            var next = item
            next.name = trimmed
            return next
        }
    }

    /// The previous Home demotes to a favorite with `savedAt` refreshed, so it
    /// surfaces at the top of favorites instead of sinking into date order.
    public static func setHome(id: UUID, in list: [SavedPlace], now: Date) -> [SavedPlace] {
        list.map { item in
            var next = item
            if item.id == id {
                next.kind = .home
            } else if item.kind == .home {
                next.kind = .favorite
                next.savedAt = now
            }
            return next
        }
    }

    public static func removeHome(id: UUID, in list: [SavedPlace]) -> [SavedPlace] {
        list.map { item in
            guard item.id == id, item.kind == .home else { return item }
            var next = item
            next.kind = .favorite
            return next
        }
    }

    /// Read-side pass that absorbs CloudKit merge artifacts: id doubles
    /// (backup-restore), key doubles (two devices saving one spot), and a
    /// two-Home merge. Keeps the newest of each; never writes back — the next
    /// genuine mutation persists the reconciled list. Sorted Home-first, then
    /// savedAt descending.
    public static func reconciled(_ list: [SavedPlace]) -> [SavedPlace] {
        var byID: [UUID: SavedPlace] = [:]
        for item in list where (byID[item.id].map { $0.savedAt <= item.savedAt } ?? true) {
            byID[item.id] = item
        }
        var byKey: [SavedPlaceKey: SavedPlace] = [:]
        for item in byID.values {
            let key = SavedPlaceKey(item.coordinate)
            if byKey[key].map({ $0.savedAt <= item.savedAt }) ?? true {
                byKey[key] = item
            }
        }
        var result = Array(byKey.values)
        let homes = result.filter { $0.kind == .home }.sorted { $0.savedAt > $1.savedAt }
        if homes.count > 1 {
            let winner = homes[0].id
            result = result.map { item in
                guard item.kind == .home, item.id != winner else { return item }
                var next = item
                next.kind = .favorite
                return next
            }
        }
        return result.sorted { a, b in
            if (a.kind == .home) != (b.kind == .home) { return a.kind == .home }
            return a.savedAt > b.savedAt
        }
    }

    public static func saved(matching place: Place,
                             in list: [SavedPlace]) -> SavedPlace? {
        if let byID = list.first(where: { $0.id == place.id }) { return byID }
        let key = SavedPlaceKey(place.coordinate)
        return list.first { SavedPlaceKey($0.coordinate) == key }
    }

    public static func isSaved(_ place: Place, in list: [SavedPlace]) -> Bool {
        saved(matching: place, in: list) != nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter SavedPlacesLogicTests`
Expected: 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models/SavedPlacesLogic.swift \
        AuraCore/Tests/AuraCoreTests/SavedPlacesLogicTests.swift
git commit -m "feat(core): SavedPlacesLogic invariants + CloudKit-merge reconcile"
```

---

### Task 4: `SavedPlaceMatcher` for search pinning

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/SavedPlaceMatcher.swift`
- Test: `AuraCore/Tests/AuraCoreTests/SavedPlaceMatcherTests.swift`

**Interfaces:**
- Consumes: `SavedPlace` (Task 1).
- Produces: `SavedPlaceMatcher.matches(query: String, in list: [SavedPlace],
  limit: Int = 3) -> [SavedPlace]` — case/diacritic-insensitive substring over
  `name` and `subtitle`; any prefix of "home" also matches the `.home` entry;
  results ordered Home first then `savedAt` descending; empty query → empty.

- [ ] **Step 1: Write the failing tests**

```swift
// AuraCore/Tests/AuraCoreTests/SavedPlaceMatcherTests.swift
import Testing
import Foundation
@testable import AuraCore

@Suite("SavedPlaceMatcher")
struct SavedPlaceMatcherTests {
    private func make(_ name: String, subtitle: String? = nil,
                      kind: SavedPlace.Kind = .favorite,
                      savedAt: TimeInterval = 0, lon: Double = -79.9) -> SavedPlace {
        SavedPlace(name: name, subtitle: subtitle,
                   coordinate: Coordinate(latitude: 40.4, longitude: lon),
                   category: .custom, kind: kind,
                   savedAt: Date(timeIntervalSince1970: savedAt))
    }

    @Test func substringCaseAndDiacriticInsensitive() {
        let list = [make("Café Colado", lon: -79.1)]
        #expect(SavedPlaceMatcher.matches(query: "cafe", in: list).count == 1)
        #expect(SavedPlaceMatcher.matches(query: "COLADO", in: list).count == 1)
        #expect(SavedPlaceMatcher.matches(query: "tavern", in: list).isEmpty)
    }

    @Test func matchesSubtitleToo() {
        let list = [make("Trace", subtitle: "Butler Street", lon: -79.2)]
        #expect(SavedPlaceMatcher.matches(query: "butler", in: list).count == 1)
    }

    @Test func homeKindMatchesHomeQueryPrefixes() {
        let list = [make("1284 Milton St", kind: .home, lon: -79.3)]
        for query in ["h", "ho", "hom", "home"] {
            #expect(SavedPlaceMatcher.matches(query: query, in: list).count == 1,
                    "query \(query) should match Home")
        }
        #expect(SavedPlaceMatcher.matches(query: "homes", in: list).isEmpty)
    }

    @Test func capsAtLimitHomeFirstThenNewest() {
        let list = [
            make("Alpha stop", savedAt: 1, lon: -79.1),
            make("Alpha park", savedAt: 3, lon: -79.2),
            make("Alpha cafe", savedAt: 2, lon: -79.3),
            make("Alpha home base", kind: .home, savedAt: 0, lon: -79.4)
        ]
        let hits = SavedPlaceMatcher.matches(query: "alpha", in: list)
        #expect(hits.count == 3)
        #expect(hits[0].kind == .home)
        #expect(hits[1].name == "Alpha park")
        #expect(hits[2].name == "Alpha cafe")
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(SavedPlaceMatcher.matches(query: "  ", in: [make("A")]).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --filter SavedPlaceMatcherTests`
Expected: compile FAILURE — `SavedPlaceMatcher` not defined.

- [ ] **Step 3: Implement**

```swift
// AuraCore/Sources/AuraCore/Models/SavedPlaceMatcher.swift
import Foundation

/// Pins saved places above Mapbox suggestions while the rider types.
public enum SavedPlaceMatcher {
    public static func matches(query: String, in list: [SavedPlace],
                               limit: Int = 3) -> [SavedPlace] {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !folded.isEmpty else { return [] }
        let hits = list.filter { item in
            if item.kind == .home, "home".hasPrefix(folded) { return true }
            let name = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                         locale: nil)
            if name.contains(folded) { return true }
            guard let subtitle = item.subtitle else { return false }
            return subtitle.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: nil).contains(folded)
        }
        let ordered = hits.sorted { a, b in
            if (a.kind == .home) != (b.kind == .home) { return a.kind == .home }
            return a.savedAt > b.savedAt
        }
        return Array(ordered.prefix(limit))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter SavedPlaceMatcherTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models/SavedPlaceMatcher.swift \
        AuraCore/Tests/AuraCoreTests/SavedPlaceMatcherTests.swift
git commit -m "feat(core): SavedPlaceMatcher for search pinning"
```

---

### Task 5: `RideSchemaV3` + `SavedPlaceRecord` + lightweight migration + guard tests

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV3.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift:39-54`
  (`inMemory()` and `persistent()` include the new model)
- Modify: `AuraCore/Tests/AuraKitTests/RideMigrationTests.swift:54,82`
  (containers must list both models so the migration destination is V3)
- Test: `AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift`

**Interfaces:**
- Consumes: `RideSchemaV2.RideRecord`, `RideMigrationPlan`, `SavedPlace` (Task 1).
- Produces: `RideSchemaV3: VersionedSchema` (version 3.0.0, models
  `[RideSchemaV2.RideRecord.self, SavedPlaceRecord.self]`);
  `typealias SavedPlaceRecord = RideSchemaV3.SavedPlaceRecord` with fields
  `id: UUID`, `name: String`, `subtitle: String?`, `latitude: Double`,
  `longitude: Double`, `categoryRaw: String`, `kindRaw: String`,
  `savedAt: Date`, plus `value: SavedPlace?` / `init(_ value: SavedPlace)`
  mapping; `RideMigrationPlan` gains `migrateV2toV3` (lightweight).

- [ ] **Step 1: Write the failing tests**

The schema-invariant tests are the two guards the iCloud review asked for,
covering both models so a CloudKit-incompatible change fails package CI:

```swift
// AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift
import Testing
import Foundation
import SwiftData
@testable import AuraKit

/// CloudKit-compatibility guards: the mirror rejects models with unique
/// constraints, relationships, or non-optional attributes without defaults.
@Suite("Schema invariants (CloudKit)")
struct SchemaInvariantTests {
    private var entities: [Schema.Entity] {
        Schema(versionedSchema: RideSchemaV3.self).entities
    }

    @Test func everyAttributeIsOptionalOrDefaulted() {
        for entity in entities {
            for attribute in entity.attributes {
                #expect(attribute.isOptional || attribute.defaultValue != nil,
                        "\(entity.name).\(attribute.name) needs a default or optionality for CloudKit")
            }
        }
    }

    @Test func noUniqueConstraintsAndNoRelationships() {
        for entity in entities {
            for attribute in entity.attributes {
                #expect(!attribute.isUnique,
                        "\(entity.name).\(attribute.name) is .unique — CloudKit-incompatible")
            }
            #expect(entity.relationships.isEmpty,
                    "\(entity.name) has relationships — out of contract for this store")
        }
    }

    @Test func v3ContainsBothModels() {
        #expect(Set(entities.map(\.name)) == ["RideRecord", "SavedPlaceRecord"])
    }

    @Test func recordRoundTripsValue() {
        let value = SavedPlace(name: "Trace", subtitle: "Butler St",
                               coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
                               category: .brewery, kind: .home,
                               savedAt: Date(timeIntervalSince1970: 7))
        let record = SavedPlaceRecord(value)
        #expect(record.value == value)
    }

    @Test func recordWithUnknownRawsMapsToNil() {
        let record = SavedPlaceRecord(SavedPlace(name: "X", subtitle: nil,
            coordinate: Coordinate(latitude: 1, longitude: 2),
            category: .custom, kind: .favorite, savedAt: .init(timeIntervalSince1970: 0)))
        record.kindRaw = "??"
        #expect(record.value == nil)   // a future kind never crashes an old build
    }
}
```

(`import AuraCore` is implied through `AuraKit`'s re-exported types; add
`import AuraCore` explicitly if the compiler asks.)

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --filter SchemaInvariantTests`
Expected: compile FAILURE — `RideSchemaV3` not defined.

- [ ] **Step 3: Implement the schema**

```swift
// AuraCore/Sources/AuraKit/Persistence/RideSchemaV3.swift
import Foundation
import SwiftData
import AuraCore

/// V3 adds `SavedPlaceRecord` beside the (unchanged) V2 `RideRecord` —
/// adding a model type is a lightweight migration. CloudKit rules hold:
/// defaults on every attribute, no `.unique`, no relationships. The Date
/// default is the fixed sentinel, not `.now` (see the V2 comment).
public enum RideSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideSchemaV2.RideRecord.self, SavedPlaceRecord.self]
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

        public init(_ value: SavedPlace) {
            id = value.id
            name = value.name
            subtitle = value.subtitle
            latitude = value.coordinate.latitude
            longitude = value.coordinate.longitude
            categoryRaw = value.category.rawValue
            kindRaw = value.kind.rawValue
            savedAt = value.savedAt
        }

        /// nil when raws come from a newer app version this build can't read.
        public var value: SavedPlace? {
            guard let category = Place.Category(rawValue: categoryRaw),
                  let kind = SavedPlace.Kind(rawValue: kindRaw) else { return nil }
            return SavedPlace(id: id, name: name, subtitle: subtitle,
                              coordinate: Coordinate(latitude: latitude, longitude: longitude),
                              category: category, kind: kind, savedAt: savedAt)
        }
    }
}

public typealias SavedPlaceRecord = RideSchemaV3.SavedPlaceRecord
```

- [ ] **Step 4: Extend the migration plan**

In `RideMigrationPlan.swift`, update `schemas` and `stages` and append the
lightweight stage (the custom V1→V2 stage is untouched):

```swift
public static var schemas: [any VersionedSchema.Type] {
    [RideSchemaV1.self, RideSchemaV2.self, RideSchemaV3.self]
}

public static var stages: [MigrationStage] { [migrateV1toV2, migrateV2toV3] }

/// Adding a model type is lightweight — no data transform.
public static let migrateV2toV3 = MigrationStage.lightweight(
    fromVersion: RideSchemaV2.self,
    toVersion: RideSchemaV3.self)
```

- [ ] **Step 5: Include the model in both container factories**

In `RideStore.swift`, `inMemory()` and `persistent()` must list both models so
the container's schema covers the new record:

```swift
public static func inMemory() throws -> RideStore {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return RideStore(container: try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                                   configurations: config),
                     isEphemeral: true)
}

public static func persistent() throws -> RideStore {
    let config = ModelConfiguration(cloudKitDatabase: .private("iCloud.com.rohunjoseph.aura"))
    let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                       migrationPlan: RideMigrationPlan.self,
                                       configurations: config)
    return RideStore(container: container)
}
```

Also expose the container for the saved-places store (Task 6):
change `private let container: ModelContainer` to
`public let container: ModelContainer` at `RideStore.swift:10`.

- [ ] **Step 6: Point the migration tests at V3 (both models)**

SwiftData resolves the migration *destination* from the model types passed to
the container, not from the plan's last schema. `RideMigrationTests` currently
builds containers with `RideRecord.self` only (lines 54 and 82), which
resolves to V2 — the new V2→V3 stage would never run there, and a store
already at V3 opened with a single-model schema throws
`SwiftDataError.backwardMigration`. Update both container constructions to
list both models:

```swift
ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
               migrationPlan: RideMigrationPlan.self,
               configurations: config)
```

and extend the round-trip test with a post-migration write to prove the new
entity is live:

```swift
// After the existing post-migration ride assertions:
let context = container.mainContext
context.insert(SavedPlaceRecord(SavedPlace(
    name: "Post-migration save", subtitle: nil,
    coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
    category: .custom, kind: .favorite,
    savedAt: Date(timeIntervalSince1970: 1))))
try context.save()
#expect(try context.fetch(FetchDescriptor<SavedPlaceRecord>()).count == 1)
```

(Adapt `#expect` to `XCTAssert` if the migration suite is XCTest — match the
file's existing style.)

- [ ] **Step 7: Run to verify pass**

Run: `cd AuraCore && swift test --filter SchemaInvariantTests`
Expected: 5 tests PASS. Then the full `swift test` — the migration suite now
genuinely exercises V1→V2→V3 (custom stage then lightweight stage) and the
whole package stays green.

- [ ] **Step 8: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideSchemaV3.swift \
        AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift \
        AuraCore/Sources/AuraKit/Persistence/RideStore.swift \
        AuraCore/Tests/AuraKitTests/RideMigrationTests.swift \
        AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift
git commit -m "feat(kit): RideSchemaV3 adds SavedPlaceRecord (lightweight) + CloudKit schema guards"
```

---

### Task 6: `SavedPlacesStore`

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/SavedPlacesStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/SavedPlacesStoreTests.swift`

**Interfaces:**
- Consumes: `SavedPlacesLogic`, `SavedPlace`, `SavedPlaceRecord`,
  `ModelContainer` (Tasks 1-5).
- Produces: `@MainActor @Observable public final class SavedPlacesStore`:
  - `init(container: ModelContainer, now: @escaping () -> Date = Date.init)`
  - `places: [SavedPlace]` (reconciled, Home first, savedAt desc)
  - `enum SaveOutcome: Equatable { case saved(SavedPlace), full }`
  - `save(_ place: Place, subtitle: String?) -> SaveOutcome`
  - `unsave(_ place: Place)`, `delete(id: UUID)`, `rename(id: UUID, to: String)`
  - `setHome(id: UUID) -> Bool` (returns whether a previous Home was demoted),
    `removeHome(id: UUID)`
  - `savedPlace(for place: Place) -> SavedPlace?`, `isSaved(_ place: Place) -> Bool`
  - `refetch()` — also runs automatically on `NSPersistentStoreRemoteChange`
    (same observer shape as `RideStore`).

- [ ] **Step 1: Write the failing tests**

```swift
// AuraCore/Tests/AuraKitTests/SavedPlacesStoreTests.swift
import Testing
import Foundation
import SwiftData
@testable import AuraKit
import AuraCore

@MainActor
@Suite("SavedPlacesStore")
struct SavedPlacesStoreTests {
    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_000)) throws -> SavedPlacesStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                           configurations: config)
        return SavedPlacesStore(container: container, now: { now })
    }
    private let coordinate = Coordinate(latitude: 40.4406, longitude: -79.9959)

    @Test func saveFetchRoundTrip() throws {
        let store = try makeStore()
        let place = Place(name: "Trace", coordinate: coordinate, category: .brewery)
        guard case let .saved(saved) = store.save(place, subtitle: "Butler St") else {
            Issue.record("expected .saved"); return
        }
        #expect(store.places == [saved])
        #expect(store.isSaved(place))
    }

    @Test func unsaveByJitteredCoordinateRemoves() throws {
        let store = try makeStore()
        _ = store.save(Place(name: "Trace", coordinate: coordinate, category: .brewery),
                       subtitle: nil)
        let jittered = Place(name: "Trace",
                             coordinate: Coordinate(latitude: 40.440601, longitude: -79.995899),
                             category: .brewery)
        store.unsave(jittered)
        #expect(store.places.isEmpty)
    }

    @Test func setHomeOrdersHomeFirstAndReportsDemotion() throws {
        let store = try makeStore()
        guard case let .saved(first) = store.save(
            Place(name: "A", coordinate: coordinate, category: .custom), subtitle: nil),
            case let .saved(second) = store.save(
            Place(name: "B", coordinate: Coordinate(latitude: 40.5, longitude: -80.0),
                  category: .custom), subtitle: nil) else {
            Issue.record("saves failed"); return
        }
        #expect(store.setHome(id: first.id) == false)  // no previous Home
        #expect(store.setHome(id: second.id) == true)  // demotes first
        #expect(store.places.first?.id == second.id)
        #expect(store.places.first?.kind == .home)
        #expect(store.places.last?.kind == .favorite)
    }

    @Test func fullOutcomeAtCap() throws {
        let store = try makeStore()
        for index in 0..<SavedPlacesLogic.maxCount {
            let place = Place(name: "P\(index)",
                              coordinate: Coordinate(latitude: 40 + Double(index) * 0.01,
                                                     longitude: -79.9),
                              category: .custom)
            guard case .saved = store.save(place, subtitle: nil) else {
                Issue.record("save \(index) failed"); return
            }
        }
        let overflow = Place(name: "Overflow",
                             coordinate: Coordinate(latitude: 41.9, longitude: -79.0),
                             category: .custom)
        #expect(store.save(overflow, subtitle: nil) == .full)
    }

    @Test func renameAndDeletePersist() throws {
        let store = try makeStore()
        guard case let .saved(saved) = store.save(
            Place(name: "Old", coordinate: coordinate, category: .custom), subtitle: nil) else {
            Issue.record("save failed"); return
        }
        store.rename(id: saved.id, to: "New")
        #expect(store.places.first?.name == "New")
        store.delete(id: saved.id)
        #expect(store.places.isEmpty)
    }

    @Test func refetchReconcilesInjectedDuplicates() throws {
        // Simulate a CloudKit merge artifact: two records, same rounded key.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                           configurations: config)
        let context = container.mainContext
        context.insert(SavedPlaceRecord(SavedPlace(
            name: "First", subtitle: nil, coordinate: coordinate,
            category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 1))))
        context.insert(SavedPlaceRecord(SavedPlace(
            name: "Second", subtitle: nil,
            coordinate: Coordinate(latitude: 40.440601, longitude: -79.995899),
            category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 9))))
        try context.save()
        let store = SavedPlacesStore(container: container)
        #expect(store.places.count == 1)
        #expect(store.places.first?.name == "Second")
    }

    @Test func remoteChangeNotificationRefetches() async throws {
        // A CloudKit import lands as records the store didn't write, announced
        // by NSPersistentStoreRemoteChange. Mirror the wait idiom used by
        // AuraCore/Tests/AuraKitTests/RideStoreSyncRevisionTests.swift.
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self,
                                           configurations: config)
        let store = SavedPlacesStore(container: container)
        #expect(store.places.isEmpty)
        container.mainContext.insert(SavedPlaceRecord(SavedPlace(
            name: "Remote", subtitle: nil,
            coordinate: Coordinate(latitude: 40.5, longitude: -80.0),
            category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 5))))
        try container.mainContext.save()
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)
        await Task.yield()   // let the observer's MainActor hop land
        #expect(store.places.first?.name == "Remote")
    }
}
```

(`import CoreData` at the top of the test file for the notification name.)

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --filter SavedPlacesStoreTests`
Expected: compile FAILURE — `SavedPlacesStore` not defined.

- [ ] **Step 3: Implement**

```swift
// AuraCore/Sources/AuraKit/Persistence/SavedPlacesStore.swift
import Foundation
import SwiftData
import Observation
import CoreData
import AuraCore

/// Saved destinations over the app's SwiftData container. All invariants are
/// `SavedPlacesLogic`; this class only fetches, maps, and persists. Mirrors
/// `RideStore`'s remote-change observer so a CloudKit import refreshes rows.
@MainActor
@Observable
public final class SavedPlacesStore {
    public enum SaveOutcome: Equatable {
        case saved(SavedPlace)
        case full
    }

    public private(set) var places: [SavedPlace] = []

    private let container: ModelContainer
    @ObservationIgnored private let now: () -> Date
    // Same shape and rationale as RideStore.remoteChangeObserver.
    @ObservationIgnored private nonisolated(unsafe) var remoteChangeObserver: NSObjectProtocol?

    public init(container: ModelContainer, now: @escaping () -> Date = Date.init) {
        self.container = container
        self.now = now
        refetch()
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refetch() }
        }
    }

    deinit {
        if let remoteChangeObserver { NotificationCenter.default.removeObserver(remoteChangeObserver) }
    }

    public func refetch() {
        let descriptor = FetchDescriptor<SavedPlaceRecord>()
        let values = (try? container.mainContext.fetch(descriptor))?.compactMap(\.value) ?? []
        places = SavedPlacesLogic.reconciled(values)
    }

    public func savedPlace(for place: Place) -> SavedPlace? {
        SavedPlacesLogic.saved(matching: place, in: places)
    }

    public func isSaved(_ place: Place) -> Bool {
        savedPlace(for: place) != nil
    }

    @discardableResult
    public func save(_ place: Place, subtitle: String?) -> SaveOutcome {
        switch SavedPlacesLogic.add(place, subtitle: subtitle, to: places, now: now()) {
        case .full:
            return .full
        case let .added(list):
            persist(list)
            guard let saved = savedPlace(for: place) else {
                assertionFailure("save persisted but lookup missed")
                return .full
            }
            return .saved(saved)
        }
    }

    public func unsave(_ place: Place) {
        guard let saved = savedPlace(for: place) else { return }
        persist(SavedPlacesLogic.remove(id: saved.id, from: places))
    }

    public func delete(id: UUID) {
        persist(SavedPlacesLogic.remove(id: id, from: places))
    }

    public func rename(id: UUID, to name: String) {
        persist(SavedPlacesLogic.rename(id: id, to: name, in: places))
    }

    /// Returns true when a previous Home was demoted (drives confirmation copy).
    @discardableResult
    public func setHome(id: UUID) -> Bool {
        let hadHome = places.contains { $0.kind == .home && $0.id != id }
        persist(SavedPlacesLogic.setHome(id: id, in: places, now: now()))
        return hadHome
    }

    public func removeHome(id: UUID) {
        persist(SavedPlacesLogic.removeHome(id: id, in: places))
    }

    /// Writes the reconciled list as the record set: upsert by id, delete the
    /// rest. ≤ 50 rows, so full-set sync is simpler than diffing.
    private func persist(_ list: [SavedPlace]) {
        let reconciled = SavedPlacesLogic.reconciled(list)
        let context = container.mainContext
        do {
            let records = try context.fetch(FetchDescriptor<SavedPlaceRecord>())
            var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for value in reconciled {
                if let record = byID.removeValue(forKey: value.id) {
                    record.name = value.name
                    record.subtitle = value.subtitle
                    record.latitude = value.coordinate.latitude
                    record.longitude = value.coordinate.longitude
                    record.categoryRaw = value.category.rawValue
                    record.kindRaw = value.kind.rawValue
                    record.savedAt = value.savedAt
                } else {
                    context.insert(SavedPlaceRecord(value))
                }
            }
            for leftover in byID.values where leftover.value != nil {
                // Unknown-raw records (newer app version) are left untouched.
                context.delete(leftover)
            }
            try context.save()
            places = reconciled
        } catch {
            assertionFailure("SavedPlacesStore persist failed: \(error)")
            refetch()
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --filter SavedPlacesStoreTests`
Expected: 7 tests PASS. Run the full `swift test` for the package gate.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/SavedPlacesStore.swift \
        AuraCore/Tests/AuraKitTests/SavedPlacesStoreTests.swift
git commit -m "feat(kit): SavedPlacesStore over the shared container"
```

---

### Task 7: App wiring — store construction and environment

**Files:**
- Modify: `Aura/Sources/AuraApp.swift:8-24`

**Interfaces:**
- Consumes: `SavedPlacesStore` (Task 6), `RideStore.container` (Task 5 step 5).
- Produces: `SavedPlacesStore` in the SwiftUI environment for every view.

- [ ] **Step 1: Wire the store**

Replace the `@State` block and `init` in `AuraApp`:

```swift
@State private var router = AppRouter()
@State private var rideStore: RideStore
@State private var savedPlaces: SavedPlacesStore
@State private var settings = SettingsStore(defaults: .standard, sync: UbiquitousKeyValueStore())
@State private var location = LocationService()

init() {
    AuraApp.configureMapbox()
    let store = AuraApp.makeRideStore()
    _rideStore = State(initialValue: store)
    _savedPlaces = State(initialValue: SavedPlacesStore(container: store.container))
}
```

and add the environment line beside the others:

```swift
.environment(savedPlaces)
```

- [ ] **Step 2: Build**

Run: `cd Aura && xcodegen generate && xcodebuild -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build` (or delegate to the builder agent).
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/AuraApp.swift
git commit -m "feat(app): construct SavedPlacesStore over the shared container"
```

---

### Task 8: Route-preview star + Set-as-Home moment

**Files:**
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (bottom-panel header,
  lines 96-134, plus new state/env properties)

**Interfaces:**
- Consumes: `SavedPlacesStore.save/unsave/setHome/savedPlace/isSaved` (Task 6).
- Produces: UI only. Exact copy per Global Constraints.

- [ ] **Step 1: Add environment + state to `RoutePreviewView`**

```swift
@Environment(SavedPlacesStore.self) private var savedPlaces

private enum SaveMoment: Equatable {
    case saved(SavedPlace)          // "Saved" + Set as Home offer
    case homeSet(demoted: Bool)     // confirmation after taking the offer
}
@State private var saveMoment: SaveMoment?
@State private var saveMomentDismiss: Task<Void, Never>?
@State private var showFullAlert = false
```

- [ ] **Step 2: Put the star in the header**

Replace the header `VStack` (lines 99-107) with an `HStack` that keeps the
existing text column and adds the toggle:

```swift
HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.md) {
    VStack(alignment: .leading, spacing: 2) {
        Text(destination.name)
            .font(.title3.bold())
            .foregroundStyle(AuraTheme.textPrimary)
            .lineLimit(1)
        Text("Choose a route")
            .font(.subheadline)
            .foregroundStyle(AuraTheme.textSecondary)
    }
    Spacer(minLength: 0)
    saveButton
}
```

with, below in the file:

```swift
private var isSaved: Bool { savedPlaces.isSaved(destination) }

private var saveButton: some View {
    Button(action: toggleSaved) {
        Image(systemName: isSaved ? "star.fill" : "star")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isSaved ? AuraTheme.accent : AuraTheme.textSecondary)
            .frame(width: 44, height: 44)   // explicit 44pt target (spec D5)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Save place")
    .accessibilityValue(isSaved ? "Saved" : "Not saved")
}

private func toggleSaved() {
    if let saved = savedPlaces.savedPlace(for: destination) {
        savedPlaces.unsave(destination)
        _ = saved   // no moment on unsave
        setSaveMoment(nil)
        return
    }
    switch savedPlaces.save(destination, subtitle: destination.subtitle) {
    case .full:
        showFullAlert = true
    case let .saved(saved):
        setSaveMoment(.saved(saved))
    }
}

private func setSaveMoment(_ moment: SaveMoment?) {
    saveMomentDismiss?.cancel()
    saveMoment = moment
    guard moment != nil else { return }
    saveMomentDismiss = Task {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        saveMoment = nil
    }
}
```

- [ ] **Step 3: Render the transient moment under the header**

Directly after the header block (before the route options `Group`):

```swift
if let moment = saveMoment {
    HStack(spacing: AuraTheme.Spacing.md) {
        switch moment {
        case let .saved(saved):
            Text("Saved")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)
            Button("Set as Home") {
                let demoted = savedPlaces.setHome(id: saved.id)
                setSaveMoment(.homeSet(demoted: demoted))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AuraTheme.textPrimary)
        case let .homeSet(demoted):
            Text(demoted ? "Home set · Previous Home kept as a favorite" : "Home set")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)
        }
        Spacer()
    }
    .padding(.horizontal, AuraTheme.Spacing.xxl)
    .padding(.bottom, AuraTheme.Spacing.sm)
    .transition(.opacity)
    .accessibilityElement(children: .combine)
}
```

Wrap `saveMoment` changes in `withAnimation(.easeOut(duration: 0.2))` where it
is set, and honor Reduce Motion by branching to no animation
(`accessibilityReduceMotion` environment), matching house convention.

- [ ] **Step 4: The full alert**

On the bottom panel root:

```swift
.alert("Saved places is full. Remove one to save another.",
       isPresented: $showFullAlert) {
    Button("OK", role: .cancel) {}
}
```

- [ ] **Step 5: Build and verify on the simulator**

Build as in Task 7. Launch on the iPhone 17 simulator, deep-link
`aura://preview?lat=40.4406&lng=-79.9959&name=Trace%20Brewing` (via
`xcrun simctl openurl booted ...`), and check through the accessibility tree:
star reads "Save place, Not saved" → tap → "Saved" + "Set as Home" appear,
value flips to "Saved" → tap "Set as Home" → "Home set" confirmation.

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/Plan/RoutePreviewView.swift
git commit -m "feat(app): save star + Set-as-Home moment on route preview"
```

---

### Task 9: Dashboard Saved section + row management + Recents filter

**Files:**
- Create: `Aura/Sources/Plan/SavedPlaceRow.swift`
- Modify: `Aura/Sources/Plan/PlanView.swift` (dashboard at lines 91-108,
  recents at 151-172, new env/state)

**Interfaces:**
- Consumes: `SavedPlacesStore` (Task 6), `SavedPlace` (Task 1),
  `router.push(.preview(_:))` (existing).
- Produces: UI only. Section order: weekly ring → Saved → last ride → Recents.

- [ ] **Step 1: Create `SavedPlaceRow`**

```swift
// Aura/Sources/Plan/SavedPlaceRow.swift
import SwiftUI
import AuraCore

/// One saved destination on the dashboard. Same anatomy as RecentRow, with a
/// kind icon, a subtitle line, and a visible ellipsis menu (the HIG-required
/// second path beside the long-press context menu).
struct SavedPlaceRow: View {
    let saved: SavedPlace
    let onTap: () -> Void
    let onRename: () -> Void
    let onSetHome: () -> Void
    let onRemoveHome: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: AuraTheme.Spacing.lg) {
                    Image(systemName: saved.kind == .home ? "house.fill" : "star.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AuraTheme.accent)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AuraTheme.textPrimary)
                            .lineLimit(1)
                        if let line = subtitleLine {
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(AuraTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .frame(minHeight: 56)
                .padding(.leading, AuraTheme.Spacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The Button is one accessibility element; the composed label and
            // the custom actions live here so the ellipsis Menu stays its own
            // queryable element (do NOT .combine the whole row — it swallows
            // the menu from both VoiceOver and XCUITest).
            .accessibilityLabel(accessibilityText)
            .accessibilityAction(named: "Rename", onRename)
            .accessibilityAction(named: saved.kind == .home ? "Remove Home" : "Set as Home") {
                if saved.kind == .home { onRemoveHome() } else { onSetHome() }
            }
            .accessibilityAction(named: "Delete", onDelete)

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
                    .frame(width: 44, height: 56)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(title)")
        }
        .contextMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Rename", systemImage: "pencil", action: onRename)
        if saved.kind == .home {
            Button("Remove Home", systemImage: "house.slash", action: onRemoveHome)
        } else {
            Button("Set as Home", systemImage: "house", action: onSetHome)
        }
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }

    /// Home renders as the concept, with the actual place demoted to context.
    private var title: String { saved.kind == .home ? "Home" : saved.name }

    /// Home shows the actual place's name (spec D6); favorites show the
    /// address line with the category label as fallback.
    private var subtitleLine: String? {
        if saved.kind == .home { return saved.name }
        return saved.subtitle ?? categoryLabel
    }

    private var categoryLabel: String {
        switch saved.category {
        case .brewery:   return "Brewery"
        case .trailhead: return "Trail"
        case .address:   return "Address"
        case .custom:    return "Place"
        }
    }

    private var accessibilityText: String {
        let line = subtitleLine.map { ", \($0)" } ?? ""
        return "\(title)\(line)"
    }
}
```

- [ ] **Step 2: Add the Saved section to `PlanView`**

New properties:

```swift
@Environment(SavedPlacesStore.self) private var savedPlaces
@State private var renameTarget: SavedPlace?
@State private var renameText = ""
```

In `dashboard` (lines 91-108), insert between `weeklyBlock` and the last-ride
block:

```swift
if !savedPlaces.places.isEmpty {
    savedSection
}
```

New section builder (mirrors `recentsSection`):

```swift
private var savedSection: some View {
    VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
        sectionHeader("Saved")
        VStack(spacing: 0) {
            ForEach(savedPlaces.places) { saved in
                SavedPlaceRow(
                    saved: saved,
                    onTap: { router.push(.preview(saved.place)) },
                    onRename: { renameText = saved.name; renameTarget = saved },
                    onSetHome: { savedPlaces.setHome(id: saved.id) },
                    onRemoveHome: { savedPlaces.removeHome(id: saved.id) },
                    onDelete: { savedPlaces.delete(id: saved.id) }
                )
                if saved.id != savedPlaces.places.last?.id {
                    Divider()
                        .background(AuraTheme.border)
                        .padding(.leading, 58)
                }
            }
        }
        .background(AuraTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
    }
    .padding(.horizontal, AuraTheme.Spacing.xxl)
}
```

Rename alert on the `PlanView` body (SwiftUI alerts cannot disable buttons on
live text state, so the empty-guard lives in `SavedPlacesLogic.rename`, which
no-ops on whitespace — documented deviation from "disabled", same effect):

```swift
.alert("Rename saved place", isPresented: Binding(
    get: { renameTarget != nil },
    set: { if !$0 { renameTarget = nil } }
)) {
    TextField("Name", text: $renameText)
    Button("Save") {
        if let target = renameTarget {
            savedPlaces.rename(id: target.id, to: renameText)
        }
        renameTarget = nil
    }
    Button("Cancel", role: .cancel) { renameTarget = nil }
}
```

- [ ] **Step 3: Filter saved places out of rendered Recents**

In `recentsSection`, compute the filtered list once and gate the section on it
(replacing the `router.recents` uses at lines 101 and 157-161):

```swift
private var visibleRecents: [Place] {
    router.recents.filter { !savedPlaces.isSaved($0) }
}
```

Dashboard gate becomes `if !visibleRecents.isEmpty { recentsSection }` and the
`ForEach` iterates `visibleRecents` (divider check against
`visibleRecents.last?.id`).

- [ ] **Step 4: Build and verify on the simulator**

Build; then on the simulator (with a place saved via Task 8's flow): the Saved
section sits between the ring and the last-ride card, Home first with a
`house.fill` icon and the word "Home"; the ellipsis opens Rename / Set as Home
/ Delete; renaming updates the row; the same place no longer appears under
Recents; deleting the last saved place hides the section.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Plan/SavedPlaceRow.swift Aura/Sources/Plan/PlanView.swift
git commit -m "feat(app): dashboard Saved section with visible management + Recents filter"
```

---

### Task 10: Search pinning while typing

**Files:**
- Modify: `Aura/Sources/Plan/DestinationSearchView.swift` (results branch at
  lines 68-94, `resolveSuggestion` at 142-181, new env)

**Interfaces:**
- Consumes: `SavedPlaceMatcher.matches` (Task 4), `SavedPlacesStore.places`
  (Task 6), `Place.subtitle` (Task 1).
- Produces: UI only; picked saved rows flow through the existing
  `onPick(Place)` carrying the saved id and `isSaved: true`.

- [ ] **Step 1: Pin saved matches above the results**

Add `@Environment(SavedPlacesStore.self) private var savedPlaces` and a
computed:

```swift
private var savedMatches: [SavedPlace] {
    SavedPlaceMatcher.matches(query: query, in: savedPlaces.places)
}
```

Inside the `if !query.isEmpty` branch, render the pinned group above the
existing error/suggestions `Group` (saved matches show from the first
character; Mapbox keeps its existing 2-character floor):

```swift
if !savedMatches.isEmpty {
    VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
        Text("Saved")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AuraTheme.textSecondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .padding(.top, AuraTheme.Spacing.sm)

        LazyVStack(spacing: 0) {
            ForEach(savedMatches) { saved in
                SavedMatchRow(saved: saved) {
                    onPick(saved.place)
                    query = ""
                    suggestions = []
                }
                if saved.id != savedMatches.last?.id {
                    Divider()
                        .background(AuraTheme.border)
                        .padding(.leading, 60)
                }
            }
        }
    }
    .background(AuraTheme.surface.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous))
    .padding(.horizontal, AuraTheme.Spacing.xxl)
    .padding(.top, AuraTheme.Spacing.sm)
}
```

The "Saved" header carries provenance (icon tint cannot — every result icon is
already accent).

- [ ] **Step 2: Add `SavedMatchRow`**

At file bottom, beside `SuggestionRow`:

```swift
// MARK: - SavedMatchRow

private struct SavedMatchRow: View {
    let saved: SavedPlace
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AuraTheme.Spacing.lg) {
                Image(systemName: saved.kind == .home ? "house.fill" : "star.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AuraTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(saved.kind == .home ? "Home" : saved.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(AuraTheme.textPrimary)
                        .lineLimit(1)
                    if let line = saved.kind == .home ? saved.name : saved.subtitle {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(AuraTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .frame(minHeight: 56)
            .padding(.horizontal, AuraTheme.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 3: Carry the search description into `Place.subtitle`**

In `resolveSuggestion`, both `Place(...)` constructions gain
`subtitle: suggestion.description` (the immediate-coordinate path at lines
145-149 and the resolved path at 168-172):

```swift
let place = Place(
    name: suggestion.name,
    subtitle: suggestion.description,
    coordinate: Coordinate(latitude: coord.latitude, longitude: coord.longitude),
    category: inferCategory(from: suggestion)
)
```

(and the same for the `resolved` branch, keeping `resolved.name`).

- [ ] **Step 4: Build and verify on the simulator**

With Home and a favorite saved: typing "h" pins Home alone (Mapbox floor is
2 chars); typing a favorite's name shows it under the "Saved" header above
Mapbox rows, with its address line; picking it lands on the route preview with
the star already filled (id round-trip).

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Plan/DestinationSearchView.swift
git commit -m "feat(app): pin saved matches above search results"
```

---

### Task 11: Verification pass, UI test, ROADMAP

**Files:**
- Modify: `Aura/Sources/AuraApp.swift` (test-only deep-link hook on RootView)
- Create: `Aura/UITests/SavedPlacesUITests.swift`
- Modify: `docs/ROADMAP.md` (unbuilt-v1-promises line + shipped note)

**Interfaces:**
- Consumes: everything above.
- Produces: the done-bar evidence.

- [ ] **Step 1: Test-only deep-link hook**

UI tests need a deterministic route to the preview without live search. Add a
launch-argument hook as a `.task` on `RootView`'s `TabView` (beside the
existing tasks; `RootView` already reads `@Environment(AppRouter.self)`).
Reading `self.router` in `AuraApp.init` is a definite-initialization error —
do not put this in `init`:

```swift
// UI-test support: "-openURL <url>" routes through the normal deep-link path
// on first appearance. Inert in production (no argument, no effect).
.task {
    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-openURL"),
       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
       let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
        router.handle(url: url)
    }
}
```

- [ ] **Step 2: The UI test**

```swift
// Aura/UITests/SavedPlacesUITests.swift
import XCTest

/// Save-from-preview lands on the dashboard. Runs locally/on-demand — the
/// UI-test CI job is still deferred (see the AuraUITests plan).
final class SavedPlacesUITests: XCTestCase {
    @MainActor
    func testSaveFromPreviewAppearsInSavedSection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-openURL",
            "aura://preview?lat=40.4406&lng=-79.9959&name=Save%20Target"]
        app.launch()

        let star = app.buttons["Save place"]
        XCTAssertTrue(star.waitForExistence(timeout: 10), "preview star missing")
        star.tap()
        XCTAssertEqual(star.value as? String, "Saved")

        // firstMatch: the failed/empty route states add a second "Back" button.
        app.buttons["Back"].firstMatch.tap()

        // Case-insensitive: the header renders through .textCase(.uppercase)
        // and the AX label casing is not guaranteed.
        let savedHeader = app.staticTexts
            .matching(NSPredicate(format: "label ==[c] %@", "saved")).firstMatch
        XCTAssertTrue(savedHeader.waitForExistence(timeout: 5),
                      "Saved section header missing on dashboard")
        XCTAssertTrue(app.staticTexts["Save Target"].exists)

        // Cleanup so reruns start clean: delete through the row's ellipsis menu
        // (its own element — the row deliberately does not combine children).
        app.buttons["Actions for Save Target"].firstMatch.tap()
        app.buttons["Delete"].tap()
    }
}
```

Register the file with the existing `AuraUITests` target in `Aura/project.yml`
if the target lists sources explicitly (check how the existing four UI-test
files are included; a directory glob needs no change).

- [ ] **Step 3: Full gates**

- `cd AuraCore && swift test` — whole package green.
- `swiftlint lint --strict` from repo root — clean.
- App build via the builder agent — succeeds.
- UI test run (simulator): `xcodebuild test -scheme Aura -only-testing:AuraUITests/SavedPlacesUITests -destination 'platform=iOS Simulator,name=iPhone 17'` — passes.
- Simulator accessibility-tree sweep per the spec's Testing section: the
  Task 8/9/10 verification lists, plus Dynamic Type at an accessibility size
  on the Saved rows and VoiceOver reading one composed element per row with
  three custom actions.

- [ ] **Step 4: ROADMAP update**

In `docs/ROADMAP.md`, edit the "Deferred and unscheduled" paragraph: the
unbuilt-v1-promises sentence drops saved places (leaving the share card), and
a shipped line lands under "Wave 4 and beyond" (or a "Smaller features"
sibling) in house style, one paragraph: model/store/schema shape, the three
surfaces, the review-driven decisions (per-record CloudKit over KVS, rounded
identity), tests added, and the device-verify fold-in (CD_SavedPlaceRecord +
two-device save/delete propagation).

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/AuraApp.swift Aura/UITests/SavedPlacesUITests.swift \
        Aura/project.yml docs/ROADMAP.md
git commit -m "test(app): saved-places UI test via -openURL hook + docs(roadmap) close-out"
```

---

## Self-review notes

- Spec coverage: D1→Tasks 5-6, D2→Tasks 1/3, D3→Task 2, D4→Task 6, D5→Task 8,
  D6→Task 9, D7→Task 10, D8→Task 9 step 3, D9 respected (nothing extra built).
  Error handling: full alert (Task 8), rename guard (Tasks 3/9), reconcile
  (Tasks 3/6), account-change/no-account posture needs no code (inherited).
  Testing section → Tasks 1-6 suites + Task 11 gates.
- Type consistency: `SaveOutcome.saved(SavedPlace)`/`.full` (Tasks 6/8);
  `setHome(id:) -> Bool` demotion flag (Tasks 6/8); `SavedPlace.place`
  (Tasks 1/9/10); `visibleRecents` only in Task 9.
- The V1→V2→V3 chain is exercised only after Task 5 step 6 updates the
  migration tests to pass both models — SwiftData resolves the migration
  destination from the container's model list, not the plan's last schema.
- Plan revised through a two-reviewer adversarial pass (coverage + snippet
  compile-verification); the confirmed findings folded in: AuraKit test
  placement, the V3 migration-destination gap, the row-accessibility /
  UI-test conflict, the RootView.task hook, the lint-safe accessibility
  action, Home-row subtitle, and case-insensitive test queries.
