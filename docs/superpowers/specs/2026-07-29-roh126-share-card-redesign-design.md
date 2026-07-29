# ROH-126 — Shareable ride card redesign: real map background, distance off the map

**Linear:** [ROH-126](https://linear.app/rohun/issue/ROH-126/redesign-shareable-post-ride-card-real-map-background-distance-off-the)
**Date:** 2026-07-29 · **Revision 2** (after adversarial review by skeptic / product / architecture lenses; all three returned REVISE against revision 1. This revision reconciles their findings.)

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
   `ImageRenderer` — but the conclusion that no real map is possible is stale:
   `MapboxMaps.Snapshotter` renders full styled map rasters offscreen, and the Home
   screen already ships on it (`MapboxTerrainSnapshotter`).

## Goals

- The shared image shows the route on a real map raster, in the rider's chosen map
  style, framed like the summary screen's `StaticRouteMap`.
- Nothing covers the map. The distance and all text move out of the map field.
- **Share is never slower or less reliable than today.** The Share button enables as
  fast as it does now (a synchronous fallback render), and the card upgrades in place
  to the map version when the raster arrives.
- A raster is used only when it demonstrably rendered map content. Blank or degenerate
  rasters fall back to the polyline card — this must be enforced by code, not hoped.
- The fallback card (polyline, no tile) remains deterministic. The map variant's pixels
  necessarily depend on tile availability; determinism is scoped to the fallback.

## Non-goals

- No visual change to the summary screen. (`RideSummaryView`'s share-image *plumbing*
  changes — the `.task` orchestration — but nothing the rider sees on that screen.)
- No change to `ShareCardContent`'s existing fields, the share payload type (PNG file
  URL), or `RouteThumbnail`'s other callers (History rows, Last Ride card, widgets).
- No new user-facing options (no share-style picker).

## Approaches considered

**A. `Snapshotter` raster + all text below the map (chosen).** Render the map field
offscreen with `MapboxMaps.Snapshotter`, stroke the route in the overlay handler, and
move the distance/context into the readout band. The map field is fully unobstructed —
the literal fix for the complaint ("blocking the full map").

**B. `Snapshotter` raster + distance on the sanctioned 0.85 scrim.** Restore the
2026-07-01 design's `mapScrim` block over a *real* map — the app's own map-floating-text
idiom. Rejected, narrowly: the driving complaint is that the distance tile blocks the
map, and a 0.85 scrim still occludes what's under it; and the band composition below is
proven to fit without it, so the scrim buys nothing we need. If the band layout had not
fit, this was the fallback design.

