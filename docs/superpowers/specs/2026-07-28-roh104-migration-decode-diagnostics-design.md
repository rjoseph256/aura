# Diagnose the two swallowed failures in `migrateV1toV2` (ROH-104) — design

Date: 2026-07-28
Issue: [ROH-104](https://linear.app/rohun/issue/ROH-104/ridemigrationplan-swallows-two-decode-failures-with-bare-try)
Status: revision 1.

## Problem

`RideMigrationPlan.migrateV1toV2`'s `didMigrate` backfills each V1 row's `thumbnailData` from
its `trackData`. Both halves of that backfill discard their errors
(`RideMigrationPlan.swift:38-41`):

```swift
if let track = try? decoder.decode([TrackPoint].self, from: record.trackData) {
    let thumb = TrackSimplifier.thumbnail(from: track.map(\.coordinate))
    record.thumbnailData = thumb.count >= 2 ? try? encoder.encode(thumb) : nil
}
```

A track that fails to decode falls out of the `if let` with `thumbnailData` left nil. A thumbnail
that fails to encode collapses to nil through the second `try?`. Neither path logs, asserts, or
records anything, in DEBUG or in release. The rider sees a History row with a blank map card;
nobody sees why.

The inconsistency is local and visible. The `statsData` branch ten lines up
(`RideMigrationPlan.swift:28-36`) handles the identical class of failure — a non-nil blob that
will not decode — and asserts on it, with a comment explaining that the silent version is
indistinguishable from a legitimately statless ride. The track branch makes the same mistake the
`statsData` branch was already fixed for.

*The issue text cites lines 37 and 39 and describes the `statsData` branch as "four lines above".
Both are stale: the file has shifted since filing, and the two branches are ten lines apart. The
substance is unchanged and confirmed against the current file.*

### The second `try?` is reachable, not theoretical

`TrackSimplifier.thumbnail(from:)` returns `[Coordinate]`, and `Coordinate` is two `Double`s
(`Coordinate.swift:3-5`). `JSONEncoder.nonConformingFloatEncodingStrategy` defaults to `.throw`,
so a NaN or infinite latitude or longitude anywhere in the simplified output makes
`encoder.encode(thumb)` throw. A V1 track carrying one corrupt point therefore produces a ride
with a decodable track, a plausible in-memory thumbnail, and a silently nil `thumbnailData`.

## Not part of the pause epic

`migrateV1toV2` operates on the frozen V2 record shape inside its own `didMigrate`. Nothing in
ROH-74 (Pause a ride) routes through this stage, which is why ROH-104 was filed separately after
revision 1 of the pause spec incorrectly bundled it into the persistence pass.

## Decision 1 — diagnose the way `RideMapper` does, not the way `statsData` does

The issue asks for parity with the `statsData` branch: bare `assertionFailure`, nothing else.
Taken literally that only half-fixes the complaint it opens with — "no diagnostic in either DEBUG
or release" — because `assertionFailure` compiles out of release builds entirely. A shipped build
would keep swallowing the failure exactly as it does today.

`RideMapper.segments(from:decoder:)` (`RideMapper.swift:64-79`) is the closer precedent. It is in
the same directory, handles the same class of failure, and does two things this fix should copy:

1. It logs through `Logger(subsystem: "app.aura.kit", category: "persistence")`
   (`RideMapper.swift:6`), interpolating the ride id with `privacy: .public`
   (`RideMapper.swift:67-70`) so the id survives redaction in a release log.
2. It separates an **empty** blob from a **corrupt** one.

**Decision:** log through the same subsystem and category, *and* assert. Release builds get a
diagnostic; DEBUG and CI stay loud. This is a deliberate superset of what the issue text asks
for, adopted because the issue's own stated goal requires it.

## Decision 2 — an empty `trackData` is an empty ride, not corruption

This is the part a literal reading of the issue would get wrong, and the reason the fix is not a
one-word edit.

`RideMapper` documents the trap directly (`RideMapper.swift:72-75`): `trackData`'s default is
`Data()`, which is what CloudKit materializes for a record that never carried the key, and
`JSONDecoder` throws on empty input. So "decode failed" and "the ride has no track" are the same
observable event at this call site. Asserting on every decode failure would fire
`assertionFailure` at container-open for a legitimately empty ride — a DEBUG crash on launch,
caused by the fix rather than by any corruption.

**Decision:** branch on `trackData.isEmpty` first and treat that case as an empty ride —
`thumbnailData` nil, no log, no assert. Only a *non-empty* blob that fails to decode is
corruption.

Three states, where the current code has two:

| `trackData` | Meaning | Behavior |
|---|---|---|
| empty `Data()` | ride with no track | `thumbnailData = nil`, silent |
| non-empty, will not decode | corruption | `log.error` + `assertionFailure` |
| decodes, thumbnail will not encode | corruption (non-finite coordinate) | `log.error` + `assertionFailure` |

## Decision 3 — extract a helper rather than nest inside the migration loop

Writing all three states inline puts three levels of branching inside a `for` loop inside a
closure. Instead, `didMigrate` calls one function:

```swift
static func thumbnailData(forTrack trackData: Data, rideID: UUID,
                          decoder: JSONDecoder, encoder: JSONEncoder) -> Data?
```

`didMigrate`'s body keeps the shape it has now — one statement per backfilled column — and the
new logic is reachable from tests without constructing a migration.

Non-goal: the helper is not made `public`. It is `internal` (`@testable` reaches it) because
nothing outside `AuraKit` has any reason to call it.

## Testing

**What is covered.** Two behaviors that are new assertions about how this code works, both
exercised directly against the helper:

- An empty `Data()` returns nil **without** tripping the assert. This is the Decision 2
  guarantee, and it is the one a future edit is most likely to regress.
- A well-formed track with enough points returns bytes that decode back to `[Coordinate]` with
  `count >= 2`; a well-formed track that simplifies below two points returns nil.

**What cannot be covered, and why.** The two corrupt paths call `assertionFailure`, which traps
in DEBUG. `swift test` builds DEBUG, so a test that drove either path would abort the suite
rather than fail an expectation. There is no way to assert on them without adding an injection
seam.

**Rejected: adding that seam.** A settable diagnostic hook, or routing the assert through a
closure a test could swap, would make both paths testable. It is rejected under YAGNI: it adds
production surface whose only consumer is a test, for a Low-priority bug, and the repository does
this nowhere else — the sibling `statsData` assert (`RideMigrationPlan.swift:35`) is untested for
exactly this reason. The gap is documented in-code instead so the next reader does not mistake it
for an oversight.

**Regression risk: none identified.** `RideMigrationTests.swift:34` writes the empty-track row as
`try encode([TrackPoint]())`, which is the two bytes `[]` — non-empty, and it decodes cleanly to
zero points. It therefore takes the "decodes, simplifies below two points" path and still yields
nil, as `RideMigrationTests.swift:86` asserts. The existing migration test is unaffected.

## Scope

In scope: `RideMigrationPlan.swift` (the logger, the helper, the two diagnosed paths) and new
unit tests.

Out of scope: the `statsData` branch's missing release-log (it asserts, which is what its own
review asked for; widening it is a separate call), `RideMapper`'s pre-existing `try?` on
`thumbnailData` (`RideMapper.swift:86-88`), which is deliberate per the D3 note at
`RideMapper.swift:10-15`, and the V6 backfill path, which is `RideSegmentBackfiller`'s job.

## Gates

`cd AuraCore && swift test --no-parallel`, and `swiftlint lint --strict` with the pinned 0.64.1
build. No `xcodegen` run is required: the change is confined to the `AuraCore` package and adds
no file to the app target.
