# Unfinished-ride treatment (ROH-107) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mark a ride the rider never ended, say what its recording covers, and keep the ride currently being recorded out of Home, the widget and the weekly ring.

**Architecture:** A new `checkpointedAt: Date?` on `Ride` / `RideRecord` (schema V7) is set by the pause-boundary flush and cleared by `finish()`, so `isUnfinished` is a derived read and no new bookkeeping exists. Separately and independently, `AppRouter` learns the active ride's id, and the glance surfaces filter it out — the marker is about *what a row is*, the exclusion is about *which row you are on*.

**Tech Stack:** Swift 6, SwiftUI, SwiftData with `NSPersistentCloudKitContainer` mirroring, Swift Testing (`@Test` / `#expect`), XcodeGen (`Aura/project.yml`).

**Spec:** `docs/superpowers/specs/2026-07-29-roh107-unfinished-ride-design.md` (revision 2).

## Global Constraints

Every task's requirements implicitly include these. Values are copied verbatim from the spec.

- **The entity name stays `RideRecord`.** CloudKit derives its record type from it; a rename orphans every already-synced ride.
- **CloudKit rules, machine-checked by `SchemaInvariantTests`:** optionality or a default on every attribute, no `.unique`, no relationships. Date defaults use the fixed sentinel `Date(timeIntervalSince1970: 0)`, never `.now`.
- **`RideStore.save`'s update branch is a hand-written field copy.** Every new `RideRecord` attribute must be added to it. Pass 3 hit this exact trap with `segmentsData`; missing it here means every paused ride stays unfinished forever.
- **The marker is not amber.** Amber carries peer-stopped and `AuraTheme.warning` (used by `GPSSignalChip` for weak/lost GPS). Use neutral secondary weight.
- **Marker copy describes the recording, not the rider.** It must be true both for a recovered ride and for a ride still running on another device. "No end recorded" is correct; "You never finished this ride" is not.
- **`activeRideID` parameters carry no default.** A defaulted `nil` lets a new call site leak silently.
- **Do not bump `WidgetSnapshot.currentVersion`.** It stays `1`. New fields are optional and decode as nil from an existing payload.
- **`checkpointedAt` is `Date?` on `Ride`, `RideRecord`, `RideSummary`, and `WidgetSnapshot.LastRide`.** Same name at every layer.
- **ROH-108 is blocked until this lands.** The CloudKit production promotion must cover `CD_segmentsData`, `CD_pausedSeconds` and `CD_checkpointedAt` in one deploy. Do not tell anyone to promote mid-plan.

**Running tests:** the package is at `AuraCore/`. `cd AuraCore && swift test --filter <SuiteOrTestName>`. Note `swift test` prints **two** totals (one per test target); read both. App-target builds go through the `apple-platform-build-tools:builder` agent, not `xcodebuild` directly.

---

## File Structure

**Created:**
- `AuraCore/Sources/AuraKit/Persistence/RideSchemaV7.swift` — V7 `RideRecord` with `checkpointedAt`, and the `RideRecord` typealias.
- `AuraCore/Sources/AuraKit/Summary/UnfinishedRideCopy.swift` — pure copy helper, so the strings are unit-testable without a view.
- `Aura/Sources/Shared/UnfinishedRideBadge.swift` — the shared marker view.
- `AuraCore/Tests/AuraKitTests/SchemaV7MigrationTests.swift`
- `AuraCore/Tests/AuraKitTests/UnfinishedRideCopyTests.swift`
- `AuraCore/Tests/AuraCoreTests/RideSummaryUnfinishedTests.swift`

**Modified:**
- `AuraCore/Sources/AuraCore/Models/Ride.swift` — `checkpointedAt` property + both inits.
- `AuraCore/Sources/AuraCore/Models/RideSummary.swift` — `checkpointedAt` + `isUnfinished`.
- `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift` — V6→V7 lightweight stage.
- `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift` — pass the field through all three directions.
- `AuraCore/Sources/AuraKit/Persistence/RideStore.swift:78-102` — the update branch.
- `AuraCore/Sources/AuraKit/RideRecorder.swift:152-157` — `checkpoint(at:)`; `end(at:)` below it.
- `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:229-250` — `finish()` ordering, new `activeRideID`.
- `Aura/Sources/App/AppRouter.swift:15` — `activeRideID`, computed `isRideActive`.
- `Aura/Sources/Ride/RideHUDView.swift:195,203` and `Aura/Sources/Ride/NavigateHUDView.swift:236,253` — write the id.
- `AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift` — `make(activeRideID:)`, `LastRide` fields.
- `Aura/Sources/Widgets/WidgetRefresh.swift:12-17` — `reload(activeRideID:)`, plus its 8 call sites.
- `Aura/Sources/Home/HomeView.swift:46-47,86` — filter at source, reload on the edge.
- `Aura/Sources/History/HistoryView.swift` — marker slot, delete confirmation.
- `Aura/Sources/Plan/LastRideCard.swift`, `Aura/Sources/Ride/RideSummaryView.swift`, `Aura/Widgets/LastRideWidget.swift` — marker.
- `AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift` — guard V7.

---

### Task 1: `checkpointedAt` through the model and schema V7

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Models/Ride.swift:8,30-38,48-56`
- Modify: `AuraCore/Sources/AuraCore/Models/RideSummary.swift`
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV7.swift`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV6.swift:90-92` (remove the typealias)
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift:12-19`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift:18-33,38-48,92-103`
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideStore.swift:83-96`
- Modify: `AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift:22,45-47`
- Test: `AuraCore/Tests/AuraKitTests/SchemaV7MigrationTests.swift` (create)
- Test: `AuraCore/Tests/AuraKitTests/RideMapperTests.swift` (append)
- Test: `AuraCore/Tests/AuraKitTests/RideStoreTests.swift` (append)

**Interfaces:**
- Produces: `Ride.checkpointedAt: Date?` (both inits gain `checkpointedAt: Date? = nil` after `pausedSeconds`), `RideSummary.checkpointedAt: Date?` (init param after `pausedSeconds`, defaulted `nil`), `RideSchemaV7.RideRecord` with `public var checkpointedAt: Date?`, `public typealias RideRecord = RideSchemaV7.RideRecord`.

- [ ] **Step 1: Write the failing store test — the update-branch trap**

Append to `AuraCore/Tests/AuraKitTests/RideStoreTests.swift`, inside the existing suite:

```swift
/// `RideStore.save`'s update branch is a hand-written field copy. Pass 3 shipped
/// `segmentsData` and nearly missed this; a missed copy here means `finish()` never clears
/// the marker and every paused ride stays unfinished forever.
@Test func savingOverACheckpointClearsCheckpointedAt() throws {
    let store = try RideStore.inMemory()
    let id = UUID()
    let start = Date(timeIntervalSince1970: 1_000)
    let checkpoint = Ride(id: id, kind: .freeRide, startedAt: start,
                          endedAt: Date(timeIntervalSince1970: 1_600),
                          track: [], stats: nil, pausedSeconds: 0,
                          checkpointedAt: Date(timeIntervalSince1970: 1_600),
                          routeId: nil, destinationPlaceId: nil)
    try store.save(checkpoint)
    #expect(try #require(store.summaries().first).checkpointedAt != nil)

    let finished = Ride(id: id, kind: .freeRide, startedAt: start,
                        endedAt: Date(timeIntervalSince1970: 2_000),
                        track: [], stats: nil, pausedSeconds: 0,
                        checkpointedAt: nil,
                        routeId: nil, destinationPlaceId: nil)
    try store.save(finished)

    let rows = try store.summaries()
    #expect(rows.count == 1, "the upsert must update, not duplicate")
    #expect(rows[0].checkpointedAt == nil, "the update branch dropped checkpointedAt")
}
```

If `RideStore.inMemory()` is not the existing helper name in that file, use whatever the neighbouring tests already use to build a store; do not invent a new one.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd AuraCore && swift test --filter savingOverACheckpointClearsCheckpointedAt`
Expected: FAIL to compile — `Ride` has no `checkpointedAt` parameter.

- [ ] **Step 3: Add `checkpointedAt` to the domain models**

In `Ride.swift`, after the `pausedSeconds` property (line 23):

```swift
    /// When the pause-boundary flush last wrote this ride, or nil once the rider ends it.
    /// Non-nil means the row is a checkpoint: either a ride a kill left behind, or one still
    /// being recorded on another device. It is when *recording* stopped, which is not
    /// necessarily when the rider stopped riding — the recording may also be short, if the
    /// rider resumed and was killed later while moving.
    public var checkpointedAt: Date?
```

Add `checkpointedAt: Date? = nil` to both inits immediately after `pausedSeconds`, and assign it in both bodies. The convenience init at line 48 forwards it.

In `RideSummary.swift`, add the same property with a matching doc comment after `pausedSeconds` (line 26), add `checkpointedAt: Date? = nil` to the init after `pausedSeconds`, and assign it.

- [ ] **Step 4: Create schema V7**

Create `AuraCore/Sources/AuraKit/Persistence/RideSchemaV7.swift`:

```swift
import Foundation
import SwiftData
import AuraCore

/// V7 adds `checkpointedAt` — when the pause-boundary flush last wrote the row, nil once the
/// rider ends the ride (ROH-107). One optional attribute, so the stage is lightweight and
/// nothing moves at launch.
///
/// **The entity name stays `RideRecord`.** CloudKit derives its record type from it, so a
/// rename produces a new `CD_` type and orphans every already-synced ride.
///
/// CloudKit rules hold: optionality or a default on every attribute, no `.unique`, no
/// relationships — machine-checked by `SchemaInvariantTests`. Date defaults are the fixed
/// sentinel, per the V2 comment.
///
/// **Why a column rather than a nil `endedAt`.** Revision 1 of the spec used nil `endedAt` and
/// needed no schema change. Two things a nil cannot do: tell a second synced device that the
/// row is being recorded *right now* rather than abandoned, and say what the recording covers
/// when the rider resumed and was killed later while riding. See the spec's D1.
public enum RideSchemaV7: VersionedSchema {
    public static let versionIdentifier = Schema.Version(7, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [RideRecord.self, RideSchemaV5.SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self]
    }

    @Model
    public final class RideRecord {
        public var id: UUID = UUID()
        public var kindRaw: String = "free"
        // Fixed sentinel, not `.now`: a default is only used when CloudKit materializes a
        // record missing this key, and "now" would be a misleading start time.
        public var startedAt: Date = Date(timeIntervalSince1970: 0)
        public var endedAt: Date?
        /// Flat, complete JSON `[TrackPoint]`. Still written from V6 on: a V5 build syncing
        /// the same CloudKit record reads this and only this, so it must never go partial.
        @Attribute(.externalStorage) public var trackData: Data = Data()
        /// JSON-encoded `[RideSegment]` — the segmented truth V6 exists for.
        @Attribute(.externalStorage) public var segmentsData: Data?
        public var statsData: Data?
        public var distanceMeters: Double = 0
        public var movingTimeSeconds: Double = 0
        public var pausedSeconds: Double = 0
        /// Set by the pause-boundary flush, cleared by `finish()`. Nil on every row written
        /// before V7, which is the correct reading: they all came from `finish()`.
        public var checkpointedAt: Date?
        public var elevationGainMeters: Double = 0
        public var thumbnailData: Data?
        public var destinationName: String?
        public var routeId: UUID?
        public var destinationPlaceId: UUID?

        public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                    trackData: Data, segmentsData: Data?, statsData: Data?,
                    distanceMeters: Double = 0, movingTimeSeconds: Double = 0,
                    pausedSeconds: Double = 0, checkpointedAt: Date? = nil,
                    elevationGainMeters: Double = 0,
                    thumbnailData: Data? = nil, destinationName: String? = nil,
                    routeId: UUID?, destinationPlaceId: UUID?) {
            self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
            self.trackData = trackData; self.segmentsData = segmentsData; self.statsData = statsData
            self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
            self.pausedSeconds = pausedSeconds; self.checkpointedAt = checkpointedAt
            self.elevationGainMeters = elevationGainMeters
            self.thumbnailData = thumbnailData; self.destinationName = destinationName
            self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
        }
    }
}

/// The rest of AuraKit refers to the current model as `RideRecord`.
public typealias RideRecord = RideSchemaV7.RideRecord
```

Delete the `public typealias RideRecord = RideSchemaV6.RideRecord` at `RideSchemaV6.swift:92` and its comment at `:90-91`, leaving V6's class frozen for its stage.

- [ ] **Step 5: Register V7 in the migration plan**

In `RideMigrationPlan.swift`, add `RideSchemaV7.self` to `schemas` (line 13-14) and `migrateV6toV7` to `stages` (line 18), then add the stage after `migrateV5toV6`:

```swift
    /// V7 redeclares `RideRecord` with one optional attribute (`checkpointedAt`) added, which
    /// is exactly what a lightweight stage handles, so **no data moves at launch**.
    ///
    /// No backfill, and none is possible: nil is the correct value for every existing row.
    /// They were all written by `finish()`, which is the only pre-V7 path that persists a
    /// ride other than the pause flush, and a flushed row that was later finished was
    /// upserted in place. A row still sitting as a pre-V7 checkpoint reads as finished, which
    /// is what it read as before this schema existed.
    public static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: RideSchemaV6.self,
        toVersion: RideSchemaV7.self)
```

- [ ] **Step 6: Pass the field through `RideMapper`**

Three edits in `RideMapper.swift`:

```swift
// in record(from:), after `pausedSeconds: ride.pausedSeconds,` (line 28):
            checkpointedAt: ride.checkpointedAt,
```
```swift
// in ride(from:), after `pausedSeconds: record.pausedSeconds,` (line 45):
            checkpointedAt: record.checkpointedAt,
