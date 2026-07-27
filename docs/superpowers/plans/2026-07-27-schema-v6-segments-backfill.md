# Schema V6 — segmented persistence, off-launch backfill (ROH-100, Pass 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** revision 3 — EXECUTED. Revision 2's plan was implemented, then put through a second three-reviewer gate against the finished diff; that gate's findings and dispositions are the last table in this document. Revision 2 text follows.

**Status of revision 2:** Revision 1 put the backfill in a custom `didMigrate` stage, as spec D2 and ROH-100 both specify. A three-reviewer adversarial gate refuted that: the stage runs synchronously inside `AuraApp.init()` before the first frame, and it cannot reach the rows its own rationale is written about. Revision 2 makes V5→V6 lightweight and moves the backfill to a resumable background sweep. PO signed off on the change of approach. Every finding and its disposition is recorded at the end of this document.

**Goal:** Persist a ride's pause boundaries and its paused total, by redeclaring `RideRecord` in a new `RideSchemaV6` with an externally-stored `segmentsData` blob and a `pausedSeconds` column, and backfilling `segmentsData` from existing flat tracks off the launch path.

**Architecture:** V6 declares its own `@Model final class RideRecord` (entity name unchanged) rather than mutating `RideSchemaV2.RideRecord`, which V3/V4/V5 all reuse — mutating it would retroactively rehash them and leave an on-disk V5 store matching no schema in the plan. Both new attributes are optional/defaulted, so **V5→V6 is a lightweight stage**. The mapper dual-writes: `trackData` stays a flat, complete `[TrackPoint]` blob for older builds syncing the same CloudKit records; `segmentsData` carries the segmented truth. Reads prefer `segmentsData` and degrade — never throw — to the flat track. A `@ModelActor` sweep backfills nil rows in small batches on a background context, kicked off after first frame.

**Tech Stack:** Swift 6 language mode, SwiftData (`VersionedSchema`, `SchemaMigrationPlan`, `@ModelActor`), `NSPersistentCloudKitContainer` mirroring, Swift Testing, `os.Logger`.

