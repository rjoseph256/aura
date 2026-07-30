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
- **Marker copy describes the recording, not the rider.** It must be true both for a recovered ride and for a ride still running on another device. "No end recorded" is correct; "You never finished this ride" is not. It must also never claim the ride is intact: a rider who paused at km 20, resumed, and was killed at km 60 has lost 40 km, so "everything up to that point was saved" is false and forbidden.
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
- `Aura/Sources/Ride/ShareCard/ShareCardContent.swift` and its card view — marker on the shared card.
- `Aura/project.yml` — add the badge to the `AuraWidgets` source list, then `xcodegen generate`.
- `AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift` — guard V7.
- `AuraCore/Tests/AuraKitTests/RideStoreCheckpointTests.swift` — extend `updatePathCarriesEveryColumn`.

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

**Do not run tests between Steps 4 and 5.** Step 4 repoints the `RideRecord` typealias to V7 while `schemas` still stops at V6, and `SchemaV6MigrationTests.openV6` opens `for: RideRecord.self, migrationPlan:` — so the whole migration suite reds with `loadIssueModelContainer` until this step lands. Verified by running it. The two steps are one atomic change split for readability.

In `RideMigrationPlan.swift`, add `RideSchemaV7.self` to `schemas` (line 13-14) and `migrateV6toV7` to `stages` (line 18) — **appended last, since stages are walked in order** — then add the stage after `migrateV5toV6`:

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

**Then extend the codebase's own completeness guard.** `RideStore.swift:64-67` says: *"Adding a column to `RideRecord` means adding a line to the update branch below… `updatePathCarriesEveryColumn` is the guard; extend it with the column."* `RideStoreCheckpointTests.swift:39-40` repeats it. That test's contract is that **every** column the mapper writes differs between its two rides; leaving it alone makes the repo's single self-describing guard quietly false at V7, and the next schema pass will read it and believe it.

Open `AuraCore/Tests/AuraKitTests/RideStoreCheckpointTests.swift`, make the two fixture rides differ in `checkpointedAt` as they already differ in every other column, and add the corresponding assertion. The new test in Step 1 does not replace this — it is a targeted regression test for one column, and this is the guard that catches the *next* one.

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

Create `AuraCore/Tests/AuraKitTests/SchemaV7MigrationTests.swift`. **Read `SchemaV6MigrationTests.swift` first and copy its `tempStoreDirectory()` helper**; the three things below are what a naive version gets wrong, and all three were reproduced by running it:

- **`@MainActor` on the suite.** `ModelContainer.mainContext` is main-actor isolated and the package is `swiftLanguageModes: [.v6]`, so a nonisolated suite touching it is a compile error, not a warning.
- **Both containers open the full three-model set.** Every `VersionedSchema` in the plan declares three models (`RideSchemaV6.swift:30-32`). A store stamped from a one-model schema matches no version, and staged migration fails with `Cannot use staged migration with an unknown coordinator model version`. `SchemaV6MigrationTests.writeV5Store` says exactly this in its doc comment.
- **Clean up the directory.** The store has an external-storage `_SUPPORT` sidecar; removing the containing directory takes the subtree.

```swift
import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
@Suite("Schema V6 → V7", .swiftDataSerialized)
struct SchemaV7MigrationTests {

    /// Every V6 row survives, and arrives with `checkpointedAt` nil — the correct reading,
    /// since every pre-V7 row was written by `finish()`.
    @Test func v6RowsMigrateWithANilCheckpoint() throws {
        let dir = try tempStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "v7.store")
        let id = UUID()

        // Seed on the EXACT V6 model set, so SwiftData stamps the store as V6.
        do {
            let container = try ModelContainer(
                for: RideSchemaV6.RideRecord.self, RideSchemaV5.SavedPlaceRecord.self,
                     RideSchemaV4.SeenGemRecord.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            container.mainContext.insert(RideSchemaV6.RideRecord(
                id: id, kindRaw: "freeRide", startedAt: Date(timeIntervalSince1970: 1_000),
                endedAt: Date(timeIntervalSince1970: 2_000), trackData: Data(),
                segmentsData: nil, statsData: nil, routeId: nil, destinationPlaceId: nil))
            try container.mainContext.save()
        }

        // Reopen on the live model set + the plan, so the destination resolves unambiguously.
        let migrated = try ModelContainer(
            for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let rows = try migrated.mainContext.fetch(FetchDescriptor<RideRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == id)
        #expect(rows.first?.checkpointedAt == nil)
    }
}
```

Use whatever names `SavedPlaceRecord` / `SeenGemRecord` are typealiased to in this codebase; if there is no typealias, spell them `RideSchemaV5.SavedPlaceRecord` and `RideSchemaV4.SeenGemRecord` as V6's `models` does.

