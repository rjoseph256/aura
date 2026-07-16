# ROH-7 — Single hoisted Mapbox map across the navigation flow

> **STATUS: REJECTED at the adversarial spec-review gate (2026-07-16).**
> The design below was PO-approved in outline, then failed a three-reviewer
> adversarial review before any code was written. It is retained as the record of
> why ROH-7 should not be built in this architecture. **Do not implement it.**
> The verdict and the errors in this spec are catalogued in the section at the
> bottom; read that first.

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

---

# Review verdict (2026-07-16): REJECTED — do not implement

Three independent reviewers (skeptic / architecture / rider-experience lenses,
each given a refuting mandate) reviewed this spec against the code before any
implementation. They converged. Summary of why ROH-7 should not be built as
designed — and why no sound variant exists in the current architecture.

## Fatal: the topology cannot receive touches

`NavigationStack` is backed by `UINavigationController`. Its container hierarchy
(`UILayoutContainerView` → `UINavigationTransitionView` →
`UIViewControllerWrapperView` → the destination's hosting view) is plain UIKit.
`UIView.hitTest(_:with:)` returns `self` for any in-bounds point unless a subview
claims it — **fill transparency is irrelevant; only `isHidden`, `alpha`, and
`isUserInteractionEnabled` matter.** `.allowsHitTesting(false)` is a SwiftUI
modifier scoped inside the destination's hosting view; it has no reach over the
nav container. A map mounted outside the `NavigationStack` therefore **cannot
receive pan/pinch** — the gestures die in the navigation container.

Making this work would require subclassing or swizzling the nav container's
`hitTest`. `Aura/Sources/App/SwipeBackGesture.swift:13-14` already documents that
this codebase holds exactly one piece of UIKit navigation introspection, by
deliberate constraint.

The alternative topology (one UIKit `MapView` shared via `UIViewRepresentable`
inside each destination) fails differently: a `UIView` has one superview, so
across a push — where both destinations are briefly mounted — the shared map
detaches and flickers. **Both topologies fail. That is the core result.**

## Fatal: purity and behavioural fidelity are mutually exclusive

Both HUDs read the **live** `Viewport` to drive the recenter control —
`RideHUDView.swift:238` and `NavigateHUDView.swift:377`:
`ControlCluster(isFollowing: viewport.followPuck != nil, …)`. Mapbox *mutates*
that binding to `.idle` when the rider pans; that is how recenter lights up.

A write-only `MapCameraIntent` set by the chrome has no channel for "the user
panned," so `isFollowing` would be permanently true after a recenter: the button
stays dark and its VoiceOver value reports "Following" while the map sits parked
elsewhere. Fixing it requires the model to hold `MapboxMaps.Viewport` — but
`AuraCore` declares no Mapbox dependency, has zero SwiftUI/UIKit imports, and
targets macOS for CI. So the model cannot live in the package, which deletes the
entire Testing section that justified the design.

## Self-defeating: the perf argument inverts

The map is mounted once and never unmounted, so at `.idle` — Home, History,
Settings, i.e. most of the app's runtime — a full-screen Mapbox GL renderer runs
**permanently behind Home's opaque snapshot backdrop**
(`HomeBackdrop.swift:22-52`), invisible and unusable. Today Home runs **zero**
live maps; `MapboxTerrainSnapshotter.swift:7-8` exists precisely to keep it that
way. `interactive: Bool` gates gestures, not rendering.

Avoiding that regression means detaching the renderer at idle — which
reintroduces the create/destroy cost the hoist exists to remove. And free-ride
and navigate never transition into each other (`RideHUDView.swift:28-30`: free
rides are solo by construction), so with preview unfixable (below) the hoist
buys almost nothing.

## Scope premise was factually wrong

`RoutePreviewView` is **not** full-bleed. `RoutePreviewView.swift:47-56` is a
`VStack` of a ~55% `mapPane` over an opaque `bottomPanel`
(`.background(AuraTheme.background)`, `:142`) that cannot be transparent — route
rows need a readable surface. Its overview fit (`:311-329`) computes
`geometryPadding` against the **pane's** bounds; against a full-screen map the
route re-centers and its lower half renders behind the opaque panel. Preserving
today's framing needs a chrome-inset channel this design lacks — and making
preview full-bleed *is* the visual redesign the spec lists as a non-goal.

## Other confirmed defects

- **Push animation regresses.** Outside the stack, the map cannot participate in
  the push transition: it appears by un-occlusion (static, already at the new
  camera) while only chrome slides. Every ride-flow transition visibly changes.
- **`popToRoot()` strands the map.** `NavigateHUDView.swift:165-166` and
  `RideHUDView.swift:131` take `path` from depth 2 to 0 in one transaction; the
  "pop restores the previous surface" model assumes single-level pops and would
  leave the map at `.preview` with a stale polyline while the rider is at Home.
  `AppRouter.handle(url:)` (`:34`) replaces `path` wholesale — neither push nor pop.
- **The group path has no push/pop.** `GroupRideFlowView.swift:28-89` is a
  `@ViewBuilder` switch on `session.phase` inside one stack entry; lobby→riding
  fires no navigation event, so the transition model has nothing to hang on.
- **Camera "continuity" is a regression, not a payoff.** Every camera path is
  Reduce-Motion gated today (`NavigateHUDView.swift:285-293`,
  `RideHUDView.swift:273-281`, `RoutePreviewView.swift:61-65`); `MapCameraIntent`
  carries no animate flag. An overview→follow-puck fly at ride start is precisely
  the motion Reduce Motion suppresses, and it lands at the worst moment (rider
  moving into traffic). The camera **reset** is load-bearing: without it, a new
  preview shows the *previous* ride's camera under the "Finding bike routes…"
  skeleton.
- **One `routeLine` field cannot express three different lines** — recorded track
  (`RideMapView.swift:89-118`, width 6), planned/rerouted route
  (`NavigateHUDView.swift:237-248`, width 6), candidate route
  (`RoutePreviewView.swift:77-88`, width **5**).
- **Hoisting deletes implicit per-mount resets.** `previousPeerCoordinates`
  (`RideMapView.swift:26`, `NavigateHUDView.swift:65`) dies with the map today; on
  an app-lifetime map, ride 2's first peer dots derive `PeerBearing` cones against
  ride 1's last fix.
- **Accessibility unaddressed.** Gem pins are real `Button`s (`GemPinView.swift:25`);
  hoisted outside the stack they are VoiceOver-reachable from Home, and chrome/map
  traversal order across the ZStack boundary is undefined.
- **The transition-table tests are tautological.** They assert the model's own API
  in an order the test author chooses; the hazard is that *SwiftUI* chooses the
  order, which is unobservable from a package test on macOS.

## Errors in this spec, for the record

- Claimed `AuraApp.swift:76-77`'s comment was aspirational. It is not: it says
  pushing retains **the screen beneath**, which is true today. The spec's
  motivation rested partly on a misreading.
- "Home → preview → navigate mounts up to three separate maps" — it mounts **two**;
  Home mounts zero.
- "Four live `Map`s each declared inside a `.navigationDestination` closure" —
  false for `StaticRouteMap`, which is in a `.sheet`; the spec contradicts itself
  20 lines later.
- Verification listed an "8-`ViewAnnotation` budget"; the real cap is `pinCap = 10`
  (`AuraCore/Sources/AuraCore/Gems/GemDiscoveryEngine.swift:11`).

## Recommendation

**Close ROH-7 as won't-do.** There is no demonstrated rider-visible problem — no
flash, jank, dropped frames, battery measurement, or bug report motivates it, and
the surviving benefit (one style load per deliberate ride push, behind a push
animation) does not justify re-plumbing every live map surface, the a11y tree, and
group/gem state through a shared app-lifetime model.

If a rider-visible symptom is ever observed, reopen with that evidence and
re-scope from it. The one latent hazard worth noting independently: a
permanently-mounted map would re-read the terrain style JSON from disk on every
navigation event (`AuraTerrainStyleLoader.swift:7-12` does `String(contentsOf:)`
per call, re-invoked because `RootView.body` re-evaluates on every `path` change);
today that is saved only by `MapStyle` being `Equatable` and the JSON comparing
equal. That is a latent flash bug in any future hoist attempt.