**Issue:** [ROH-100](https://linear.app/rohun/issue/ROH-100) · **Spec:** `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md` (D2, D3, D5)

## Global Constraints

- **Package-first.** One call site in `Aura/` (the sweep trigger) is the only app-target change; everything else is in `AuraCore/`.
- **The entity name stays `RideRecord`.** A rename creates a new CloudKit record type and orphans every already-synced ride.
- **CloudKit model rules on every V6 attribute:** optional or defaulted, no `.unique`, no relationships. Machine-checked by `SchemaInvariantTests`.
- **`segmentsData` carries `@Attribute(.externalStorage)`** — matching `trackData` (`RideSchemaV2.swift:20`). Without it a ~300 KB blob sits inline and `RideStore.summaries()` faults it on every row (ROH-64). Machine-checked, not inferred from a sidecar file's existence.
- **`thumbnailData` stays flat** (D3).
- **No read path may throw on a bad or empty blob.** `RideMapper.ride` runs inside a `.map` in `RideStore.allRides()`, so one throw fails every ride at once. *(Corrected at the second gate: `allRides()` has no production caller today — History renders from `summaries()`, which cannot throw, and the detail sheet uses `try? ride(id:)`. The constraint stands for the shape of the API, not for a live blast radius.)*
- **Nothing added here may be able to fail the `ModelContainer`.** `AuraApp.swift:56-62` catches a throwing `RideStore.persistent()` and falls back to `RideStore.inMemory()`, which shows the rider an empty History *and* lets `WidgetRefresh.reload` overwrite the App Group snapshot with the empty store. A backfill is best-effort by construction and must never reach that path.
- **Release gate, not code:** the CloudKit **production** schema must be promoted before a V6 build ships.
- Date defaults stay the fixed sentinel `Date(timeIntervalSince1970: 0)`.
- `swiftlint --strict` passes before pushing.

---

## Decisions

**D-a. `segmentsData` is `Data?`.** Optionality is the "not backfilled" signal the read path and the sweep both branch on, and it is what a V5-written CloudKit record materializes as on a V6 device. A defaulted `Data()` would be indistinguishable from a genuinely empty ride.

**D-b. V5→V6 is lightweight; the backfill is a separate background sweep.** *(Revised — revision 1 had a custom stage.)* Three reasons, each independently sufficient:

- **It is launch-blocking.** `AuraApp.init()` → `makeRideStore()` → `RideStore.persistent()` → `ModelContainer(migrationPlan:)` runs `didMigrate` before the first frame. Measured on desktop silicon: 0.043 s per 3-hour ride to decode and re-encode, so ~16 s of CPU for a 365-ride history, before counting ~500 MB of external-blob writes. That is watchdog territory, and a watchdog kill re-enters the identical path on the next launch.
- **It cannot fail safely.** Any throw inside `didMigrate` fails the container and drops the rider into the ephemeral store described in the constraints. The rider most likely to run out of disk mid-backfill is the rider with the most rides.
- **It does not close the population it exists for.** `didMigrate` runs once. Every ride a V5 device records *after* a V6 device migrates arrives by CloudKit import with `segmentsData` nil, is never revisited by `RideStore.save` (which only rewrites rows this build wrote), and is never seen by any stage. The sweep, keyed on `segmentsData == nil`, catches those too — so it is the only form of this work that can ever make `trackData` retirable.

Both new attributes are optional/defaulted, which is exactly what a lightweight stage handles.

**D-c. The sweep is resumable and failure-contained.** It collects the ids of nil rows in one cheap fetch, then processes them one row at a time. Per-row failures are counted, never thrown. Resumability is free: a row is pending precisely while `segmentsData` is nil, so a kill mid-sweep costs only the row in flight. Revision 1's `fetchOffset`-based paging was refuted — the offset counter double-counted undecodable rows across batches and skipped good rows permanently. *(Revised again at the second gate: batching was dropped for a save per row. A row dirty across a batch loses a concurrent writer's columns to CoreData's dirty-object conflict resolution, which was reproduced.)*

**D-d. Zero points is ZERO segments, never one empty segment** (`Ride.swift:45-48`), so a backfilled fix-less ride round-trips `==` to a fresh one.

**D-e. Empty `trackData` is an empty ride, not a corrupt one — on read as well as in the sweep.** `trackData`'s default is `Data()`, which is what a CloudKit record materialized without the key carries, and `JSONDecoder` throws on it. Revision 1 handled that in the sweep only, leaving `RideMapper.ride` to throw on exactly that row and empty the whole History fetch. Both paths now treat an empty blob as zero points.

**D-f. Corrupt `segmentsData` degrades to the flat track; corrupt `trackData` still throws.** The second is pre-existing behavior and is deliberately not widened into a silent blank ride. V6-written rows never read `trackData`, so a corrupt flat blob stops mattering for new rides.

**D-g. No ROH-107 "unfinished ride" flag in V6.** *(Reasoning strengthened after review.)* The production schema is immutable once promoted, and ROH-107 has not decided what the state stores. More decisively, a reviewer showed **it may need no column at all**: `RideSummary.endedAt` is already `Date?`, and D5 already specifies a statless treatment for a nil `endedAt`. The only reason that does not work today is that Pass 2's checkpoint deliberately stamps `endedAt` *because* no surface reads it. Teaching the read surfaces to honor a nil `endedAt` costs zero schema versions and zero promotions — which is ROH-107's own scope, app-side, not this pass. Recorded on ROH-107, with the sequencing warning that Pass 4 makes recovered-checkpoint rides common.

**D-h. `pausedSeconds` is a defaulted `Double`, not optional.** A reviewer argued for `Double?` so "recorded before pause existed" is distinguishable from "rider did not pause". Rejected: spec D5 states `0` is the correct reading for every pre-pause ride, and `Ride.pausedSeconds` (shipped in Pass 1/2) is a non-optional `TimeInterval` — an optional column would introduce a lossy seam at the mapper with no consumer able to use it. The residual concern is real and recorded: after Pass 4, a pre-pause ride and an unpaused ride are indistinguishable, so active time on an old ride equals elapsed. That is a true statement about a ride with no recorded pauses.

---

## File Structure

**Created**

| File | Responsibility |
| -- | -- |
| `AuraCore/Sources/AuraKit/Persistence/RideSchemaV6.swift` | The V6 `VersionedSchema`: redeclared `RideRecord`, plus the `RideRecord` typealias moved from V2 |
| `AuraCore/Sources/AuraKit/Persistence/RideSegmentBackfill.swift` | `@ModelActor` sweep: finds `segmentsData == nil` rows, backfills from the flat track, batched/resumable/contained |
| `AuraCore/Tests/AuraKitTests/SchemaV6MigrationTests.swift` | V5 store opens as V6 with no data loss and no work done at launch |
| `AuraCore/Tests/AuraKitTests/RideSegmentBackfillTests.swift` | The sweep: backfill, skip, resume, idempotence, no-clobber |
| `AuraCore/Tests/AuraKitTests/RideMapperSegmentsTests.swift` | Dual-write, read preference, degradation, `pausedSeconds` |

**Modified**

| File | Change |
| -- | -- |
| `AuraCore/Sources/AuraKit/Persistence/RideSchemaV2.swift:47-48` | Delete the `RideRecord` typealias |
| `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift` | Register V6; lightweight `migrateV5toV6` |
| `AuraCore/Sources/AuraKit/Persistence/RideMapper.swift` | Dual-write; segment-preferring read with fallbacks; empty-blob handling; `pausedSeconds` in the summary |
| `AuraCore/Sources/AuraKit/Persistence/RideStore.swift:74-96` | Copy both new columns on the update branch |
| `AuraCore/Sources/AuraCore/Models/RideSummary.swift` | Add `pausedSeconds` |
| `AuraCore/Sources/AuraCore/Models/Ride.swift:20-21` | The "not persisted until V6 (pinned by …)" comment is now false |
| `Aura/Sources/AuraApp.swift` | Kick the sweep off after first frame, once per launch, skipped when ephemeral |
| `AuraCore/Tests/AuraKitTests/SchemaInvariantTests.swift` | Repoint V5→V6; assert `segmentsData` optionality **and** `.externalStorage` via `attribute.options` |
| `AuraCore/Tests/AuraKitTests/RideMapperTests.swift` | Flip the segment-collapse pin |
| `AuraCore/Tests/AuraKitTests/RideStoreCheckpointTests.swift` | Flip the paused-seconds pin; extend `updatePathCarriesEveryColumn` |
| `AuraCore/Tests/AuraKitTests/RideSchemaV2DefaultsTests.swift` | Pin to `RideSchemaV2.RideRecord` explicitly — the typealias move would silently repoint it at V6 |
| `AuraCore/Tests/AuraKitTests/RideTrackExternalStorageTests.swift` | Segmented long-ride cold reopen |
| `AuraCore/Tests/AuraKitTests/Support/SwiftDataSerialGate.swift` + container suites | Two `@Model` classes now share the entity name `RideRecord` |

---

### Task 1: V6 schema + mapper + store, as one commit

Tasks 1, 3 and 4 of revision 1 are merged: making `segmentsData` a required initializer parameter breaks `RideMapper` and `RideSchemaV2DefaultsTests` the moment the typealias moves, so splitting them lands two non-compiling commits and makes both "watch it fail" steps meaningless (the failure is a compile error, not the semantic one claimed).

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSchemaV6.swift`
- Modify: `RideSchemaV2.swift:47-48`, `RideMigrationPlan.swift`, `RideMapper.swift`, `RideStore.swift:59-96`, `RideSummary.swift`, `Ride.swift:20-21`
- Test: `SchemaInvariantTests.swift`, `RideMapperSegmentsTests.swift`, `RideMapperTests.swift`, `RideStoreCheckpointTests.swift`, `RideSchemaV2DefaultsTests.swift`

**Interfaces:**
- Produces: `RideSchemaV6.RideRecord` (twelve V2 attributes + `segmentsData: Data?` + `pausedSeconds: Double`), `typealias RideRecord = RideSchemaV6.RideRecord`, `RideSummary.pausedSeconds: Double`, `RideMigrationPlan.migrateV5toV6` (lightweight). `RideMapper` signatures unchanged.

- [x] **Step 1: Write the failing tests.** `SchemaInvariantTests` repointed to `Schema(versionedSchema: RideSchemaV6.self)`, `v5ContainsAllModels` → `v6ContainsAllModels`, plus:

```swift
/// `.externalStorage` asserted on the attribute itself. A behavioral check would not catch
/// its loss: `trackData` externalizes on the same row, so a sidecar file exists either way.
@Test func segmentBlobsAreExternallyStored() {
    let ride = entities.first { $0.name == "RideRecord" }
    let segments = ride?.attributes.first { $0.name == "segmentsData" }
    #expect(segments?.isOptional == true, "nil is how an un-backfilled row is representable")
    #expect(segments?.options.contains(.externalStorage) == true,
            "an inline ~300 KB blob is faulted by summaries() on every row — ROH-64")
    let track = ride?.attributes.first { $0.name == "trackData" }
    #expect(track?.options.contains(.externalStorage) == true)
}
```

`RideMapperSegmentsTests` (dual-write, read preference against deliberately disagreeing blobs, absent-blob fallback, corrupt-blob fallback, the whole-History-fetch guard, `pausedSeconds` through record and summary) — and, from D-e:

```swift
/// The shape a CloudKit record materialized without the key carries: no segments blob and an
/// EMPTY flat blob, which `JSONDecoder` throws on. `allRides()` maps over every row, so a
/// throw here is not one bad ride — it is an empty History for every ride the rider owns.
@Test func aRecordWithNoBlobsAtAllReadsAsAnEmptyRideRatherThanThrowing() throws {
    let record = try RideMapper.record(from: twoSegmentRide())
    record.segmentsData = nil
    record.trackData = Data()
    let back = try RideMapper.ride(from: record)
    #expect(back.segments.isEmpty)
}
```

Flip `multiSegmentRideFlattensThroughTheStoreUntilV6` → `multiSegmentRideSurvivesTheStore` (`segments.count == 2`); flip `pausedSecondsIsDroppedByTheStoreUntilV6` → `pausedSecondsSurvivesTheStoreFromV6`; extend `updatePathCarriesEveryColumn` so the second ride differs in both new columns (two segments vs one, `pausedSeconds: 120` vs `0`) — the checkpoint-then-End shape that would otherwise leave every paused ride truncated at its first stop. Repoint `RideSchemaV2DefaultsTests` at `RideSchemaV2.RideRecord` explicitly.

Drop revision 1's `pausedSecondsIsDefaultedForCloudKit`: it asserted `isOptional || defaultValue != nil`, which `everyAttributeIsOptionalOrDefaulted` already asserts for every attribute — a tautology dressed as coverage.

- [x] **Step 2: Run and watch them fail.** `swift test --package-path AuraCore --filter "Schema invariants"` → FAIL, `cannot find 'RideSchemaV6' in scope`.

- [x] **Step 3: Implement.** `RideSchemaV6.swift` as in revision 1 (redeclared record with the doc comment explaining the rehash hazard, the entity-name rule, the CloudKit rules and D-g); delete the V2 typealias; register V6 with `MigrationStage.lightweight(fromVersion: RideSchemaV5.self, toVersion: RideSchemaV6.self)` and a comment recording why it is lightweight and where the backfill went; `RideMapper.record` writes `segmentsData: try encoder.encode(ride.segments)` and `pausedSeconds:`; `RideMapper.ride` prefers segments, logs and falls back on a corrupt blob, treats an empty `trackData` as zero points (D-e); `summary` gains `pausedSeconds`; `RideStore.save`'s update branch copies both columns; `RideSummary` gains `pausedSeconds` (defaulted `0` in the initializer, one production writer).

- [x] **Step 4: Run.** `swift test --package-path AuraCore --filter "RideMapper|RideStore|Schema invariants"` → PASS.

- [x] **Step 5: Commit.** `feat(roh-100): schema V6 — redeclared RideRecord, dual-written segments, paused time`

---

### Task 2: The lightweight stage does no work and loses nothing

**Files:** Test: `AuraCore/Tests/AuraKitTests/SchemaV6MigrationTests.swift`

Revision 1's migration suite asserted backfill results. Under D-b those move to Task 3, and this suite asserts what a lightweight stage must guarantee: a V5 store opens as V6, every column survives, un-backfilled rows read correctly through the degrading path, and **nothing is rewritten at launch**. Revision 1's `migratedRowReadsBackThroughTheStore` was refuted for passing against a no-op stage — under D-b a no-op is the specification, and the suite now says so explicitly.

- [x] **Step 1: Write the tests** — write a V5-shaped store (V2 `RideRecord` + V5 `SavedPlaceRecord` + V4 `SeenGemRecord`, no plan, `cloudKitDatabase: .none`), reopen through the plan on the V6 model set, then assert: rows survive with `trackData` byte-identical; `segmentsData == nil` ("the stage must not touch data — the sweep owns that, off the launch path"); `pausedSeconds == 0`; `store.ride(id:)` returns one segment with every point; `summaries()` works. Plus a row with `Data()` as its track, which must read back as an empty ride rather than throwing.

- [x] **Step 2: Run and watch it fail** — FAIL: no V6 in the plan (or, after Task 1, PASS, in which case it is a regression guard rather than a driver; note it and move on).

- [x] **Step 3: Run.** `swift test --package-path AuraCore --filter "Schema V6 migration"` → PASS.

- [x] **Step 4: Commit.** `test(roh-100): pin the lightweight V5→V6 stage as lossless and inert`

---

### Task 3: The background backfill sweep

**Files:**
- Create: `AuraCore/Sources/AuraKit/Persistence/RideSegmentBackfill.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSegmentBackfillTests.swift`

**Interfaces:**
- Produces:

```swift
@ModelActor
public actor RideSegmentBackfiller {
    public struct Result: Equatable, Sendable {
        public var backfilled: Int   // rows given a segmentsData blob
        public var skipped: Int      // rows whose flat track could not be decoded
        public var remaining: Int    // rows still pending when maxRows ran out
    }
    @discardableResult
    public func backfill(batchSize: Int = 10, maxRows: Int = .max) -> Result
}
```

Constructed `RideSegmentBackfiller(modelContainer: store.container)`. `backfill` does not throw: every failure is counted and logged. `batchSize` is a save cadence, not a fetch window.

- [x] **Step 1: Write the failing tests**, covering: a nil row backfills to one segment with its points intact; empty and `Data()` tracks backfill to zero segments; **an undecodable row is skipped, counted, and does not stop the sweep — with enough rows and a small enough `batchSize` that skipped rows and pending rows interleave across several batches** (the combination revision 1's paging bug lived in, and which no revision 1 test reached); a row that already has segments is never rewritten (a real 2-segment ride stays 2 segments); running twice is idempotent (`backfilled == 0` the second time); `maxRows` leaves `remaining > 0` and a second run finishes the job (resumability); and the sweep's writes are visible through `RideStore.ride(id:)`.

- [x] **Step 2: Run and watch them fail** — `cannot find 'RideSegmentBackfiller' in scope`.

- [x] **Step 3: Implement.** One fetch of pending ids (cheap — external blobs are not faulted by reading `id`), then per-row fetch by `#Predicate { $0.id == id }` (the only predicate shape this codebase already proves, `RideStore.swift:78`), decode → wrap → encode → assign, `save()` every `batchSize` rows with `await Task.yield()` between batches, everything inside `do/catch` that counts and logs. Empty track → zero segments (D-d/D-e). Never touch a row whose `segmentsData` is non-nil.

