# Interactive Home Map (ROH-84) — Design

**Linear:** [ROH-84](https://linear.app/rohun/issue/ROH-84) · **Epic:** Summary & Map Polish
**Date:** 2026-07-20 · **Status:** Approved (brainstorming)

## Summary

Make the Home screen map something a rider can move: pan and pinch-zoom to look
around their area, scout terrain, and check a specific place before a ride. Today
the Home backdrop is an inert, cached terrain image hardcoded to downtown
Pittsburgh. This work turns it into a genuine, movable map that opens framed on the
rider's current location — while keeping Home's signature Aura terrain look and its
current low-power idle behavior.

Discovery (gems, route-planning, "ride here from the map") is explicitly **not** in
scope — that stays the job of the Explore surface (ROH-50). Home stays lightweight:
pan/zoom only.

## Background & prior decisions this reverses

- **ROH-43** (Chunk 1, Home reinvention, Done) made the Home backdrop a cached
  Mapbox Snapshotter image, deliberately *not* a live map, to keep the sheet/gesture
  surface free and avoid a live renderer on Home. This spec keeps that cached image
  as the resting state but adds a live map on demand (see Approach B).
- **ROH-7** (single hoisted Mapbox map, Canceled) failed because it placed a live
  `Map` *outside* the `NavigationStack`, where the UIKit navigation container
  swallowed its touches. **That failure does not apply here:** Home's backdrop
  already lives *inside* the `NavigationStack` root (`HomeView` is the root content),
  which is the safe side of the line ROH-7 tripped over.
- **ROH-83** (idle Home should stay low-power / release location, High, open) is
  *advanced* by this design, not regressed — the interactive map is mounted only
  while in use.

## Current implementation (as-is)

- `Aura/Sources/Home/HomeView.swift` — root content of the app's single
  `NavigationStack` (`AuraApp.swift` `RootView`). A `ZStack`: `HomeBackdrop` at the
  bottom, a header + `HomeLaunchBand` above it, a `SearchOverlay` when expanded, and
  an always-present dashboard sheet (`.homeDashboardSheet`) peeking ~250pt at the
  bottom.
- `Aura/Sources/Home/HomeBackdrop.swift` — renders `Image(uiImage:)` from
  `renderer.image(for:size:)`. No hit-testing, no gestures. Doc: "a cached,
  non-interactive rendered image (never a live Map)".
- `Aura/Sources/Home/MapboxTerrainSnapshotter.swift` — `MapboxMaps.Snapshotter`,
  disk-cached PNG by `request.cacheKey`, fixed camera `zoom: 12.5, pitch: 0`, loads
  the authored bundled style JSON (`AuraTerrainStyle.json`, ROH-6) via `styleJSON`,
  else falls back to `dark-v11`.
- `AuraCore/Sources/AuraKit/Home/TerrainSnapshotRequest.swift` — center is
  `center(forRider:) = rider ?? curatedDefaultCenter(40.4406, -79.9959)`. **Home
  passes `riderCoordinate: nil`, so it always renders Pittsburgh, not the rider.**
- Reusable live-map infra (MapboxMaps v11 SwiftUI `Map(viewport:)` + `Viewport` +
  `@MapContentBuilder` + `Puck2D`): `RideMapView.swift`, `NavigateHUDView.swift`,
  `RoutePreviewView.swift`; static-map reference `StaticRouteMap.swift`
  (`.allowsHitTesting(false)`). Style bridge `MapStyle+Mapbox.swift`. Token set once
  at launch (`AuraApp.swift`).
- Location: `LocationService.current()` is one-shot (cached fix < 30s, else a 3s-timeout
  race, else Pittsburgh fallback). Home holds **no** continuous location subscription
  today — `current()` is called once for the greeting weather only.

## Approach (B — snapshot idle, live on touch)

The backdrop is a two-phase surface bridged by a shared camera.

Alternatives considered and rejected: **(A) always-live map** — simplest, but a live
renderer + standing GPS run the whole time Home is on screen even when untouched;
regresses ROH-83. **(C) live only while foregrounded** — still pays the full idle
cost on every Home visit. B is the only option that preserves Home's current
zero-cost idle state.

### Phases

- **Idle** — the existing cached snapshot PNG, now centered on the rider. No live
  renderer, no standing GPS. Shown on Home appearance and whenever the map is not
  actively in use.
- **Live** — a MapboxMaps v11 `Map(viewport:)` at the authored Aura terrain style
  with a location puck, mounted on first touch.

### Shared camera

A single camera value (`center` + `zoom`) is the bridge. The snapshot renders at
that camera; when the live map mounts, its `Viewport` opens at the **same** camera
so there is no positional jump. The still snapshot stays painted beneath the live
map until the live style finishes loading (`onStyleLoaded`), then cross-fades out.
Reduce Motion → hard cut, no fade.

Default zoom is the snapshot's current `12.5`; a shared constant is used by both the
snapshot request and the live viewport so they cannot drift.

### Lifecycle

- **Home appear** — one-shot `LocationService.current()` resolves the camera center
  to the rider's location (reuses the call Home already makes; no new standing
  subscription). Idle snapshot renders there. This is the "always reset to me"
  behavior: every Home appearance re-centers on the rider.
