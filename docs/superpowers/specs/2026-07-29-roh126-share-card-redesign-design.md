# ROH-126 — Shareable ride card redesign: real map background, distance off the map

**Linear:** [ROH-126](https://linear.app/rohun/issue/ROH-126/redesign-shareable-post-ride-card-real-map-background-distance-off-the)
**Date:** 2026-07-29 · **Revision 4 (converged).** Three adversarial review rounds:
rev 1 and rev 2 drew REVISE ×3 (skeptic / product / architecture); rev 3's delta round
returned REVISE ×2 with minimal, convergent, mechanical must-change lists whose fixes
this revision adopts verbatim. The review loop hit its 3-iteration cap here; the
remaining verification burden moves to the plan review gate and device verification.

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
  style, framed like the summary screen's `StaticRouteMap` (one deliberate divergence:
  extra bottom camera padding keeps the route clear of the SDK's attribution chrome).
- No Aura content over the map. The distance and all text move out of the map field.
  (The SDK composites the Mapbox logo + attribution chip into the raster's bottom
  corners; that is a Mapbox ToS obligation and an acknowledged cost of a real map —
  and nothing of ours, including the route stroke, may overdraw it.)
- **Share is never slower or less reliable than today.** The Share button enables as
  fast as it does now (the same synchronous fallback render), and the card upgrades in
  place when a raster is accepted. A failed upgrade can never take Share away.
- A raster is used only when it demonstrably rendered map content, enforced by
  sampling pixels we did not draw, in a region that excludes the SDK chrome.
- The fallback card (polyline, no tile) remains deterministic; the map variant's pixels
  necessarily depend on tile availability.

## Non-goals

- No visual change to the summary screen except one transient affordance: a quiet
  progress hint while the map upgrade is in flight (see Share flow).
- No change to `ShareCardContent`'s existing fields, the share payload type (PNG file
  URL), or `RouteThumbnail`'s other callers (History rows, Last Ride card, widgets).
- No new user-facing options. No Home-snapshotter refactor (Home's version-bearing
  string identity doesn't type-check against a shared helper; Home's latent blank-cache
  bug is tracked separately).

## Approaches considered

**A. `Snapshotter` raster + all text below the map (chosen).** The map field is fully
free of Aura content — the literal fix for "blocking the full map."

**B. `Snapshotter` raster + distance on the sanctioned 0.85 scrim.** The 2026-07-01
design restored over a real map. Rejected, narrowly: the driving complaint is that the
distance tile blocks the map, a 0.85 scrim still occludes what's under it, and the band
composition below is measured to fit without it. Honest ledger: A spends the 56 pt hero
(→ 48) and B would keep it. A rendered B variant can be produced for PO comparison at
PR time if wanted.

