# ROH-126 — Shareable ride card redesign: real map background, distance off the map

**Linear:** [ROH-126](https://linear.app/rohun/issue/ROH-126/redesign-shareable-post-ride-card-real-map-background-distance-off-the)
**Date:** 2026-07-29 · **Revision 3** (rev 1 and rev 2 each drew REVISE from three
independent adversarial reviewers — skeptic / product / architecture. Rev 2's layout
budget and fallback-first flow were verified correct in round 2; this revision rebuilds
the raster-acceptance machinery per the round-2 findings and adopts the reviewers'
mechanisms wholesale.)

## Problem

The post-ride summary screen reads well: a real map with the route, then the distance
hero, the elevation band, and the supporting stats. The image produced by **Share**
does not match it, and it has two defects the rider actually notices:

1. **The distance sits in an opaque tile on top of the route.** `ShareCardView.overlayBlock`
   draws the date line and the distance hero on `AuraTheme.surface` at full opacity over
   the route field. (The 2026-07-01 spec called for the sanctioned 0.85 `mapScrim`
   treatment; full opacity was an implementation deviation — but see Approaches for why
   we go further than restoring the scrim.)
2. **The map background is gone.** The card draws only the bare polyline
   (`RouteThumbnail`, a `Canvas`) on the flat app background. The card's header comment
   is accurate about its narrow claim — a live Mapbox `Map` cannot render inside
   `ImageRenderer` — but the conclusion is stale: `MapboxMaps.Snapshotter` renders full
   styled map rasters offscreen, and Home already ships on it (`MapboxTerrainSnapshotter`).

## Goals

- The shared image shows the route on a real map raster, in the rider's chosen map
  style, framed like the summary screen's `StaticRouteMap`.
- No Aura content over the map. The distance and all text move out of the map field.
  (The SDK composites the Mapbox logo + attribution chip into the raster's bottom
  corners; that is a Mapbox ToS obligation and an acknowledged cost of a real map.)
- **Share is never slower or less reliable than today.** The Share button enables as
  fast as it does now (the same synchronous fallback render), and the card upgrades in
  place when a raster is accepted. A failed upgrade can never take Share away.
- A raster is used only when it demonstrably rendered map content, enforced by
  sampling **pixels we did not draw** (see acceptance step 6).
- The fallback card (polyline, no tile) remains deterministic; the map variant's pixels
  necessarily depend on tile availability.

## Non-goals

- No visual change to the summary screen except one transient affordance: a quiet
  progress hint while the map upgrade is in flight (see Share flow).
- No change to `ShareCardContent`'s existing fields, the share payload type (PNG file
  URL), or `RouteThumbnail`'s other callers (History rows, Last Ride card, widgets).
