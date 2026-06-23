# Aura v1 — Plan 4: Persistence, History, Settings & Offline Maps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make rides persist, browsable, and configurable: SwiftData-backed ride history, a History screen, a Settings screen (units, voice, map style, **offline map region downloads**), saved places, and the required OSM/BikePGH attribution. This completes v1.

**Architecture:** Persistence logic lands in `AuraKit` so it stays unit-testable via `swift test` with an **in-memory** SwiftData container: a `RideRecord` `@Model`, a pure `RideMapper` (`Ride` ⇄ `RideRecord`), a `RideStore` (save/fetch/delete), and a `SettingsStore` over an injectable `UserDefaults`. The app gains a History list, a Settings screen wired to `SettingsStore`, an attribution view, and Mapbox offline tile downloading.

**Tech Stack:** Swift 5.10+, SwiftData, SwiftUI, Mapbox Maps offline (`TileStore`/`OfflineManager`), `AuraCore` + `AuraKit`, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-22-aura-cycling-app-v1-design.md`
**Depends on:** Plans 1–3.

**This is Plan 4 of 4 — the last v1 plan.**

### Notes for implementers
- **SwiftData in `swift test`:** SwiftData is available on macOS 14+, so `RideStore` is tested headlessly with `ModelConfiguration(isStoredInMemoryOnly: true)`. No simulator needed for the persistence tests.
- **`RideStore` and `SettingsStore` writes are `@MainActor`** where SwiftData requires it; tests annotate the class `@MainActor` if needed (same pattern as Plan 2's `RideRecorder`).
- **Offline maps (Task 7) is caveated Mapbox glue** — verify `TileStore`/`OfflineManager`/`TilesetDescriptor` symbols against the installed Maps SDK v11. The download-region *math* (a bounding box around Pittsburgh) is the only deterministic part.
- **Design-skill checkpoint** for the History and Settings UI (Tasks 5–6).

---

## File Structure

```
biking-app/
  AuraCore/
    Sources/AuraKit/
      Persistence/RideRecord.swift     # @Model
      Persistence/RideMapper.swift      # Ride <-> RideRecord (pure)
      Persistence/RideStore.swift       # save/fetch/delete (in-memory testable)
      Settings/SettingsStore.swift      # units/voice/mapStyle over UserDefaults
    Tests/AuraKitTests/
      RideMapperTests.swift
      RideStoreTests.swift
      SettingsStoreTests.swift
  Aura/
    Sources/
      History/HistoryView.swift         # list past rides -> summary
      Settings/SettingsView.swift       # units/voice/map style/offline/attribution
      Settings/AttributionView.swift    # OSM (c) + BikePGH credits
      Offline/OfflineMapManager.swift   # Mapbox TileStore region download (glue)
      Offline/OfflineMapsView.swift     # download Pittsburgh region + progress
    Sources/AuraApp.swift               # MODIFY: install ModelContainer + tabs (Plan/History/Settings)
```

---

## Prerequisites

- [ ] Plans 1–3 complete and green.
- [ ] Branch: `git checkout -b plan-4-persistence`.

---

## Task 1: `RideRecord` model + `RideMapper` round-trip

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideRecord.swift`
- Create: `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideMapperTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/RideMapperTests.swift`:
```swift
import XCTest
import AuraCore
@testable import AuraKit

final class RideMapperTests: XCTestCase {
    func test_ride_roundTripsThroughRecord() throws {
        let ride = Ride(
            kind: .navigate,
            startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 2000),
            track: [TrackPoint(coordinate: .init(latitude: 40.44, longitude: -80.0), elevation: 250,
                               timestamp: Date(timeIntervalSince1970: 1000))],
            stats: RideStats(distanceMeters: 1234, movingTimeSeconds: 600,
                             averageSpeedMetersPerSecond: 2.0, maxSpeedMetersPerSecond: 6.0,
                             elevationGainMeters: 42),
            routeId: UUID(),
            destinationPlaceId: UUID())
        let record = try RideMapper.record(from: ride)
        let back = try RideMapper.ride(from: record)
        XCTAssertEqual(back, ride)
    }

    func test_freeRide_withNilStats_roundTrips() throws {
        let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
                        track: [], stats: nil, routeId: nil, destinationPlaceId: nil)
        XCTAssertEqual(try RideMapper.ride(from: RideMapper.record(from: ride)), ride)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideMapperTests`