```
```swift
// in summary(from:), after `pausedSeconds: record.pausedSeconds,` (line 100):
            checkpointedAt: record.checkpointedAt,
```

Match each call's argument order to the initializer you wrote in Step 3 / Step 4.

- [ ] **Step 7: Add the field to `RideStore.save`'s update branch**

In `RideStore.swift`, after `existing.pausedSeconds = record.pausedSeconds` (line 88):

```swift
            existing.checkpointedAt = record.checkpointedAt
```

- [ ] **Step 8: Point `SchemaInvariantTests` at V7 and pin the new attribute**

In `SchemaInvariantTests.swift`, change line 22 to `Schema(versionedSchema: RideSchemaV7.self).entities`, update the doc comment's `RideSchemaV6` references to V7, and append inside the suite:

```swift
    /// `checkpointedAt` must be optional: nil is how "the rider ended this ride" is
    /// representable, and CloudKit requires optionality or a default regardless.
    @Test func checkpointedAtIsOptional() {
        let ride = entities.first { $0.name == "RideRecord" }
        let attribute = ride?.attributes.first { $0.name == "checkpointedAt" }
        #expect(attribute != nil, "V7 must carry checkpointedAt")
        #expect(attribute?.isOptional == true)
    }
```

- [ ] **Step 9: Run the store test to verify it passes**

Run: `cd AuraCore && swift test --filter savingOverACheckpointClearsCheckpointedAt`
Expected: PASS

- [ ] **Step 10: Write the migration and mapper tests**

Create `AuraCore/Tests/AuraKitTests/SchemaV7MigrationTests.swift`, modelled on the existing `SchemaV6MigrationTests.swift` — read that file first and mirror its container setup, including `cloudKitDatabase: .none` (macOS CI has no CloudKit entitlement) and the `.swiftDataSerialized` suite trait:

```swift
import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@Suite("Schema V6 → V7", .swiftDataSerialized)
struct SchemaV7MigrationTests {

    /// Every V6 row survives, and arrives with `checkpointedAt` nil — the correct reading,
    /// since every pre-V7 row was written by `finish()`.
    @Test func v6RowsMigrateWithANilCheckpoint() throws {
        // Mirror SchemaV6MigrationTests' helper: open a store as V6, insert rows, reopen
        // under RideMigrationPlan, then assert.
        let url = URL.temporaryDirectory.appending(path: "v7-\(UUID().uuidString).store")
        let id = UUID()
        do {
            let container = try ModelContainer(
                for: RideSchemaV6.RideRecord.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            container.mainContext.insert(RideSchemaV6.RideRecord(
                id: id, kindRaw: "freeRide", startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 2_000), trackData: Data(),
                segmentsData: nil, statsData: nil, routeId: nil, destinationPlaceId: nil))
            try container.mainContext.save()
        }

        let migrated = try ModelContainer(
            for: RideRecord.self, migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let rows = try migrated.mainContext.fetch(FetchDescriptor<RideRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rows.first?.checkpointedAt == nil)
    }
}
```

Append to `AuraCore/Tests/AuraKitTests/RideMapperTests.swift`:

```swift
@Test func checkpointedAtRoundTripsThroughTheRecordAndTheSummary() throws {
    let stamp = Date(timeIntervalSince1970: 1_600)
    let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 1_000),
                    endedAt: stamp, track: [], stats: nil, pausedSeconds: 0,
                    checkpointedAt: stamp, routeId: nil, destinationPlaceId: nil)
    let record = try RideMapper.record(from: ride)
    #expect(record.checkpointedAt == stamp)
    #expect(try RideMapper.ride(from: record).checkpointedAt == stamp)
    #expect(RideMapper.summary(from: record).checkpointedAt == stamp)
}
```

- [ ] **Step 11: Run the full package suite**

Run: `cd AuraCore && swift test`
Expected: PASS, both totals. Any pre-existing test that constructs a `Ride`, `RideSummary` or `RideRecord` positionally will need the new argument; fix those call sites rather than reordering the initializers.

- [ ] **Step 12: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models AuraCore/Sources/AuraKit/Persistence AuraCore/Tests/AuraKitTests
git commit -m "feat(roh-107): schema V7 adds checkpointedAt through the model layer"
```

---

### Task 2: The recorder sets it, `finish()` clears it, and stops dropping the handle early

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideRecorder.swift:139-157` (`checkpoint`), and `end(at:)` below it
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:236-245`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCheckpointFlushTests.swift` (append)

**Interfaces:**
- Consumes: `Ride.checkpointedAt` from Task 1.
- Produces: `RideRecorder.checkpoint(at:destinationName:)` returns a `Ride` with `checkpointedAt` set to `date` **and `endedAt` still stamped**; `end(at:destinationName:)` returns one with `checkpointedAt` nil.

- [ ] **Step 1: Write the failing tests**

Append to `RideSessionCheckpointFlushTests.swift`:

```swift
/// The marker is set at the pause and cleared at End. `endedAt` keeps its Pass 2 stamp
/// throughout, so an unfinished row still carries a real duration.
@Test func aCheckpointIsMarkedAndFinishingClearsIt() async throws {
    let saving = SpyRideSaving()
    let c = try await pausedRideWithACheckpoint(saving: saving)
    let checkpoint = try #require(saving.saved.last)
    #expect(checkpoint.checkpointedAt != nil)
    #expect(checkpoint.endedAt != nil, "Pass 2's stamp stays; the marker is a separate field")

    c.finish()
    let finished = try #require(saving.saved.last)
    #expect(finished.checkpointedAt == nil)
    #expect(finished.endedAt != nil)
}

/// `finish()` cleared `checkpointedRideID` before the save, so a throw stranded the row with
/// nothing able to remove it — and the rider saw "couldn't save this ride" beside a History
/// row marked as never ended.
@Test func aFailedFinishKeepsTheDeletionHandle() async throws {
    let saving = SpyRideSaving()
    let c = try await pausedRideWithACheckpoint(saving: saving)
    saving.failNextSave = true

    c.finish()

    #expect(c.saveFailed)
    #expect(c.checkpointedRideID != nil, "the row is still out there and must stay removable")
}
```

Read the existing `SpyRideSaving` in this file first. If it has no failure switch, add a `var failNextSave = false` that makes `save(_:)` throw once and then reset; if the spy is named differently, use the existing name. `checkpointedRideID` is currently private — widen it to `private(set)` on the coordinator so the test can read it.

- [ ] **Step 2: Run to verify they fail**

Run: `cd AuraCore && swift test --filter RideSessionCheckpointFlushTests`
Expected: FAIL — `checkpointedAt` is nil on the checkpoint, and `checkpointedRideID` is nil after a failed finish.

- [ ] **Step 3: Set the marker in `checkpoint(at:)`**

In `RideRecorder.swift`, replace the doc comment at lines 143-151 (which explains why `endedAt` is stamped *instead of* a marker — that reasoning is now obsolete) and the `Ride(...)` construction:

```swift
    /// `endedAt` is the pause instant, **not nil**. Nil would be the more literal encoding of
    /// "not ended", but it costs the row its elapsed and active time, and it cannot tell a
    /// second synced device that this ride is being recorded right now rather than abandoned.
    /// `checkpointedAt` carries that instead (ROH-107, spec D1), and it additionally records
    /// what the recording covers — a rider who resumed and was killed later while riding has a
    /// row whose track stops well before they did.
    public func checkpoint(at date: Date, destinationName: String? = nil) -> Ride {
        Ride(id: rideID, kind: kind, startedAt: startedAt ?? date, endedAt: date,
             segments: normalizedSegments, stats: stats,
             pausedSeconds: pausedSeconds(asOf: date), checkpointedAt: date,
             destinationName: destinationName,
             routeId: nil, destinationPlaceId: nil)
    }