Append to `AuraCore/Tests/AuraKitTests/RideMapperTests.swift` — **at the very end of the file**. That file opens with `final class RideMapperTests: XCTestCase` and a Swift Testing struct follows it; a `@Test` placed inside the XCTest class fails with *"Attribute 'Test' cannot be applied to a function within class"*.

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
git add AuraCore/Sources AuraCore/Tests
git commit -m "feat(roh-107): schema V7 adds checkpointedAt through the model layer"
```

Stage `AuraCore/Tests` whole, not just `AuraKitTests` — Step 11 may have required fixes in `AuraCoreTests` too.

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
    let saving = RecordingRideSaving()
    let c = try await pausedRideWithACheckpoint(saving: saving)
    let checkpoint = try #require(saving.saved.last)
    #expect(checkpoint.checkpointedAt != nil)
    #expect(checkpoint.endedAt != nil, "Pass 2's stamp stays; the marker is a separate field")

    c.finish()
    let finished = try #require(saving.saved.last)
    #expect(finished.checkpointedAt == nil)
    #expect(finished.endedAt != nil)
}

/// `finish()` cleared `pendingCheckpoint` before the save, so a throw stranded the row with
/// nothing able to remove it — and the rider saw "couldn't save this ride" beside a History
/// row marked as never ended.
@Test func aFailedFinishKeepsTheDeletionHandle() async throws {
    let saving = RecordingRideSaving()
    let c = try await pausedRideWithACheckpoint(saving: saving)
    saving.failNextSave = true

    c.finish()

    #expect(c.saveFailed)
    #expect(c.pendingCheckpoint != nil, "the row is still out there and must stay removable")
}
```

**There is no `SpyRideSaving` in this repo, and no existing double will work.** The two `RideSaving` doubles are `FlakyRideSaving` (`RideSessionCoordinatorPauseTests.swift:240`) and `ThrowingRideSaving` (`RideSessionCoordinatorTests.swift:281`), and **neither records the saved `Ride`** — they keep counters. Both tests above read a `Ride` off the double, so write a new one at the top of `RideSessionCheckpointFlushTests.swift`:

```swift
/// Records what was saved, which neither `FlakyRideSaving` nor `ThrowingRideSaving` does —
/// they count. These tests assert on the `Ride`'s fields, so they need the object.
@MainActor
final class RecordingRideSaving: RideSaving {
    private(set) var saved: [Ride] = []
    private(set) var discarded: [UUID] = []
    var failNextSave = false

    func save(_ ride: Ride) throws {
        if failNextSave { failNextSave = false; throw CocoaError(.fileWriteUnknown) }
        saved.append(ride)
    }
    func discard(id: UUID) throws { discarded.append(id) }
}
```

Check `RideSaving`'s real requirements in `RideSessionSeams.swift:24-38` before writing this — it has a defaulted `discard(id:)` and the protocol may carry members not shown here. The two tests above already name it `RecordingRideSaving`.

`pendingCheckpoint` is currently private — widen it to `private(set)` on the coordinator so the test can read it.

