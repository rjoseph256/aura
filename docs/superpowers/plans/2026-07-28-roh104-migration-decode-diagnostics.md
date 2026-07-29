# ROH-104 Migration Decode Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the two swallowed failures in `RideMigrationPlan.migrateV1toV2`'s thumbnail backfill
report themselves — in release via `os.Logger` and in DEBUG via `assertionFailure` — without
firing on a ride that legitimately has no track.

**Architecture:** Extract the backfill into a testable static helper,
`RideMigrationPlan.thumbnailData(forTrack:rideID:decoder:encoder:)`, that resolves four outcomes:
two silent (empty blob, track too short to draw) and two loud (undecodable blob, unencodable
thumbnail). `didMigrate` shrinks to a single assignment. The logging subsystem, category, and
`privacy: .public` id interpolation copy `RideMapper`, the nearest precedent.

**Tech Stack:** Swift 6, SwiftData `SchemaMigrationPlan`, `os.Logger`, Swift Testing (`@Test`/
`#expect`/`#require`). Package: `AuraCore`.

**Spec:** [2026-07-28-roh104-migration-decode-diagnostics-design.md](../specs/2026-07-28-roh104-migration-decode-diagnostics-design.md)

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift` | Modify | Add `import os`, the `log` property, and the helper; simplify `didMigrate` |
| `AuraCore/Tests/AuraKitTests/RideMigrationThumbnailTests.swift` | Create | Cover the three non-asserting outcomes of the helper |

No new file in the app target, so **no `xcodegen generate` is needed**. The change is confined to
the `AuraCore` Swift package.

### Why the helper is `internal`, not `public`

Nothing outside `AuraKit` calls it. `@testable import AuraKit` reaches internal symbols, so tests
need no wider access. Do not mark it `public`.

### Why the test suite has no `.swiftDataSerialized` trait

That trait exists (`Support/SwiftDataSerialGate.swift:42-50`) for suites that build a
`ModelContainer` **or** materialize entity descriptions via `Schema(versionedSchema:)`. This suite
does neither — it calls one pure static function over `AuraCore` value types. Adding the trait
would serialize it against every other SwiftData suite for no reason.

---

## Task 1: Extract and diagnose the thumbnail backfill

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift:1-3` (imports), `:22-44` (`didMigrate`)
- Test: `AuraCore/Tests/AuraKitTests/RideMigrationThumbnailTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/RideMigrationThumbnailTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Covers `RideMigrationPlan.thumbnailData(forTrack:rideID:decoder:encoder:)`, the V1→V2
/// backfill helper, for the three outcomes that do **not** assert.
///
/// The two loud paths are deliberately absent. Both call `assertionFailure`, which traps in
/// DEBUG, and `swift test` builds DEBUG — a test that drove either would abort the suite rather
/// than fail an expectation. See the spec's Testing section for why no injection seam was added.
///
/// No `.swiftDataSerialized` trait: this suite builds no container and materializes no schema.
@Suite("V1→V2 thumbnail backfill")
struct RideMigrationThumbnailTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private func track(_ count: Int) -> [TrackPoint] {
        (0..<count).map {
            TrackPoint(coordinate: Coordinate(latitude: Double($0) * 0.001,
                                              longitude: Double($0) * 0.001),
                       elevation: nil,
                       timestamp: Date(timeIntervalSince1970: TimeInterval($0)))
        }
    }

    /// The load-bearing guarantee. `trackData`'s default is `Data()` — what CloudKit
    /// materializes for a record that never carried the key — and `JSONDecoder` throws on it.
    /// That is an empty ride, not corruption, so it must return nil **without** asserting.
    /// If this regresses, DEBUG builds trap at container-open on launch.
    @Test func emptyBlobIsAnEmptyRideNotCorruption() {
        #expect(RideMigrationPlan.thumbnailData(
            forTrack: Data(), rideID: UUID(), decoder: decoder, encoder: encoder) == nil)
    }

    /// The happy path: a real track round-trips to a decodable polyline of at least two points.
    @Test func trackWithEnoughPointsProducesADecodableThumbnail() throws {
        let data = try encoder.encode(track(200))
        let thumb = try #require(RideMigrationPlan.thumbnailData(
            forTrack: data, rideID: UUID(), decoder: decoder, encoder: encoder))
        let coords = try decoder.decode([Coordinate].self, from: thumb)
        #expect(coords.count >= 2)
    }

    /// A ride with fewer than two points has no polyline to draw. Silent, like the empty blob.
    /// This is the path `RideMigrationTests.swift:34`'s free-ride row already takes — it encodes
    /// `[TrackPoint]()` as the two bytes `[]`, which is non-empty and decodes to zero points.
    @Test(arguments: [0, 1]) func trackTooShortToDrawIsSilent(count: Int) throws {
        let data = try encoder.encode(track(count))
        #expect(RideMigrationPlan.thumbnailData(
            forTrack: data, rideID: UUID(), decoder: decoder, encoder: encoder) == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd AuraCore && swift test --no-parallel --filter RideMigrationThumbnailTests
```

Expected: **compile failure** — `type 'RideMigrationPlan' has no member 'thumbnailData'`. A
compile error is the correct "red" here; the helper does not exist yet.

- [ ] **Step 3: Add the import and the logger**

In `AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift`, add `import os` to the import
block (line 1-3), then add the logger as the first member of the enum, directly above `schemas`:

```swift
    private static let log = Logger(subsystem: "app.aura.kit", category: "persistence")
```

