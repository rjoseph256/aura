# Route-planning elevation gate (ROH-94) — design

Status: approved design 2026-07-22 (approach A of A/B/C); revised after
3-reviewer adversarial spec review (efficacy / architecture / test-design)
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
the PNG-to-RGBA8 decode, the RGB-to-meters formula, and the provider's own
sampling orchestration (placement → tile fetch → ordered read → drop-on-miss)
that wires samples through gain to ranking.

Two facts make a package-level gate practical:

1. The AuraCore package declares `.iOS(.v17), .macOS(.v14)`, and both
   CoreGraphics and ImageIO exist on macOS. A real PNG decode runs on the
   macOS CI host with no `#if os` guards.
2. The decode/placement/orchestration code has no dependency on MapboxMaps or
   URLSession beyond the fetch itself. It is structurally pure and can move.

## Decision

Extract the pure Terrain-RGB core — placement math, tile decode, and the
sampling orchestration — into the package and gate it there with a committed
**generated** terrain-rgb fixture tile, plus an end-to-end ranking gate over
fixture routes. The app provider keeps only the token guard, the URLSession
fetch, and the actor cache, all delegating to the extracted core.

Layering (the package's convention is deliberate and this design follows it):

- `AuraCore` target is Foundation-only today. Only the pure Web Mercator
  placement math goes there, beside `ElevationSampling`.
- `AuraKit` already hosts all Apple-framework code (CoreGraphics in
  `Plotting`, resources, `Bundle.module` precedent) and `RouteMetrics`. The
  CG/ImageIO tile decode and the sampler go there.
- Both test suites live in `AuraKitTests`, which can import `AuraKit` and
  (transitively) `AuraCore`. Placement-math frozen-literal checks live in
  `AuraCoreTests` beside `ElevationSamplingTests`.

Alternatives rejected:

- Seam-level fake only (no extraction): never exercises the decoder, which is
  where the original regression lived.
- App-target unit-test bundle with URLProtocol-stubbed tiles: highest
  fidelity (covers the actor cache in place) but new CI infrastructure and an
  app build per test run; the issue asked for a package-level shape.
- A test-local provider that *mirrors* the production sampling pipeline
  (first draft of this spec): review showed a mirror cannot catch drift in
  production's own orchestration (transposed px/py, out-of-order appends,
  changed drop behavior). Hence the sampler extraction below — production
  and test must execute the same code, differing only in tile source.
- Committing a real Mapbox terrain-rgb tile: this repo is public, and
  Mapbox's terms do not allow persistent redistribution of tile content.
  A generated fixture also makes truth literals exactly derivable and
  re-recording tokenless. See §2 for the residual-fidelity mitigation.

## 1. Extraction

### AuraCore (Foundation-only)

`AuraCore/Sources/AuraCore/Routing/TerrainRGBPlacement.swift`:

- `TerrainTileID: Hashable, Sendable` — `z/x/y` (public; replaces the
  app-private `TileKey`).
- `TerrainRGBPlacement.placement(lat:lon:z:) -> Placement` — the Web
  Mercator math moved from the app provider, with the `Placement` struct
  (`tileX/tileY/px/py`) moved alongside and made public.

### AuraKit (CG/ImageIO allowed)

`AuraCore/Sources/AuraKit/Routing/TerrainRGBTile.swift`:

- `TerrainRGBTile: Sendable` (explicit conformance — public structs get no
  implicit `Sendable` synthesis) holding a decoded RGBA8 buffer and side
  length.
  - `init?(pngData: Data)` — the ImageIO/CoreGraphics decode moved from
    `TerrainTileCache.fetchDecoded`, **hardened**, not verbatim:
    - fails (`nil`) unless the source image is exactly `side × side`
      (256×256) — `ctx.draw` would otherwise silently rescale a wrong-size
      tile into plausible garbage;
    - fails unless both `CGImageSourceGetStatus` and
      `CGImageSourceGetStatusAtIndex(_, 0)` are `.statusComplete` (the
      source-level status can be complete for truncated in-memory data; these
      status checks are kept as cheap guards but empirically do not catch
      prefix-truncated in-memory PNGs, so the decode additionally rejects any
      tile whose drawn buffer is entirely zero—all-pixels −10000 m—which is
      what actually catches partial decodes) — this prevents ImageIO's ability
      to render a partial image with undrawn all-zero rows (elevation −10000 m),
      which is exactly the flat fabrication this gate forbids;
    - the render must be color-conversion-free: draw into the source image's
      own colorspace (fall back to sRGB only for untagged input) so DEM byte
      values are never color-matched (a ±1 shift in R is ±6553.6 m);
    - buffer access is made pointer-safe (`withUnsafeMutableBytes` around
      context creation + draw) instead of the current escaping `&buf`.
  - `elevation(px:py:)` — the `-10000 + (r*65536 + g*256 + b) * 0.1` formula,
    with the bounds guard tightened to `(0..<side).contains(px/py)` (the old
    `off + 2 < count` guard accepts out-of-range px and reads the wrong row).