- [x] **Step 4: Run.** `swift test --package-path AuraCore --filter RideSegmentBackfill` → PASS.

- [x] **Step 5: Commit.** `feat(roh-100): resumable background sweep backfilling segmentsData`

---

### Task 4: Trigger the sweep after first frame

**Files:** Modify `Aura/Sources/AuraApp.swift`

- [x] **Step 1: Wire it** — a `.task` on the root view (not `init`, not `scenePhase`), once per launch, skipped when `rideStore.isEphemeral`, at `.background`/`.utility` priority, result logged. It must be structurally impossible for this to affect launch or to throw into the container.

- [x] **Step 2: Build the app.** Delegate to the `apple-platform-build-tools:builder` agent — build the `Aura` scheme for an iPhone simulator. Expected: BUILD SUCCEEDED.

- [x] **Step 3: Commit.** `feat(roh-100): run the segment backfill after first frame`

---

### Task 5: External storage and entity-name flake-proofing

**Files:** `RideTrackExternalStorageTests.swift`, `Support/SwiftDataSerialGate.swift`, container suites

- [x] **Step 1:** Add the segmented long-ride cold-reopen test (3000 points split across two segments): both segments survive externalization byte-for-byte, `pausedSeconds` survives, and `summaries()` still reads columns only. The `.externalStorage` *attribute* guard lives in `SchemaInvariantTests` (Task 1) — `hasExternalData(in:)` cannot prove it, because `trackData` externalizes on the same row regardless.