The subsystem and category match `RideMapper.swift:6` so migration diagnostics land in the same
stream as the rest of persistence.

- [ ] **Step 4: Add the helper**

Add to `RideMigrationPlan`, immediately after the `migrateV1toV2` declaration:

```swift
    /// The V1→V2 thumbnail backfill, extracted from `didMigrate` so its outcomes are testable
    /// without driving a migration.
    ///
    /// Returns nil for a ride that legitimately has no polyline to draw, and logs + asserts only
    /// on corruption. The distinction matters: `assertionFailure` here fires inside
    /// `ModelContainer.init`, on the launch path, so a false positive is a DEBUG crash at app
    /// start rather than a test failure.
    ///
    /// Neither loud path is covered by a test, because `assertionFailure` traps in DEBUG and
    /// `swift test` builds DEBUG — driving one would abort the suite. The sibling `statsData`
    /// assert above is untested for the same reason. This is a deliberate gap, not an oversight.
    static func thumbnailData(forTrack trackData: Data, rideID: UUID,
                              decoder: JSONDecoder, encoder: JSONEncoder) -> Data? {
        // An EMPTY blob is an empty ride, not a corrupt one: `trackData`'s default is `Data()`,
        // which is what CloudKit materializes for a record that never carried the key, and
        // JSONDecoder throws on it. Same distinction RideMapper draws (`RideMapper.swift:72-75`).
        guard !trackData.isEmpty else { return nil }

        guard let track = try? decoder.decode([TrackPoint].self, from: trackData) else {
            log.error("""
                Migration: trackData unreadable for ride \(rideID, privacy: .public) \
                (\(trackData.count) bytes); thumbnail dropped, History draws a blank card
                """)
            assertionFailure("Migration: failed to decode trackData for ride \(rideID)")
            return nil
        }

        // Fewer than two points is a ride too short to draw, not a failure.
        let thumb = TrackSimplifier.thumbnail(from: track.map(\.coordinate))
        guard thumb.count >= 2 else { return nil }

        do {
            return try encoder.encode(thumb)
        } catch {
            // Unreachable today: JSON carries no non-finite literal, so a coordinate that would
            // break the encoder fails the decode above instead, and TrackSimplifier only selects
            // existing coordinates by index. Diagnosed anyway, to catch a future edit that makes
            // it reachable — a changed encoder strategy, or a simplifier that interpolates.
            log.error("""
                Migration: thumbnail unencodable for ride \(rideID, privacy: .public) \
                (\(thumb.count) points); thumbnail dropped, History draws a blank card
                """)
            assertionFailure("Migration: failed to encode thumbnail for ride \(rideID): \(error)")
            return nil
        }
    }
```

- [ ] **Step 5: Simplify `didMigrate` to call the helper**

In `migrateV1toV2`'s `didMigrate`, replace these four lines (`RideMigrationPlan.swift:38-41`):

```swift
                if let track = try? decoder.decode([TrackPoint].self, from: record.trackData) {
                    let thumb = TrackSimplifier.thumbnail(from: track.map(\.coordinate))
                    record.thumbnailData = thumb.count >= 2 ? try? encoder.encode(thumb) : nil
                }
```

with:

```swift
                record.thumbnailData = thumbnailData(
                    forTrack: record.trackData, rideID: record.id,
                    decoder: decoder, encoder: encoder)
```

Note the behavioral tightening: the old code left `thumbnailData` **unassigned** when the decode
failed; the new code assigns nil explicitly. Same observable result — the V2 column is nil for a
freshly migrated row either way — but it no longer depends on that default.

- [ ] **Step 6: Run the new tests to verify they pass**

```bash
cd AuraCore && swift test --no-parallel --filter RideMigrationThumbnailTests
```

Expected: PASS, 4 tests (the parameterized case counts as two).

- [ ] **Step 7: Run the existing migration tests for regressions**

```bash
cd AuraCore && swift test --no-parallel --filter RideMigration
```

Expected: PASS. This picks up `RideMigrationTests` too. The free-ride row at
`RideMigrationTests.swift:34` must still yield `thumbnailData == nil` (asserted at `:86`) and must
**not** trap — if the suite aborts here, the empty-vs-short distinction was implemented wrong.

- [ ] **Step 8: Run the full package suite**

```bash
cd AuraCore && swift test --no-parallel
```

Expected: PASS, no aborts. `--no-parallel` matches CI (`.github/workflows/ci.yml`).

- [ ] **Step 9: Lint with the pinned SwiftLint**

```bash
swiftlint lint --strict
```

Expected: clean, zero violations. Must be the pinned 0.64.1 at `~/bin/swiftlint` — confirm with
`swiftlint version`. Homebrew's build has different rules and will disagree with CI. Watch line
length on the multi-line log strings; the `"""` blocks with trailing `\` keep each source line
short.

- [ ] **Step 10: Commit**

```bash
git add AuraCore/Sources/AuraKit/Persistence/RideMigrationPlan.swift \
        AuraCore/Tests/AuraKitTests/RideMigrationThumbnailTests.swift
git commit -m "fix(roh-104): diagnose the two swallowed failures in the V1 to V2 thumbnail backfill"
```

---

## Done criteria

- [ ] `swift test --no-parallel` passes for the whole package
- [ ] `swiftlint lint --strict` clean under pinned 0.64.1
- [ ] An empty `trackData` returns nil without asserting (covered by test)
- [ ] Both corrupt paths log through `app.aura.kit`/`persistence` **and** assert
- [ ] `RideMigrationTests` unchanged and still green