Expected: FAIL — `RideRecord` / `RideMapper` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraKit/Persistence/RideRecord.swift`:
```swift
import Foundation
import SwiftData

@Model
public final class RideRecord {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var startedAt: Date
    public var endedAt: Date?
    public var trackData: Data        // JSON-encoded [TrackPoint]
    public var statsData: Data?       // JSON-encoded RideStats
    public var routeId: UUID?
    public var destinationPlaceId: UUID?

    public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                trackData: Data, statsData: Data?, routeId: UUID?, destinationPlaceId: UUID?) {
        self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
        self.trackData = trackData; self.statsData = statsData
        self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
    }
}
```

`AuraCore/Sources/AuraKit/Persistence/RideMapper.swift`:
```swift
import Foundation
import AuraCore

public enum RideMapper {
    public static func record(from ride: Ride) throws -> RideRecord {
        let encoder = JSONEncoder()
        return RideRecord(
            id: ride.id,
            kindRaw: ride.kind.rawValue,
            startedAt: ride.startedAt,
            endedAt: ride.endedAt,
            trackData: try encoder.encode(ride.track),
            statsData: try ride.stats.map { try encoder.encode($0) },
            routeId: ride.routeId,
            destinationPlaceId: ride.destinationPlaceId)
    }

    public static func ride(from record: RideRecord) throws -> Ride {
        let decoder = JSONDecoder()
        return Ride(
            id: record.id,
            kind: Ride.Kind(rawValue: record.kindRaw) ?? .freeRide,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            track: try decoder.decode([TrackPoint].self, from: record.trackData),
            stats: try record.statsData.map { try decoder.decode(RideStats.self, from: $0) },
            routeId: record.routeId,
            destinationPlaceId: record.destinationPlaceId)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RideMapperTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideRecord.swift AuraCore/Sources/AuraKit/Persistence/RideMapper.swift AuraCore/Tests/AuraKitTests/RideMapperTests.swift
git commit -m "feat(kit): RideRecord model + Ride<->RideRecord mapper"
```

---

## Task 2: `RideStore` — save/fetch/delete (in-memory testable)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/RideStoreTests.swift`:
```swift
import XCTest
import AuraCore
@testable import AuraKit

@MainActor
final class RideStoreTests: XCTestCase {
    private func ride(_ t: TimeInterval) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: t), endedAt: Date(timeIntervalSince1970: t + 100),
             track: [], stats: .zero, routeId: nil, destinationPlaceId: nil)
    }

    func test_savesAndFetchesNewestFirst() throws {
        let store = try RideStore.inMemory()
        try store.save(ride(100))
        try store.save(ride(300))
        try store.save(ride(200))
        let all = try store.allRides()
        XCTAssertEqual(all.map(\.startedAt.timeIntervalSince1970), [300, 200, 100])
    }

    func test_delete() throws {
        let store = try RideStore.inMemory()
        let r = ride(100)
        try store.save(r)
        try store.delete(id: r.id)
        XCTAssertTrue(try store.allRides().isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RideStoreTests`
Expected: FAIL — `RideStore` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraKit/Persistence/RideStore.swift`:
```swift
import Foundation
import SwiftData
import AuraCore

@MainActor
public final class RideStore {
    private let container: ModelContainer
    public init(container: ModelContainer) { self.container = container }

    public static func inMemory() throws -> RideStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return RideStore(container: try ModelContainer(for: RideRecord.self, configurations: config))
    }

    public func save(_ ride: Ride) throws {
        let context = container.mainContext
        context.insert(try RideMapper.record(from: ride))
        try context.save()
    }

    public func allRides() throws -> [Ride] {
        let descriptor = FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try container.mainContext.fetch(descriptor).map { try RideMapper.ride(from: $0) }
    }

    public func delete(id: UUID) throws {
        let context = container.mainContext
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        for record in try context.fetch(descriptor) { context.delete(record) }
        try context.save()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RideStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideStore.swift AuraCore/Tests/AuraKitTests/RideStoreTests.swift
git commit -m "feat(kit): RideStore (SwiftData save/fetch/delete, in-memory testable)"
```

---

## Task 3: `SettingsStore` over `UserDefaults`

**Files:**
- Create: `AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift`:
```swift
import XCTest
@testable import AuraKit

final class SettingsStoreTests: XCTestCase {
    private func freshStore() -> SettingsStore {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return SettingsStore(defaults: defaults)
    }

    func test_defaults_areImperialVoiceOnDarkMap() {
        let s = freshStore()
        XCTAssertEqual(s.units, .imperial)
        XCTAssertTrue(s.voiceEnabled)
        XCTAssertEqual(s.mapStyle, .dark)
    }

    func test_persistsChanges() {
        let s = freshStore()
        s.units = .metric
        s.voiceEnabled = false
        XCTAssertEqual(s.units, .metric)
        XCTAssertFalse(s.voiceEnabled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter SettingsStoreTests`
Expected: FAIL — `SettingsStore` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraKit/Settings/SettingsStore.swift`:
```swift
import Foundation

public enum DistanceUnits: String, Sendable { case imperial, metric }
public enum MapStyle: String, Sendable { case dark, standard }

public final class SettingsStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var units: DistanceUnits {
        get { DistanceUnits(rawValue: defaults.string(forKey: Key.units) ?? "") ?? .imperial }
        set { defaults.set(newValue.rawValue, forKey: Key.units) }
    }
    public var voiceEnabled: Bool {
        get { defaults.object(forKey: Key.voice) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.voice) }
    }
    public var mapStyle: MapStyle {
        get { MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .dark }
        set { defaults.set(newValue.rawValue, forKey: Key.mapStyle) }
    }

    private enum Key { static let units = "units"; static let voice = "voiceEnabled"; static let mapStyle = "mapStyle" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter SettingsStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Full suite green**

Run: `cd AuraCore && swift test`
Expected: PASS — all AuraCore + AuraKit tests across Plans 1–4.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Settings/SettingsStore.swift AuraCore/Tests/AuraKitTests/SettingsStoreTests.swift
git commit -m "feat(kit): SettingsStore (units/voice/map style)"
```

---

## Task 4: Install the ModelContainer + save real rides

**Files:**
- Modify: `Aura/Sources/AuraApp.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift` and `Aura/Sources/Ride/NavigateHUDView.swift`

- [ ] **Step 1: Create a shared on-disk container in `AuraApp`**

In `AuraApp.swift`, build a `RideStore` backed by a persistent `ModelContainer(for: RideRecord.self)` and inject it (via `.environment` or a simple shared instance). Keep a `SettingsStore()` available too.

- [ ] **Step 2: Save on ride end**

In both `RideHUDView.endRide()` and `NavigateHUDView` arrival/end, after building the `Ride`, call `try? rideStore.save(ride)` before presenting the summary.

- [ ] **Step 3: Build + run; end a (simulated) ride; relaunch**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED; a ride survives an app relaunch (verified via History in Task 5).

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/AuraApp.swift Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(app): persist rides via RideStore on ride end"
```

---

## Task 5: History screen

**Files:**
- Create: `Aura/Sources/History/HistoryView.swift`

> **Design-skill checkpoint.**

- [ ] **Step 1: History list**

`Aura/Sources/History/HistoryView.swift`:
```swift
import SwiftUI
import AuraCore
import AuraKit

struct HistoryView: View {
    let store: RideStore
    @State private var rides: [Ride] = []
    @State private var selected: Ride?

    var body: some View {
        List(rides) { ride in
            Button { selected = ride } label: { row(ride) }
        }
        .background(AuraTheme.bg)
        .navigationTitle("Rides")
        .onAppear { rides = (try? store.allRides()) ?? [] }
        .sheet(item: $selected) { RideSummaryView(ride: $0) }
    }

    private func row(_ ride: Ride) -> some View {
        let stats = ride.stats ?? .zero
        return HStack {
            VStack(alignment: .leading) {
                Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(AuraTheme.text)
                Text(ride.kind == .navigate ? "Navigated" : "Free ride")
                    .font(.caption).foregroundStyle(AuraTheme.muted)
            }
            Spacer()
            Text("\(UnitConverter.miles(fromMeters: stats.distanceMeters), specifier: "%.1f") mi")
                .font(.headline).foregroundStyle(AuraTheme.text)
        }
    }
}
```

- [ ] **Step 2: Build + run; confirm saved rides appear newest-first and open into the summary**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED + history list works.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/History/HistoryView.swift
git commit -m "feat(app): ride history screen"
```

---

## Task 6: Settings screen (units, voice, map style) + apply to app

**Files:**
- Create: `Aura/Sources/Settings/SettingsView.swift`

> **Design-skill checkpoint.**

- [ ] **Step 1: Settings view**

`Aura/Sources/Settings/SettingsView.swift`:
```swift
import SwiftUI
import AuraKit

struct SettingsView: View {
    let settings: SettingsStore
    @State private var units: DistanceUnits
    @State private var voice: Bool
    @State private var mapStyle: MapStyle

    init(settings: SettingsStore) {
        self.settings = settings
        _units = State(initialValue: settings.units)
        _voice = State(initialValue: settings.voiceEnabled)
        _mapStyle = State(initialValue: settings.mapStyle)
    }

    var body: some View {
        Form {
            Picker("Units", selection: $units) {
                Text("Miles / feet").tag(DistanceUnits.imperial)
                Text("Kilometers / meters").tag(DistanceUnits.metric)
            }.onChange(of: units) { _, v in settings.units = v }

            Toggle("Voice guidance", isOn: $voice).onChange(of: voice) { _, v in settings.voiceEnabled = v }

            Picker("Map style", selection: $mapStyle) {
                Text("Dark").tag(MapStyle.dark); Text("Standard").tag(MapStyle.standard)
            }.onChange(of: mapStyle) { _, v in settings.mapStyle = v }

            NavigationLink("Offline maps") { OfflineMapsView() }
            NavigationLink("Attribution & data") { AttributionView() }
        }
        .navigationTitle("Settings")
    }
}
```

- [ ] **Step 2: Apply settings** — read `settings.voiceEnabled` in `NavigateHUDView` (mute the SDK voice when off), and `settings.units` in `SpeedRail`/`RideSummaryView`/preview (branch metric vs imperial via `UnitConverter`). For v1, imperial is the default path; metric branches use `m`/`km` (add `UnitConverter.km(fromMeters:)` if needed, with a test).

- [ ] **Step 3: Build + run; toggle settings and confirm they take effect and persist**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED + settings persist and apply.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Settings/SettingsView.swift AuraCore/Sources/AuraKit AuraCore/Tests/AuraKitTests
git commit -m "feat(app): settings screen wired to SettingsStore"
```

---

## Task 7: Offline map region download (Pittsburgh)

**Files:**
- Create: `Aura/Sources/Offline/OfflineMapManager.swift`
- Create: `Aura/Sources/Offline/OfflineMapsView.swift`

- [ ] **Step 1: Offline manager** (representative Mapbox v11 — verify `TileStore`/`OfflineManager`/`TilesetDescriptorOptions`)

`Aura/Sources/Offline/OfflineMapManager.swift`:
```swift
import Foundation
import MapboxMaps

/// Downloads a Pittsburgh tile region for offline display. Verify symbols against the installed Maps SDK v11.
@MainActor
final class OfflineMapManager: ObservableObject {
    @Published var progress: Double = 0   // 0...1

    // Pittsburgh bounding box (approx): SW (40.36, -80.10) — NE (40.50, -79.86)
    static let pittsburghBounds = (sw: (lat: 40.36, lon: -80.10), ne: (lat: 40.50, lon: -79.86))

    func downloadPittsburgh() {
        // 1) TileStore.default; OfflineManager
        // 2) create TilesetDescriptor for the dark style at zoom 10...16
        // 3) loadTileRegion(forId:loadOptions:) with the bbox geometry; observe progress → self.progress
        // Wire against the installed SDK; the bbox above is the only fixed input.
    }
}
```

- [ ] **Step 2: Offline maps view**

`Aura/Sources/Offline/OfflineMapsView.swift`:
```swift
import SwiftUI

struct OfflineMapsView: View {
    @StateObject private var manager = OfflineMapManager()
    var body: some View {
        VStack(spacing: 18) {
            Text("Download Pittsburgh for offline rides on low-signal trails.")
                .foregroundStyle(AuraTheme.muted).multilineTextAlignment(.center)
            if manager.progress > 0 && manager.progress < 1 {
                ProgressView(value: manager.progress)
            }
            Button("Download Pittsburgh") { manager.downloadPittsburgh() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Offline maps")
    }
}
```

- [ ] **Step 3: Build + run; trigger the download and confirm progress completes; verify the map renders with networking disabled**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED; after downloading, the dark map renders for the Pittsburgh region in Airplane Mode.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Offline
git commit -m "feat(app): offline Pittsburgh map region download"
```

---

## Task 8: Attribution + tabs

**Files:**
- Create: `Aura/Sources/Settings/AttributionView.swift`
- Modify: `Aura/Sources/AuraApp.swift`

- [ ] **Step 1: Attribution view (legally required)**

`Aura/Sources/Settings/AttributionView.swift`:
```swift
import SwiftUI

struct AttributionView: View {
    var body: some View {
        List {
            Section("Map data") {
                Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Text("Map data is available under the Open Database License (ODbL).")
                    .font(.caption).foregroundStyle(AuraTheme.muted)
            }
            Section("Pittsburgh bike data") {
                Link("BikePGH / WPRDC (CC-BY)", destination: URL(string: "https://data.wprdc.org/dataset/shape-files-for-bikepgh-s-pittsburgh-bike-map")!)
            }
            Section("Maps & navigation") { Text("© Mapbox") }
        }
        .navigationTitle("Attribution & data")
    }
}
```

- [ ] **Step 2: Tab shell** — make the app root a `TabView`: **Ride** (PlanView), **History** (HistoryView), **Settings** (SettingsView), each in a `NavigationStack`, sharing the injected `RideStore` + `SettingsStore`. Keep the `AppRouter`-driven plan→preview→ride flow inside the Ride tab.

- [ ] **Step 3: Build + run; confirm tabs + attribution reachable**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED; three tabs; attribution shows OSM/BikePGH/Mapbox credits.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Settings/AttributionView.swift Aura/Sources/AuraApp.swift
git commit -m "feat(app): attribution screen + tab shell (Ride/History/Settings)"
```

---

## Task 9: Full green + v1 wrap-up

- [ ] **Step 1:** `cd AuraCore && swift test` → all green (RideMapper, RideStore, SettingsStore added).
- [ ] **Step 2:** `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build` → BUILD SUCCEEDED.
- [ ] **Step 3: Manual v1 acceptance pass** (simulator, City Bicycle Ride location):
  - Free ride → live HUD → end → summary → appears in History.
  - Search a Pittsburgh brewery → 3 route options → navigate with growing turn card + voice → end → summary → in History.
  - Toggle units/voice in Settings; confirm they apply and persist across relaunch.
  - Download Pittsburgh offline region; confirm map renders in Airplane Mode.
  - Attribution shows OSM + BikePGH + Mapbox.
- [ ] **Step 4:** `git add -A && git commit -m "chore: Aura v1 complete (Plans 1–4)" || echo "nothing to commit"`

---

## Done criteria for Plan 4 (and v1)

- `swift test` green across all of AuraCore + AuraKit (Plans 1–4).
- Rides persist (SwiftData) and are browsable in History; Settings (units/voice/map style) persist and apply; offline Pittsburgh region downloads and renders without signal; OSM/BikePGH/Mapbox attribution present.
- **v1 feature-complete** per the spec: plan + free-ride/navigate RIDE-mode HUD + history + settings + offline. The routing engine remains swappable for a future Valhalla/BRouter move; the data model and app structure leave room for Phase 2 (group rides) and Phase 3 (in-ride voice).