- **Idle → Live** — first touch on the map area transitions to the live phase.
- **Live** — pan/zoom freely; the puck's location updates run only in this phase.
- **Live → Idle (teardown)** — triggers: navigation away from Home (ride start,
  History, Settings), app backgrounding, or the map sitting untouched past a short
  idle timeout. Teardown unmounts the live map and releases its location. Because we
  always reset to the rider on the next appearance, no camera is persisted.

## Controls & gestures

- **Gestures:** pan + pinch-zoom only. Rotation and pitch are **locked off** (calm,
  north-up "look around"). Zoom bounded to roughly neighborhood-out to street-level-in.
- **Recenter control:** a small floating button (reusing the ride maps' recenter
  affordance) appears in the live phase once the rider has moved off-center; tapping
  animates the viewport back to the rider's location at default zoom. Absent in idle
  (idle is already centered on the rider).
- **Coexistence with existing Home layout:** the map is interactive only in the open
  area *above* the dashboard sheet's ~250pt peek. The dashboard sheet, launch band
  ("Where to?" + Explore/Join/Saved chips), header cluster, and search overlay are
  unchanged — they keep floating above the map and capture their own touches; map
  pans happen in the gaps. The only change to the existing `ZStack` is that the
  backdrop becomes hit-testable in the live phase.

## Style

The live map loads the authored `AuraTerrainStyle.json` via `MapStyle(json:)` (the
same JSON the snapshotter uses), so idle and live are visually identical. On load
failure, fall back to `dark-v11` — the snapshotter's existing fallback.

## Error handling & edge cases

- **No location permission / fetch timeout:** `current()` already falls back to the
  curated Pittsburgh center. Interactivity still works, just not centered on the
  rider; recenter is hidden or disabled without a usable fix.
- **Authored style fails on the live map:** fall back to `dark-v11`.
- **Handoff flash:** snapshot stays beneath the live map until `onStyleLoaded`, then
  cross-fades (hard cut under Reduce Motion).
- **Rapid leave during live:** teardown is idempotent; no renderer leak.
- **Close-zoom legibility of the authored style:** the authored style was tuned for a
  single zoom-12.5 snapshot; how it reads when zoomed in is the one genuine unknown —
  a device-verify checkpoint, with the `dark-v11` fallback covering a hard failure.

## Components & boundaries

- **AuraCore (pure, unit-tested):**
  - Camera-center resolution (extends the existing `center(forRider:)`) and the
    shared default-zoom constant.
  - A pure phase-transition reducer: `idle ↔ live` given the trigger inputs (touch,
    navigation-away, background, idle-timeout). Testable with no Mapbox dependency.
- **App target (device-verified):**
  - The idle snapshot render (existing `HomeBackdrop` / `MapboxTerrainSnapshotter`,
    changed only to center on the rider).
  - The live `Map(viewport:)` view, its authored-style + puck content, the recenter
    control, gesture configuration, and the cross-fade handoff.

## Testing

- **Unit (AuraCore):** camera-center resolution; phase-transition reducer across all
  triggers.
- **Device-first (per project norm):** handoff has no visible jump; pan/zoom smooth;
  rotation/pitch absent; recenter returns to the rider; authored style legible at
  close zoom; and — proving the ROH-83 tie — the iOS location indicator goes **off**
  when leaving Home.
- **XCUITest (optional):** the map region is hit-testable in the live phase; the
  recenter control appears after panning.

## Out of scope (YAGNI)

- Gems, discovery, route-planning, "ride here from the map" — Explore's job (ROH-50).
- Persisted camera across Home visits (contradicts "always reset to me").
- Rotation / pitch / 3D.

## Open follow-ups (not blocking)

- If the authored style reads poorly at close zoom, a zoom-aware style tweak is a
  separate ticket.
- "Panning Home flows into Explore" is a natural additive follow-up once this
  interactive canvas exists — deliberately deferred.