> **This handle was named `checkpointedRideID` while the plan was written**, and every reference in this document has been renamed to match the code. The whole-branch review's fix wave collapsed the id and the flush stamp into one `pendingCheckpoint: PendingCheckpoint?` (`rideID` + `at`), so that a failed `finish()` can publish the surviving row's marker, and so neither half can be cleared without the other. Where the plan reads the id specifically, the shipped expression is `c.pendingCheckpoint?.rideID`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd AuraCore && swift test --filter RideSessionCheckpointFlushTests`
Expected: FAIL — `checkpointedAt` is nil on the checkpoint, and `pendingCheckpoint` is nil after a failed finish.

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
            pendingCheckpoint = nil
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

**`RideSessionCoordinator.start` is not a no-argument call.** Its real signature (`RideSessionCoordinator.swift:91-97`) is `start(location:saving:units:authorization:saveToHealth:groupSink:discoverySink:)`, with the first four required. Read how the existing suites drive a ride — `RideSessionCoordinatorTests` builds one with `SpyScreenWake()` / `SpyRideActivity()`, and `RideSessionCheckpointFlushTests.pausedRideWithACheckpoint(saving:)` already encapsulates start-and-feed-fixes — and reuse whichever helper fits rather than inventing a call.

```swift
/// `recorder.rideID` survives `end()` — it is reset only in `start(at:)` — so a passthrough
/// that forgets the recording check hands the glance surfaces an id for a ride that finished,
/// permanently filtering it out of Home and the widget.
@Test func activeRideIDIsNilOnceTheRideEnds() async throws {
    let saving = RecordingRideSaving()
    // Reuse the suite's existing start-a-ride helper; do not hand-roll the start(...) call.
    let c = try await pausedRideWithACheckpoint(saving: saving)
    #expect(c.activeRideID != nil, "a paused ride is still active")

    c.finish()
    #expect(c.activeRideID == nil, "rideID survives end(); the isRecording check is what saves us")
}
```

Put this in `RideSessionCheckpointFlushTests.swift` beside the Task 2 tests, where that helper and `RecordingRideSaving` already exist, rather than in `RideSessionCoordinatorTests.swift`.

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

`recorder.rideID` is already `public private(set)` (`RideRecorder.swift:34`) and `isRecording` is already public (`:23`), so this compiles as written with no visibility change.

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

Append to `AuraCore/Tests/AuraKitTests/WidgetSnapshotTests.swift`.

**Pass the suite's pinned calendar explicitly.** `make` defaults to `Calendar.current`, and this fixture is week-boundary-sensitive: `1_750_000_000` is a **Sunday**, so on a Sunday-first calendar (`en_US`, the macOS CI default) the earlier ride lands in the *previous* week and both ring assertions read 0 no matter how correct the implementation is. `WidgetSnapshotTests` already pins `Calendar(identifier: .gregorian)` with UTC and `firstWeekday = 2` at the top of the file — use that constant, and the two dates fall in the same Monday-start week.

```swift
/// The exclusion is by id, not by "is it unfinished". A rider who recovered an unfinished
/// ride earlier this week and starts a ride today has two unfinished rows; only the one they
/// are on should leave Home. A Bool-shaped rule hides both and drops the earlier ride's
/// distance from the week-to-date ring for the whole of today's ride.
@Test func onlyTheActiveRideIsExcluded() {
    // Sunday 2025-06-15. With the suite's firstWeekday = 2 calendar, the week is
    // Mon 2025-06-09 ..< Mon 2025-06-16, so `earlier` (Sat 2025-06-14) is inside it.
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let earlier = RideSummary(id: UUID(), kind: .freeRide, startedAt: now.addingTimeInterval(-86_400),
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

    let snapshot = WidgetSnapshot.make(summaries: [earlier, today], goalMeters: 40_000,
                                       units: .metric, now: now, activeRideID: today.id,
                                       calendar: Self.calendar)

    #expect(snapshot.lastRide?.id == earlier.id, "the in-flight ride must not own the slot")
    #expect(snapshot.week.distanceMeters == 10_000, "the earlier ride still counts")
    #expect(snapshot.week.rideCount == 1)
}
```

Use whatever the pinned calendar is actually called in that file rather than `Self.calendar`. Before running, print the resolved week interval once and confirm both fixture dates are inside it — a green bar on a fixture that silently sits outside the week proves nothing.

The companion "nothing is excluded when no ride is active" case is deliberately **not** written: `$0.id != nil` is vacuously true for every row, so such a test passes whether or not `make` reads the parameter at all.

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

- [ ] **Step 4: Fix the five existing callers, then run**

`activeRideID` has no default by design, so adding it breaks every existing call. There are five in `WidgetSnapshotTests.swift` (lines 30, 44, 53, 71, 85) plus `WidgetRefresh.swift:14` (Step 5). Add `activeRideID: nil` to each of the five test calls — none of them is testing the exclusion.

Run: `cd AuraCore && swift test --filter WidgetSnapshotTests`
Expected: PASS. It will not compile until all five are updated.

- [ ] **Step 5: Thread the id through `WidgetRefresh`, and never write an emptied snapshot**

The snapshot is a **file** in the App Group, read by a separate extension process on its own timeline — so the exclusion is not process-local, it is durable. Two consequences the naive version gets wrong:

- A rider whose only ride this week is the one in flight foregrounds Aura mid-ride and the widget renders **"No rides yet · Start a ride"** with the ring at 0%, while they are stood over their bike 20 km in. Today they see their in-flight distance.
- If iOS then kills Aura during the pause, that emptied snapshot is what the widget shows until the rider next *opens the app* — days, for the widget-only persona. That is the same multi-day window Task 5 refuses to accept for a version bump, introduced here deliberately.

Both are fixed by not writing a snapshot the exclusion hollowed out. Leaving the previous one in place is strictly better: it is stale by one ride rather than actively wrong.

```swift
    static func reload(rideStore: RideStore, settings: SettingsStore,
                       activeRideID: UUID?, now: Date = Date()) {
        let summaries = (try? rideStore.summaries()) ?? []
        let snapshot = WidgetSnapshot.make(summaries: summaries,
                                           goalMeters: settings.weeklyGoalMeters,
                                           units: settings.units, now: now,
                                           activeRideID: activeRideID)
        // The exclusion removed the rider's only ride. Writing this would replace a correct
        // widget with the first-run empty state mid-ride — and the snapshot is a file, so a
        // jetsam kill during the pause freezes that empty state until the app is next opened.
        // Keeping the previous snapshot is stale by one ride instead of wrong.
        if activeRideID != nil, snapshot.lastRide == nil, !summaries.isEmpty { return }
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
// HistoryView.swift:82 — History is not reachable during a ride
        WidgetRefresh.reload(rideStore: store, settings: settings, activeRideID: nil)
```

**Settings is the one site where `nil` needs checking rather than assuming.** `SettingsView.swift:30,34` carry `.disabled(router.isRideActive)` — guards that only make sense if that screen can be on-screen while a ride is active. Either those guards are dead code or Settings *is* reachable mid-ride, in which case `activeRideID: nil` at `:122,125` reintroduces the exact leak this task closes, on a settings change. Determine which before writing the argument: if reachable, pass `router.activeRideID`; if genuinely unreachable, pass `nil` and delete the misleading `.disabled` guards in a separate commit.

`SettingsView` binds the store as `rideStore` (`:5`); only `HistoryView:82` uses `store`. Use the right name at each site.

- [ ] **Step 7: Filter Home at the source, and reload when the exclusion lifts**

`HomeView` derives **four** things from `summaries`: `weekStats` and `lastRide` (`:46-47`), `lastRide` again inside `WeeklyGlanceView` (`:169`), and `hasRides: !summaries.isEmpty` feeding `HomeMode.resolve` (`:50`).

**Only the first three get the filter.** `mode` stays on the unfiltered array, deliberately — it answers "does this rider have any rides at all", not "what should the ring show", and filtering it would flip a rider whose only ride is the one in flight toward the first-run screen. This is a presentation filter for the ring, card and glance; it is not a "does this rider have rides" filter. Do not apply it uniformly.

Replace lines 46-47:

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
}

/// `RideSummary.isUnfinished` and `LastRide.isUnfinished` are deliberately different
/// expressions — the widget struct needs the `pausedSeconds` provenance guard and the summary
/// does not. Nothing else stops them drifting apart.
@Test func theWidgetPredicateAgreesWithTheSummaryPredicate() {
    let base = Date(timeIntervalSince1970: 1_750_000_000)
    func summary(endedAt: Date?, checkpointedAt: Date?) -> RideSummary {
        RideSummary(id: UUID(), kind: .freeRide, startedAt: base, endedAt: endedAt,
                    hasStats: true, distanceMeters: 1_000, movingTimeSeconds: 300,
                    pausedSeconds: 0, checkpointedAt: checkpointedAt,
                    elevationGainMeters: 10, destinationName: nil, thumbnailCoordinates: [])
    }
    for s in [summary(endedAt: base, checkpointedAt: nil),
              summary(endedAt: base, checkpointedAt: base),
              summary(endedAt: nil, checkpointedAt: nil)] {
        #expect(WidgetSnapshot.LastRide(s).isUnfinished == s.isUnfinished)
    }
}
```

Dropped from this test deliberately: an `#expect(WidgetSnapshot.currentVersion == 1)` assertion. It compares a compile-time constant to a literal and can never fail — the reason the version must stay 1 belongs in the comment above, not in a green checkmark.

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

Add all three to the memberwise `init` **without defaults**, assign them, and extend the `init(_ summary: RideSummary)` convenience to forward `summary.checkpointedAt`, `summary.endedAt` and `summary.pausedSeconds`. Update `WidgetSnapshot.sample` to pass `checkpointedAt: nil, endedAt: <a real date>, pausedSeconds: 0` so the gallery placeholder stays a finished ride.

Defaults are wrong here for the same reason they are wrong on `activeRideID` (Global Constraints): `pausedSeconds` is load-bearing as a *provenance* signal in the predicate below, so a caller who passes a real `endedAt: nil` and omits `pausedSeconds` silently reports a checkpoint as finished. Make every call site state its answer.

Then:

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

### Task 6: Confirm before deleting a ride with no recorded end

**Ordered before the marker deliberately.** This project device-verifies on a real iPhone with real ride history. If the marker landed first, there would be an installed build where History labels real rides as damaged while `.swipeActions(allowsFullSwipe: true)` still hard-deletes them to every device on a single flick — the exact trap spec D4 identifies. Landing the guard first makes it inert for one commit, which costs nothing.

**Files:**
- Modify: `Aura/Sources/History/HistoryView.swift:48,67-71`

**Interfaces:**
- Consumes: `RideSummary.isUnfinished` and `RideSummary.checkpointedAt` from Tasks 1 and 3.

- [ ] **Step 1: Add the confirmation**

History's delete is `.swipeActions(edge: .trailing, allowsFullSwipe: true)` with a destructive role, calling a hard delete that propagates to every device via CloudKit (`RideStore.swift:125`). Labelling a row as damaged and leaving a one-gesture irreversible destroy on it is a trap: in the common case the row is a complete, correct ride missing only its ending, and a rider who reads the marker as "broken, junk" full-swipes away a real ride.

Add state to `HistoryView`:

```swift
    /// A ride awaiting delete confirmation. Only unfinished rides land here: the marker is what
    /// makes a rider likely to delete a row they would otherwise keep, so the confirmation
    /// answers the hazard this feature creates rather than slowing down ordinary deletes.
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

`allowsFullSwipe: !summary.isUnfinished` matters as much as the dialog: a full swipe would otherwise fire the destructive button without the rider ever seeing it.

Attach the dialog next to the existing `.sheet` (around line 48). **Use a derived two-way binding, not `.constant`.** SwiftUI writes `false` to an `isPresented` binding on every dismissal, including ones that run no button action; a `.constant` swallows that write, `pendingDelete` stays non-nil, and the dialog re-presents. `HomeView.swift:112-113` already has the correct shape for this optional-driven case.

```swift
        .confirmationDialog("Delete this ride?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { summary in
            Button("Delete ride", role: .destructive) { delete(summary); pendingDelete = nil }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { summary in
            Text(UnfinishedRideCopy.deleteWarning(checkpointedAt: summary.checkpointedAt))
        }
```

`UnfinishedRideCopy.deleteWarning` arrives in Task 7. Until then, inline the no-timestamp string it returns — `"Aura never recorded this ride's end. Deleting removes it from all your devices."` — and swap it for the call when Task 7 lands. Do **not** write "everything up to that point was saved": for a rider who paused at km 20, resumed, rode to km 60 and was killed while moving, that is false, and it is the precise claim spec defect 2 exists to avoid making.

- [ ] **Step 2: Build**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme for an iPhone simulator. Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/History/HistoryView.swift
git commit -m "feat(roh-107): confirm before deleting a ride with no recorded end"
```

---

### Task 7: The marker, its copy, and where it renders

**Files:**
- Create: `AuraCore/Sources/AuraKit/Summary/UnfinishedRideCopy.swift`
- Create: `Aura/Sources/Shared/UnfinishedRideBadge.swift`
- Modify: `Aura/project.yml` (widget target sources) — then re-run `xcodegen generate`
- Modify: `Aura/Sources/History/HistoryView.swift:184-192`, and the dialog message from Task 6
- Modify: `Aura/Sources/Plan/LastRideCard.swift:24-35`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:117-152`
- Modify: `Aura/Sources/Ride/ShareCard/ShareCardContent.swift` and its card view
- Modify: `Aura/Widgets/LastRideWidget.swift:44,97,142`
- Test: `AuraCore/Tests/AuraKitTests/UnfinishedRideCopyTests.swift` (create)

**Interfaces:**
- Consumes: `RideSummary.isUnfinished`, `RideSummary.checkpointedAt`, `WidgetSnapshot.LastRide.isUnfinished`, `Ride.checkpointedAt`.
- Produces: `UnfinishedRideCopy.label`, `.detail(checkpointedAt:relativeTo:calendar:)`, `.accessibilityLabel(...)`, `.deleteWarning(checkpointedAt:relativeTo:calendar:)`, and the `UnfinishedRideBadge` view.

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
    private let stamp = Date(timeIntervalSince1970: 1_750_000_000)

    /// The detail line has to do the job schema V7 was bought for: separate "you forgot to
    /// press End" from "40 km are missing". "Recorded until X" reads as "the recording ran to
    /// the end" and does neither, so the string must say what was lost, not just when.
    @Test func theDetailSaysWhatWasNotSaved() throws {
        let detail = try #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                            relativeTo: stamp, calendar: cal))
        #expect(detail.contains("wasn't saved"))
    }

    /// A PR #90 dev-build row has no marker timestamp, so there is nothing honest to say
    /// beyond the label.
    @Test func detailIsNilWithoutATimestamp() {
        #expect(UnfinishedRideCopy.detail(checkpointedAt: nil,
                                          relativeTo: stamp, calendar: cal) == nil)
    }

    /// A stop from an earlier day needs its date, or a bare "2:14 PM" is ambiguous.
    @Test func anEarlierDayCarriesItsDate() throws {
        let later = stamp.addingTimeInterval(3 * 86_400)
        let sameDay = try #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                             relativeTo: stamp, calendar: cal))
        let otherDay = try #require(UnfinishedRideCopy.detail(checkpointedAt: stamp,
                                                              relativeTo: later, calendar: cal))
        #expect(otherDay.count > sameDay.count)
    }

    /// The delete warning must not claim the recording is complete. A rider who paused at
    /// km 20, resumed and was killed at km 60 loses 40 km, and this dialog is the last thing
    /// they read before an irreversible, all-devices delete.
    @Test func theDeleteWarningDoesNotPromiseEverythingWasSaved() {
        let warning = UnfinishedRideCopy.deleteWarning(checkpointedAt: stamp,
                                                       relativeTo: stamp, calendar: cal)
        #expect(warning.contains("wasn't saved"))
        #expect(!warning.lowercased().contains("everything"))
        #expect(warning.contains("all your devices"))
    }

    @Test func theDeleteWarningWorksWithoutATimestamp() {
        let warning = UnfinishedRideCopy.deleteWarning(checkpointedAt: nil,
                                                       relativeTo: stamp, calendar: cal)
        #expect(!warning.isEmpty)
        #expect(warning.contains("all your devices"))
    }

    @Test func theAccessibilityLabelCarriesBothParts() {
        let spoken = UnfinishedRideCopy.accessibilityLabel(checkpointedAt: stamp,
                                                           relativeTo: stamp, calendar: cal)
        #expect(spoken.contains(UnfinishedRideCopy.label))
        #expect(spoken.contains("wasn't saved"))
    }
}
```

Note what is deliberately **not** tested: `#expect(UnfinishedRideCopy.label == "No end recorded")`. Asserting a `let` against the literal it was declared with passes forever and detects no behavior.

- [ ] **Step 2: Run to verify it fails**

Run: `cd AuraCore && swift test --filter UnfinishedRideCopyTests`
Expected: FAIL to compile — no `UnfinishedRideCopy`.

- [ ] **Step 3: Write the copy helper**

Create `AuraCore/Sources/AuraKit/Summary/UnfinishedRideCopy.swift`:

```swift
import Foundation
import AuraCore

/// Copy for a ride the rider never ended. Pure and view-free so the strings are unit-tested
/// rather than eyeballed, and shared by History, the last-ride card, the summary sheet, the
/// share card and the widget so they cannot drift.
///
/// **It describes the recording, not the rider** (spec D4). A rider who rode to the brewery
/// and got a lift home did finish their ride; Aura failed to record the end. The copy must
/// also be true for a ride still being recorded on another device, since a synced second
/// device cannot tell that apart from an abandoned one.
///
/// **And it has to separate two failures.** A ride killed *during* the stop is complete but
/// un-ended. A ride whose rider resumed and was killed later while moving is truncated, and
/// the missing distance is invisible. Both render identically, so the detail line says what
/// was not saved rather than only when recording stopped. This is what `checkpointedAt`, and
/// the schema version it cost, was bought for.
public enum UnfinishedRideCopy {
    public static let label = "No end recorded"

    /// "Recording stops at 2:14 PM. Anything after that wasn't saved." Carries the date too
    /// when the stop was not on `now`'s day. Nil when there is no marker timestamp, which is a
    /// PR #90 dev-build row.
    public static func detail(checkpointedAt: Date?, relativeTo now: Date = Date(),
                              calendar: Calendar = .current) -> String? {
        guard let when = timestamp(checkpointedAt, relativeTo: now, calendar: calendar) else {
            return nil
        }
        return "Recording stops at \(when). Anything after that wasn't saved."
    }

    /// Shown before an irreversible, all-devices delete. It must not claim the ride is intact:
    /// the rider standing in front of this dialog may be missing 40 km.
    public static func deleteWarning(checkpointedAt: Date?, relativeTo now: Date = Date(),
                                     calendar: Calendar = .current) -> String {
        let tail = "Deleting removes it from all your devices."
        guard let when = timestamp(checkpointedAt, relativeTo: now, calendar: calendar) else {
            return "Aura never recorded this ride's end, so anything after the last pause wasn't saved. \(tail)"
        }
        return "Aura recorded this ride up to \(when). Anything after that wasn't saved. \(tail)"
    }

    /// One spoken string. A VoiceOver user handed the same caption as a finished ride has not
    /// been told anything.
    public static func accessibilityLabel(checkpointedAt: Date?, relativeTo now: Date = Date(),
                                          calendar: Calendar = .current) -> String {
        guard let detail = detail(checkpointedAt: checkpointedAt, relativeTo: now,
                                  calendar: calendar) else { return label }
        return "\(label). \(detail)"
    }

    private static func timestamp(_ date: Date?, relativeTo now: Date,
                                  calendar: Calendar) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .medium
        return formatter.string(from: date)
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
///
/// **Not a pause glyph.** The rider just learned `pause.circle` in the HUD, where it means
/// "paused and resumable". Here it means the opposite: this ride can never be resumed or
/// ended. A clock says "when" without promising an action.
struct UnfinishedRideBadge: View {
    let checkpointedAt: Date?
    /// `.compact` shows the label alone for dense rows; `.full` adds the detail line.
    enum Style { case compact, full }
    var style: Style = .compact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
            Image(systemName: "clock")
                .font(.caption2.weight(.semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(UnfinishedRideCopy.label)
                if style == .full,
                   let detail = UnfinishedRideCopy.detail(checkpointedAt: checkpointedAt) {
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(AuraTheme.textSecondary)
        .padding(.horizontal, AuraTheme.Spacing.sm)
        .padding(.vertical, 2)
        .background(AuraTheme.textSecondary.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UnfinishedRideCopy.accessibilityLabel(checkpointedAt: checkpointedAt))
    }
}
```

Verify `"clock"` exists on the deployment target by reading the installed simulator runtime's SF Symbols plist rather than trusting recall — this bit us on ROH-44.

Footnote weight, not caption2: the badge competes with a 22 pt Saira distance numeral on the same row, and its job is to stop the rider trusting that numeral. Run the new foreground/background pair through the project's existing WCAG contrast guard, as every other palette pair is.

- [ ] **Step 6: Add the badge to the widget target**

`Aura/project.yml`'s `AuraWidgets` target enumerates individual files from `Sources/` (`LiveActivity/RideActivityAttributes.swift`, `Theme/AuraTheme.swift`, `Theme/StatPair.swift`, `Shared/RouteThumbnail.swift`). Without this step `UnfinishedRideBadge` compiles into the app target only, and Step 8's widget work fails with "cannot find 'UnfinishedRideBadge' in scope".

Add `- path: Sources/Shared/UnfinishedRideBadge.swift` to that list, then regenerate:

```bash
cd Aura && xcodegen generate
```

The `.xcodeproj` is untracked, so the regeneration is local-only; `project.yml` is the tracked change.

- [ ] **Step 7: Render it on the three app surfaces**

**History row** (`HistoryView.swift`, the middle `VStack` at 184-192). The caption is one `.footnote` with `.lineLimit(1)`; appending the marker there makes it the first thing Dynamic Type truncates, for the users least able to lose it. Give it its own line inside the existing `VStack`, after the caption `Text`:

```swift
                if summary.isUnfinished {
                    UnfinishedRideBadge(checkpointedAt: summary.checkpointedAt)
                }
```

This takes the row from ~66 pt to ~89 pt. That is a deliberate signal, not an accident: in a list of uniform rows the marked one is visibly different before any text is read.

**Last-ride card** (`LastRideCard.swift`, the `VStack` at 24-35), after the `relativeDate` `Text`:

```swift
                    if summary.isUnfinished {
                        UnfinishedRideBadge(checkpointedAt: summary.checkpointedAt)
                    }
```

This takes the card past the 88 pt thumbnail that currently governs its height, to ~111 pt — which no longer matches the hardcoded 88 pt loading placeholder at `HomeView.swift:174`, and eats ~23 pt of the peek's scroll affordance at `peekHeight` 250. Update the placeholder to match and check the peek; both are in Step 9's acceptance.

**Ride summary sheet** (`RideSummaryView.swift`, `titleBlock`). This screen is reachable — every History row taps into it via `HistoryView.swift:62` — and it is where a rider goes *because* the row looked odd, so it gets `.full`.

**Keep the "Nice ride" headline.** Flipping it to "Your ride" would change how the app addresses the *rider* over something Aura got wrong, which is the rule spec D4 sets for the copy, and it would break the golden-ride E2E assertion at `Aura/UITests/Screens/Screens.swift:90` for no gain. The badge carries the fact.

Add after the destination-name block, before the `isLongest` label:

```swift
            if ride.checkpointedAt != nil || ride.endedAt == nil {
                UnfinishedRideBadge(checkpointedAt: ride.checkpointedAt, style: .full)
            }
```

`RideSummaryView` takes a `Ride`, not a `RideSummary`, which is why the condition is spelled out. If `Ride` has grown an equivalent helper by now, use it.

Two more changes on this screen:

1. **Suppress the trophy.** `isLongest` (`RideSummaryView.swift:128`, computed at `:216`) can fire on a truncated ride, putting a lime celebration capsule directly under a grey "anything after that wasn't saved" pill. Gate it: `if isLongest && ride.checkpointedAt == nil && ride.endedAt != nil`. The reverse case — a rider who genuinely rode their longest and is denied the trophy because the end was lost — is a real cost and is accepted: claiming a record from a recording we have just told them is incomplete is worse.
2. **Skip the count-up.** The hero distance counts up from zero over ~0.7 s. Jump straight to the value for an unfinished ride, the way `reduceMotion` already does at `:151`. Celebrating a number the same screen calls incomplete is the same contradiction as the trophy.

**Fix the save-failure copy while you are here.** `RideSummaryView.swift:135-137` says *"Couldn't save this ride — it won't appear in History."* Since Task 2, a ride whose `finish()` throws still has its checkpoint row in History, now wearing the badge — so the app asserts absence and displays presence. When a checkpoint exists, say instead: *"Aura couldn't save the end of this ride. What was recorded is in History."*

- [ ] **Step 8: The widget renders the marker, not just an accessibility label**

Do **not** ship the marker to VoiceOver only. A sighted rider glancing at the Lock Screen would see a truncated ride looking complete while a VoiceOver user is told the truth — backwards from every other surface here, and it makes the glance surface the one that misleads.

There is room. Both tight families already spend a line on low-value text: `accessoryRectangular` renders `"Last ride · Tue"` (`LastRideWidget.swift:97`) and `systemSmall` renders `"Tue · Explore"` (`:44`). When `ride.isUnfinished`, replace that secondary line with `UnfinishedRideCopy.label` (plus the badge glyph if it fits). Zero added height, no stat truncated.

Extend the existing accessibility string at `LastRideWidget.swift:142` with `UnfinishedRideCopy.accessibilityLabel(checkpointedAt: ride.checkpointedAt)`.

**Share card** (`ShareCardContent.swift` and its rendered view). PO decision, 2026-07-29: mark it now rather than deferring. Without this the marker reaches every surface only the rider sees and none of the surface other people see — the rider reads "anything after 2:14 PM wasn't saved", taps Share, and posts a card showing a truncated distance as though it were the whole ride. Add `checkpointedAt` to `ShareCardContent` and render `UnfinishedRideCopy.label` in the card footer when it is non-nil. Keep it quiet; this is a footnote on the card, not a headline.

Note on spec D4's duration labeling: the detail line now states the recording boundary explicitly on every surface that carries the badge, which is what that clause was for. A separate per-number qualifier ("1h 38m moving") is **not** implemented, and that is a deliberate cut rather than an oversight.

- [ ] **Step 9: Swap the dialog message from Task 6 to the real string**

In `HistoryView.swift`, replace the inlined placeholder with the helper:

```swift
        } message: { summary in
            Text(UnfinishedRideCopy.deleteWarning(checkpointedAt: summary.checkpointedAt))
        }
```

- [ ] **Step 10: Build and eyeball**

Delegate to the `apple-platform-build-tools:builder` agent: build the `Aura` scheme **and** the `AuraWidgets` extension for an iPhone simulator. Expected: clean.

Then, on the smallest device in the matrix (iPhone SE) at the largest accessibility text size, confirm:

- the History row's badge does not push the hero distance numeral off the row, and the caption stays legible;
- the last-ride card still fits the Home peek with its scroll affordance intact, and the 88 pt loading placeholder no longer jumps on load;
- the badge's label wraps rather than clipping inside its capsule in the narrow column between the 88 pt thumbnail and the chevron;
- the summary sheet shows no trophy and no count-up on an unfinished ride.

- [ ] **Step 11: Commit**

```bash
git add AuraCore Aura
git commit -m "feat(roh-107): mark a ride with no recorded end across every surface"
```
---

## After the plan

Run the whole gate before opening a PR:

```bash
cd AuraCore && swift test
cd "$(git rev-parse --show-toplevel)" && swiftlint lint --strict
```

**SwiftLint runs from the repo root, not from `AuraCore/`.** It reads `.swiftlint.yml` from the
current directory and does not walk parents, and the only rule-configuring config is the one at
the root — so running it inside `AuraCore/` silently drops `identifier_name.min_length` and the
relaxed `line_length` and reports ~11,000 violations that CI does not see. CI invokes
`swiftlint lint --strict` from the root (`.github/workflows/ci.yml:188`); match it.

Then build the app target through the builder agent, and device-verify the recovery path: pause a real ride above the 25 m floor, kill Aura from the app switcher, relaunch, and confirm the badge, the "Recorded until" line, the weekly ring still counting the distance, and Home showing the recovered ride rather than a stale mid-ride row.

**Do not promote the CloudKit production schema during this plan.** [ROH-108](https://linear.app/rohun/issue/ROH-108) deploys once, after V7 has landed, covering `CD_segmentsData`, `CD_pausedSeconds` and `CD_checkpointedAt` together.

Running a signed device build *will* add `CD_checkpointedAt` to the CloudKit **development** schema, which is correct and required — development auto-updates from the client, and it is what makes the eventual promotion possible. The constraint above is about production only; do not let it stop you device-verifying.

**Once a Task-1-or-later build is on a device, do not install a `main` build on that device without deleting the app first.** A store stamped V7 cannot be opened by a V6 build: `RideStore.persistent()` throws, `AuraApp` catches it by falling back to the ephemeral in-memory store, and the rider's History reads empty with no error surface. This project device-verifies on a real phone with real history, so it is a live hazard, not a theoretical one.

**`RideMigrationTests` is the only end-to-end chain guard.** It reopens on `RideRecord.self` plus the plan, so it silently becomes the V1→V7 chain test the moment Task 1 lands. It must stay green; a mis-ordered stage does not fail loudly, it throws inside `ModelContainer.init` and the rider just sees an empty History.

Stale comments to update while you are in there: `SwiftDataSerialGate.swift:9-10` and `SchemaInvariantTests.swift:12-13` both say two `@Model` classes share the entity name `RideRecord`. From Task 1 there are three. Those comments are the institutional memory of the ROH-65 flake, so leaving them wrong costs the next person real time.

**Known gap, deliberate:** `AppRouter` has no unit-test coverage and cannot get any here — it lives in the app target, and `Aura/project.yml` defines only `Aura`, `AuraWidgets` and `AuraUITests`. Task 3's computed-property change is covered by the existing `AuraUITests` deep-link cases and by device verification. If that is judged insufficient, moving the guard logic into AuraCore is its own pass, not a step in this one.
