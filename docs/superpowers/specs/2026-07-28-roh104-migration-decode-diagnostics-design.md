# Diagnose the two swallowed failures in `migrateV1toV2` (ROH-104) — design

Date: 2026-07-28
Issue: [ROH-104](https://linear.app/rohun/issue/ROH-104/ridemigrationplan-swallows-two-decode-failures-with-bare-try)
Status: revision 2, after a spec review that verified every cited line against the source.

Revision 1 made one substantive error and one omission. It asserted the second `try?` was
reachable through a non-finite coordinate; it is not, and the corrected reasoning is kept inline
rather than deleted because it changes what that diagnosed path is *for*. It also gave a
three-row state table that omitted the "simplifies below two points" case — the one the existing
migration test actually exercises — which a planner could have folded into the corrupt row and
aborted the suite. Both are marked below.

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

### The second `try?` is unreachable today, and is diagnosed defensively

*Revision 1 claimed this path was reachable via a non-finite coordinate. That was wrong, and the
correction is recorded here rather than deleted because it changes what the second diagnosed path
is for.*

The argument was: `TrackSimplifier.thumbnail(from:)` returns `[Coordinate]`, `Coordinate` is two
`Double`s (`Coordinate.swift:3-5`), and `JSONEncoder.nonConformingFloatEncodingStrategy` defaults
to `.throw` — so a NaN latitude would make `encoder.encode(thumb)` throw. The last step holds; a
NaN cannot get there. Two independent reasons:

1. **JSON cannot carry one.** The format has no `NaN` or `Infinity` literal, and `JSONDecoder`
   rejects out-of-range magnitudes. Decoding `{"latitude":1e400,…}`, `…:NaN`, and `…:Infinity`
   each throw `DecodingError` — verified empirically, not reasoned about. So a blob that would
   produce a non-finite coordinate fails at the **decode**, which is the *first* diagnosed path.
2. **The simplifier cannot synthesize one.** `TrackSimplifier.thumbnail` only selects existing
   elements by index (`TrackSimplifier.swift:13`); its arithmetic is entirely on indices, never
   on latitude or longitude.

A successfully decoded `[TrackPoint]` therefore provably cannot yield a `thumb` that fails to
encode. The corruption the original argument described is real, but it is caught one path
earlier.

**The path is still diagnosed**, for the same reason it is still written with error handling
rather than `try!`: an unreachable-by-construction failure that becomes reachable later — a
changed encoder strategy, a `Coordinate` that grows a computed field, a simplifier that starts
interpolating midpoints — should surface as a log line and a trapped assert, not as a blank
History card. It is diagnosed as a guard against future edits, not against current data.

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

Four states, where the current code distinguishes two. Two are silent and two are loud, and the
split does not fall where a quick read suggests:

| `trackData` | Meaning | Behavior |
|---|---|---|
| empty `Data()` | ride with no track | `thumbnailData = nil`, **silent** |
| decodes, simplifies to fewer than 2 points | ride too short to draw | `thumbnailData = nil`, **silent** |
| non-empty, will not decode | corruption | `log.error` + `assertionFailure` |
| decodes, thumbnail will not encode | unreachable today (see above); guards future edits | `log.error` + `assertionFailure` |

The second row is easy to lose, and losing it is the expensive mistake. It is not an error
condition — `thumb.count >= 2` is the existing guard at `RideMigrationPlan.swift:40`, and a ride
with zero or one recorded point legitimately has no polyline to draw. Folding it into row 3 would
trap in DEBUG on the `freeId` row of `RideMigrationTests.swift:34` and abort the suite. It stays
silent, exactly as today.

## Decision 3 — extract a helper rather than nest inside the migration loop

Writing all three states inline puts three levels of branching inside a `for` loop inside a
closure. Instead, `didMigrate` calls one function:

```swift
static func thumbnailData(forTrack trackData: Data, rideID: UUID,
                          decoder: JSONDecoder, encoder: JSONEncoder) -> Data?
```

The caller passes `record.trackData` and `record.id` from the loop it already runs; the helper
takes the two values rather than the `RideSchemaV2.RideRecord` so it can be tested without
materializing a model.

`didMigrate`'s body keeps the shape it has now — one statement per backfilled column — and the
new logic is reachable from tests without constructing a migration.

**Log contents.** Both messages carry the ride id with `privacy: .public` and the blob's byte
count, matching what `RideMapper.swift:67-70` records — the size is what makes a triage log
actionable, since it separates "a few bytes of garbage" from "a truncated 300 KB track". Each
message also names the consequence, as the `statsData` assert does: the thumbnail is dropped and
History draws a blank card for that ride.

Non-goal: the helper is not made `public`. It is `internal` (`@testable` reaches it) because
nothing outside `AuraKit` has any reason to call it.

## Testing

**What is covered.** Three behaviors that are new assertions about how this code works, all
exercised directly against the helper:

- An empty `Data()` returns nil **without** tripping the assert. This is the Decision 2
  guarantee, and it is the one a future edit is most likely to regress.
- A well-formed track with enough points returns bytes that decode back to `[Coordinate]` with
  `count >= 2`.
- A well-formed track that simplifies below two points returns nil **without** tripping the
  assert — row 2 of the state table, and the path `RideMigrationTests.swift:34` already depends
  on.

**What cannot be covered, and why.** Both loud paths call `assertionFailure`, which traps in
DEBUG. `swift test` builds DEBUG, so a test that drove either would abort the suite rather than
fail an expectation. Of the two, only the undecodable-blob path is reachable at all — the encode
path is unreachable by construction (see above), so there is no input that could drive it even if
the assert were removed — no seam would help there, because the problem is that the state cannot
be reached, not that the assert traps. For the undecodable-blob path a seam would work, and is
rejected below.

**Rejected: adding that seam.** A settable diagnostic hook, or routing the assert through a
closure a test could swap, would make the undecodable-blob path testable. It is rejected under YAGNI: it adds
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
`RideMapper.swift:10-15`, and the V6 backfill path, which is `RideSegmentBackfill`'s job
(`RideSegmentBackfill.swift:50` — three doc comments elsewhere call it `RideSegmentBackfiller`,
which is not a type that exists; noted, and left alone as unrelated).

## Gates

`cd AuraCore && swift test --no-parallel`, and `swiftlint lint --strict` with the pinned 0.64.1
build. No `xcodegen` run is required: the change is confined to the `AuraCore` package and adds
no file to the app target.