- [x] **Step 2:** Widen the gate's doc comment: from V6 on, `RideSchemaV2.RideRecord` and `RideSchemaV6.RideRecord` share the CoreData entity name `RideRecord`, the same process-global hazard `SavedPlaceRecord` hit in ROH-65. Then:

```bash
grep -rln "RideStore.inMemory()\|ModelContainer(" AuraCore/Tests/AuraKitTests | xargs grep -L "swiftDataSerialized"
```

For each hit, add `.swiftDataSerialized`. **`RideStoreTests` is an `XCTestCase`** and cannot take a Swift Testing `SuiteTrait` — convert it to a Swift Testing suite rather than leaving the one ungated container suite in the run.

- [x] **Step 3: Run the full suite three times** (`for i in 1 2 3; do swift test --package-path AuraCore || break; done`) — this class of bug is intermittent by construction.

- [x] **Step 4: Commit.** `test(roh-100): guard external storage and serialize the two RideRecord entities`

---

### Task 6: Lint, full verification, review gate, hand-off

- [x] **Step 1:** `swiftlint --strict` → clean.
- [x] **Step 2:** `swift test --package-path AuraCore` → all suites pass.
- [x] **Step 3:** App build via the builder agent → BUILD SUCCEEDED.
- [x] **Step 4:** Adversarial review gate — three independent reviewers, distinct lenses, refuting mandate, against the full branch diff. Reconcile before merging.
- [x] **Step 5:** Hand-off to the PO, in the PR body and in Linear:
  - **CloudKit production schema promotion**, with the actionable detail review found missing: container `iCloud.com.rohunjoseph.aura`, CloudKit Console → Schema → Deploy Schema Changes, and the prerequisite that a V6 build must first run against the **development** environment so `CD_segmentsData` and `CD_pausedSeconds` exist to promote. Missing it stops sync for every V6 user with no in-app error surface. Filed as a Linear issue blocking first TestFlight/App Store release, not left in a PR body three passes before the builds that reach a device.
  - **Unverifiable here:** that a V5 build ignores an unknown `CD_segmentsData` and degrades to a flat track. macOS CI has no CloudKit entitlement. Needs two-device verification — and the check should include what the V5 device *pays*: the sweep dirties every historical row, so the whole history re-exports and re-downloads.
  - **Storage:** dual-write roughly doubles per-ride bytes on disk and in the rider's iCloud quota. File the `trackData` retirement issue with a named trigger; the spec calls it "a separate issue" and no such issue exists.
  - **ROH-107:** no flag in V6 (D-g), with the sequencing warning that Pass 4 makes recovered-checkpoint rides common.

