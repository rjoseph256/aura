# Aura Wave 1 — Persistence: design

**Goal:** Rebuild the SwiftData ride store so the History list and dashboard read
a lightweight summary instead of decoding every ride's full GPS track, make the
schema CloudKit-ready, and put the model behind a versioned schema with a tested
migration so future changes cannot silently lose recorded rides.

## Context

`RideRecord` is the app's only persisted model. Three things about it block the
next features and waste work today:

1. `@Attribute(.unique)` on `id` is incompatible with CloudKit sync. The ROADMAP
   parks sync in a later wave, but the schema has to stop using uniqueness before
   that work can start.
2. The full GPS track is a JSON `Data` blob stored inline in the row, with no
   `@Attribute(.externalStorage)`. `allRides()` decodes it for every row, so the
   History list reads roughly a megabyte per multi-hour ride just to show a date
   and a distance.
3. There is no `VersionedSchema` and no migration plan, so the first non-additive
   change risks dropping rows.

This sub-project is a behavior-preserving rebuild of the storage layer plus the
read path that sits on it. The screens look and act the same; what changes is how
they get their data and how the schema evolves. Scope is persistence only.
Navigation, the next Wave 1 item, is not touched.

## Decisions settled during brainstorming

- **Thumbnails stay, backed by a stored simplified polyline.** The History row and
  the dashboard's last-ride card both draw a route thumbnail from the full track
  today. Rather than lose them or decode tracks lazily, a compact simplified
  polyline is denormalized into its own column, so the list draws thumbnails from
  a few hundred bytes and never loads the track.