```

In `end(at:)` just below, pass `checkpointedAt: nil` explicitly in the returned `Ride` (do not rely on the default — an explicit nil is what a reviewer reads as "End clears the marker").

- [ ] **Step 4: Move the handle clear after a successful save**

In `RideSessionCoordinator.finish()`, replace lines 236-245:

```swift
        do {
            // An upsert on `ride.id`: if a pause already flushed this ride, the same row is
            // updated rather than duplicated.
            try saving?.save(ride)
            // Cleared only on success, and only after the save. Clearing first meant a throw
            // stranded the checkpoint row with nothing able to remove it (ROH-107). Safe to
            // clear here: only `discard()` deletes, and `cancel()` — the one thing
            // `onDisappear` always fires — does not.
            checkpointedRideID = nil
            saveFailed = false
        } catch {
            saveFailed = true
        }
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd AuraCore && swift test --filter RideSessionCheckpointFlushTests`
Expected: PASS

- [ ] **Step 6: Annotate the misleading existing test**

`discardingAPausedRideRemovesTheCheckpoint` (around line 74) calls `discard()` directly in a state the UI cannot produce: `flushCheckpoint` only writes above the 25 m discard floor and `RideHUDView.backTapped` only discards below it, so the two are mutually exclusive and `NavigateHUDView` has no discard path at all. Keep the test, and add above it:

```swift
/// **Seam test, not a reachable production state.** `flushCheckpoint` writes only above the
/// 25 m discard floor (`RideSessionCoordinator.swift:206`) and `RideHUDView.backTapped`
/// discards only below it, so a checkpoint and a discard cannot coexist in the app.
/// `finish()` is the only path that clears the marker in production. This pins the seam so a
/// future UI that *can* reach both still deletes the row.
```

- [ ] **Step 7: Run the full suite and commit**

Run: `cd AuraCore && swift test`
Expected: PASS, both totals.

```bash
git add AuraCore/Sources/AuraKit AuraCore/Tests/AuraKitTests
git commit -m "feat(roh-107): mark the checkpoint, clear it at End, keep the handle on failure"
```

---

### Task 3: `isUnfinished`, and the active ride's id on the router

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Models/RideSummary.swift`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Modify: `Aura/Sources/App/AppRouter.swift:15`
- Modify: `Aura/Sources/Ride/RideHUDView.swift:195,203`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:236,253`
- Test: `AuraCore/Tests/AuraCoreTests/RideSummaryUnfinishedTests.swift` (create)
- Test: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift` (append)

**Interfaces:**
- Produces: `RideSummary.isUnfinished: Bool`, `RideSessionCoordinator.activeRideID: UUID?`, `AppRouter.activeRideID: UUID?` with `AppRouter.isRideActive` computed over it.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/RideSummaryUnfinishedTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("RideSummary.isUnfinished")
struct RideSummaryUnfinishedTests {
    private func summary(endedAt: Date?, checkpointedAt: Date?) -> RideSummary {
        RideSummary(id: UUID(), kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                    endedAt: endedAt, hasStats: true, distanceMeters: 1_000,
                    movingTimeSeconds: 300, pausedSeconds: 0, checkpointedAt: checkpointedAt,
                    elevationGainMeters: 10, destinationName: nil, thumbnailCoordinates: [])
    }

    @Test func aFinishedRideIsNotUnfinished() {
        #expect(!summary(endedAt: Date(timeIntervalSince1970: 100), checkpointedAt: nil).isUnfinished)
    }