---

## Review reconciliation (revision 1 → 2)

| # | Finding | Disposition |
| -- | -- | -- |
| 1 | Backfill is launch-blocking (~16 s CPU at 365 rides, watchdog risk) | **Fixed** — D-b, lightweight stage + background sweep. PO signed off |
| 2 | A throw in `didMigrate` drops the rider into an ephemeral store and wipes the widget snapshot | **Fixed** — nothing added can fail the container; sweep never throws (constraint + D-c) |
| 3 | The stage cannot reach V5 rows imported after migration, so `trackData` is not retirable anyway | **Fixed** — the sweep's predicate catches them on any later run |
| 4 | `fetchOffset` paging double-counts undecodable rows and permanently skips good ones | **Fixed** — per-id processing, no offset arithmetic (D-c) |
| 5 | Tasks 1/2 commit a non-compiling tree; "watch it fail" is a compile error | **Fixed** — Tasks 1+3+4 merged into one commit |
| 6 | `RideSchemaV2DefaultsTests` is an unlisted call site and would silently start testing V6 | **Fixed** — pinned to `RideSchemaV2.RideRecord` explicitly, Task 1 |
| 7 | Empty `trackData` + nil `segmentsData` throws on read → empties History | **Fixed** — D-e, both paths treat it as zero points, with a test |
| 8 | `migratedRowReadsBackThroughTheStore` passes against a no-op stage | **Fixed** — under D-b a no-op *is* the spec; Task 2 asserts inertness explicitly |
| 9 | `hasExternalData` can't detect a missing `.externalStorage` | **Fixed** — asserted on `attribute.options` in `SchemaInvariantTests` |
| 10 | `pausedSecondsIsDefaultedForCloudKit` is a tautology | **Fixed** — dropped |
| 11 | `summaryOfAPreV6RowReadsPausedSecondsAsZero` tests nothing about a pre-V6 row | **Fixed** — replaced by the V5-store read in Task 2 |
| 12 | Paging test compiles? (tuple labels) and doesn't distinguish paged from fetch-all | **Moot** — that test is gone; the sweep's batching is tested by resumability and interleaved skips |
| 13 | Undecodable × multi-batch untested | **Fixed** — Task 3 Step 1 requires exactly that shape |
| 14 | `RideStoreTests` is XCTest and cannot take `.swiftDataSerialized` | **Fixed** — converted, Task 5 |
| 15 | `Ride.swift:20-21` comment references a test this pass renames | **Fixed** — Task 1 |
| 16 | Migration re-entrancy / partial-backfill state unanalyzed | **Moot** — a lightweight stage has no data work to interrupt; the sweep is resumable by construction |
| 17 | Storage doubling, CloudKit re-export burst, no retirement issue | **Partly** — unavoidable given dual-write; paced off-launch by the sweep. Surfaced in Task 6 and filed |
| 18 | Release gate not actionable, lives in a PR body | **Fixed** — Task 6 Step 5, filed as a release-blocking issue with console path and dev-schema prerequisite |
| 19 | `pausedSeconds` should be optional to distinguish "couldn't record" | **Rejected** — D-h, with the residual concern recorded |
| 20 | D-g under-argued; ROH-107 may need no column at all | **Accepted into the reasoning** — D-g rewritten; recorded on ROH-107 |
| 21 | Pause flush gets ~2× more expensive per tap (three track passes, two blobs) | **Out of scope, handed off** — Pass 4 measures the flush on device at ~9,000 points |
| 22 | `SchemaV5MigrationTests` may now drive V5→V6 | **Verify during Task 2** — deliberately, not as a flake in Task 5's triple run |
| 23 | Sort-order dependence of unsorted fetches | **Moot** — no offset paging remains |