- **`statsData` stays canonical; the summary numbers are denormalized columns.**
  This is the ROADMAP's literal intent. The encoded `RideStats?` blob is left
  untouched (it carries the nil-stats case for free rides cleanly and keeps the
  migration's test surface small), and `distanceMeters`, `movingTimeSeconds`, and
  `elevationGainMeters` are added as columns the fast read path uses. The
  redundancy is safe because rides are immutable after they are saved.

## Schema

Two namespaced `@Model` types behind a `SchemaMigrationPlan`, in
`AuraCore/Sources/AuraKit/Persistence/`.

`enum RideSchemaV1: VersionedSchema` is a frozen copy of the model as it ships
today: `@Attribute(.unique) id`, inline `trackData`, `statsData`,
`destinationName`, `routeId`, `destinationPlaceId`. It exists so the migration has
a real "from" type and the round-trip test can write old-shaped rows.

`enum RideSchemaV2: VersionedSchema` is the new shape:

| Field | V1 | V2 |
| --- | --- | --- |
| `id: UUID` | `@Attribute(.unique)` | no attribute (sync-ready) |
| `trackData: Data` | inline | `@Attribute(.externalStorage)` |
| `statsData: Data?` | inline | unchanged (canonical `RideStats?`) |
| `distanceMeters: Double` | — | new, default `0` |
| `movingTimeSeconds: Double` | — | new, default `0` |
| `elevationGainMeters: Double` | — | new, default `0` |
| `thumbnailData: Data?` | — | new, JSON `[Coordinate]`, `nil` when < 2 points |
| `kindRaw`, `startedAt`, `endedAt`, `destinationName`, `routeId`, `destinationPlaceId` | present | unchanged |

`typealias RideRecord = RideSchemaV2.RideRecord` keeps the rest of `AuraKit`
referring to `RideRecord`.

## Migration

`enum RideMigrationPlan: SchemaMigrationPlan` with one custom stage, V1 to V2. It
has to be custom rather than lightweight because the new columns are computed from
existing data, which lightweight migration cannot do.

`didMigrate` fetches every V2 record and backfills each one:

- decode `statsData`, set the three stat columns (`0` when stats is `nil`),
- decode `trackData` once, run it through the simplifier, set `thumbnailData`.

Migration is the only place that decodes a track, and it runs once per store
upgrade. This is deliberate: the steady-state read path never faults the external
blob, and the migration pays that cost a single time so every later summary fetch
does not have to.

The on-disk container is the only one that migrates. A new factory
`RideStore.persistent()` in `AuraKit` builds
`ModelContainer(for: RideRecord.self, migrationPlan: RideMigrationPlan.self)` so
the app and the migration test share one wiring path. `inMemory()` stays on the V2
schema with no plan.

## Read path

`RideSummary` is a new pure value type in `AuraCore/Sources/AuraCore/Models/`,
holding only cheap columns:

```swift
public struct RideSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: Ride.Kind
    public let startedAt: Date
    public let endedAt: Date?
    public let distanceMeters: Double
    public let movingTimeSeconds: Double
    public let elevationGainMeters: Double
    public let destinationName: String?
    public let thumbnailCoordinates: [Coordinate]   // simplified; empty when none
}
```

`thumbnailCoordinates` is the in-memory end of the storage round-trip: a `nil`
`thumbnailData` column (a track with fewer than 2 points) maps to an empty array
here, and a present column decodes to its points. The views treat an empty array
as "no thumbnail, show the kind badge."

The type also carries a cheap `hasStats: Bool`, set from `statsData != nil` without
decoding the blob. The denormalized stat columns are non-optional and default to
`0`, so a statless ride (a free ride saved without computed stats) is otherwise
indistinguishable from a real zero. `hasStats` lets the dashboard's last-ride card
keep showing "—" for a statless ride, preserving today's behavior.

`RideStore` gains two methods and keeps the rest:

- `summaries() throws -> [RideSummary]` fetches records newest-first and maps each
  from columns only. It never reads `trackData`, so the external blob never faults.
- `ride(id:) throws -> Ride?` does the full decode (track and stats) for a single
  ride, used when a row is tapped.
- `save()` now also writes the three stat columns and `thumbnailData` through the
  mapper. `allRides()`, `delete(id:)`, and `inMemory()` are unchanged.

`TrackSimplifier` is a new pure function in `AuraCore`:
`thumbnail(from: [Coordinate], maxPoints: Int = 60) -> [Coordinate]`. At or below
the cap it returns the input. Above it, it keeps the first and last points and
evenly strides the rest. Deterministic, so it is easy to test. Used at save time
and in the migration backfill.

`RideMapper` gains `summary(from: RideRecord) -> RideSummary`. `record(from: Ride)`
now also computes the stat columns and `thumbnailData`. `ride(from:)` is unchanged.

`RideAggregator` switches its input from `[Ride]` to `[RideSummary]`. It only ever
reads `startedAt` and the three stat fields, so the rollup is identical. Nil-stats
rides carry `0` in the columns, so they still count toward `rideCount` and add no
distance, matching today's behavior. `weekToDate` takes `[RideSummary]` and
`mostRecent` returns `RideSummary?`, which is what feeds the dashboard's last-ride
card.

## App wiring

All of this is behavior-preserving at the screen level.

- `HistoryView`: list state becomes `[RideSummary]` from `store.summaries()`.
  `RideRow` reads summary fields and draws its thumbnail from
  `thumbnailCoordinates`, falling back to the kind badge when it is empty. The
  selection state stays typed `Ride?`: tapping a row sets
  `selected = try? store.ride(id:)`, and the sheet shows `RideSummaryView(ride:)`
  exactly as before (it still needs a full `Ride` for its large map).
- `PlanView` and `LastRideCard`: the weekly ring and last-ride card read summaries.
  `LastRideCard`'s parameter changes from `Ride` to `RideSummary`, and its
  thumbnail, stats line, title, and relative date all read the equivalent
  `RideSummary` fields instead of `Ride`/`ride.stats`.
- `AuraApp.makeRideStore()`: calls `RideStore.persistent()`, which wires the
  migration plan internally. The in-memory fallback is unchanged.

## Behavior preservation

| Behavior | Before | After |
| --- | --- | --- |
| History list contents and order | full `Ride` decode, newest first | `RideSummary`, newest first |
| History row thumbnail | drawn from full track | drawn from stored simplified polyline |
| Open a ride from History | passes the in-memory `Ride` | fetches full `Ride` by `id` |
| Dashboard weekly ring and last-ride card | full `Ride` decode | summaries; thumbnail from polyline |
| Weekly rollup math, nil-stats handling | `[Ride]`, reads optional stats | `[RideSummary]`, reads `0`-default columns |
| In-memory fallback when disk fails | `inMemory()`, ephemeral banner | unchanged |
| Saving a finished ride | encodes track and stats | also writes stat columns and thumbnail |

## Testing

Swift Testing for the new suites, matching the coordinator precedent. Existing
XCTest suites are updated in place.

- **Round-trip migration test (the headline).** Build an on-disk store on
  `RideSchemaV1`, insert a navigate ride with a multi-point track and stats and a
  free ride with `nil` stats and an empty track, then close it. Reopen the same
  file through `RideMigrationPlan` on V2 and assert: same count, `id`s preserved,
  the full track decodes intact, the three stat columns match the old `statsData`,
  and `thumbnailData` is populated for the ride that had a track and `nil` for the
  empty one.
- `TrackSimplifier`: passthrough at or below the cap, point count and endpoint
  preservation above it, and the degenerate 0 and 1 point cases.
- `RideMapper.summary(from:)`: columns map through without decoding the track.
- `RideStore.summaries()` and `ride(id:)`: summaries are newest-first and
  track-free; `ride(id:)` returns the full track.
- `RideAggregator` tests rebuilt on `[RideSummary]`; `RideStoreTests` and
  `RideMapperTests` updated for the new columns.

The whole package (125 tests today) stays green, plus the new cases.

## Risks

- Toggling `trackData` to `.externalStorage` and dropping `.unique` across a schema
  boundary is the kind of change that can fail to move data or drop rows. The
  round-trip migration test is the guard, and it asserts track bytes and row count
  directly rather than trusting the migration ran.
- Migration runs at container open in `RideStore.persistent()`. If it throws, the
  app falls back to the in-memory store and shows the existing ephemeral banner, so
  a failed upgrade degrades to "rides are not saved" rather than a crash.

## Out of scope

- CloudKit sync wiring (the schema becomes sync-ready; turning sync on is a later
  wave).
- Navigation (the next Wave 1 sub-project).
- Any edit-ride feature.
- Douglas-Peucker or other shape-aware simplification. Uniform downsampling is
  enough for a 54x42 thumbnail.

## Rough task order

1. `TrackSimplifier` and its tests.
2. `RideSummary` value type.
3. `RideSchemaV1` (frozen) and `RideSchemaV2` models, with `RideRecord` typealias.
4. `RideMapper` updates (`record(from:)` writes new columns, new `summary(from:)`).
5. `RideMigrationPlan` and `RideStore.persistent()`; the round-trip migration test.
6. `RideStore.summaries()` and `ride(id:)`; store tests.
7. `RideAggregator` switch to `[RideSummary]`; aggregator tests.
8. App wiring: `HistoryView`, `PlanView`, `LastRideCard`, `AuraApp`.