    @Test func aCheckpointIsUnfinished() {
        #expect(summary(endedAt: Date(timeIntervalSince1970: 100),
                        checkpointedAt: Date(timeIntervalSince1970: 100)).isUnfinished)
    }

    /// Commits c356419 / ac5582c (PR #90) shipped a `checkpoint(at:)` that wrote a nil
    /// `endedAt`. No App Store build carried it, but a dev build used during Pass 2 device
    /// verification could have written such rows, and they mirror to CloudKit. They carry no
    /// `checkpointedAt` and would otherwise render as finished.
    @Test func aPassTwoDevBuildRowIsUnfinished() {
        #expect(summary(endedAt: nil, checkpointedAt: nil).isUnfinished)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter RideSummaryUnfinishedTests`
Expected: FAIL to compile — no `isUnfinished`.

- [ ] **Step 3: Add the predicate**

At the bottom of `RideSummary.swift`:

```swift
extension RideSummary {
    /// The rider never ended this ride: it is a pause checkpoint that a kill, or a ride still
    /// running on another device, left behind.
    ///
    /// The `endedAt == nil` clause is not redundant with `checkpointedAt`. It catches rows
    /// written by the PR #90 dev builds, whose `checkpoint(at:)` wrote a nil `endedAt` and no
    /// marker at all.
    public var isUnfinished: Bool { checkpointedAt != nil || endedAt == nil }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd AuraCore && swift test --filter RideSummaryUnfinishedTests`
Expected: PASS

- [ ] **Step 5: Write the failing coordinator test**

Append to `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`:

```swift
/// `recorder.rideID` survives `end()` — it is reset only in `start(at:)` — so a passthrough
/// that forgets the recording check hands the glance surfaces an id for a ride that finished,
/// permanently filtering it out of Home and the widget.
@Test func activeRideIDIsNilOnceTheRideEnds() async throws {
    let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                   screen: SpyScreenWake(), activity: SpyRideActivity())
    #expect(c.activeRideID == nil, "no ride has started")
    c.start()
    #expect(c.activeRideID != nil)
    c.finish()
    #expect(c.activeRideID == nil)
}
```

Match the existing suite's construction helper and its way of starting a ride; read the file first rather than assuming `start()` is the entry point.

- [ ] **Step 6: Run to verify it fails, then add the property**

Run: `cd AuraCore && swift test --filter activeRideIDIsNilOnceTheRideEnds`
Expected: FAIL to compile.

On `RideSessionCoordinator`:

```swift
    /// The id of the ride being recorded, for the glance surfaces to exclude (ROH-107, D3).
    /// **The `isRecording` check is load-bearing:** `recorder.rideID` survives `end()`, so a
    /// bare passthrough would keep filtering the ride out of Home after it finished.
    public var activeRideID: UUID? { recorder.isRecording ? recorder.rideID : nil }
```

If `recorder.rideID` is not visible at this scope, widen it to `public private(set)` on `RideRecorder` rather than adding a second stored copy.

- [ ] **Step 7: Run to verify it passes**

Run: `cd AuraCore && swift test --filter activeRideIDIsNilOnceTheRideEnds`
Expected: PASS

- [ ] **Step 8: Put the id on the router**

In `AppRouter.swift`, replace `var isRideActive = false` (line 15):

```swift
    /// The ride being recorded, or nil. Written by both HUDs alongside their existing
    /// lifecycle edges.
    var activeRideID: UUID?
    /// Computed, never stored: two stored properties written from four HUD sites can desync,
    /// and a desync means either the in-flight ride leaks back into Home or a finished ride
    /// vanishes from it. Every existing reader — the deep-link guard below,
    /// `LocationAccuracyMode.desired`, Settings' toggles, Home's post-ride reset, and the
    /// backfill cancellation — is unchanged, and observation still propagates because this
    /// getter reads the tracked stored property.
    var isRideActive: Bool { activeRideID != nil }
```

**Do not write `private(set)`** on `activeRideID`. The four writers are in other files, and `private(set)` scopes the setter to `AppRouter.swift`; it does not compile.

- [ ] **Step 9: Update the four HUD writes**

`RideHUDView.swift:195` and `NavigateHUDView.swift:236` currently read `router.isRideActive = recording`. Replace each with:

```swift
            router.activeRideID = coordinator.activeRideID
```

`RideHUDView.swift:203` and `NavigateHUDView.swift:253` currently read `router.isRideActive = false`. Replace each with:

```swift
            router.activeRideID = nil
```

Check the surrounding closure at each site: if the `recording` parameter becomes unused, replace it with `_`.

- [ ] **Step 10: Build the app target**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator and report any compile error. Expected: builds clean. Fix any remaining `isRideActive =` assignment the compiler finds — a computed property has no setter, so the compiler will point at every one.

- [ ] **Step 11: Commit**

```bash
git add AuraCore/Sources/AuraCore/Models AuraCore/Sources/AuraKit AuraCore/Tests Aura/Sources
git commit -m "feat(roh-107): isUnfinished predicate and the active ride's id on the router"
```

---

### Task 4: Exclude the in-flight ride from the glance surfaces

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift:86-99` (`make`)
- Modify: `Aura/Sources/Widgets/WidgetRefresh.swift:12-17`
- Modify: `Aura/Sources/AuraApp.swift:135,178,183`, `Aura/Sources/Settings/SettingsView.swift:122,125`, `Aura/Sources/Ride/NavigateHUDView.swift:243`, `Aura/Sources/Ride/RideHUDView.swift:199`, `Aura/Sources/History/HistoryView.swift:82`
- Modify: `Aura/Sources/Home/HomeView.swift:46-47,86`
- Test: `AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift` (append)

**Interfaces:**
- Consumes: `AppRouter.activeRideID`, `RideSummary.isUnfinished` from Task 3.
- Produces: `WidgetSnapshot.make(summaries:goalMeters:units:now:activeRideID:calendar:)` and `WidgetRefresh.reload(rideStore:settings:activeRideID:now:)`, both with `activeRideID` non-defaulted.

- [ ] **Step 1: Write the failing test**

Append to `AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift`:

```swift
/// The exclusion is by id, not by "is it unfinished". A rider who recovered an unfinished
/// ride on Monday and starts a ride on Wednesday of the same week has two unfinished rows;
/// only the one they are on should leave Home. A Bool-shaped rule hides both and drops
/// Monday's distance from the week-to-date ring for the whole of Wednesday's ride.
@Test func onlyTheActiveRideIsExcluded() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let monday = RideSummary(id: UUID(), kind: .freeRide, startedAt: now.addingTimeInterval(-86_400),
                             endedAt: now.addingTimeInterval(-80_000), hasStats: true,
                             distanceMeters: 10_000, movingTimeSeconds: 1_800, pausedSeconds: 0,
                             checkpointedAt: now.addingTimeInterval(-80_000),
                             elevationGainMeters: 100, destinationName: nil,
                             thumbnailCoordinates: [])
    let today = RideSummary(id: UUID(), kind: .freeRide, startedAt: now.addingTimeInterval(-600),
                            endedAt: now, hasStats: true,
                            distanceMeters: 5_000, movingTimeSeconds: 600, pausedSeconds: 0,
                            checkpointedAt: now, elevationGainMeters: 20, destinationName: nil,
                            thumbnailCoordinates: [])

    let snapshot = WidgetSnapshot.make(summaries: [monday, today], goalMeters: 40_000,
                                       units: .metric, now: now, activeRideID: today.id)

    #expect(snapshot.lastRide?.id == monday.id, "the in-flight ride must not own the slot")
    #expect(snapshot.week.distanceMeters == 10_000, "Monday still counts; only today is excluded")
    #expect(snapshot.week.rideCount == 1)
}

@Test func nothingIsExcludedWhenNoRideIsActive() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ride = RideSummary(id: UUID(), kind: .freeRide, startedAt: now.addingTimeInterval(-600),
                           endedAt: now, hasStats: true, distanceMeters: 5_000,
                           movingTimeSeconds: 600, pausedSeconds: 0, checkpointedAt: nil,
                           elevationGainMeters: 20, destinationName: nil,
                           thumbnailCoordinates: [])
    let snapshot = WidgetSnapshot.make(summaries: [ride], goalMeters: 40_000,
                                       units: .metric, now: now, activeRideID: nil)
    #expect(snapshot.lastRide?.id == ride.id)
    #expect(snapshot.week.rideCount == 1)
}
```

Confirm the week arithmetic against the real calendar before relying on the literals: if `now - 86_400` falls in the previous week, shift both dates so they land in the same week, or the first test asserts nothing.

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter WidgetSnapshotTests`
Expected: FAIL to compile — `make` has no `activeRideID`.

- [ ] **Step 3: Filter inside `make`**

In `WidgetSnapshot.swift`, change the signature and filter once at the top:

```swift
    /// Builds the snapshot from the cheap summary projection + settings. `now` is injected
    /// (not `Date()`) so the factory is deterministic and testable.
    ///
    /// `activeRideID` carries **no default**, deliberately: the ride the rider is currently on
    /// must never present itself as their last ride, and a defaulted nil lets a new call site
    /// leak it silently. Excluded by id rather than by `isUnfinished`, because a rider can hold
    /// a recovered unfinished ride from earlier the same week that still belongs in the ring.
    public static func make(summaries: [RideSummary], goalMeters: Double,
                            units: DistanceUnits, now: Date, activeRideID: UUID?,
                            calendar: Calendar = .current) -> WidgetSnapshot {
        let visible = summaries.filter { $0.id != activeRideID }
        let weekly = RideAggregator.weekToDate(visible, now: now, calendar: calendar)
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now, end: now)
        let last = RideAggregator.mostRecent(visible).map(LastRide.init)
```