---

## Second review gate — against the finished diff

Three independent reviewers (skeptic / architecture / product lenses, refuting mandate) ran against the implemented branch. The headline finding is that the sweep was still running on the main thread: `@ModelActor`'s executor serializes on whatever thread enqueues it, and a `Task { }` started inside a SwiftUI `.task` inherits MainActor isolation — so the work had moved one frame later rather than off the main thread. Measured by two reviewers independently (~0.4 s stalls at the old batch size; ~110 ms of synchronous main-thread work before the first suspension).

| Finding | Disposition |
| -- | -- |
| Sweep ran on the main thread; `Task(priority:).value` also escalated its priority | **Fixed** — `Task.detached(priority: .utility)`, not awaited. The reason is documented at both the call site and the actor |
| A dirty row's stale snapshot wins a CoreData conflict, so the batch save reverted a concurrent writer's columns (reproduced) | **Mitigated** — per-row saves shrink the window to the save itself. Not closed: SwiftData exposes no merge policy. Documented on the type; the reachable writer is the CloudKit import context, which is part of the two-device verification |
| `maxRows` budgeted rows *examined*, so unreadable rows starved the rows behind them forever | **Fixed** — the budget counts rows filled. Mutation-verified |
| An empty `trackData` was stamped as an empty ride, freezing a row whose CloudKit asset had not materialized | **Fixed** — left pending; it already reads as an empty ride |
| `segmentsData` is derived once and never re-derived, so a V5 device finishing a ride after a V6 device backfilled its partial track pins the ride to the fragment | **Mitigated** — 24 h settling window. A full fix needs a derivation marker, i.e. another column and another promotion. Documented as a known limitation |
| Sweep was uncancellable and ran under an active ride | **Fixed** — `Task.isCancelled` per row; the app cancels it when `isRideActive` goes true |
| Unbounded CloudKit export burst on the update launch (`maxRows` never passed) | **Fixed** — 50 rows per launch. Un-filled rows read correctly meanwhile |
| `remaining` reported 0 while rows were permanently pending; save failures were counted as unreadable | **Fixed** — `remaining` is counted from the store; `unreadable` and `failedWrites` are separate |
| A full disk would fail every save and grind the whole history for nothing | **Fixed** — the run stops after three consecutive write failures. No free-space precheck: accepted, the stop covers the symptom |
| Nothing prevented two concurrent sweeps | **Mitigated** — the app holds the task and will not start a second; the nil re-check makes a race correct anyway. Test added |
| The nil re-check, the batching, cancellation, and two tests could not fail against a broken implementation | **Fixed** — `batchSize` is gone with per-row saves; the rest are covered and each guard was verified by mutating the source and watching the test fail |
| Every sweep test used an in-memory store — the one configuration the app skips | **Fixed** — an on-disk test with a 3000-point externalized track |
| `allRides()` has no production caller, so "one throw empties History" was false in five places | **Fixed** — corrected in the mapper, two test files and a test name. `statsData` can still throw; said so rather than widening behavior in this pass |
| `RideSummary.pausedSeconds` documented as read by History and the widget; nothing reads it | **Fixed** — documented as Pass 4/5, including that `WidgetSnapshot` will need its own shape change |
| `.task` "runs once per launch" is a view-lifecycle claim | **Fixed** — the task is held in state and not restarted |
| `Package.resolved` originHash churn | **Fixed** — reverted |
| Pass 4 makes recovered-checkpoint ghost rides common while ROH-107 is still open | **Raised** — on ROH-107 and ROH-74 as a Pass 4 sequencing decision for the PO |
| Pass 4/5 must decide what a pre-V6 ride's active-time headline shows, given `pausedSeconds == 0` | **Raised** — on ROH-101 |
| Every End tap now encodes the track twice (inherent to dual-write) | **Named** in the PR rather than hidden; Pass 4 measures the flush on device |
| The release gate was prose in a plan document | **Fixed** — filed as a release-blocking Linear issue and linked from the roadmap |
| No `trackData` retirement issue existed | **Fixed** — filed |
