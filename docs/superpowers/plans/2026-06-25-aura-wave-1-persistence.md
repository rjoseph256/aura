# Aura Wave 1 — Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the SwiftData ride store so the History list and dashboard read a lightweight summary instead of decoding every ride's full GPS track, make the schema CloudKit-ready, and put the model behind a versioned schema with a tested migration.

**Architecture:** Split `RideRecord` into namespaced `RideSchemaV1` (frozen) and `RideSchemaV2` (drops `@Attribute(.unique)`, moves `trackData` to `.externalStorage`, adds denormalized `distanceMeters`/`movingTimeSeconds`/`elevationGainMeters` columns and a `thumbnailData` simplified-polyline column) behind a custom `RideMigrationPlan`. A new `RideSummary` value type plus `RideStore.summaries()` / `ride(id:)` give a read path that never faults the track blob. `RideAggregator`, `HistoryView`, `PlanView`, and `LastRideCard` move onto summaries; the behavior at the screen level is unchanged.

**Tech Stack:** Swift 6.2, SwiftData (`VersionedSchema`, `SchemaMigrationPlan`, `.externalStorage`), Swift Testing for new suites, XCTest for existing suites. Spec: `docs/superpowers/specs/2026-06-25-aura-wave-1-persistence-design.md`.

**Reference skills:** Consult `swiftdata` for migration/schema API shape and `swift-testing` for `@Test`/`#expect`. Delegate all builds and test runs to the `apple-platform-build-tools:builder` subagent.

**Conventions / guardrails:**
- Package tests run from the `AuraCore/` directory: `swift test --filter <Name>`. The app target builds via `xcodebuild` (delegate to the builder).
- NEVER `git add AuraCore/Package.resolved`. If a build dirties it, run `git checkout -- AuraCore/Package.resolved`.
- All new files under `AuraCore/Sources/**` are auto-included by SwiftPM. This plan adds/edits **no** files under `Aura/Sources/**` except edits to existing files, so no `xcodegen generate` is needed. Deleting `RideRecord.swift` is a package file change and needs no project regeneration.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Stage only the files each task names.

---

## File structure

**Create:**
- `AuraCore/Sources/AuraCore/Geo/TrackSimplifier.swift` — pure downsampling function for thumbnails.
- `AuraCore/Sources/AuraCore/Models/RideSummary.swift` — lightweight read-path value type.
- `AuraCore/Sources/AuraKit/Persistence/RideSchemaV1.swift` — frozen V1 schema + model.
- `AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift` — V2 schema + model + `RideRecord` typealias.
- `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift` — custom V1→V2 migration.
- `AuraCore/Tests/AuraCoreTests/TrackSimplifierTests.swift` (Swift Testing)
- `AuraCore/Tests/AuraKitTests/RideMigrationTests.swift` (Swift Testing)
- `AuraCore/Tests/AuraKitTests/RideStoreSummaryTests.swift` (Swift Testing)

**Modify:**
- `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift` — fill new columns in `record(from:)`, add `summary(from:)`.
- `AuraCore/Sources/AuraKit/Persistence/RideStore.swift` — add `persistent()`, `summaries()`, `ride(id:)`.
- `AuraCore/Sources/AuraKit/Home/RideAggregator.swift` — input `[Ride]` → `[RideSummary]`.
- `AuraCore/Tests/AuraKitTests/RideAggregatorTests.swift` — build `[RideSummary]`.
- `AuraCore/Tests/AuraKitTests/RideMapperTests.swift` — assert new columns.
- `Aura/Sources/History/HistoryView.swift` — list reads summaries; row takes `RideSummary`; tap fetches full ride.
- `Aura/Sources/Plan/PlanView.swift` — read summaries.
- `Aura/Sources/Plan/LastRideCard.swift` — take `RideSummary`.
- `Aura/Sources/AuraApp.swift` — `makeRideStore()` calls `RideStore.persistent()`.

**Delete:**
- `AuraCore/Sources/AuraKit/Persistence/RideRecord.swift` — content moves into the schema files.

---

### Task 1: TrackSimplifier

Pure, deterministic downsampling so a thumbnail polyline can be stored without the full track.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Geo/TrackSimplifier.swift`
- Test: `AuraCore/Tests/AuraCoreTests/TrackSimplifierTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AuraCore