- No new user-facing options. No Home-snapshotter refactor (round-2 review showed the
  proposed shared style helper doesn't type-check against Home's version-bearing string
  identity; Home's own latent blank-cache bug is tracked separately).

## Approaches considered

**A. `Snapshotter` raster + all text below the map (chosen).** The map field is fully
free of Aura content — the literal fix for "blocking the full map."

**B. `Snapshotter` raster + distance on the sanctioned 0.85 scrim.** The 2026-07-01
design restored over a real map. Rejected, narrowly: the driving complaint is that the
distance tile blocks the map, a 0.85 scrim still occludes what's under it, and the band
composition below is measured to fit without it. Honest ledger: A spends the 56 pt hero
(→ 48) and B would keep it; A was chosen because the reporter's words were about the
tile covering the map. A rendered B variant can be produced for PO comparison at PR
time if wanted.

**C. Mapbox Static Images API.** Rejected: token in a URL, a second styling pipeline
that drifts (the authored `auraTerrain` JSON isn't hosted), weaker offline.

**D. Snapshot the live `StaticRouteMap` view.** Rejected: couples the share image to
on-screen view size, load timing, and visibility; flaky by construction.

## Design

### Layout (the numbers are the spec)

Card stays 360×450 pt (1080×1350 @3x). Saira Condensed's measured line-box ratio is
**1.574×** the point size (verified from the shipped TTFs in round-2 review); the budget
uses line boxes, not point sizes.

**Map field: exactly 360×240 pt** — full-bleed top, same height as the summary map. The
raster is requested at exactly this size @3x; the constant lives in one place
(`ShareCardLayout.mapFieldSize`, AuraKit) used by both the snapshot request and the
view. Drawn `Image(uiImage:).resizable().frame(width:height:).clipped()` — `resizable`
because a cache round-trip re-materializes at scale 1 (`UIImage(data:)`), and the cache
read must pass `UIImage(data:scale: 3)`; the exact-size aspect match means stretch
cannot distort and the SDK's attribution corners cannot be cropped.

**Readout band: 210 pt**, horizontal padding `xl` 20 (320 pt content width), top
padding `md` 12 + bottom `lg` 16 → 182 pt vertical content:

| Row | Content | Line box |
|---|---|---|
| Context | date · destination — caption rounded semibold, tracked, `lineLimit(1)` tail-truncated | 14.1 |
| (gap xs) | | 4 |
| Hero | distance `speedHero(48)` + unit inline (`metricCockpit(18)`) | 75.4 |
| (gap sm) | | 8 |
| Sparkline | `ElevationSparkline`, height 40, only when elevation exists | 40 |
| (gap sm) | | 8 |
| Stats row | moving time and climbed as **Saira numerals** (`metricCockpit(17, .semibold)`) with rounded small labels, concatenated `Text` runs; **AURA wordmark trailing** (`metricCockpit(16)`, tracking 4) | 26.8 |
| **Total** | | **176.3 ≤ 182** ✓ |

- Hero is 48 (round 2 measured that it fits; rev 2's 44 was an unforced shrink).
- Stats numerals stay in Saira — the cockpit-numeral rule from DESIGN.md and the
  2026-07-01 spec; SF Rounded is labels only. At ~130 pt feed-thumbnail scale, 17 pt
  Saira ≈ 6.1 pt-equivalent vs today's 7.9: partially mitigated by semibold weight and
  `lineLimit(1) + minimumScaleFactor(0.85)`; the worst measured stats string
  (`480 MIN MOVING · 12000 FT CLIMBED` + wordmark = 324 pt vs 320) scales to ~0.99.
  The wordmark gets `layoutPriority(1)` and `fixedSize()`; the stats text yields.
- Row order puts the sparkline mid-band (uncaptioned — climbed lives in the stats row)
  and the stats row + wordmark **last**, restoring the wordmark as the card's
  bottom-anchored sign-off. (Rev 2 justified moving it up by Instagram's 1:1 grid crop;
  review noted IG grids have been 4:5 since 2025, so the premise is weak — composition
  wins.) Without elevation, the sparkline row disappears and a `Spacer` keeps the stats
  row bottom-anchored so the band never shows a dead gap.
- The vertical budget is enforced by a **package test**: `ShareCardLayout` (AuraKit)
  exposes the row constants and a pure budget function (line-box arithmetic with the
  1.574 factor); the view derives its sizes/spacings from the same constants. Honest
  limit: a font-file swap that changes the ratio is not caught — that constant is
  asserted against the bundled TTF's metrics in the test comment, no more. Preview
  checks remain for eyes, not enforcement.

**Variants**, selected from one source of truth (`content.routeSegments`, never raw
`Ride.segments`):

- **Map** — route present and an accepted raster: raster full-bleed, band below.
- **Polyline fallback** — route, no accepted raster: `RouteThumbnail` in the map field
  (inset `lg`, 3 pt — the thumbnail idiom; the 5 pt stroke is the *raster* treatment),
  same band, no opaque tile anywhere.
- **No-route** — unchanged centered composition; `StatPair` gains an optional
  `labelColor` (default unchanged) so the card can pass its high-contrast secondary
  (today's 0.62 labels violate the card's own pinned-contrast rule).

### Route drawing: capture, then composite ourselves

The SDK composites overlay → logo → attribution *into* the returned image, so a raster
that contained our route stroke could never be blank-checked (round 2's decisive
finding). Instead:

1. `start(overlayHandler:)`'s handler **draws nothing**. It only captures each
   segment's projected points via `pointForCoordinate` into `[[CGPoint]]`.
2. Acceptance (below) runs on the returned raster — bare map + SDK logo/attribution,
   none of our ink.
3. On acceptance, we composite the route in our own `UIGraphicsImageRenderer` pass:
   per-segment paths (never across pause gaps), **casing first** — near-black
   (`AuraPalette.nearBlack`) 8 pt round-cap stroke — then mint
   (`AuraTheme.routeUIColor`) 5 pt round-cap on top. The casing is what keeps the route
   legible on light basemaps (`.standard`), standard cartographic practice. Path
   building from points is a pure, package-testable function.

### `ShareMapRasterProviding` + `ShareMapSnapshotter`

`@MainActor` protocol seam (the Home `TerrainSnapshotRendering` pattern), injected at
both construction sites (`AuraApp` ride-end push, `HistoryView` sheet) with **no default
argument**; the provider must be trivially constructible (no Snapshotter or observers
in `init`, both sites re-evaluate closures on parent body passes).

```swift
@MainActor protocol ShareMapRasterProviding {
    func raster(for request: ShareMapRequest) async -> UIImage?   // accepted+composited, or nil
}
```

`nil` means exactly: *no acceptable map; use the polyline fallback.* The concrete
`ShareMapSnapshotter` is a **single-flight coordinator**: at most one snapshot pipeline
alive at a time, in-flight dedup by cache key (a second request for the same key awaits
the first), and every await point checks `Task.isCancelled`. This bounds the
History-browse pattern (N quick open/close cycles) to one live Snapshotter, not N.

Pipeline, in order — reject (`nil`) unless every step passes:

1. **Input hygiene** (pure AuraKit, package-tested): from `content.routeSegments`,
   drop non-finite coordinates; require ≥ 2 distinct coordinates and a bounding span
   above epsilon; decimate each segment to the raster's pixel budget (~600 pts/segment,
   stride) **force-including each segment's bbox-extremal points** so framing can't
   drift from the full track. This hygiene is the real guard for the camera call —
   `Snapshotter.camera(for:)` is exception-unsafe on degenerate input (unlike
   `MapboxMap`'s wrapped variants), so garbage must never reach it.
2. **Cache read**: `TerrainSnapshotDiskCache` in its own directory
   (`ShareCardSnapshots`), key = ride id + **route-content hash** (over the decimated
   coordinates — ride rows are upserted/backfilled/CloudKit-merged, so the id alone is
   not a route identity) + **style identity including version**
   (`TerrainStyle.authoredStyleIdentity` for `.auraTerrain`; the `StyleURI` raw value
   otherwise) + field size + scale. Hit → `UIImage(data:scale: 3)` → composite route →
   return. Prune to a stated budget (24 MB) after every write; prune is
   least-recently-written (cache reads don't touch mtime) — accepted.
3. **Style load**: `Snapshotter` inherits `StyleManager.load(mapStyle:completion:)` —
   callback-driven (no event race, no replay problem) and takes the **existing**
   `settings.mapStyle.mapboxStyle` from `MapStyle+Mapbox`, so there is no new style
   resolution copy. A 4 s belt timeout applies; on timeout consult `isStyleLoaded`
   before rejecting. An `onMapLoadingError` observer is attached **before** the load
   and stays alive through `start()` (token cancelled in a `defer`); any style/source
   error → reject; any tile error observed before completion → reject.
4. **Camera**: `snapshotter.camera(for: coords, padding: UIEdgeInsets(all: 24),
   bearing: 0, pitch: 0)`; validate via a pure predicate over primitives
   (`center lat/lon: Double?`, `zoom: Double?` — `CameraOptions` fields are optionals
   and the degenerate path returns nil or NaN): finite and present, else reject; then
   clamp zoom ≤ 16 (guard-then-clamp; `min(_:_:)` propagates NaN order-dependently).
5. **Render, bounded, resume-once**: `start(overlayHandler: capture-only)` raced
   against a 6 s timeout with an `OSAllocatedUnfairLock` resolve-once latch (the Home
   gate's `finishOnce` shape) absorbing all three racers — SDK completion, timeout,
   and cancel-induced completion — so the continuation can never double-resume
   (`Snapshotter.cancel()` is *documented* to fire the completion with an error, but
   there is a window where a parked success still arrives; the latch is the guarantee,
   not the doc). Timeout and task-cancellation both call `cancel()` **hopped to the
   main actor** (`Task { @MainActor in … }`) — `Snapshotter` is non-Sendable and
   main-thread-only, and a direct capture in a `@Sendable onCancel` closure does not
   compile under this repo's Swift 6 / default-MainActor settings. Strong-capture the
   snapshotter in the completion (the Home continuation-leak fix).
6. **Acceptance on bare pixels**: downsample the raster's **map interior** — excluding
   a bottom 30 pt strip that covers the SDK logo (bottom-left) and attribution chip
   (bottom-right) — and require variance above threshold vs. a flat fill. The sampled
   region contains nothing we drew (route not yet composited) and no SDK chrome. The
   buffer math is a pure AuraKit function over `[UInt8]`, package-tested with fixture
   buffers (flat, flat+noise, real-map crops of all three styles); the threshold is
   tuned against real captures during device verification. Slow-network partial tiles:
   the tile-error observer from step 3 is the primary defense; the interior variance
   check is the backstop.
7. **Composite route** (casing + mint, above) → **cache write** (only accepted rasters;
   *not* guarded on cancellation — an accepted raster is worth keeping for the reopen) →
   return. PNG encode, downsample, cache write, and file I/O run **off the main actor**
   (the raster and buffers are `Sendable` value data); only `ImageRenderer`,
   `Snapshotter` calls, and `@State` writes stay on main.

### Share flow — fallback first, upgrade in place, prefetch ahead

1. **Prefetch**: when a ride ends (the moment `AppRouter` decides to push the summary),
   fire-and-forget a raster request through the same provider — single-flight dedup
   makes this safe. By the time the rider can reach Share, the summary's own request is
   usually a warm-cache hit. History opens don't prefetch; their request starts after
   the entrance-animation window (the existing `Task.yield` discipline — DESIGN.md's
   "sanctioned delight moment" must not stutter; today's code already yields before the
   sync render for exactly this reason).
2. `.task`: build `ShareCardContent`; render the **fallback card** synchronously (same
   cost as today's only render — this is why Share's enable time is unchanged); set
   `shareImage`.
3. If a route exists: `await` the provider. On acceptance and `!Task.isCancelled`,
   re-render with the raster and swap — **`if let upgraded { shareImage = upgraded }`**;
   a failed upgrade render keeps the working fallback (never assign nil over an enabled
   Share).
4. While the upgrade is in flight, a quiet one-line hint near the Share button
   (`ProgressView` + "Adding your map…", caption, high-contrast secondary) shows and
   then disappears. Share itself is enabled and works throughout.
5. **Accepted cost, stated**: a rider who shares within the first couple of seconds
   (or in dead coverage) shares the polyline fallback card. With prefetch this window
   is mostly gone on the ride-end path; we accept the residue rather than block Share
   or add retry UI. In weak coverage the card is the fallback every time — also
   accepted; reopening from History after coverage returns produces the map card.

**Swap-while-sheet-open** is a named risk: replacing `shareImage` swaps the
`ShareLink`'s item while a share sheet may be presented. Device verification must
confirm the presented sheet neither dismisses nor changes its payload; if it does, the
mitigation is a swap latch (defer the upgrade swap until the sheet is dismissed).

### Files

Each render writes `tmp/ShareCard/<rideID>/<generation>/Aura ride.png` — the leaf name
stays clean (it is user-visible in Messages/Mail/Files; rev 2's UUID-bearing filename
regressed that), and uniqueness comes from the directory. Generation 0 = fallback,
1 = map. Sweep policy: on **summary entry only** (not per render), delete `ShareCard/`
subdirectories for *other* rides older than one hour; never the current ride's, and
never between a swap and its predecessor's release — an open share sheet's file is
structurally out of the sweep's reach. `RideShareImage` gains a `title` used by
`SharePreview`: `"Aura ride · <distance> <unit> · <date>"` (keeps the brand token in
share-sheet metadata).

### Error handling

| Failure | Behavior |
|---|---|
| Offline, remote style never loads | `load` completion errors or 4 s belt fires (and `isStyleLoaded` false) → `nil`; Share already live with fallback |
| Offline, bundled `auraTerrain` loads, tiles absent | tile-error observer and/or interior-variance reject → `nil` → fallback |
| Slow network, tiles partial | tile-error observer primary; interior variance backstop → `nil` |
| `start()` never completes (backgrounding) | 6 s latch race → `cancel()` on main → `nil`; Share unaffected |
| Degenerate route (stationary, single point, NaN) | hygiene/camera predicate → `nil` → fallback (and camera never sees garbage) |
| `.standard` misrenders through `Snapshotter` | acceptance rejects → **polyline fallback**, never a different style than the screen behind it |
| Upgrade render/write fails | fallback `shareImage` kept; Share stays enabled |
| Initial fallback render fails | Share disabled (today's behavior, unchanged) |

### ROH-7 (single live renderer)

On the ride-end path the HUD's live map is torn down before the summary pushes
(`RideSummaryRouting.collapsed`), so the steady state is one live `Map`
(`StaticRouteMap`) plus one transient `Snapshotter` — the same category Home ships.
Single-flight caps it at one. The snapshot may compete with the on-screen map for
bandwidth on slow links; prefetch (which usually completes before the summary's map
mounts) reduces the overlap, and the residue is accepted and measured on device.

### Testing

- **Package (runs in the agent gate):** existing `ShareCardContent` tests unchanged;
  new tests — coordinate hygiene/decimation (incl. forced bbox extremes), camera
  predicate over primitives (nil/NaN/degenerate), interior-variance function (flat,
  flat+chrome-strip-excluded, real-map fixture crops), cache key (route hash, style
  version), `ShareCardLayout` budget, route path building from captured points.
- **Previews** (eyes, not enforcement): map variant (fixture at exactly 360×240@3x),
  polyline fallback, no-route, route-without-elevation (Spacer anchoring), long
  destination truncation, worst-case stats string, metric + imperial.
- **Device/simulator verification (all required; airplane mode is device-only —
  simulator lacks it; Network Link Conditioner on the host throttles the simulator):**
  golden-ride harness to a real summary; inspect the written PNG full-size and at
  ~130 pt thumbnail; **tap Share before the upgrade lands and complete a share to
  Photos and Messages**; confirm sheet behavior when the swap occurs while presented;
  **second open of the same ride** (cache-hit path — catches the scale-1 crop class);
  offline with `auraTerrain` specifically → polyline fallback actually renders; slow
  network → partial raster rejected; paused multi-segment ride (no stroke across the
  gap); no-route variant on device; all three styles, including route-casing legibility
  on `.standard`; assert `cancel()` fires the completion (its contract is doc-only);
  measure time-to-upgrade on the ride-end path and record it in the PR.

## Risks

- **Interior-variance threshold** — too strict rejects sparse night-style areas, too
  loose ships blanks. The sampled region now contains only map pixels (no route, no
  chrome), which is what makes a workable threshold plausible; tuned against real
  captures of all three styles, and the pure function keeps the boundary testable.
- **`Snapshotter.load(mapStyle:)` on this SDK version** — inherited-API behavior on a
  snapshotter (vs. a map view) is the least-exercised assumption; verified first thing
  in implementation (it's the pipeline's foundation), with the event-gate as a known
  fallback shape if it misbehaves.
- **Swap-while-presented ShareLink behavior** — unverified SwiftUI behavior; named
  contingency above.
- **Two Mapbox render paths briefly concurrent** — transient, single-flight-capped,
  measured on device.
