# Route-planning elevation gate (ROH-94) — design

Status: approved by Rohun 2026-07-22 (approach A of A/B/C)
Issue: [ROH-94](https://linear.app/rohun/issue/ROH-94/route-planning-elevation-gate-terrain-rgb-regression-class)
Predecessors: ROH-92 golden-ride harness (PR #83), ROH-93 navigate golden ride (PR #84)

## Problem

The golden-ride harness gates the recording/stats/persist elevation path
(`RideStatsCalculator`) and both HUDs' finish flows. The regression class that
motivated it is still open on the route-planning side: if
`MapboxTerrainRGBElevationProvider` silently returns flat or empty elevation,
`RouteMetrics.elevationGain` is 0 for every candidate, the "Flattest" label is
assigned arbitrarily, and no test fails. Both harness specs carry this as their
honest "not caught" row.

Everything at risk lives in the app target
([Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift](../../../Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift)),
which has no unit-test bundle. The downstream pieces (`ElevationSampling`,
`RouteMetrics.elevationGain`, `RouteRanker`) are in the AuraCore package and
already unit-tested. The untested code is: Web Mercator tile/pixel placement,
the PNG-to-RGBA8 decode, the RGB-to-meters formula, and the end-to-end wiring
from samples through gain to ranking.

Two facts make a package-level gate practical:

1. The AuraCore package declares `.iOS(.v17), .macOS(.v14)`, and both
   CoreGraphics and ImageIO exist on macOS. A real PNG decode over a canned
   terrain-rgb tile runs on the macOS CI host with no `#if os` guards.
2. The decode/placement code has no dependency on MapboxMaps or URLSession
   beyond the fetch itself. It is structurally pure and can move.

## Decision

Extract the pure Terrain-RGB core into AuraCore and gate it there with a
committed real tile fixture, plus an end-to-end ranking gate over fixture
routes. The app provider keeps only the network fetch and the actor cache.
Only URLSession stays ungated, which is the part that should stay out of CI.

Alternatives rejected:

- Seam-level fake only (no extraction): never exercises the decoder, which is
  where the original regression lived; it would mostly re-test `RouteRanker`
  and `RouteMetrics`, which are already covered.
- App-target unit-test bundle with URLProtocol-stubbed tiles: highest
  fidelity (covers the actor cache in place) but new CI infrastructure, an
  app build per test run, and the issue asked for a package-level shape.

## 1. Extraction

New file `AuraCore/Sources/AuraCore/Routing/TerrainRGBTile.swift`:

- `TerrainRGBTile` — value type holding a decoded RGBA8 buffer and side
  length (256).
  - `init?(pngData: Data)` — the ImageIO/CoreGraphics decode moved verbatim
    from `TerrainTileCache.fetchDecoded` (CGImageSource → CGContext render
    into a known RGBA8 layout), minus URLSession. Returns `nil` on any decode
    failure; it never fabricates a flat tile.
  - `elevation(px:py:)` — the `-10000 + (r*65536 + g*256 + b) * 0.1` formula
    moved from `TerrainTileCache.elevation`, with the same bounds guard.
- `TerrainRGBPlacement` — namespace for the Web Mercator math.
  - `placement(lat:lon:z:) -> Placement` (the `tileX/tileY/px/py` struct)
    moved verbatim from `MapboxTerrainRGBElevationProvider.placement`,
    with the `Placement` struct moving alongside it.

App-side refactor (behavior preserving, no caller outside the provider
changes):

- `MapboxTerrainRGBElevationProvider.placement` delegates to
  `TerrainRGBPlacement`.
- `TerrainTileCache` stores `TerrainRGBTile?` per key instead of a raw byte
  buffer. `warm` fetches `Data` over URLSession, then constructs
  `TerrainRGBTile(pngData:)`. `elevation` delegates to the tile value.
- Public API of the provider, its defaults (spacing 150 m, samples 16–96,
  zoom 14), and its best-effort error behavior are unchanged.

## 2. Fixture

One real `mapbox.terrain-rgb` z14 tile covering hilly Pittsburgh, chosen so a
single tile contains both strong relief (South Side slopes) and the flat
Monongahela riverbank. Downloaded once during implementation with the
gitignored token, then committed as
`AuraCore/Tests/AuraCoreTests/Resources/terrain-rgb-fixture.pngraw`
(expected ~15–60 KB). The test file records the tile's z/x/y and fetch date
in a comment. `Package.swift` adds a `resources:` clause to `AuraCoreTests`.

Frozen-literal policy applies: expected elevations and gains are recorded
once from a verified run and pasted as literals. Tests never recompute truth
values at run time. If the fixture is ever re-recorded, all literals are
re-recorded with it in the same commit.

## 3. Decoder gate — `TerrainRGBTileTests`

Swift Testing suite in `AuraCoreTests`:

- Decode the fixture tile; `#require` it is non-nil.
- Frozen-literal elevations at ~4 chosen pixels, `±0.5 m` tolerance. Pixels
  are chosen during implementation to span the tile's relief (riverbank low,
  hillside high).
- Non-flat assertion: max − min elevation across the full tile exceeds 50 m.
  Pittsburgh relief inside this tile is well above that, so the threshold
  only fires when the decode goes flat.
- Garbage input (random bytes, truncated PNG, empty data) → `init?` returns
  `nil`. A silent all-zero tile is the regression we are gating, so failure
  must be `nil`, never a flat buffer.
- `TerrainRGBPlacement` frozen-literal checks: known lat/lon (Pittsburgh
  landmarks) → expected tile x/y and pixel, at z14.

## 4. Ranking gate — `RoutePlanningElevationGateTests`

Swift Testing suite in `AuraCoreTests`, exercising the same path production
takes from geometry to label, with the network swapped for the fixture:

- `FixtureTileElevationProvider: ElevationProvider` (test-local): holds the
  decoded fixture tile; `elevations(along:)` uses
  `ElevationSampling.proportionalCount` + `sampleIndices` +
  `TerrainRGBPlacement` + `TerrainRGBTile.elevation`, mirroring the
  production provider's read path. Coordinates outside the fixture tile drop
  the sample, mirroring best-effort behavior.
- Three hand-authored polylines inside the tile bounds: one along the flat
  riverbank, two crossing the slopes with visibly different climb.
- Assertions:
  - Every route's elevations are non-empty.
  - Gains (`RouteMetrics.elevationGain`) are not all zero and not all equal.
  - Frozen-literal expected gain per route with a ±15% relative tolerance
    (sampling is deterministic, so this is generous headroom for future
    intentional sampling tweaks without being loose enough to pass flat).
  - `RouteRanker.labeled` over the three candidates assigns "Flattest" to
    the riverbank route.

The not-all-zero plus label assertion is the line that fails if the decoder
ever silently goes flat again.

## 5. Error handling and CI

- No network access in any test; the fixture is the only tile source.
- No `#if os` guards needed: CoreGraphics and ImageIO are available on both
  declared platforms. (`corelocation-macos-ci-guards` does not bite here.)
- The existing `swift test` CI job picks up both new suites with no workflow
  changes. The app-build CI job proves the refactored provider compiles
  against the extracted core.
- SwiftLint must stay clean (`swiftlint --strict`).

## 6. Testing the change itself

- Regression drill before merge: temporarily break the decode (e.g. zero the
  formula's multiplier) and confirm both the decoder gate and the ranking
  gate fail; revert and quote the drill output in the PR.
- Both harness specs' "not caught — ROH-94" rows get updated to point at
  this gate, and the ROADMAP testing section notes the new coverage.

## 7. Out of scope

- No app-target unit-test bundle, no URLProtocol stubbing.
- No change to provider behavior, ranking semantics, tile zoom, or sampling
  defaults.
- No gating of the URLSession fetch path or the actor cache's concurrency
  (covered indirectly by app build + device use).