- The app-side comments about default MainActor isolation do not apply in
  the package (no default-isolation setting there); comments are rewritten
  for the package's concurrency world, not copied.

`AuraCore/Sources/AuraKit/Routing/TerrainRGBSampler.swift`:

- `TerrainRGBSampler.elevations(along:zoom:spacingMeters:minSamples:maxSamples:tile:) async -> [Double]`
  — the provider's orchestration moved verbatim in behavior: proportional
  count → sample indices → placements → dedupe unique tile IDs → fetch each
  unique tile once concurrently via the injected
  `tile: @Sendable (TerrainTileID) async -> TerrainRGBTile?` lookup → read
  samples **in order**, dropping any sample whose tile or pixel is
  unavailable. This is the single copy of the pipeline; production and tests
  both call it.

### App target (thin shell)

`MapboxTerrainRGBElevationProvider` keeps: the empty-token early return, its
defaults (spacing 150 m, samples 16–96, zoom 14), and a call into
`TerrainRGBSampler` with a `TerrainTileCache`-backed lookup. `TerrainTileCache`
keeps URLSession fetch + `TerrainRGBTile(pngData:)` and **must preserve the
double-optional negative-result caching** (`[TerrainTileID: TerrainRGBTile?]`
with `guard tiles[key] == nil`) so failed tiles are not re-fetched. Public API
and behavior of the provider are unchanged; `import MapboxMaps` stays (token
read); the app already links AuraKit, so no project change.

## 2. Fixture

A **generated** terrain-rgb PNG, committed as
`AuraCore/Tests/AuraKitTests/Resources/terrain-rgb-fixture.png` with a
`.copy` resources clause (byte-exactness guaranteed; `AuraKitTests` gains its
first `resources:` entry). Nothing Mapbox-owned enters the repo.

- The DEM is a deterministic analytic surface defined in the record helper:
  a flat low "riverbank" band (constant elevation) plus asymmetric hillsides
  with total relief well above 50 m, designed so chosen check-pixels are
  transpose-distinct (`elevation(px,py) ≠ elevation(py,px)`) — a row/column
  transposition in the offset math cannot slip through.
- The tile is assigned the real z14 x/y of a Pittsburgh South Side tile, so
  fixture routes use realistic lat/lon and the placement math is exercised
  with real-world numbers.
- Record mechanism follows the ROH-92 convention: a
  `TERRAIN_FIXTURE_RECORD=1`-gated test in `AuraKitTests` regenerates the
  PNG (raw RGB bytes via CGImageDestination — a different code path than the
  CGContext-render decode, so encode and decode bugs do not cancel) and
  prints paste-ready truth literals derived **from the DEM function**, not
  from the decoder under test.
- Frozen-literal policy applies: literals are recorded once and pasted; any
  intentional change to fixture, sampling, or formula re-records fixture and
  all literals in the same commit.
- Residual-fidelity mitigation: at record time, a one-off manual cross-check
  decodes one live Mapbox tile (token from the gitignored file, nothing
  committed) and compares a few pixels against Mapbox's public formula;
  the result is quoted in the PR. This validates the decoder against the
  real encoder without redistributing Mapbox data.

## 3. Decoder gate — `TerrainRGBTileTests` (AuraKitTests)

- Decode the fixture; `#require` non-nil.
- Frozen-literal elevations at 4 transpose-distinct pixels, ±0.5 m (the
  format quantizes at 0.1 m; ±0.5 m is neither loose nor brittle).
- Non-flat assertion: max − min across the tile exceeds 50 m.
- Rejection tests, each expecting `nil`: random bytes, empty data, truncated
  PNG, and a **valid but wrong-size** PNG (e.g. 512×512) — the silent-rescale
  case.
- Colorspace identity: `#require` the fixture's source colorspace is sRGB or
  untagged, pinning the no-color-management invariant the literals depend on.

Placement checks — `TerrainRGBPlacementTests` (AuraCoreTests): frozen-literal
tile x/y and pixel for known Pittsburgh landmarks at z14.

## 4. Ranking gate — `RoutePlanningElevationGateTests` (AuraKitTests)

Runs the extracted production pipeline end to end with the network swapped
for the fixture:

- Tile lookup: a closure returning the decoded fixture tile for its
  `TerrainTileID`, `nil` otherwise (drop-on-miss mirrors production because
  it *is* production code via `TerrainRGBSampler`).