**C. Mapbox Static Images API.** Server-rendered raster. Rejected: token in a URL, a
second style pipeline that drifts (the authored `auraTerrain` JSON isn't hosted), weaker
offline.

**D. Snapshot the live `StaticRouteMap` view.** Rejected: couples the share image to
on-screen view size, load timing, and visibility; flaky by construction.

## Design

### Layout (the numbers are the spec)

Card stays 360×450 pt (1080×1350 @3x). Saira Condensed Bold renders at ≈1.57× line
height per point size — the budget below uses measured line boxes, not point sizes.
(Rev 1 failed review here: its band needed ~286 pt in a 220 pt budget.)

**Map field: exactly 360×240 pt** — full-bleed top, same height as the summary map, 53%
of the card (more map than today's inset polyline field). The raster is generated at
exactly 360×240 pt @3x and drawn with `.frame(width:height:)` — **no `scaledToFill`**,
so the SDK-composited Mapbox logo/attribution in the raster's bottom corners can never
be cropped. The field size lives in one constant (`ShareCardLayout.mapFieldSize`) used
by both the snapshot request and the view.

**Readout band: 210 pt**, top padding `md` 12 + bottom `lg` 16 → 182 pt of content:

| Row | Content | Line box |
|---|---|---|
| Context | date · destination — caption rounded semibold, tracked, `lineLimit(1)` tail-truncated | ~14 |
| (gap xs) | | 4 |
| Hero | distance `speedHero(44)` + unit inline (`metricCockpit(18)`) | ~69 |
| (gap sm) | | 8 |
| Stats row | `42 MIN MOVING · 412 FT CLIMBED` — subheadline rounded semibold, high-contrast secondary; **AURA wordmark trailing** on the same row (`metricCockpit(16)`, tracked) | ~25 |
| (gap sm) | | 8 |
| Sparkline | `ElevationSparkline`, height 40, only when elevation exists | 40 |
| **Total** | | **168 ≤ 182** ✓ |

Without elevation the sparkline row disappears (climbed already lives in the stats
row) — 120 pt, trivially fits. The hero at 44 pt is smaller than today's 56, traded for
a map 4× the visual weight; at feed-thumbnail scale (~130 pt wide) 44 pt ≈ 16 pt
equivalent, comfortably legible. The wordmark moves up to the stats row (~y 350), which
*improves* its survival of Instagram's 1:1 grid crop (bottom 45 pt cropped) over
today's bottom anchor; the sparkline is the only thing in the crop zone, and it's
decorative. A preview-based fitting assertion (`fittingSize.height ≤ 210` at width 360)
guards the budget against font drift.

**Variants** (selection logic in one place, from one source of truth):

- **Map** — `content.routeSegments` non-empty *and* an accepted raster: raster
  full-bleed, band below. Nothing drawn over the raster.
- **Polyline fallback** — route but no accepted raster: `RouteThumbnail` fills the map
  field (inset `lg` as today), same band. No opaque tile anywhere.
- **No-route** — unchanged centered composition, except `StatPair` labels use the
  card's high-contrast secondary (see StatPair note).

Brand identity with a stock raster in the top half: the mint 5 pt route stroke, Saira
numerals, the tracked AURA wordmark, and the near-black band. The common case is the
authored dark terrain style (the app default), which is distinctly Aura's. A rider on
`.standard` gets a bright map over the dark band — an intentional seam: it's *their*
map style, matching the summary screen behind the share sheet. (Named as a trade, per
review; pinning a card-only style was rejected as breaking goal #1.)

### `ShareMapRasterProviding` (protocol seam) + `ShareMapSnapshotter`

Follows the Home pattern (`TerrainSnapshotRendering`): a `@MainActor` protocol in the
app target, concrete `ShareMapSnapshotter` bound at the view's construction sites, so
the orchestration is stubbable.

```swift
@MainActor protocol ShareMapRasterProviding {
    func raster(segments: [[Coordinate]], size: CGSize, scale: CGFloat,
                style: AuraKit.MapStyle, cacheKey: String) async -> UIImage?
}
```

`nil` from this seam means exactly one thing: *no acceptable map rendered; use the
polyline fallback.* (Distinct from `RideCardRenderer`'s `nil`, which disables Share —
the two never mix because the caller renders the fallback card first; see flow.)

`ShareMapSnapshotter` implementation, in acceptance order — **a raster is rejected
(`nil`) unless every step passes**:

1. **Input hygiene** (pure, package-tested `AuraKit` helpers): take
   `content.routeSegments` (the *same* filtered source the card's variant logic uses —
   never raw `Ride.segments`); drop non-finite coordinates; require ≥ 2 distinct
   coordinates and a bounding span above a small epsilon (a stationary "route" gets no
   map); decimate each segment to the raster's pixel budget (~600 points/segment,
   stride) before any Mapbox call.
2. **Cache read**: `TerrainSnapshotDiskCache` (reused from AuraKit, share-card
   directory) keyed by ride id + style + field size + scale. Hit → return. This is what
   makes History browsing cheap after first open.
3. **Style**: one shared resolution helper (new `MapStyle.snapshotSource` returning
   `.json(String)` or `.uri(StyleURI)`) mirroring `MapStyle+Mapbox`; the Home
   snapshotter is refactored onto the same helper so there is one copy of this
   decision, not three. `.standard` maps to `StyleURI.standard`.
4. **Style-load gate**: wait for `onStyleLoaded` with a 4 s timeout. **Timeout or
   `onMapLoadingError` (style/source/tile) → return `nil` without calling `start()`.**
   (Rev 1 copied Home's gate, which *proceeds* to render on timeout — that ships a
   blank map as a `.success`; Home's own comment admits "worst case blank". That
   outcome is exactly what this surface must never produce.)
5. **Camera**: `snapshotter.camera(for:padding: 24, bearing: 0, pitch: 0)`; **validate**
   the result — finite center, finite zoom (the Snapshotter variant has no error
   channel and can return NaN on degenerate input; note `min(zoom, 16)` propagates NaN
   depending on argument order, so the guard is `zoom.isFinite`, then clamp). Invalid →
   `nil`.
6. **Render, bounded**: `start(overlayHandler:)` raced against a 6 s timeout;
   on timeout call `snapshotter.cancel()` (SDK invokes the completion with an error)
   and return `nil`. The whole operation cooperates with task cancellation via
   `withTaskCancellationHandler` → `snapshotter.cancel()`. Strong-capture the
   snapshotter in the completion (the Home continuation-leak fix). Overlay: stroke each
   segment separately (never across pause gaps) via `pointForCoordinate`,
   `AuraTheme.routeUIColor`, **5 pt line width, unscaled** — the overlay context is
   already in points (rev 1 said "scaled by context scale"; that draws a 15 pt slug) —
   round caps/joins (matching `RouteThumbnail`'s treatment; `StaticRouteMap` uses Mapbox
   defaults, a sub-pixel difference at this width).
7. **Non-blank check** (the decisive backstop for slow-but-not-failing networks, where
   the style loads and tiles half-arrive): downsample the raster and require pixel
   variance above a threshold vs. a flat fill. The buffer math is a pure `AuraKit`
   function over `[UInt8]`, package-tested; the CG downsample wrapper lives with the
   snapshotter. Fails → `nil`, and **do not cache**.
8. **Cache write** only after acceptance (never memoize a blank — the Home snapshotter
   currently *does* cache blank rasters to disk; that latent bug is flagged separately
   and not widened here).

### Share flow — fallback first, upgrade in place

`RideSummaryView`'s `.task` becomes:

1. Build `ShareCardContent`; synchronously render the **fallback card**
   (`RideCardRenderer.make(content, mapImage: nil)`) — sub-frame, exactly today's
   speed — and set `shareImage`. **Share is enabled from the first frame.**
2. If `content.routeSegments` is non-empty, `await` the raster from the injected
   `ShareMapRasterProviding`. On acceptance (and `!Task.isCancelled`), re-render with
   the raster and swap `shareImage`.

This removes rev 1's dead-button window entirely (review: up to 6 s of disabled Share
with no affordance, and a permanently dead button if `start()` never called back after
backgrounding — both structurally impossible now: Share never waits on the network).
If the share sheet is already open during the swap, it keeps its own file — see
filenames. A raster that arrives after the rider shared the fallback is simply the
card they get next time; no retry UI.

### Filenames (fixes a real cross-ride race)

`RideCardRenderer` currently writes one fixed `tmp/Aura ride.png`. With an async window
between decision and write, two History sheets in quick succession can interleave —
preview showing ride B, file containing ride A. Each render now writes
`Aura ride <rideID> <generation>.png` (generation: fallback=0, map=1); stale share
PNGs (matched by prefix) are swept on renderer entry; writes are guarded on
`!Task.isCancelled`. `SharePreview` title becomes `"<distance> <unit> · <date>"`
instead of the generic "Aura ride".

### StatPair contrast note

The card pins `scrimText` to the high-contrast secondary because a fixed PNG can't
honor Increase Contrast — but `StatPair` hardcodes `AuraTheme.textSecondary` (0.62)
labels, so the no-route variant's labels violate the card's own rule today. `StatPair`
gains an optional `labelColor` (default unchanged) and the card passes the
high-contrast value.

### ROH-7 (single live renderer)

A `Snapshotter` is an off-map transient raster, the same category Home ships
(`MapboxTerrainSnapshotter` — "adds no persistent live renderer"). It runs briefly
alongside the summary's one live `StaticRouteMap`; that concurrency is new and its
memory spike (raster + SDK attribution composite + `ImageRenderer` pass + `pngData()`)
is bounded by the acceptance timeouts and measured during device verification.

### Error handling

| Failure | Behavior |
|---|---|
| Offline, style never loads | gate times out → `nil` **before** `start()` → polyline fallback (already shared-able) |
| Offline, bundled `auraTerrain` style loads but no tiles | `onMapLoadingError` and/or non-blank check → `nil` → fallback |
| Slow network, tiles partially arrive | non-blank check is the backstop; a partially-blank raster fails variance → `nil` |
| `start()` never completes (backgrounded mid-render) | 6 s race → `cancel()` → `nil`; Share was never blocked |
| Degenerate route (stationary, single point, NaN coords) | input hygiene / camera validation → `nil` → fallback |
| `.standard` misrenders through `Snapshotter` | verified on device; if broken, that style returns `nil` → **polyline fallback** (never a silently different map style than the screen behind it) |
| `ImageRenderer`/PNG write fails | `nil` share image → Share disabled (unchanged, now only reachable for the sync fallback render) |

### Testing

- **Package (AuraCore, runs in the agent gate):** existing `ShareCardContent` tests
  unchanged; new tests for the pure helpers — coordinate hygiene/decimation, camera
  validation predicate (incl. NaN zoom), non-blank variance function, cache key.
- **App-target logic behind the seam** (variant selection, upgrade-in-place) is
  exercised through previews with a stubbed `ShareMapRasterProviding` and verified on
  device; the repo has no app unit-test target and this change does not add one (named
  honestly — the pure kernels above carry the automated weight).
- **Previews:** map variant (fixture image at exactly 360×240@3x), polyline fallback,
  no-route, route-without-elevation, long destination (truncation), metric + imperial —
  plus the band fitting assertion (≤ 210 pt).
- **Device/simulator verification (all required):** golden-ride harness
  (`-auraSimulatedRide golden …`) to a real summary; pull the written PNG from the app
  container and inspect at full size **and at ~130 pt thumbnail scale**; share into
  Messages once; all **three** styles (`auraTerrain`, `dark`, `standard`); airplane
  mode → confirm the **polyline fallback actually renders** (not a blank map);
  slow-network (Network Link Conditioner) → confirm the non-blank check rejects a
  partial raster; measure time-to-upgrade on the ride-end path and record it in the PR.

## Risks

- **Mapbox Standard through `Snapshotter`** — least-exercised path; device-verified,
  and its failure mode is the fallback card, not a wrong-style map.
- **Non-blank threshold tuning** — too strict rejects legitimately sparse night-style
  areas, too loose ships partial rasters. Mitigation: threshold chosen against real
  captures of all three styles during verification; the pure function makes the
  boundary testable.
- **Two Mapbox render paths at once on the summary screen** — transient; measured on
  device during verification.
