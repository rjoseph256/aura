# ROH-7 — Single hoisted Mapbox map across the navigation flow

Status: approved (PO, 2026-07-16). Approach and scope confirmed before spec.

## Goal

One live Mapbox renderer, mounted once and retained across the whole ride flow,
instead of a fresh map built and torn down on every navigation transition.
Camera state carries across surfaces rather than resetting.

## The problem (measured from the code, 2026-07-16)

There is no shared map today. Four live SwiftUI `Map` instances exist, each
declared inside a `.navigationDestination` closure, so SwiftUI builds a new
Mapbox `MapView` (new GL renderer, fresh style load, reset camera) on every push
and destroys it on every pop:

| Surface | File | Kind |
|---|---|---|
| Free-ride map | `Aura/Sources/Ride/RideMapView.swift:46` | live `Map(viewport:)` |
| Navigate HUD map | `Aura/Sources/Ride/NavigateHUDView.swift:231` | live `Map(viewport:)` |
| Route preview map | `Aura/Sources/Plan/RoutePreviewView.swift:76` | live `Map(viewport:)` |
| Ride summary map | `Aura/Sources/Ride/StaticRouteMap.swift:21` | live but `.allowsHitTesting(false)` |

Home's backdrop is already a still `Snapshotter`
(`Aura/Sources/Home/MapboxTerrainSnapshotter.swift:24`), deliberately not a live
renderer, and its docstring already names the ROH-7 invariant.

Home → preview → navigate mounts up to three separate maps in sequence. Each
seeds its own `@State viewport`, so camera state does not carry across. The
comment at `Aura/Sources/AuraApp.swift:76-77` claims transitions no longer rebuild
the map; that is the goal state, not the current implementation. This spec makes
it true.

## Decision: approach (approved)

**A single SwiftUI `Map` hoisted into `RootView`, driven by a shared
`@Observable` model.** The map is mounted once as the base layer of a `ZStack`
below the `NavigationStack`, so no push/pop can unmount it. Ride surfaces stop
constructing a `Map` and become chrome overlays that publish map intent.

Rejected alternatives:

- **One UIKit `MapView` via `UIViewRepresentable`.** A single `UIView` cannot be
  in two destination views at once; during push/pop both are briefly mounted, so
  the shared view detaches and flickers. It also forces an imperative rewrite of
  every polyline, annotation, and puck, discarding the declarative content that
  works today. Higher risk, more code, no additional benefit.
- **Full imperative Mapbox rewrite** (style/layer/annotation-manager API end to
  end). Maximum blast radius for no gain over the above.

## Decision: scope (approved)

**In scope — the three full-bleed live surfaces** collapse onto the one hoisted
map: free-ride (`RideMapView`), route preview (`RoutePreviewView`), navigate HUD
(`NavigateHUDView`). This is where the rebuild cost, style reload, and camera
reset actually occur.

**Explicitly out of scope, left exactly as-is:**

- **Ride summary** (`StaticRouteMap`, 240 pt inset inside a `.sheet`). Different
  framing, already non-interactive, already ROH-7-neutral. Routing a sheet-inset
  card through a full-bleed background map fights the model for no benefit.
- **Home backdrop** (`MapboxTerrainSnapshotter`). A still image by deliberate
  design choice; replacing it with a live renderer would regress that choice.

Non-goals: no visual redesign, no new map features, no change to the authored
terrain style (ROH-46), no change to routing/guidance.

## Architecture (ownership made explicit)

### `RideMapModel` — the single source of truth (AuraKit, `@MainActor @Observable`)

Holds everything the one map renders:

- `surface: MapSurface` — `.idle` / `.freeRide` / `.preview` / `.navigate`
- `camera: MapCameraIntent` — `.followPuck(bearing:)` / `.overview(coordinates:)` /
  `.none`; resolved to a `Viewport` by the view layer
- `routeLine: RouteLineState?` — geometry plus the lit/dimmed progress split
- `detourLine: [Coordinate]?`
- `peers: [RidePeer]`, `nameMap`, `selfProgress`
- `gems: [Gem]`, `seenGemIDs`, `onSelectGem`
- `puck: PuckMode` — `.hidden` / `.heading`
- `interactive: Bool` — preview and the HUDs allow gestures; `.idle` does not