struct TrackSimplifierTests {
    private func line(_ n: Int) -> [Coordinate] {
        (0..<n).map { Coordinate(latitude: Double($0), longitude: Double($0)) }
    }

    @Test func underCapReturnsInputUnchanged() {
        let input = line(40)
        #expect(TrackSimplifier.thumbnail(from: input, maxPoints: 60) == input)
    }

    @Test func atCapReturnsInputUnchanged() {
        let input = line(60)
        #expect(TrackSimplifier.thumbnail(from: input, maxPoints: 60) == input)
    }

    @Test func overCapDownsamplesToCapAndKeepsEndpoints() {
        let input = line(500)
        let out = TrackSimplifier.thumbnail(from: input, maxPoints: 60)
        #expect(out.count == 60)
        #expect(out.first == input.first)
        #expect(out.last == input.last)
    }

    @Test func emptyAndSinglePassThrough() {
        #expect(TrackSimplifier.thumbnail(from: [], maxPoints: 60) == [])
        let one = line(1)
        #expect(TrackSimplifier.thumbnail(from: one, maxPoints: 60) == one)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `AuraCore/`): `swift test --filter TrackSimplifierTests`
Expected: FAIL — `TrackSimplifier` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Downsamples a coordinate list to a small, fixed-size polyline for History
/// thumbnails, so the list can draw a route shape without decoding the full track.
/// Uniform stride that always keeps the first and last points. Deterministic.
public enum TrackSimplifier {
    public static func thumbnail(from coordinates: [Coordinate], maxPoints: Int = 60) -> [Coordinate] {
        guard maxPoints >= 2 else { return Array(coordinates.prefix(1)) }
        guard coordinates.count > maxPoints else { return coordinates }
        let last = coordinates.count - 1
        return (0..<maxPoints).map { i in
            let t = Double(i) / Double(maxPoints - 1)   // 0...1, inclusive of both ends
            return coordinates[Int((t * Double(last)).rounded())]
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TrackSimplifierTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/TrackSimplifier.swift AuraCore/Tests/AuraCoreTests/TrackSimplifierTests.swift
git commit -m "feat(core): add TrackSimplifier for ride thumbnails

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Versioned schema + RideSummary + mapper

Split `RideRecord` into V1 (frozen) and V2 (new shape), add the `RideSummary` type, and update the mapper to fill the new columns and project summaries. After this task the package compiles on the V2 schema and the in-memory store works; on-disk migration is wired in Task 3.

**Files:**
- Create: `AuraCore/Sources/AuraCore/Models/RideSummary.swift`
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV1.swift`
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift`
- Delete: `AuraCore/Sources/AuraKit/Persistence/RideRecord.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideMapperTests.swift` (extend)

- [ ] **Step 1: Create the `RideSummary` value type**

`AuraCore/Sources/AuraCore/Models/RideSummary.swift`:

```swift
import Foundation

/// The lightweight projection History and the dashboard read. Carries only cheap,
/// denormalized columns, never the GPS track or the encoded stats blob.
public struct RideSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: Ride.Kind
    public let startedAt: Date
    public let endedAt: Date?
    /// True when the ride was saved with computed stats. Lets the last-ride card
    /// keep showing "—" for a statless ride instead of a real zero.
    public let hasStats: Bool
    public let distanceMeters: Double
    public let movingTimeSeconds: Double
    public let elevationGainMeters: Double
    public let destinationName: String?
    /// Simplified route for the thumbnail; empty when the ride has no drawable track.
    public let thumbnailCoordinates: [Coordinate]

    public init(id: UUID, kind: Ride.Kind, startedAt: Date, endedAt: Date?,
                hasStats: Bool, distanceMeters: Double, movingTimeSeconds: Double,
                elevationGainMeters: Double, destinationName: String?,
                thumbnailCoordinates: [Coordinate]) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.hasStats = hasStats
        self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
        self.elevationGainMeters = elevationGainMeters
        self.destinationName = destinationName
        self.thumbnailCoordinates = thumbnailCoordinates
    }
}
```

- [ ] **Step 2: Create the frozen V1 schema**

`AuraCore/Sources/AuraKit/Persistence/RideSchemaV1.swift` (this is the current model verbatim, nested under the schema enum):

```swift
import Foundation
import SwiftData

/// The persisted shape as it shipped before Wave 1 persistence. Frozen: do not
/// change it. It exists so the migration has a real "from" version and the
/// round-trip migration test can write old-shaped rows.
public enum RideSchemaV1: VersionedSchema {
    public static var versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [RideRecord.self] }

    @Model
    public final class RideRecord {
        @Attribute(.unique) public var id: UUID
        public var kindRaw: String
        public var startedAt: Date
        public var endedAt: Date?
        public var trackData: Data        // JSON-encoded [TrackPoint]
        public var statsData: Data?       // JSON-encoded RideStats
        public var destinationName: String?
        public var routeId: UUID?
        public var destinationPlaceId: UUID?

        public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                    trackData: Data, statsData: Data?, destinationName: String? = nil,
                    routeId: UUID?, destinationPlaceId: UUID?) {
            self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
            self.trackData = trackData; self.statsData = statsData
            self.destinationName = destinationName
            self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
        }
    }
}
```

- [ ] **Step 3: Create the V2 schema + `RideRecord` typealias**

`AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift`:

```swift
import Foundation
import SwiftData

/// The current persisted shape. Drops `@Attribute(.unique)` (CloudKit-ready),
/// moves the GPS track to external storage so a summary fetch never faults it,
/// and denormalizes the summary numbers + a thumbnail polyline into columns.
public enum RideSchemaV2: VersionedSchema {
    public static var versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] { [RideRecord.self] }

    @Model
    public final class RideRecord {
        public var id: UUID
        public var kindRaw: String
        public var startedAt: Date
        public var endedAt: Date?
        @Attribute(.externalStorage) public var trackData: Data   // JSON-encoded [TrackPoint]
        public var statsData: Data?                                // JSON-encoded RideStats (canonical)
        // Denormalized summary columns (defaults let old rows migrate cleanly;
        // backfilled by RideMigrationPlan, written by RideMapper.record(from:)).
        public var distanceMeters: Double = 0
        public var movingTimeSeconds: Double = 0
        public var elevationGainMeters: Double = 0
        public var thumbnailData: Data? = nil                      // JSON-encoded [Coordinate]; nil when < 2 points
        public var destinationName: String?
        public var routeId: UUID?
        public var destinationPlaceId: UUID?

        public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                    trackData: Data, statsData: Data?,
                    distanceMeters: Double = 0, movingTimeSeconds: Double = 0,
                    elevationGainMeters: Double = 0, thumbnailData: Data? = nil,
                    destinationName: String? = nil, routeId: UUID?, destinationPlaceId: UUID?) {
            self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
            self.trackData = trackData; self.statsData = statsData
            self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
            self.elevationGainMeters = elevationGainMeters; self.thumbnailData = thumbnailData
            self.destinationName = destinationName
            self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
        }
    }
}

/// The rest of AuraKit refers to the current model as `RideRecord`.
public typealias RideRecord = RideSchemaV2.RideRecord
```

- [ ] **Step 4: Delete the old model file**

```bash
git rm AuraCore/Sources/AuraKit/Persistence/RideRecord.swift
```

- [ ] **Step 5: Write the failing mapper test (extend RideMapperTests)**

Add to `AuraCore/Tests/AuraKitTests/RideMapperTests.swift`:

```swift
    func test_record_populatesDenormalizedColumns() throws {
        let ride = Ride(
            kind: .navigate, startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 100),
            track: [TrackPoint(coordinate: .init(latitude: 1, longitude: 1), elevation: nil,
                               timestamp: Date(timeIntervalSince1970: 0)),
                    TrackPoint(coordinate: .init(latitude: 2, longitude: 2), elevation: nil,
                               timestamp: Date(timeIntervalSince1970: 50))],
            stats: RideStats(distanceMeters: 1234, movingTimeSeconds: 600,
                             averageSpeedMetersPerSecond: 2, maxSpeedMetersPerSecond: 6,
                             elevationGainMeters: 42),
            destinationName: "Frick Park", routeId: nil, destinationPlaceId: nil)
        let record = try RideMapper.record(from: ride)
        XCTAssertEqual(record.distanceMeters, 1234, accuracy: 0.001)
        XCTAssertEqual(record.movingTimeSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(record.elevationGainMeters, 42, accuracy: 0.001)
        XCTAssertNotNil(record.thumbnailData)
    }

    func test_summary_mapsColumnsWithoutTrack() throws {
        let ride = Ride(
            kind: .freeRide, startedAt: Date(timeIntervalSince1970: 10), endedAt: nil,
            track: [], stats: nil, routeId: nil, destinationPlaceId: nil)
        let summary = RideMapper.summary(from: try RideMapper.record(from: ride))
        XCTAssertEqual(summary.id, ride.id)
        XCTAssertEqual(summary.kind, .freeRide)
        XCTAssertFalse(summary.hasStats)
        XCTAssertEqual(summary.distanceMeters, 0, accuracy: 0.001)
        XCTAssertTrue(summary.thumbnailCoordinates.isEmpty)
    }
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --filter RideMapperTests`
Expected: FAIL — `record.distanceMeters` / `RideMapper.summary` do not exist yet.

- [ ] **Step 7: Update `RideMapper`**

Replace `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift` with:

```swift
import Foundation
import AuraCore

public enum RideMapper {
    public static func record(from ride: Ride) throws -> RideRecord {
        let encoder = JSONEncoder()
        let thumb = TrackSimplifier.thumbnail(from: ride.track.map(\.coordinate))
        return RideRecord(
            id: ride.id,
            kindRaw: ride.kind.rawValue,
            startedAt: ride.startedAt,
            endedAt: ride.endedAt,
            trackData: try encoder.encode(ride.track),
            statsData: try ride.stats.map { try encoder.encode($0) },
            distanceMeters: ride.stats?.distanceMeters ?? 0,
            movingTimeSeconds: ride.stats?.movingTimeSeconds ?? 0,
            elevationGainMeters: ride.stats?.elevationGainMeters ?? 0,
            thumbnailData: thumb.count >= 2 ? try encoder.encode(thumb) : nil,
            destinationName: ride.destinationName,
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
            destinationName: record.destinationName,
            routeId: record.routeId,
            destinationPlaceId: record.destinationPlaceId)
    }

    /// Cheap projection for the list/dashboard. Reads only denormalized columns and
    /// the small thumbnail blob; never touches `trackData`, so the external blob
    /// never faults.
    public static func summary(from record: RideRecord) -> RideSummary {
        let coords: [Coordinate]
        if let data = record.thumbnailData,
           let decoded = try? JSONDecoder().decode([Coordinate].self, from: data) {
            coords = decoded
        } else {
            coords = []
        }
        return RideSummary(
            id: record.id,
            kind: Ride.Kind(rawValue: record.kindRaw) ?? .freeRide,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            hasStats: record.statsData != nil,
            distanceMeters: record.distanceMeters,
            movingTimeSeconds: record.movingTimeSeconds,
            elevationGainMeters: record.elevationGainMeters,
            destinationName: record.destinationName,
            thumbnailCoordinates: coords)
    }
}
```

- [ ] **Step 8: Run the full package test suite**

Run: `swift test`
Expected: PASS. Existing `RideStoreTests` and `RideMapperTests` round-trips still pass (the `Ride` round-trip is unchanged), plus the two new mapper cases. If `Package.resolved` was dirtied: `git checkout -- AuraCore/Package.resolved`.

- [ ] **Step 9: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models/RideSummary.swift \
        AuraCore/Sources/AuraKit/Persistence/RideSchemaV1.swift \
        AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift \
        AuraCore/Sources/AuraKit/Persistence/RideRecord.swift \
        AuraCore/Sources/AuraKit/Persistence/RideMapper.swift \
        AuraCore/Tests/AuraKitTests/RideMapperTests.swift
git commit -m "feat(persistence): versioned RideRecord schema + RideSummary projection

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Migration plan + persistent container + round-trip test

The headline of this sub-project: prove a V1 store upgrades to V2 without losing rides, with columns and thumbnails backfilled.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift` (add `persistent()`)
- Test: `AuraCore/Tests/AuraKitTests/RideMigrationTests.swift`

- [ ] **Step 1: Write the failing migration test**

`AuraCore/Tests/AuraKitTests/RideMigrationTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
struct RideMigrationTests {
    /// A unique on-disk store URL per run; cleaned up after.
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-migration-\(UUID().uuidString).store")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    @Test func migratesV1StoreToV2BackfillingColumnsAndThumbnail() throws {
        let url = tempStoreURL()
        defer {
            for ext in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ext))
            }
        }

        let navId = UUID()
        let freeId = UUID()
        let track = (0..<200).map {
            TrackPoint(coordinate: .init(latitude: Double($0) * 0.001, longitude: Double($0) * 0.001),
                       elevation: nil, timestamp: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        let stats = RideStats(distanceMeters: 5000, movingTimeSeconds: 1800,
                              averageSpeedMetersPerSecond: 2.7, maxSpeedMetersPerSecond: 9,
                              elevationGainMeters: 120)

        // 1. Write two V1-shaped rows, then release the container.
        do {
            let cfg = ModelConfiguration(url: url)
            let v1 = try ModelContainer(for: RideSchemaV1.RideRecord.self, configurations: cfg)
            let ctx = v1.mainContext
            ctx.insert(RideSchemaV1.RideRecord(
                id: navId, kindRaw: "navigate", startedAt: Date(timeIntervalSince1970: 1000),
                endedAt: Date(timeIntervalSince1970: 2800),
                trackData: try encode(track), statsData: try encode(stats),
                destinationName: "Frick Park", routeId: nil, destinationPlaceId: nil))
            ctx.insert(RideSchemaV1.RideRecord(
                id: freeId, kindRaw: "freeRide", startedAt: Date(timeIntervalSince1970: 500),
                endedAt: nil, trackData: try encode([TrackPoint]()), statsData: nil,
                destinationName: nil, routeId: nil, destinationPlaceId: nil))
            try ctx.save()
        }

        // 2. Reopen the same file through the migration plan on V2.
        let cfg = ModelConfiguration(url: url)
        let v2 = try ModelContainer(for: RideRecord.self,
                                    migrationPlan: RideMigrationPlan.self,
                                    configurations: cfg)
        let records = try v2.mainContext.fetch(
            FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))

        #expect(records.count == 2)
        let nav = try #require(records.first { $0.id == navId })
        let free = try #require(records.first { $0.id == freeId })

        // Track bytes intact.
        let decodedTrack = try JSONDecoder().decode([TrackPoint].self, from: nav.trackData)
        #expect(decodedTrack.count == 200)

        // Stat columns backfilled from the old statsData blob.
        #expect(nav.distanceMeters == 5000)
        #expect(nav.movingTimeSeconds == 1800)
        #expect(nav.elevationGainMeters == 120)
        #expect(free.distanceMeters == 0)

        // Thumbnail backfilled for the ride with a track, nil for the empty one.
        #expect(nav.thumbnailData != nil)
        #expect(free.thumbnailData == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RideMigrationTests`
Expected: FAIL — `RideMigrationPlan` does not exist.

(Note on the API: `ModelConfiguration(url:)` opens a store at a specific file URL. If the toolchain's signature differs, consult the `swiftdata` skill; the two-scope pattern — write with a V1 container, release it, then reopen with the plan — is the part that matters.)

- [ ] **Step 3: Write the migration plan**

`AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift`:

```swift
import Foundation
import SwiftData
import AuraCore

/// V1 → V2: drops `.unique`, moves the track to external storage, and adds the
/// denormalized summary columns + thumbnail. The stage is custom because the new
/// columns are computed from existing rows, which a lightweight stage cannot do.
public enum RideMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [RideSchemaV1.self, RideSchemaV2.self]
    }

    public static var stages: [MigrationStage] { [migrateV1toV2] }

    public static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: RideSchemaV1.self,
        toVersion: RideSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let records = try context.fetch(FetchDescriptor<RideSchemaV2.RideRecord>())
            for record in records {
                if let statsData = record.statsData,
                   let stats = try? decoder.decode(RideStats.self, from: statsData) {
                    record.distanceMeters = stats.distanceMeters
                    record.movingTimeSeconds = stats.movingTimeSeconds
                    record.elevationGainMeters = stats.elevationGainMeters
                }
                if let track = try? decoder.decode([TrackPoint].self, from: record.trackData) {
                    let thumb = TrackSimplifier.thumbnail(from: track.map(\.coordinate))
                    record.thumbnailData = thumb.count >= 2 ? try? encoder.encode(thumb) : nil
                }
            }
            try context.save()
        })
}
```

- [ ] **Step 4: Add `RideStore.persistent()`**

In `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`, add this factory next to `inMemory()`:

```swift
    /// The app's on-disk store, with the migration plan wired in. This is the only
    /// container that migrates; `inMemory()` always starts fresh on the current schema.
    public static func persistent() throws -> RideStore {
        let container = try ModelContainer(for: RideRecord.self,
                                           migrationPlan: RideMigrationPlan.self)
        return RideStore(container: container)
    }
```

- [ ] **Step 5: Run the migration test**

Run: `swift test --filter RideMigrationTests`
Expected: PASS. If it fails on the `trackData` storage change (data not carried), consult the `swiftdata` skill and move the track/stats capture into `willMigrate`; the assertions stay the same.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS (all prior + the migration test). `git checkout -- AuraCore/Package.resolved` if dirtied.

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift \
        AuraCore/Sources/AuraKit/Persistence/RideStore.swift \
        AuraCore/Tests/AuraKitTests/RideMigrationTests.swift
git commit -m "feat(persistence): custom V1->V2 migration with round-trip test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: RideStore read path

`summaries()` (track-free, newest first) and `ride(id:)` (full decode for the detail sheet).

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideStoreSummaryTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/RideStoreSummaryTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
struct RideStoreSummaryTests {
    private func ride(_ t: TimeInterval, distance: Double) -> Ride {
        Ride(kind: .navigate, startedAt: Date(timeIntervalSince1970: t),
             endedAt: Date(timeIntervalSince1970: t + 100),
             track: [TrackPoint(coordinate: .init(latitude: 1, longitude: 1), elevation: nil,
                                timestamp: Date(timeIntervalSince1970: t)),
                     TrackPoint(coordinate: .init(latitude: 2, longitude: 2), elevation: nil,
                                timestamp: Date(timeIntervalSince1970: t + 50))],
             stats: RideStats(distanceMeters: distance, movingTimeSeconds: 100,
                              averageSpeedMetersPerSecond: 1, maxSpeedMetersPerSecond: 2,
                              elevationGainMeters: 5),
             destinationName: "X", routeId: nil, destinationPlaceId: nil)
    }

    @Test func summariesAreNewestFirstAndCarryColumns() throws {
        let store = try RideStore.inMemory()
        try store.save(ride(100, distance: 10))
        try store.save(ride(300, distance: 30))
        try store.save(ride(200, distance: 20))
        let summaries = try store.summaries()
        #expect(summaries.map(\.startedAt.timeIntervalSince1970) == [300, 200, 100])
        #expect(summaries.first?.distanceMeters == 30)
        #expect(summaries.first?.thumbnailCoordinates.count == 2)
    }

    @Test func rideByIdReturnsFullTrack() throws {
        let store = try RideStore.inMemory()
        let r = ride(100, distance: 10)
        try store.save(r)
        let full = try #require(try store.ride(id: r.id))
        #expect(full.track.count == 2)
        #expect(full.stats?.distanceMeters == 10)
    }

    @Test func rideByIdMissingIsNil() throws {
        let store = try RideStore.inMemory()
        #expect(try store.ride(id: UUID()) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RideStoreSummaryTests`
Expected: FAIL — `summaries()` / `ride(id:)` undefined.

- [ ] **Step 3: Add the methods**

In `RideStore.swift`, after `allRides()`:

```swift
    /// Lightweight, newest-first projection for the list and dashboard. Never reads
    /// `trackData`, so the external blob never faults.
    public func summaries() throws -> [RideSummary] {
        let descriptor = FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try container.mainContext.fetch(descriptor).map(RideMapper.summary(from:))
    }

    /// The full ride (track + stats), for opening one ride into the detail sheet.
    public func ride(id: UUID) throws -> Ride? {
        let descriptor = FetchDescriptor<RideRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try container.mainContext.fetch(descriptor).first else { return nil }
        return try RideMapper.ride(from: record)
    }
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter RideStoreSummaryTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideStore.swift \
        AuraCore/Tests/AuraKitTests/RideStoreSummaryTests.swift
git commit -m "feat(persistence): RideStore.summaries() and ride(id:) read path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: RideAggregator on summaries

The dashboard rollup reads `[RideSummary]` instead of `[Ride]`. Behavior is identical: statless rides carry `0` columns, so they still count and add no distance.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Home/RideAggregator.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideAggregatorTests.swift` (rewrite helper + call sites)

- [ ] **Step 1: Update the test to build `[RideSummary]`**

In `RideAggregatorTests.swift`, replace the `ride(...)` helper and its uses. New helper:

```swift
    private func summary(day: Int, distance: Double?, elevation: Double = 30, moving: Double = 600) -> RideSummary {
        let start = date(day)
        return RideSummary(
            id: UUID(), kind: .navigate, startedAt: start,
            endedAt: start.addingTimeInterval(moving),
            hasStats: distance != nil,
            distanceMeters: distance ?? 0,
            movingTimeSeconds: distance == nil ? 0 : moving,
            elevationGainMeters: distance == nil ? 0 : elevation,
            destinationName: nil, thumbnailCoordinates: [])
    }
```

Then change every `ride(day:...)` call to `summary(day:...)`. The assertions are unchanged. `test_mostRecent_returnsLatestStart` still reads `.startedAt` on the returned `RideSummary?`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RideAggregatorTests`
Expected: FAIL — `weekToDate`/`mostRecent` still take `[Ride]`.

- [ ] **Step 3: Update `RideAggregator`**

Change the two method signatures and the loop body in `RideAggregator.swift`:

```swift
    public static func weekToDate(_ rides: [RideSummary], now: Date,
                                  calendar: Calendar = .current) -> WeeklyRideStats {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return .zero }
        var out = WeeklyRideStats.zero
        for ride in rides where week.contains(ride.startedAt) {
            out.rideCount += 1
            out.distanceMeters += ride.distanceMeters
            out.elevationGainMeters += ride.elevationGainMeters
            out.movingTimeSeconds += ride.movingTimeSeconds
        }
        return out
    }

    public static func mostRecent(_ rides: [RideSummary]) -> RideSummary? {
        rides.max { $0.startedAt < $1.startedAt }
    }
```

Update the doc comments to say "summaries" rather than "rides with computed stats" where relevant.

- [ ] **Step 4: Run the test**

Run: `swift test --filter RideAggregatorTests`
Expected: PASS.

- [ ] **Step 5: Run the full package suite**

Run: `swift test`
Expected: PASS (whole package green). `git checkout -- AuraCore/Package.resolved` if dirtied.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Home/RideAggregator.swift \
        AuraCore/Tests/AuraKitTests/RideAggregatorTests.swift
git commit -m "refactor(home): RideAggregator reads RideSummary

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: App wiring

Move the three screens onto the summary read path and wire the migrating container. No unit tests (the project does not unit-test views); correctness is the app build plus a simulator smoke test at finish.

**Files:**
- Modify: `Aura/Sources/AuraApp.swift`
- Modify: `Aura/Sources/Plan/LastRideCard.swift`
- Modify: `Aura/Sources/Plan/PlanView.swift`
- Modify: `Aura/Sources/History/HistoryView.swift`

- [ ] **Step 1: `AuraApp.makeRideStore()` uses the migrating container**

Replace the body of `makeRideStore()`:

```swift
    @MainActor static func makeRideStore() -> RideStore {
        do {
            return try RideStore.persistent()
        } catch {
            assertionFailure("Failed to build persistent ModelContainer: \(error)")
            return (try? RideStore.inMemory()) ?? {
                fatalError("Could not create any RideStore: \(error)")
            }()
        }
    }
```

`import SwiftData` is no longer needed in `AuraApp.swift` if nothing else uses it — remove the import only if the build warns it is unused.

- [ ] **Step 2: `LastRideCard` takes a `RideSummary`**

Change the stored property and the three reads. Replace `let ride: Ride` with `let summary: RideSummary`, and update the members:

```swift
    let summary: RideSummary
    let units: DistanceUnits
    let onTap: () -> Void

    // thumbnail:
    private var thumbnail: some View {
        let coords = summary.thumbnailCoordinates
        let isNavigate = summary.kind == .navigate
        // ... unchanged ZStack, using `coords` and `isNavigate` ...
    }

    private var title: String {
        if let name = summary.destinationName, !name.isEmpty { return name }
        return summary.kind == .navigate ? "Ride" : "Free ride"
    }

    private var statsLine: String {
        guard summary.hasStats else { return "—" }
        return "\(fmt.distanceValue(summary.distanceMeters)) \(fmt.distanceUnit) · \(fmt.minutes(summary.movingTimeSeconds))"
    }

    private var relativeDate: String {
        // identical, but read summary.startedAt
    }
```

- [ ] **Step 3: `PlanView` reads summaries**

```swift
    @State private var summaries: [RideSummary] = []

    private var weekStats: WeeklyRideStats {
        RideAggregator.weekToDate(summaries, now: Date())
    }
    private var lastRide: RideSummary? { RideAggregator.mostRecent(summaries) }

    private func loadRides() async {
        summaries = (try? rideStore.summaries()) ?? []
    }
```

And `lastRideSection(_ ride: RideSummary)` passes `LastRideCard(summary: ride, units: settings.units) { router.selectedTab = .history }`.

- [ ] **Step 4: `HistoryView` reads summaries; tap fetches the full ride**

```swift
    @State private var summaries: [RideSummary] = []
    @State private var selected: Ride?     // unchanged type: the sheet needs a full Ride

    // body: iterate `summaries`; empty check on `summaries.isEmpty`.
    // onAppear:
    summaries = (try? store.summaries()) ?? []

    // rideList ForEach:
    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
        RideRow(summary: summary, units: settings.units)
            // ...
            .onTapGesture { selected = try? store.ride(id: summary.id) }
            // ...
            .swipeActions(...) { Button(role: .destructive) { delete(summary) } ... }
    }

    private func delete(_ summary: RideSummary) {
        try? store.delete(id: summary.id)
        summaries.removeAll { $0.id == summary.id }
    }
```

Rewrite the private `RideRow` to take a `RideSummary`:

```swift
private struct RideRow: View {
    let summary: RideSummary
    let units: DistanceUnits

    private var isNavigate: Bool { summary.kind == .navigate }
    private var symbol: String { isNavigate ? "location.north.line.fill" : "bicycle" }
    private var symbolWeight: Font.Weight { isNavigate ? .semibold : .medium }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: units) }

    private var caption: String {
        let lead: String
        if let name = summary.destinationName, !name.isEmpty { lead = name }
        else { lead = isNavigate ? "Navigated" : "Free ride" }
        let climb = "\(fmt.elevationValue(summary.elevationGainMeters)) \(fmt.elevationUnit)"
        return "\(lead) · \(fmt.minutes(summary.movingTimeSeconds)) · ↑ \(climb)"
    }

    private var distance: String { fmt.distanceValue(summary.distanceMeters) }
    private var distanceUnit: String { fmt.distanceUnit.uppercased() }

    @ViewBuilder
    private var leadingThumbnail: some View {
        let coords = summary.thumbnailCoordinates
        if coords.count > 1 {
            RouteThumbnail(coordinates: coords, lineColor: AuraTheme.accent, lineWidth: 2)
        } else {
            Image(systemName: symbol)
                .font(.headline.weight(symbolWeight))
                .foregroundStyle(AuraTheme.accent)
        }
    }

    // body: unchanged layout, reading `summary.startedAt`, `caption`, `distance`, `distanceUnit`.
}
```

- [ ] **Step 5: Build the app + run the package suite**

Delegate to `apple-platform-build-tools:builder`:
- `swift test` from `AuraCore/` — expected PASS (all suites).
- `xcodebuild` build of the `Aura` app scheme for the iPhone 17 simulator — expected BUILD SUCCEEDED.
- SwiftLint `--strict` (the pinned 0.64.1) over changed files — expected clean. Watch for `large_tuple` / `multiple_closures_with_trailing_closure` as seen before.

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/AuraApp.swift Aura/Sources/Plan/LastRideCard.swift \
        Aura/Sources/Plan/PlanView.swift Aura/Sources/History/HistoryView.swift
git commit -m "feat(app): History and dashboard read the summary path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done criteria

- `swift test` green: existing 125 plus the new TrackSimplifier, migration, summary, and updated aggregator/mapper cases.
- The round-trip migration test proves a V1 store upgrades to V2 with row count, track bytes, stat columns, and thumbnails intact.
- The app builds for the iPhone 17 simulator and SwiftLint `--strict` is clean.
- History list, the dashboard weekly ring, and the last-ride card render from summaries; opening a ride still shows the full route. Verified on the simulator at finish (free ride and navigate-to-a-destination, each start → summary → home, ride persisted).
- `AuraCore/Package.resolved` is not staged in any commit.
```