The rest of the body is unchanged.

- [ ] **Step 4: Run to verify it passes**

Run: `cd AuraCore && swift test --filter WidgetSnapshotTests`
Expected: PASS

- [ ] **Step 5: Thread the id through `WidgetRefresh`**

In `WidgetRefresh.swift`:

```swift
    static func reload(rideStore: RideStore, settings: SettingsStore,
                       activeRideID: UUID?, now: Date = Date()) {
        let summaries = (try? rideStore.summaries()) ?? []
        let snapshot = WidgetSnapshot.make(summaries: summaries,
                                           goalMeters: settings.weeklyGoalMeters,
                                           units: settings.units, now: now,
                                           activeRideID: activeRideID)
```

Keep the existing body otherwise; match the real argument names in the current call.

- [ ] **Step 6: Update all eight call sites explicitly**

Two pass the real id, because they can fire while a ride is running:

```swift
// AuraApp.swift:183 — the scenePhase edge, which is the leak this fixes
            if phase == .active {
                WidgetRefresh.reload(rideStore: rideStore, settings: settings,
                                     activeRideID: router.activeRideID)
            }
```
```swift
// AuraApp.swift:178 — the KVS sync loop, reachable mid-ride when another device
// changes a setting
                    WidgetRefresh.reload(rideStore: rideStore, settings: settings,
                                         activeRideID: router.activeRideID)
```

Six pass `nil`, each with the one-line reason a reviewer can check:

```swift
// AuraApp.swift:135 — launch .task; no ride can be active yet
        .task { WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil) }
```
```swift
// RideHUDView.swift:199 and NavigateHUDView.swift:243 — fire from
// onChange(of: coordinator.finishedRide), i.e. after finish() cleared the marker
            WidgetRefresh.reload(rideStore: rideStore, settings: settings, activeRideID: nil)
```
```swift
// SettingsView.swift:122,125 and HistoryView.swift:82 — unreachable during a ride
            WidgetRefresh.reload(rideStore: store, settings: settings, activeRideID: nil)
```

Use the correct store variable at each site (`rideStore` vs `store`) — `HistoryView.swift:82` uses `store`.

- [ ] **Step 7: Filter Home at the source, and reload when the exclusion lifts**

`HomeView` derives three things from one array — `weekStats`, `lastRide`, and `lastRide` again inside `WeeklyGlanceView` at line 169 — so filter once rather than per-read. Replace lines 46-47:

```swift
    /// Filtered once, so the ring, the card and the glance headline cannot disagree. Excluded
    /// by id: a recovered unfinished ride from earlier this week still belongs in the ring.
    private var visibleSummaries: [RideSummary] { summaries.filter { $0.id != router.activeRideID } }
    private var weekStats: WeeklyRideStats { RideAggregator.weekToDate(visibleSummaries, now: Date()) }
    private var lastRide: RideSummary? { RideAggregator.mostRecent(visibleSummaries) }
```

Then add a reload on the true-to-false edge, next to the existing observer at line 105. Home is retained beneath the pushed HUD so its `.task` does not re-run, and a checkpoint that synced mid-ride is already in `summaries`; without this the filter lifts at End and Home re-renders the stale checkpoint row for the ride just finished.

```swift
        // The exclusion lifting is not enough: `summaries` may still hold the mid-ride
        // checkpoint that synced while the rider was out. Refetch so the finished row wins.
        .onChange(of: router.activeRideID) { previous, current in
            if previous != nil, current == nil { Task { await loadRides() } }
        }
```

- [ ] **Step 8: Build and commit**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator. Expected: clean. The compiler will flag any `reload` call site you missed, because the parameter has no default — that is the point.

Run: `cd AuraCore && swift test`
Expected: PASS, both totals.

```bash
git add AuraCore Aura/Sources
git commit -m "feat(roh-107): keep the in-flight ride out of Home, the widget and the ring"
```

---

