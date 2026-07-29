# ROH-126 — Shareable ride card redesign: real map background, distance off the map

**Linear:** [ROH-126](https://linear.app/rohun/issue/ROH-126/redesign-shareable-post-ride-card-real-map-background-distance-off-the)
**Date:** 2026-07-29

## Problem

The post-ride summary screen reads well: a real map with the route, then the distance
hero, the elevation band, and the supporting stats. The image produced by **Share**
does not match it, and it has two defects a rider actually notices:

1. **The distance sits in an opaque tile on top of the route.** `ShareCardView.overlayBlock`
   draws the date line and the distance hero on `AuraTheme.surface` at full opacity,
   anchored bottom-leading over the route field. Any route that passes through that corner
   is hidden.
2. **The map background is gone.** The card draws only the bare polyline
   (`RouteThumbnail`, a `Canvas`) on the flat app background. The header comment explains
   why: the card renders offscreen through `ImageRenderer`, and a live Mapbox `Map` view
   cannot render there.

That second constraint is stale. The Home screen already renders offscreen map rasters
with `MapboxMaps.Snapshotter` (`MapboxTerrainSnapshotter`), which draws a full styled map
to a `UIImage` with no live map view. The same mechanism can give the share card a real
map.

## Goals

- The shared image shows the route on a real map raster, in the rider's chosen map style,
  visually consistent with the summary screen's `StaticRouteMap`.
- Nothing opaque covers the map. The distance moves out of the map field entirely.
- The card degrades gracefully: if the snapshot cannot be produced (offline, style load
  failure, timeout), the card falls back to the current polyline-only look — minus the
  opaque tile — and sharing still works.
- The card remains a deterministic 1080×1350 (4:5) PNG: Dynamic Type pinned, no live
  views, unit-testable content unchanged.

## Non-goals

- No change to the summary screen itself, `ShareCardContent`'s data fields, the share
  payload (PNG file URL), or the no-route card variant's structure.
- No new user-facing options (e.g. picking a share style).
- No History-thumbnail or widget changes; `RouteThumbnail` stays as-is for those callers.

## Approaches considered

**A. `MapboxMaps.Snapshotter` raster + route overlay (chosen).** Render the map field
offscreen with `Snapshotter`, fit the camera with `snapshotter.camera(for:padding:…)`,
and stroke the route segments in the `start(overlayHandler:)` callback, which hands us a
`CGContext` plus a `pointForCoordinate` converter. Matches the summary map (same style
resolution as `MapStyle+Mapbox`), works offline-degraded, keeps everything on-device,
and reuses a pattern the codebase already trusts (`MapboxTerrainSnapshotter`).

**B. Mapbox Static Images API.** A network fetch of a server-rendered map. Rejected:
requires the public token in a URL, a second styling pipeline that will drift from the
app styles (the authored `auraTerrain` JSON isn't hosted), and it's weaker offline.

**C. Snapshot the live `StaticRouteMap` view on the summary screen.** Rejected: couples
the share image to the on-screen view's size, load timing, and visibility; flaky by
construction, and the summary map's 240 pt frame is not the card's map field.

## Design

### Components

**`ShareMapSnapshotter` (new, `Aura/Sources/Ride/ShareCard/`)** — `@MainActor` enum (or
small struct) with one async entry point:

```swift
static func image(segments: [[Coordinate]], size: CGSize, scale: CGFloat,
                  style: AuraKit.MapStyle) async -> UIImage?
```

- Builds `MapSnapshotOptions(size:pixelRatio:)` at the card map field's point size with
  `pixelRatio` 3 so raster pixels match `RideCardRenderer`'s scale-3 output.
- Resolves the style exactly as `MapStyle+Mapbox` does: `.auraTerrain` → the bundled
  authored JSON via `AuraTerrainStyleLoader`, falling back to stock dark when missing;
  `.dark`/`.standard` → the corresponding `StyleURI`.
- Waits for `onStyleLoaded` with a timeout gate (same shape as
  `MapboxTerrainSnapshotter`, including the strong-capture-of-snapshotter fix so the
  continuation can't leak).
- Camera: `snapshotter.camera(for: allCoords, padding: 24 pt, bearing: 0, pitch: 0)`,
  zoom clamped to ≤ 16 to mirror `StaticRouteMap`'s overview fit.
- Route: in `overlayHandler`, stroke each segment as its own path (never connect across
  a pause gap) using `pointForCoordinate`, `AuraTheme.routeUIColor`, 5 pt width scaled
  by the overlay context's scale, round caps and joins — matching `StaticRouteMap`'s
  polyline.
- Returns `nil` on any failure; no caching (each ride is shared at most a handful of
  times, and the temp PNG itself is the cache).
- Mapbox logo and attribution are composited into the snapshot by the SDK; the design
  keeps the map field's bottom edge clean (no gradient or overlay) so attribution stays
  legible, which the Mapbox ToS requires on exported map images.

**`ShareCardView` (redesigned layout)** — gains a `mapImage: UIImage?` parameter next to
`content`. Still a dumb, static 360×450 pt projection. Three variants:

- **Map variant** (`hasRoute && mapImage != nil`): the map raster full-bleed at the top
  of the card, ~230 pt tall, `scaledToFill` + clipped; no text, tile, or scrim over it.
- **Polyline fallback** (`hasRoute && mapImage == nil`): identical layout with
  `RouteThumbnail` in the map field, as today but with no overlay tile.
- **No-route variant**: unchanged centered composition.

The readout band below the map field (~220 pt) now carries everything the tile used to,
echoing the summary screen's order:

1. Context line — date · destination, caption, tracked, secondary.
2. Distance hero — `speedHero` value with unit, sized to fit the band (≈48 pt value; the
   exact size is an implementation detail, but the full band must fit 450 pt with no
   truncation in previews for both metric and imperial and long destination names).
3. Elevation block — climbed caption + `ElevationSparkline`, when elevation exists.
4. Bottom row — moving time `StatPair` (plus climbed `StatPair` when there is no
   sparkline), with the AURA wordmark trailing-aligned on the same baseline row to
   reclaim vertical space.

**`RideCardRenderer`** — `make` becomes
`make(_ content: ShareCardContent, mapImage: UIImage?) -> RideShareImage?`; still
synchronous and `@MainActor`. The async snapshot happens before it, in the caller.

**`RideSummaryView`** — the existing `.task` becomes: build `ShareCardContent`; `await
ShareMapSnapshotter.image(…)` when the ride has a route (style from
`settings.mapStyle`); then `RideCardRenderer.make(content, mapImage:)`. The Share button
stays disabled until the image exists, exactly as today; the snapshot path always
resolves (timeout → `nil` → fallback card), so the button can't be stuck disabled by a
network stall for more than the gate timeout.

### Data flow

```
Ride ──> ShareCardContent (pure, AuraCore — unchanged fields)
Ride.segments ──> ShareMapSnapshotter (async, Mapbox) ──> UIImage?
(content, mapImage) ──> ShareCardView ──> RideCardRenderer (ImageRenderer @3x) ──> PNG file URL
```

`ShareCardContent` stays free of UIKit/Mapbox so its unit tests keep running in the
package; the raster is app-layer state passed alongside it.

### Error handling

| Failure | Behavior |
|---|---|
| Offline / tiles or style fail to load | style-load gate times out → snapshot `nil` → polyline fallback card |
| Style JSON missing/unreadable (`auraTerrain`) | falls back to stock dark URI (same as Home) |
| Snapshot API returns failure | `nil` → fallback card |
| `ImageRenderer` or PNG write fails | `nil` share image → Share stays disabled (current behavior, unchanged) |

### Testing

- **Package (AuraCore):** `ShareCardContent` tests unchanged — no field changes.
- **Previews:** map variant (stub `UIImage` fixture), polyline fallback, no-route,
  route-without-elevation, long destination + metric units — all must fit 360×450
  without clipping.
- **Device/simulator verification (required by repo rules):** open a saved ride's
  summary from History, let the share render complete, pull the written
  `tmp/Aura ride.png` from the app container, and inspect: map imagery visible, route
  stroked on it, nothing covering the map, attribution legible, band content complete.
  Verify once in `auraTerrain` and once in `standard` style, plus airplane-mode run to
  see the fallback.

## Risks

- **Mapbox Standard style through `Snapshotter`** (style-import based) is the least
  exercised path; verified explicitly on device. If it renders wrong, the snapshotter
  can substitute stock dark for `.standard` without blocking the release of the fix.
- **Snapshot latency** adds up-front delay before Share enables (network fetch of
  tiles). Bounded by the load gate timeout; acceptable because the button is already
  render-gated today.
- **Attribution overlap**: the band content never enters the map field, and the map
  field bottom edge has no overlay, so the SDK-composited attribution stays legible.