- Three hand-authored polylines inside the tile bounds, each with ≥ 32
  vertices so the downsampling branch of `sampleIndices` actually executes:
  - `hillA` — monotonic climb up the ridge (gain ≈ relief; any
    sign-reversal or reordering of elevations collapses its gain to ~0, so
    reversal cannot pass);
  - `riverbank` — along the flat band (gain exactly 0 by DEM construction);
  - `hillB` — a different climb with a distinct frozen gain.
  - Honesty note: in-tile routes are ~≤ 2.6 km, so `proportionalCount`
    min-clamps to 16 samples; the proportional branch stays covered by
    `ElevationSamplingTests`. Zoom is pinned to 14 to match the provider
    default.
- `CandidateRoute` choreography (required — `RouteRanker` assigns mostPaths
  first and dedups winners, so unpinned inputs can leave "Flattest"
  unassigned): candidates ordered `[hillA, riverbank, hillB]`; `hillA` gets
  the strictly lowest `walkFraction` (wins mostPaths), `hillB` the strictly
  lowest duration (wins fastest), so flattest must go to the minimum-gain
  candidate.
- Assertions:
  - every route's elevations are non-empty;
  - gains are not all zero and not all equal;
  - frozen-literal expected gain per route, **±0.5 m absolute** (sampling
    and fixture are deterministic; intentional tweaks are re-record events,
    not tolerance headroom);
  - `RouteRanker.labeled` assigns `.flattest` to `sourceIndex` 1
    (riverbank).

The flat-regression kill line: if the decoder or sampler silently goes flat,
gains collapse to 0, the not-all-zero assertion and all three gain literals
fail. Offset and uniform-scale errors are the decoder gate's job (pixel
literals), not this suite's.

## 5. Error handling and CI

- No network access in any test; the fixture is the only tile source.
- No `#if os` guards needed: CoreGraphics and ImageIO are available on both
  declared platforms. (`corelocation-macos-ci-guards` does not bite here.)
- The existing `swift test` CI job picks up the new suites with no workflow
  changes. The app-build CI job proves the refactored provider compiles
  against the extracted core.
- Truth literals are recorded from a run on the CI toolchain (macos-15,
  latest-stable Xcode) to pin any residual ImageIO variance where CI runs.
- SwiftLint must stay clean (`swiftlint --strict`).

## 6. Coverage honesty — what this gate would and would not catch

| Regression class | Caught by |
|---|---|
| Silently flat/garbage decode (the original Terrain-RGB class) | Decoder gate + ranking gate |
| RGB formula, byte-order, colorspace, wrong-size/partial-image regressions | Decoder gate |
| Placement math regressions | Placement frozen literals |
| Sampling orchestration drift (order, dedupe, drop, px/py wiring) | Ranking gate via shared `TerrainRGBSampler` |
| Samples → gain → "Flattest" label wiring | Ranking gate |
| Empty-token early return (`elevations == []` → gain 0) | **Not caught** — app-side guard; device verification |
| URLSession fetch, HTTP status handling | **Not caught** — deliberately out of CI |
| `TerrainTileCache` warm dedupe / negative-result caching | **Not caught** — app-side actor; compile-gated only |
| Provider left unwired at a call site (`MapboxRoutingProvider` default, `RoutePreviewView`, `MapboxDetourRouting`) | **Not caught** — same symptom as the original class; device verification |
| Real Mapbox encoder drift vs the generated fixture | **Not caught** in CI — one-time live cross-check at record time (§2) |

The first draft of this spec claimed "only URLSession stays ungated"; review
showed that was false. This table is the honest boundary.

## 7. Testing the change itself

Regression drill before merge, one break per gated class, reverted after
proof and quoted in the PR:

1. Force the decode to produce an all-zero buffer (the historical failure
   shape) → decoder gate and ranking gate both fail.
2. Break the placement `y` formula → placement literals fail.
3. Zero the RGB formula multiplier → decoder pixel literals fail.

## 8. Definition of done

- Both suites green locally (`swift test` in `AuraCore/`); CI green on the
  PR; `swiftlint --strict` clean.
- Regression drill output quoted in the PR.
- Sibling harness specs: **append** to their "Not caught — ROH-94" rows
  ("gated since ROH-94, see this spec") — the dated specs stay point-in-time
  records. ROADMAP §Testing closes the Terrain-RGB cautionary tale with a
  pointer here.
- Linear: ROH-94 → In Review at PR, Done after merge (board flow).

## 9. Out of scope

- No app-target unit-test bundle, no URLProtocol stubbing.
- No change to provider behavior, ranking semantics, tile zoom, or sampling
  defaults.
- No gating of the URLSession fetch, token guard, or the actor cache
  (rows in §6).
