# Interactive Home Map (ROH-84) — Design

**Linear:** [ROH-84](https://linear.app/rohun/issue/ROH-84) · **Epic:** Summary & Map Polish
**Date:** 2026-07-20 · **Status:** Approved (brainstorming), reconciled after 3-reviewer adversarial spec review

## Summary

Make the Home screen map something a rider can move: pan and pinch-zoom to look
around their area, scout terrain, and check a specific place before a ride. Today
the Home backdrop is an inert, cached terrain image hardcoded to downtown
Pittsburgh. This work turns it into a genuine, movable map that opens framed on the
rider's current location, keeps Home's signature Aura terrain look, and preserves
Home's current low-power *untouched-idle* behavior.

To make "check a specific place" real (rather than a pan-by-eye scavenger hunt), a
**light assist** is in scope: tapping a search result or a Saved place flies the map
to it, and Saved places render as pins. Deeper discovery (gems, route tracing, "ride
here from the map") stays the Explore surface's job (ROH-50).

## Locked decisions (from brainstorming + reviews)

1. **Genuine pan + pinch-zoom.** No rotation, no pitch. North-up. Zoom bounded
   (roughly neighborhood-out to street-level-in).
2. **Keeps the authored Aura terrain style** (identity), shared with today's snapshot.
3. **Camera persists within an app session.** The map stays where the rider left it
   while the app lives; a recenter control returns to the rider on demand. It resets
   to the rider only on a **cold app launch** or **after a completed ride** — never
   while the rider is looking at Home. There is **no idle-timeout camera reset**.
4. **Light "check a place" assist in scope:** search-result / Saved-place tap →
   fly-to; Saved places shown as pins. No gems, no route tracing.
5. **Approach B** (snapshot idle → live map on interaction), chosen and re-confirmed
   below.

## Background & prior decisions this touches

- **ROH-43** (Home reinvention) made the backdrop a cached Snapshotter image,
  deliberately not a live map. This work keeps that image as the resting state and
  adds a live map on interaction.
- **ROH-7** (single hoisted map, Canceled) failed on a live map placed *outside* the
  `NavigationStack` having its touches swallowed. **Correction from review:** what
  actually lets touches reach Home's backdrop is the dashboard sheet's
  `.presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))`
  (`Aura/Sources/Home/HomeSheet.swift:39`), *not* NavigationStack placement. This
  changes the gesture design (see Controls).
- **ROH-83** (idle Home low-power / release location, open) — this design keeps the
  *untouched* idle state renderer-free and GPS-free, and adds explicit teardown, but
  it does **not** claim a blanket "location off when leaving Home" (the ride path
  legitimately keeps location on — see Location lifecycle).

## Current implementation (as-is)

- `Aura/Sources/Home/HomeView.swift` — root content of the app's single
  `NavigationStack` (`AuraApp.swift` `RootView`). `ZStack`: `HomeBackdrop` bottom;
  header + `HomeLaunchBand` above; `SearchOverlay` when expanded; an always-present
  dashboard sheet (`.homeDashboardSheet`) peeking ~250pt, raisable to `.large` by the
  Saved chip (`HomeView.swift:100`). `HomeBackdrop` is passed `riderCoordinate: nil`
  (`HomeView.swift:88`).
- `HomeBackdrop.swift` — `Image(uiImage:)` from `renderer.image(for:size:)`; no
  hit-testing, no gestures.
- `MapboxTerrainSnapshotter.swift` — `MapboxMaps.Snapshotter`, disk-cached PNG,
  **hardcoded `pixelRatio: 3` (`:22`)** and **hardcoded `zoom: 12.5, pitch: 0`
  (`:38`)**, authored bundled style via `styleJSON` (`:28`) else `dark-v11`.
- `AuraCore/.../Home/TerrainSnapshotRequest.swift` — `center(forRider:) = rider ??
  curatedDefaultCenter(40.4406,-79.9959)`. **cacheKey quantizes center to a ~1.1 km
  grid (`quantizationDegrees = 0.01`, `:11,21-27`)** — so a cached image can be up to
  ~0.8 km from the true center. No zoom field on the request.
- `TerrainSnapshotDiskCache.swift` — `read`/`write`/`url` only; **no eviction / size
  cap** (files live in OS-evictable `Caches/`).
- `LocationService.swift` — `current()` is one-shot (cached <30 s, else 3 s-timeout
  race, else Pittsburgh). Home's only call is inside `refreshWeather()`, **gated on
  `authorization == .authorized`** (`HomeView.swift:141-143`) — so an unauthorized
  user triggers no `current()` today.
- Reusable live-map infra: MapboxMaps v11 SwiftUI `Map(viewport:)` + `Viewport` +
  `@MapContentBuilder` + `Puck2D` in `RideMapView.swift`, `NavigateHUDView.swift`,
  `RoutePreviewView.swift`; static reference `StaticRouteMap.swift`. **All existing
  live maps use `.followPuck` / `.overview` viewports only — none uses a fixed
  `.camera(center:zoom:)`, `onCameraChanged`, `MapReader`, or `onStyleLoaded` on a
  live `Map`.** Those are net-new for this feature. `App` retains Home beneath pushed
  routes (`AuraApp.swift:75-77`).

## Approach B (snapshot idle → live on interaction)

The backdrop is a two-phase surface.

- **Idle** — the cached snapshot PNG (rendered per the fixes below), now centered on
  the rider. No live renderer, no standing GPS. Carries a visible **"tap to explore"**
  affordance so the rider knows it is interactive.
- **Live** — a MapboxMaps v11 `Map(viewport:)` at the authored Aura terrain style,
  mounted when the rider activates the map, with the location puck (see Location
  lifecycle).

**Why B over always-live (A/C):** because idle shows a static image with no renderer,
the *common* ride-start path (rider taps "start ride" from a resting Home) has no live
Home map to collide with the ride's map — so the single-renderer invariant holds in
the common case. Always-live variants hold a Home renderer at every ride-start,
guaranteeing a two-map window. B's cost is the idle↔live seam, addressed below.

### First-touch interaction (fixes lost-gesture + discoverability)

A freshly mounted SwiftUI/UIKit view does **not** receive an already-in-flight touch,
so "start panning a static image and have a live map pick it up mid-drag" is not
achievable — the first drag would be lost. Instead the idle map is explicitly
**tap-to-activate**: a visible affordance ("tap to explore" / a subtle control)
invites a tap; the tap mounts the live map at the current camera; the rider then pans.
This turns the unavoidable mount boundary into a designed, discoverable gesture rather
than a dropped-first-pan bug.

### Idle→live handoff (fixes pixel-ratio + quantization jump)

Two root causes would otherwise make the handoff visibly jump:

1. **Pixel ratio.** The snapshot is `pixelRatio: 3`; a live `Map` renders at device
   scale. On 2× devices, label/glyph/stroke sizing differs. Fix: render the
   on-appear/interactive snapshot at the **device screen scale**, not a hardcoded 3.
2. **Center quantization.** The cache key rounds center to a ~1.1 km grid, so the
   idle image may be offset from the rider's true `current()` coordinate, while the
   live map opens at the true coordinate. Fix: render the rider-centered idle snapshot
   at the **true center** (a precise-center render path that bypasses / tightens the
   quantized cache for the on-appear image).

Even with both fixed, exact pixel-identity across a raster→live cross-fade is not
guaranteed by any in-repo precedent. The transition is therefore designed as a
**tasteful short cross-fade** (snapshot held beneath the live map until the live
`Map`'s style is ready, then faded out; hard cut under Reduce Motion) that tolerates
minor differences — not a promise of an invisible swap. Whether a tighter
zero-artifact handoff is achievable is a **device spike** (see Risks).

### Camera model & session persistence

- A shared **default-zoom constant** (net-new; today `12.5` is a literal in the
  snapshotter) is threaded to both the snapshot request (gaining a zoom field) and the
  live `Viewport` so they cannot drift.
- **Session persistence:** while the app is alive and Home is retained, the live
  camera the rider leaves is preserved and restored when they return to Home (the
  retain-beneath architecture already keeps Home mounted, so this is the natural
  behavior). On **cold launch** and **after a completed ride**, the camera resets to
  the rider's current location at default zoom. No idle-timeout reset.
- **Recenter control:** a floating button appears in the live phase once the camera
  has moved off the rider (detected via `onCameraChanged` — net-new; the ride
  recenter's follow-puck state logic does *not* transfer, only its visuals). Tap →
  animate the viewport to the rider at default zoom. Hidden/disabled without a usable
  fix.

### Lifecycle & teardown (fixes retain-beneath multi-renderer window)

Because pushing a route **retains** Home (`AuraApp.swift:75-77`), teardown cannot rely
on unmount. Instead:

- The live phase is **gated on Home being top-of-stack and the scene active**
  (`router.path.isEmpty` + `scenePhase`). Net-new: Home has no scenePhase observer
  today.
- On any navigation push (ride start, History, Settings) the map flips **to idle
  synchronously before/at the push** so Home is showing the static snapshot (no
  renderer) by the time the pushed screen's map mounts — closing the two-map window.
  Starting a ride mid-pan must specifically force idle before `router.push`.
- On backgrounding, tear down to idle.
- Teardown must be **ordering-safe**, not merely idempotent: a new `Map` must not
  mount before the previous `MapView`'s GPU context releases on rapid leave/return.
  This is a **device spike** (see Risks).

### Location lifecycle (fixes puck-provider leak + ROH-83 over-claim)

- **Centering:** one-shot `LocationService.current()` on the relevant Home appearances
  (cold launch, post-ride). This is **net-new plumbing** — `HomeBackdrop` is currently
  fed `nil`, and today's `current()` call is gated on authorization, so an
  unauthorized user needs a distinct code path. `current()` may take up to 3 s or fall
  back; the idle snapshot renders at the fallback first and re-centers when the fix
  lands (a brief idle-side re-frame, acceptable, animated).
- **Puck:** the live map's `Puck2D` is driven by Mapbox's **own** internal
  `LocationProvider` (a separate `CLLocationManager`), not `LocationService`. The
  design must **explicitly start it only in the live phase and stop it on teardown**;
  "no `LocationService` subscription" is not the same as "no location running."
- **ROH-83 scope, corrected:** the acceptance test is "leaving Home **to History /
  Settings** releases location (indicator off)" — *not* the ride path, where location
  legitimately stays on and the indicator cannot distinguish a leak. Verifying the ride
  path requires confirming exactly one location consumer is alive after the transition
  (instrumentation, not the indicator).

## Controls, gestures & layout coexistence

- **Gestures:** pan + pinch-zoom only; rotation and pitch disabled; zoom bounded.
- **Sheet detents (corrected):** background interaction reaches the map only up
  through the sheet's `0.55` fraction. At the **`.large` detent** (Saved chip)
  background interaction is disabled — the map is intentionally inert there. The spec
  treats "map interactive" as a function of detent, and the design must define behavior
  at each detent rather than assume the map is always live.
- **Gesture precedence (must be explicit, not "in the gaps"):** define who wins for
  (a) a vertical drag near the sheet's top edge (sheet expand vs map pan), (b) a pinch
  spanning a floating chip and open map, (c) taps on header / launch-band / search
  controls. Floating controls consume their own hits; the map receives pans/pinches
  only in the uncovered region above the peek.
- **Usable area:** after the ~250pt peek and the top header + launch band, the clean
  interactive band is roughly a third of the screen. Acceptable for "look around," and
  the fly-to assist (below) reduces reliance on long manual pans.

## "Check a place" assist (in scope)

- **Search → fly-to:** selecting a result in the existing `SearchOverlay` flies the
  live map to that coordinate (activating the live phase if idle).
- **Saved-place pins:** Saved places render as lightweight map annotations; tapping a
  pin flies to / focuses it. Reuses the existing saved-places store and the ride maps'
  annotation patterns.
- Out: gems, route lines, turn-by-turn, "ride here" — Explore's job.

## Style

Live map loads the authored `AuraTerrainStyle.json` via `MapStyle(json:)` (same JSON
and same `dark-v11` fallback as the snapshotter), so idle and live match. Close-zoom
legibility of a style authored for a single zoom-12.5 snapshot is an unknown —
device-verify checkpoint; `dark-v11` fallback covers a hard failure (at the cost of
the signature look).

## Cache growth (fixes unbounded disk use)

Once snapshots follow the rider, the coordinate-quantized cache accumulates a
full-screen PNG per grid cell × size × style version. Add a **bound** (LRU or a simple
size/count cap with eviction) to `TerrainSnapshotDiskCache`, rather than relying on
unpredictable OS `Caches/` eviction (which can also purge mid-session and stall a
re-render).

## Error handling & edge cases

- **Location denied / timeout:** replace the silent Pittsburgh fallback with a
  **visible state** — a small "Location off — showing a default area · Enable"
  affordance — so a rider in another city understands why the map isn't on them and
  can act. Interactivity still works.
- **Authored style fails on live map:** fall back to `dark-v11`.
- **Handoff:** snapshot held beneath live map until style-ready, then cross-fade (hard
  cut under Reduce Motion).
- **Rapid leave/return during live:** ordering-safe teardown (see Lifecycle) — no
  renderer leak, no double-mount.
- **In-flight snapshot vs live mount:** a tap arriving while the on-appear `Snapshotter`
  is still rendering must not leave both a `Snapshotter` and a live `Map` active;
  cancel/await the snapshot before/at live mount.

## Components & boundaries

- **AuraCore (pure, macOS-CI-safe, unit-tested):**
  - `center(forRider:)` resolution and the shared default-zoom constant.
  - A pure **phase reducer**: `idle ↔ live` over abstract triggers (activate,
    push/top-of-stack change, background, permission state) — no Mapbox/CoreLocation
    types leak in; those are mapped to abstract inputs at the app boundary.
- **App target (device-verified + as much XCUITest as practical):**
  - Snapshot render (device-scale, true-center), the live `Map` view + authored style +
    puck + Saved-place annotations + fly-to, recenter, gesture config, cross-fade,
    scenePhase/router-path teardown wiring, cache bound.

## Testing

- **Unit (AuraCore):** center resolution; phase reducer across all triggers
  (activate, top-of-stack change during a push, background, permission changes).
- **Instrumented / device-first — the load-bearing properties, explicitly covered
  (not left to "optional"):**
  - Exactly one live Mapbox renderer across a Home-live → ride-start transition (the
    multi-renderer invariant) — verified by instrumentation/logging, since XCUITest
    can't assert renderer count.
  - Location released when leaving Home **to History/Settings** (indicator off); one
    location consumer after leaving to a ride (instrumented).
  - Handoff has no gross jump; recenter returns to rider; fly-to lands on the target;
    Saved pins appear; map inert at `.large` detent; "tap to explore" discoverable.
- **XCUITest (where feasible):** map region hit-testable in live phase; recenter
  appears after panning; search result fly-to.

## Risks / device spikes (run early in execution)

1. **Teardown/mount ordering** — confirm a synchronous flip-to-idle before push
   actually prevents a two-renderer overlap given SwiftUI update timing and async
   MapboxMaps `MapView` teardown. If it can't be guaranteed, revisit the approach.
2. **Handoff seam** — confirm device-scale + true-center render brings the cross-fade
   within acceptable visual tolerance; if not, fall back to a more overt transition.
3. **Close-zoom legibility** of the authored style.

## Out of scope (YAGNI)

- Gems, discovery, route tracing, "ride here from the map" — Explore's job (ROH-50).
- Rotation / pitch / 3D.
- Persisting the camera across cold launches or across a completed ride (both reset by
  design).

## Open follow-ups (not blocking)

- Zoom-aware authored-style tweak if close-zoom reads poorly (separate ticket).
- "Panning Home flows into Explore" — a natural additive follow-up once this canvas
  exists; deliberately deferred.