**C. Mapbox Static Images API.** Rejected: token in a URL, a second styling pipeline
that drifts (the authored `auraTerrain` JSON isn't hosted), weaker offline.

**D. Snapshot the live `StaticRouteMap` view.** Rejected: couples the share image to
on-screen view size, load timing, and visibility; flaky by construction.

## Design

### Layout (the numbers are the spec)

Card stays 360×450 pt (1080×1350 @3x). Saira Condensed's measured line-box ratio is
**1.574×** the point size (verified from the shipped TTFs); the budget uses line boxes.

**Map field: exactly 360×240 pt** — full-bleed top, same height as the summary map. The
raster is requested at exactly this size @3x; the constant lives in `ShareCardLayout`
(AuraKit) used by both the snapshot request and the view. Drawn
`Image(uiImage:).resizable().frame(width:height:).clipped()` — `resizable` because a
cache round-trip re-materializes at scale 1 unless re-wrapped, and the cache read must
use `UIImage(data:scale: 3)`; the exact-size aspect match means stretch cannot distort
and the SDK's attribution corners cannot be cropped.

**Readout band: 210 pt**, horizontal padding `xl` 20 (320 pt content width), top
padding `md` 12 + bottom `lg` 16 → 182 pt vertical content:

| Row | Content | Line box |
|---|---|---|
| Context | date · destination — caption rounded semibold, tracked, `lineLimit(1)` tail-truncated | 14.3 |
| (gap xs) | | 4 |
| Hero | distance `speedHero(48)` + unit inline (`metricCockpit(18)`) | 75.55 |
| (gap sm) | | 8 |
| Sparkline | `ElevationSparkline`, height 40, only when elevation exists | 40 |
| (gap sm) | | 8 |
| Stats row | moving time and climbed as **Saira numerals** (`metricCockpit(17, face: .semibold)`) with **13 pt** rounded-semibold labels, concatenated `Text` runs; **AURA wordmark trailing** (`metricCockpit(16)`, tracking 4) | 26.8 |
| **Total** | | **176.6 ≤ 182** ✓ |

- Hero is 48 (measured to fit; rev 2's 44 was an unforced shrink).
- Stats numerals stay in Saira — the cockpit-numeral rule (DESIGN.md, 2026-07-01 spec);
  SF Rounded is labels only. The stats text gets `lineLimit(1) + minimumScaleFactor(0.85)`;
  the wordmark gets `layoutPriority(1)` + `fixedSize()`. Hand-measured worst case
  (`480 MIN MOVING · 12000 FT CLIMBED` + wordmark ≈ 324 pt vs 320) scales to ~0.99 —
  this width case is covered by a preview with that exact string, not by a test.
- Row order: sparkline mid-band (uncaptioned — climbed lives in the stats row), stats
  row + wordmark **last**, restoring the wordmark as the bottom-anchored sign-off.
  Without elevation, a `Spacer` keeps the stats row bottom-anchored (no dead gap).
- **Budget enforcement:** `ShareCardLayout` (AuraKit) owns the card's field size, row
  point sizes, gaps, paddings, and the chrome-strip constant. These are card-local
  constants — deliberately *not* `AuraTheme.Spacing` (an app-target type AuraKit cannot
  see); the card is a fixed PNG and pins its own numbers. The package test measures
  real line boxes via CoreText against a copy of the Saira TTF in test resources (the
  repo already decodes PNG fixtures in AuraKitTests, so host-side CoreText is fine) and
  asserts the composed budget ≤ 182 — an actual measurement, not arithmetic over the
  spec's own constants.

**Variants**, selected from one source of truth (`content.routeSegments`, never raw
`Ride.segments`):

- **Map** — route present and an accepted raster: raster full-bleed, band below.
- **Polyline fallback** — route, no accepted raster: `RouteThumbnail` in the map field
  (inset `lg`, 3 pt — the thumbnail idiom; 5 pt is the raster treatment), same band.
- **No-route** — unchanged centered composition; `StatPair` gains an optional
  `labelColor` (default unchanged) so the card can pass its high-contrast secondary.

### Route drawing: capture, then composite ourselves

The SDK composites overlay → logo → attribution *into* the returned image, so a raster
containing our route stroke could never be blank-checked. Instead:

1. `start(overlayHandler:)`'s handler **draws nothing**: it captures each segment's
   projected points via `pointForCoordinate` into a `[[CGPoint]]` buffer **owned by the
   request** (never the coordinator — a late-arriving handler run after a timeout must
   land in the abandoned request's buffer, not the next request's) and drops writes
   once the request's latch has resolved.
2. Acceptance runs on the returned raster — bare map + SDK chrome, none of our ink.
3. On acceptance, composite the route in our own `UIGraphicsImageRenderer` pass:
   per-segment paths (never across pause gaps), **casing first** — `AuraPalette.nearBlack`
   8 pt round-cap — then mint (`AuraTheme.routeUIColor`) 5 pt round-cap. The casing
   keeps the route legible on light basemaps (`.standard`). Path building from points
   is a pure, package-testable function.
4. **The route can never touch the SDK chrome** because the camera fit reserves the
   chrome band (bottom padding 40 pt, below) — our ink and Mapbox's never overlap by
   construction, preserving the ToS obligation without re-blitting.

### `ShareMapRasterProviding` + `ShareMapSnapshotter`

`@MainActor` protocol seam (the Home `TerrainSnapshotRendering` pattern — but unlike
Home, **instance identity is load-bearing**: in-flight dedup state lives on it).
**Exactly one app-lifetime instance**, created once at app scope (owned alongside the
app's other singletons in `AuraApp`/root composition, not inside a view-builder closure
that re-runs per body pass) and handed to the ride-end prefetch site and both
`RideSummaryView` construction sites (`AuraApp` push, `HistoryView` sheet). No default
argument anywhere.

```swift
@MainActor protocol ShareMapRasterProviding {
    func raster(for request: ShareMapRequest) async -> UIImage?   // accepted+composited, or nil
}
```

`ShareMapRequest` carries: ride id (`ShareCardContent` has no id — the request needs it
for the cache key and file directory), the filtered `routeSegments`, field size, scale
(pinned 3), and the `AuraKit.MapStyle`.

`nil` means exactly: *no acceptable map; use the polyline fallback.*

**Single-flight semantics (pinned):** the pipeline for a key runs in a
**coordinator-owned unstructured `Task`**; callers `await` its value. A caller's
cancellation abandons only that caller's await — the pipeline runs to completion
(bounded by its own timeouts) and writes the cache. The in-flight table entry is
removed in a `defer` on the pipeline task; waiters are resolved exactly once. At most
one pipeline is alive at a time; a request for a different key queues.

Pipeline, in order — reject (`nil`) unless every step passes:

1. **Input hygiene** (pure AuraKit, package-tested): from `content.routeSegments`,
   drop non-finite coordinates; require ≥ 2 distinct coordinates and a bounding span
   above epsilon; decimate each segment to ~600 pts (stride), **force-including
   bbox-extremal points**. This is the real guard for the camera call —
   `Snapshotter.camera(for:)` is exception-unsafe on degenerate input.
2. **Cache read**: `TerrainSnapshotDiskCache` in its own `ShareCardSnapshots`
   directory. **The cache stores the accepted, composited image**; a hit is returned
   as-is via `UIImage(data:scale: 3)` — no re-composite (a cache hit has no projected
   points and never needs them). Key = **FNV-1a hash** (filename-safe by construction —
   raw `StyleURI` values contain `/` and `:` which silently break
   `TerrainSnapshotDiskCache`'s key-as-filename writes) over: ride id + route-content
   hash (decimated coordinates) + style identity **derived from the `AuraKit.MapStyle`
   case** (`TerrainStyle.authoredStyleIdentity` for `.auraTerrain`; a stable slug for
   `.dark`/`.standard` — the SDK's `MapStyle.data` is internal) + **composite-treatment
   version** (casing/mint changes must invalidate) + field size + scale. Prune to 24 MB
   after every write (least-recently-written; accepted).
3. **Style load**: `snapshotter.load(mapStyle: settings.mapStyle.mapboxStyle, …)` —
   callback-driven, inherited from `StyleManager`, drives the snapshotter's own style
   (verified to the reconciler wiring). **Never combine with the `styleJSON`/`styleURI`
   setters** — a second load parks in `pendingCompletions` and can hang. The completion
   can fire synchronously; its continuation gets the same resolve-once latch as the
   render (a double resume is a crash, not a soft failure). 4 s belt timeout; on
   timeout consult `isStyleLoaded` before rejecting. An `onMapLoadingError` observer is
   attached **before** the load and stays alive through `start()` (token cancelled in a
   `defer`): **`.style`/`.source` errors reject; `.tile` errors are non-fatal** (edge
   tiles 404 routinely — DEM outside coverage, glyphs — and Home's precedent only logs;
   the interior-variance check is the primary defense for partial tiles).
4. **Camera** (strictly **after** the style load resolves — a style's root
   `center`/`zoom` would otherwise override the fit):
   `snapshotter.camera(for: coords, padding: UIEdgeInsets(top: 24, left: 24,
   bottom: 40, right: 24), bearing: 0, pitch: 0)`. **Bottom 40 is deliberate**: SDK
   chrome occupies the bottom ~33 pt of the raster; 40 pt of fit padding minus the 4 pt
   casing half-width keeps every stroked pixel clear of it (divergence from
   `StaticRouteMap`'s symmetric 24, noted per the framing goal). Validate via a pure
   predicate over primitives (`Double?` center/zoom — the degenerate path returns nil
   or NaN): present and finite, else reject; then clamp zoom ≤ 16 (guard-then-clamp;
   `min` propagates NaN order-dependently).
5. **Render, bounded, resume-once**: a `@MainActor final class` request handle
   (implicitly `Sendable`) owns the snapshotter reference, the resolve-once latch
   (`OSAllocatedUnfairLock` `finishOnce`, absorbing SDK completion / 6 s timeout /
   cancel-induced completion), and the point buffer. `withTaskCancellationHandler`'s
   `@Sendable onCancel` captures **the handle** (capturing the non-Sendable
   `Snapshotter` — even inside a nested `Task { @MainActor … }` — does not compile
   under this repo's Swift 6 + default-MainActor settings) and hops:
   `Task { @MainActor in handle.cancel() }`. The handle holds the snapshotter
   **strongly until the latch resolves**, and the SDK completion captures it weakly —
   so a `cancel()` that never fires its completion (the contract is doc-only) cannot
   leak the snapshotter, and a late completion after dealloc is dropped harmlessly
   while the timeout arm has already resumed the continuation. The completion body does
   minimal work — take the lock, stash, resume — with all main-actor work after the
   `await` (the SDK's compositor callback thread is not guaranteed main when the
   attribution text falls to `.none` at small sizes).
6. **Acceptance on bare pixels**: downsample the raster's map interior, excluding a
   bottom strip of **36 pt** (`ShareCardLayout.mapChromeStripHeight` — derived from the
   SDK's margin 10 + logo 21 + attribution-chip slack; measured chrome tops out at
   ~33 pt, and a 30 pt strip would leak bright chrome rows into the sample, biasing
   toward false-accept), and require variance above threshold vs. a flat fill. Pure
   AuraKit function over `[UInt8]`, package-tested with fixture buffers (flat,
   flat+chrome, real-map crops of all three styles); threshold tuned against real
   captures during device verification.
7. **Composite route** (casing + mint, §Route drawing) → encode → **create the target
   directory, then cache write** (only accepted rasters; not guarded on cancellation —
   an accepted raster is worth keeping) → return. PNG encode, downsample, and file I/O
   run **off the main actor** (`UIImage`/`CGImage`/`Data` are Sendable; AuraKit's pure
   functions are nonisolated); only `ImageRenderer`, `Snapshotter` calls, and `@State`
   writes stay on main.

### Share flow — fallback first, upgrade in place, prefetch after the transition

1. **Prefetch**: fired from the ride-end HUD call sites (`RideHUDView` /
   `NavigateHUDView`, which own `settings` and the ride — `AppRouter` has neither),
   **after a transition-settling delay** (~0.7 s): the summary push and HUD teardown
   overlap the push animation, and the SDK's compositor pass runs on the main queue,
   so starting the pipeline inside the transition window would drop frames during
   DESIGN.md's sanctioned delight moment. Single-flight dedup (one shared provider
   instance) joins the summary's own request onto the prefetch.
2. `.task`: build `ShareCardContent`; render the **fallback card** synchronously (same
   cost as today's only render); set `shareImage`. Share is enabled from the first
   frame. History opens (no prefetch) start their raster request after the
   entrance-animation window, per the existing `Task.yield` discipline.
3. If a route exists: `await` the provider. On acceptance and `!Task.isCancelled`,
   re-render and swap — **`if let upgraded { shareImage = upgraded }`**; a failed
   upgrade render keeps the working fallback.
4. While the upgrade is in flight, a quiet one-line hint near Share (`ProgressView` +
   "Adding your map…", caption, high-contrast secondary) — with a **show-delay
   (~300 ms)** so a warm cache hit doesn't flash it, hidden for the no-route variant.
5. **Accepted cost, stated**: a rider who shares within the first seconds (or in dead
   coverage) shares the polyline fallback card. Prefetch makes this rare on the
   ride-end path; the residue is accepted rather than blocking Share or adding retry
   UI. Weak coverage → fallback every time — accepted; a later History open upgrades.

**Swap-while-sheet-open** remains a named risk: device verification must confirm a
presented share sheet neither dismisses nor changes payload when `shareImage` swaps;
if it does, defer the swap until dismissal (swap latch).

### Files

Each render writes `tmp/ShareCard/<rideID>/<presentationUUID>/<generation>/Aura ride.png`
— the leaf name stays clean (user-visible in Messages/Mail/Files), uniqueness comes
from the directories, and the **per-presentation UUID** means a second presentation of
the same ride can never overwrite files a still-live consumer of the first
presentation's URL may read lazily. Generation 0 = fallback, 1 = map. Directories are
created before writing (an atomic write into a missing directory throws → `nil` →
Share disabled, the one promise this spec makes). Sweep on **summary entry only**:
delete other rides' `ShareCard/` subtrees older than one hour — the current ride's
files are structurally out of reach, which is what makes "an open sheet keeps its file"
hold (the sheet always belongs to the current ride). The swapped-out generation-0 file
is orphaned until a later summary entry collects it — bounded, in `tmp`, accepted.
`RideShareImage` gains a `title` used by `SharePreview`:
`"Aura ride · <distance> <unit> · <date>"`.

### Error handling

| Failure | Behavior |
|---|---|
| Offline, remote style never loads | `load` completion errors or 4 s belt (with `isStyleLoaded` false) → `nil`; Share already live with fallback |
| Offline, bundled `auraTerrain` loads, tiles absent | interior-variance reject (primary) → `nil` → fallback |
| Slow network, tiles partial | interior-variance reject (primary; tile-error signals are non-fatal input) |
| Style/source loading error | observer reject → `nil` |
| `start()` never completes (backgrounding) | 6 s latch race → handle `cancel()` on main → `nil`; snapshotter released by the handle, no leak |
| Degenerate route (stationary, single point, NaN) | hygiene/camera predicate → `nil` → fallback; camera never sees garbage |
| `.standard` misrenders through `Snapshotter` | acceptance rejects → polyline fallback, never a different style than the screen behind it |
| Upgrade render/write fails | fallback `shareImage` kept; Share stays enabled |
| Initial fallback render fails | Share disabled (today's behavior, unchanged) |

### ROH-7 (single live renderer)

During the ride-end push there are transiently two live `Map`s (the HUD's, mid-teardown
through the ~0.35 s transition) — which is why the prefetch waits out the transition;
the steady state is one live `Map` (`StaticRouteMap`) plus at most one transient
`Snapshotter` (single-flight-capped). Bandwidth competition with the on-screen map on
slow links is accepted and measured on device.

### Testing

- **Package (runs in the agent gate):** existing `ShareCardContent` tests unchanged;
  new tests — coordinate hygiene/decimation (incl. forced bbox extremes), camera
  predicate over primitives (nil/NaN/degenerate), interior-variance function (flat,
  flat+chrome-excluded, real-map fixture crops), FNV-1a cache key (route hash, style
  identity slug, composite version; filename-safety), route path building from
  captured points, and the **CoreText-measured** `ShareCardLayout` budget (against the
  Saira TTF in test resources).
- **Previews** (eyes, not enforcement): map variant (fixture at exactly 360×240@3x),
  polyline fallback, no-route (Spacer anchoring), route-without-elevation, long
  destination truncation, the worst-case stats string, metric + imperial.
- **Device/simulator verification (all required; airplane mode is device-only; Network
  Link Conditioner on the host throttles the simulator):** golden-ride harness to a
  real summary; inspect the PNG full-size and at ~130 pt thumbnail; **tap Share before
  the upgrade lands and complete a share to Photos and Messages**; sheet behavior on
  swap-while-presented; **second open of the same ride** (cache hit — catches scale-1
  crop and double-composite classes); offline with `auraTerrain` → polyline fallback
  actually renders; slow network → partial raster rejected; paused multi-segment ride;
  no-route variant; all three styles incl. casing legibility on `.standard`; route
  never touches the chrome band; assert `cancel()` fires the completion (doc-only
  contract); **no dropped frames during the summary entrance** (prefetch delay
  verified); time-to-upgrade measured and recorded in the PR.

## Risks

- **Interior-variance threshold** — too strict rejects sparse night-style areas, too
  loose ships blanks. The sampled region contains only bare map pixels; tuned against
  real captures of all three styles; the pure function keeps the boundary testable.
- **`Snapshotter.load(mapStyle:)`** — verified in SDK source down to the reconciler
  wiring, but it is the pipeline's foundation: implement and device-verify it first;
  the pre-attached-observer event gate is the fallback shape.
- **Swap-while-presented ShareLink behavior** — unverified SwiftUI behavior; named
  contingency (swap latch).
- **Transient two-`Map` window + Snapshotter bandwidth** — mitigated by the prefetch
  delay; measured on device.