### Task 5: The widget snapshot carries the new fields, without a version bump

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Widgets/WidgetSnapshot.swift:16-47,110-120`
- Test: `AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift` (append)

**Interfaces:**
- Produces: `WidgetSnapshot.LastRide.checkpointedAt: Date?`, `.endedAt: Date?`, `.pausedSeconds: Double?`, and `LastRide.isUnfinished: Bool`.

- [ ] **Step 1: Write the failing backward-compatibility test**

Append to `WidgetSnapshotTests.swift`:

```swift
/// A payload written by the previous app version has none of the new keys. Swift's
/// synthesized `Codable` decodes a missing key for an Optional as nil, which is the safe
/// reading: not a checkpoint, no duration pair, no paused time.
///
/// This is why `currentVersion` stays 1. Bumping it would make `WidgetSnapshotStore.read()`
/// reject the stored payload, and the only writer is in the app target — so both widgets
/// would render "No rides yet" with the ring at 0% until the rider next foregrounds Aura,
/// which for a widget user can be days.
@Test func aPayloadWrittenWithoutTheNewFieldsStillDecodes() throws {
    let json = """
    {"version":1,"generatedAt":749000000,"units":"metric",
     "lastRide":{"id":"00000000-0000-0000-0000-000000000001","kind":"freeRide",
                 "startedAt":748000000,"hasStats":true,"distanceMeters":20000,
                 "movingTimeSeconds":3720,"elevationGainMeters":104,
                 "thumbnailCoordinates":[]},
     "week":{"distanceMeters":20000,"rideCount":3,"goalMeters":40000,
             "start":748000000,"end":749000000}}
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: json)
    let ride = try #require(decoded.lastRide)
    #expect(ride.checkpointedAt == nil)
    #expect(ride.endedAt == nil)
    #expect(ride.pausedSeconds == nil)
    #expect(!ride.isUnfinished, "a payload from before this field must not read as unfinished")
    #expect(WidgetSnapshot.currentVersion == 1, "bumping the version blanks the widget for days")
}
```

Check how the existing suite encodes dates before trusting the numeric timestamps above — if `WidgetSnapshotStore` configures a non-default date strategy, build the fixture with the same encoder instead of a hand-written literal.

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter aPayloadWrittenWithoutTheNewFieldsStillDecodes`
Expected: FAIL to compile — `LastRide` has no `checkpointedAt`.

- [ ] **Step 3: Add the fields**

In `WidgetSnapshot.LastRide`, after `movingTimeSeconds`:

```swift
        /// Nil on a payload written before ROH-107, and on every finished ride.
        public let checkpointedAt: Date?
        /// `endedAt` and `pausedSeconds` are here for ROH-112's active-with-elapsed pair, added
        /// now because this struct was being touched anyway. Optional so an existing payload
        /// decodes without a version bump.
        public let endedAt: Date?
        public let pausedSeconds: Double?
```

Add all three to the memberwise `init` with `= nil` defaults, assign them, and extend the `init(_ summary: RideSummary)` convenience to forward `summary.checkpointedAt`, `summary.endedAt` and `summary.pausedSeconds`. Then:

```swift
extension WidgetSnapshot.LastRide {
    /// Mirrors `RideSummary.isUnfinished`. The widget renders from this struct, not from
    /// `RideSummary`, so the predicate exists twice by necessity — keep them in step.
    public var isUnfinished: Bool { checkpointedAt != nil || (endedAt == nil && pausedSeconds != nil) }
}
```

The `pausedSeconds != nil` guard distinguishes "written by a build that had these fields, and `endedAt` really was nil" from "an old payload where every new field is nil". Without it, every pre-ROH-107 snapshot reads as unfinished.

Leave `WidgetSnapshot.sample` compiling by relying on the defaults; do not mark the sample unfinished.

- [ ] **Step 4: Run to verify it passes, then the full suite**

Run: `cd AuraCore && swift test --filter WidgetSnapshotTests`
Expected: PASS

Run: `cd AuraCore && swift test`
Expected: PASS, both totals.

- [ ] **Step 5: Commit**

```bash
git add AuraCore
git commit -m "feat(roh-107): widget snapshot carries checkpointedAt, endedAt and pausedSeconds"
```

---

### Task 6: The marker, its copy, and where it renders

**Files:**
- Create: `AuraCore/Sources/AuraKit/Summary/UnfinishedRideCopy.swift`
- Create: `Aura/Sources/Shared/UnfinishedRideBadge.swift`
- Modify: `Aura/Sources/History/HistoryView.swift:183-192`
- Modify: `Aura/Sources/Plan/LastRideCard.swift:24-35`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:117-143`
- Modify: `Aura/Widgets/LastRideWidget.swift`
- Test: `AuraCore/Tests/AuraKitTests/UnfinishedRideCopyTests.swift` (create)

**Interfaces:**
- Consumes: `RideSummary.isUnfinished`, `WidgetSnapshot.LastRide.isUnfinished`.
- Produces: `UnfinishedRideCopy.label`, `UnfinishedRideCopy.detail(checkpointedAt:relativeTo:calendar:)`, `UnfinishedRideCopy.accessibilityLabel(checkpointedAt:relativeTo:calendar:)`, and the `UnfinishedRideBadge` view.

- [ ] **Step 1: Write the failing copy tests**

Create `AuraCore/Tests/AuraKitTests/UnfinishedRideCopyTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraKit

/// The copy is the whole feature, so it is pinned here rather than left to a view.
@Suite("Unfinished-ride copy")
struct UnfinishedRideCopyTests {
    private let cal = Calendar(identifier: .gregorian)

    /// It must be true for a recovered ride AND for one still being recorded on another
    /// device, because a synced second device cannot tell them apart. It must also not blame
    /// the rider: someone who rode to the brewery and got a lift home did finish their ride,
    /// Aura just failed to record the end.
    @Test func theLabelDescribesTheRecordingRatherThanTheRider() {
        #expect(UnfinishedRideCopy.label == "No end recorded")
    }

    @Test func detailNamesWhenRecordingStopped() {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let detail = try! #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                             relativeTo: stamp, calendar: cal))
        #expect(detail.hasPrefix("Recorded until "))
    }

    /// A PR #90 dev-build row has no marker timestamp, so there is nothing honest to say
    /// beyond the label.
    @Test func detailIsNilWithoutATimestamp() {
        #expect(UnfinishedRideCopy.detail(checkpointedAt: nil,
                                          relativeTo: Date(), calendar: cal) == nil)
    }

    /// A stop from an earlier day needs its date, or "until 2:14 PM" is ambiguous.
    @Test func anEarlierDayCarriesItsDate() {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let later = stamp.addingTimeInterval(3 * 86_400)
        let sameDay = try! #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                              relativeTo: stamp, calendar: cal))
        let otherDay = try! #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                               relativeTo: later, calendar: cal))
        #expect(sameDay != otherDay)
        #expect(otherDay.count > sameDay.count)
    }

    @Test func theAccessibilityLabelCarriesBothParts() {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let spoken = UnfinishedRideCopy.accessibilityLabel(checkpointedAt: stamp,
                                                           relativeTo: stamp, calendar: cal)
        #expect(spoken.contains("No end recorded"))
        #expect(spoken.contains("Recorded until"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter UnfinishedRideCopyTests`
Expected: FAIL to compile — no `UnfinishedRideCopy`.

- [ ] **Step 3: Write the copy helper**

Create `AuraCore/Sources/AuraKit/Summary/UnfinishedRideCopy.swift`:

```swift
import Foundation
import AuraCore

/// Copy for a ride the rider never ended. Pure and view-free so the strings are unit-tested
/// rather than eyeballed, and shared by History, the last-ride card, the summary sheet and
/// the widget so they cannot drift.
///
/// **It describes the recording, not the rider** (spec D4). "Unfinished" reads as an
/// accusation on a Home surface whose job is motivation, and it is wrong in the common case:
/// a rider who rode to the brewery and got a lift home did finish their ride. It must also be
/// true for a ride still being recorded on another device, since a synced second device cannot
/// tell that apart from an abandoned one.
public enum UnfinishedRideCopy {
    public static let label = "No end recorded"

    /// "Recorded until 2:14 PM", or with the date when the stop was not on `now`'s day.
    /// Nil when there is no marker timestamp, which is a PR #90 dev-build row.
    public static func detail(checkpointedAt: Date?, relativeTo now: Date = Date(),
                              calendar: Calendar = .current) -> String? {
        guard let stamp = checkpointedAt else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        if calendar.isDate(stamp, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return "Recorded until \(formatter.string(from: stamp))"
    }

    /// One spoken string. A VoiceOver user handed the same caption as a finished ride has not
    /// been told anything.
    public static func accessibilityLabel(checkpointedAt: Date?, relativeTo now: Date = Date(),
                                          calendar: Calendar = .current) -> String {
        guard let detail = detail(checkpointedAt: checkpointedAt, relativeTo: now,
                                  calendar: calendar) else { return label }
        return "\(label). \(detail)"
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd AuraCore && swift test --filter UnfinishedRideCopyTests`
Expected: PASS

- [ ] **Step 5: Build the badge view**

Create `Aura/Sources/Shared/UnfinishedRideBadge.swift`:

```swift
import SwiftUI
import AuraKit

/// The marker for a ride with no recorded end.
///
/// **Neutral, never amber.** Amber already carries peer-stopped and `AuraTheme.warning`, which
/// `GPSSignalChip` uses for weak or lost GPS — pausing under a railway bridge would otherwise
/// light two amber elements meaning different things. This is a fact about the recording, not
/// an app error, so it takes secondary weight.
struct UnfinishedRideBadge: View {
    let checkpointedAt: Date?
    /// `.compact` drops the detail line for dense rows; `.full` shows it.
    enum Style { case compact, full }
    var style: Style = .compact

    var body: some View {
        HStack(spacing: AuraTheme.Spacing.xs) {
            Image(systemName: "pause.circle")
                .font(.caption2.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text(UnfinishedRideCopy.label)
                if style == .full,
                   let detail = UnfinishedRideCopy.detail(checkpointedAt: checkpointedAt) {
                    Text(detail)
                }
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(AuraTheme.textSecondary)
        .padding(.horizontal, AuraTheme.Spacing.sm)
        .padding(.vertical, 2)
        .background(AuraTheme.textSecondary.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UnfinishedRideCopy.accessibilityLabel(checkpointedAt: checkpointedAt))
    }
}
```

Verify `"pause.circle"` exists on the deployment target before shipping it — read the symbol list from the installed simulator runtime's SF Symbols plist rather than trusting recall (this bit us on ROH-44). If it is missing, use `"clock"`.

- [ ] **Step 6: Render it on the three app surfaces**

**History row** (`HistoryView.swift`, the middle `VStack` at 183-192). The caption is one `.footnote` with `.lineLimit(1)`; appending the marker there makes it the first thing Dynamic Type truncates, for the users least able to lose it. Give it its own line inside the existing `VStack`, after the caption `Text`:

```swift
                if summary.isUnfinished {
                    UnfinishedRideBadge(checkpointedAt: summary.checkpointedAt)
                }
```

**Last-ride card** (`LastRideCard.swift`, the `VStack` at 24-35), after the `relativeDate` `Text`:

```swift
                    if summary.isUnfinished {
                        UnfinishedRideBadge(checkpointedAt: summary.checkpointedAt)
                    }
```

**Ride summary sheet** (`RideSummaryView.swift`, `titleBlock`). This screen is reachable — every History row taps into it via `HistoryView.swift:62` — and it is where a rider goes *because* the row looked odd, so it gets the full style. Replace the `Text("Nice ride")` line with:

```swift
                Text(ride.checkpointedAt != nil || ride.endedAt == nil ? "Your ride" : "Nice ride")
                    .font(.largeTitle.bold()).foregroundStyle(AuraTheme.textPrimary)
```

and add, immediately after the destination-name block and before the `isLongest` label:

```swift
            if ride.checkpointedAt != nil || ride.endedAt == nil {
                UnfinishedRideBadge(checkpointedAt: ride.checkpointedAt, style: .full)
            }
```

`RideSummaryView` takes a `Ride`, not a `RideSummary`, which is why the condition is spelled out rather than reusing `isUnfinished`. If `Ride` already carries an equivalent helper by the time you get here, use it instead of duplicating the expression.

**Widget** (`LastRideWidget.swift`): add the badge only where there is room. `systemSmall` (lines 37-56) and `accessoryRectangular` (lines 90-114) are already tight — a 34 pt thumbnail plus three lines on the Lock Screen. If a family cannot fit it without truncating a stat, render that family without the marker rather than shrinking a number, and put the state in its accessibility label via `UnfinishedRideCopy.accessibilityLabel`. `LastRideWidget.swift:142` already builds an accessibility string; extend that.

- [ ] **Step 7: Build and eyeball**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator. Expected: clean.

Then check the badge at the largest accessibility text size on the smallest device in the matrix (iPhone SE), on both the History row and the last-ride card. The badge must not push the hero distance numeral off the row, and the caption must still be legible.

- [ ] **Step 8: Commit**

```bash
git add AuraCore Aura
git commit -m "feat(roh-107): mark an unfinished ride on History, Home, the summary and the widget"
```

---

### Task 7: Confirm before deleting an unfinished ride

**Files:**
- Modify: `Aura/Sources/History/HistoryView.swift:67-71`

**Interfaces:**
- Consumes: `RideSummary.isUnfinished`.

- [ ] **Step 1: Add the confirmation**

History's delete is `.swipeActions(edge: .trailing, allowsFullSwipe: true)` with a destructive role, calling a hard delete that propagates to every device via CloudKit (`RideStore.swift:125`). Labelling a row as damaged and leaving a one-gesture irreversible destroy on it is a trap: in the common case the row is a complete, correct ride missing only its ending, and a rider who reads the marker as "broken, junk" full-swipes away a real ride.

Add state to `HistoryView`:

```swift
    /// A ride awaiting delete confirmation. Only unfinished rides land here: the marker is what
    /// makes a rider likely to delete a row they would otherwise keep, so the confirmation
    /// exists to answer the hazard this feature created — not to slow down ordinary deletes.
    @State private var pendingDelete: RideSummary?
```

Change the swipe action to route unfinished rows through it:

```swift
                    .swipeActions(edge: .trailing, allowsFullSwipe: !summary.isUnfinished) {
                        Button(role: .destructive) {
                            if summary.isUnfinished { pendingDelete = summary } else { delete(summary) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
```

Attach the dialog to the same view that carries the existing `.sheet` (around line 48):

```swift
        .confirmationDialog("Delete this ride?", isPresented: .constant(pendingDelete != nil),
                            presenting: pendingDelete) { summary in
            Button("Delete ride", role: .destructive) { delete(summary); pendingDelete = nil }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Aura never recorded this ride's end, but everything up to that point was saved. Deleting removes it from all your devices.")
        }
```

`allowsFullSwipe: !summary.isUnfinished` matters as much as the dialog: a full swipe on an unfinished row would otherwise fire the destructive button without the rider ever seeing it.

- [ ] **Step 2: Build**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator. Expected: clean.

- [ ] **Step 3: Verify by hand in the simulator**

Seed an unfinished ride (start a simulated ride, pause it, then kill the app from the simulator rather than ending the ride), relaunch, and confirm: History shows the row with the badge, a full swipe does **not** delete it, the swipe button opens the dialog, "Keep" leaves the row, and a finished ride still full-swipes away with no dialog.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/History/HistoryView.swift
git commit -m "feat(roh-107): confirm before deleting a ride with no recorded end"
```

---

## After the plan

Run the whole gate before opening a PR:

```bash
cd AuraCore && swift test && swiftlint --strict
```

Then build the app target through the builder agent, and device-verify the recovery path: pause a real ride above the 25 m floor, kill Aura from the app switcher, relaunch, and confirm the badge, the "Recorded until" line, the weekly ring still counting the distance, and Home showing the recovered ride rather than a stale mid-ride row.

**Do not promote the CloudKit production schema during this plan.** [ROH-108](https://linear.app/rohun/issue/ROH-108) deploys once, after V7 has landed, covering `CD_segmentsData`, `CD_pausedSeconds` and `CD_checkpointedAt` together.

**Known gap, deliberate:** `AppRouter` has no unit-test coverage and cannot get any here — it lives in the app target, and `Aura/project.yml` defines only `Aura`, `AuraWidgets` and `AuraUITests`. Task 3's computed-property change is covered by the existing `AuraUITests` deep-link cases and by device verification. If that is judged insufficient, moving the guard logic into AuraCore is its own pass, not a step in this one.