Style is not stored: it stays read from `SettingsStore.mapStyle` exactly as today
(`MapStyle+Mapbox.swift:10-17`), so the ROH-46 authored terrain style keeps
flowing from one place.

The model is pure state plus small pure resolvers. It owns no Mapbox type, so it
unit-tests in the package on the macOS CI host.

### `HoistedRideMap` — the one map view (app target)

The moved content builder, reading the model: `Puck2D`, the route ribbon
(lit/dimmed split, from `RideMapView.swift:87-119`), the detour polyline
(`:123-132`), peer `MapViewAnnotation`s → `PeerDotView`, gem `MapViewAnnotation`s
→ `GemPinView`, and `.mapStyle(settings.mapStyle.mapboxStyle)`. Mounted once in
`RootView`'s `ZStack` beneath the `NavigationStack`.

### Surfaces become chrome

`RideHUDView`, `RoutePreviewView`, `NavigateHUDView` keep all their chrome (turn
card, trip strip, speed rail, control clusters, route-options sheet, gem cards,
group roster/toasts) and drop their `Map` and their `@State viewport`. Each
publishes intent to the model on `.onAppear` and restores the previous surface on
`.onDisappear`, so a pop returns the map to the surface underneath.

### Interaction and hit-testing (the hard part)

The base map receives pan/pinch. Each destination renders over it with a clear
background and hit-tests only on its controls — the same layering each HUD
already uses over its own map today, lifted one level. Explicit rule: a
destination's background layer sets `.allowsHitTesting(false)`; controls sit in
overlays that hit-test normally.

### Camera continuity (the payoff)

One camera on the model. Preview's overview-fit animates into navigate's
follow-puck instead of resetting; a pop from navigate back to preview restores
the overview. Recenter (`NavigateHUDView.swift:285-293`) sets the model's camera
intent rather than a local `@State`.

## Testing

Pure, in-package (Swift Testing, the established pattern):

- surface transition table: appear/disappear ordering leaves the expected surface
  owning the map, including push and pop
- camera intent resolution per surface, and that a preview → navigate transition
  requests follow-puck without an intervening reset
- route-line lit/dimmed split derivation, detour passthrough
- peer and gem passthrough, including the solo (no group) and no-gems paths
- `interactive` is false only for `.idle`

View wiring and interaction are simulator-verified (below); they are not
unit-testable.

## Verification (device-first, per project norm)

On the iPhone 17 / iOS 26 simulator, driving a real flow:

1. Home → free ride → back → preview → navigate: the map is **retained** — no
   restyle flash, no camera reset between surfaces.
2. Gestures still work on every live surface (pan, pinch), and chrome controls
   still receive their taps (recenter, mute, end ride, route option rows).
3. Peer dots and gem pins still render on the hoisted map (group + gems paths).
4. Reroute still redraws the live polyline on the navigate surface.
5. Ride summary sheet still shows its own inset map (untouched), and Home still
   shows the snapshot backdrop (untouched).

## Risks

- **Regression surface is every live map.** Gestures, peer/gem rendering, reroute
  polyline, and camera behavior are the danger zones. Mitigated by the adversarial
  spec/plan reviews, per-task TDD, whole-branch review, and the sim pass above.
- **Chrome background transparency.** A destination that keeps an opaque
  background will hide the map. Caught by verification step 1.
- **Hit-testing inversion.** Getting `.allowsHitTesting` wrong either eats map
  gestures or eats control taps. Caught by verification step 2.
- **Sheet-presented summary** covers the map while up; the map must not be
  disturbed underneath. Verified by step 5 plus returning to root after dismiss.
- **`.onDisappear` ordering.** SwiftUI does not guarantee appear/disappear
  ordering across a transition; the surface stack must be explicit (a push sets
  the new surface; a pop restores the prior one) rather than relying on
  disappear-clears-state. Pinned by the transition-table tests.
