# Explore Nearby Gems — Plan 3: The Detour (design)

**Linear:** ROH-59 (child of ROH-52, project *Interface & Feel*, epic ROH-50).
**Slice:** 3 of 4. Branch fresh off `main` `659e642`.
**Umbrella spec:** `docs/superpowers/specs/2026-07-04-explore-nearby-gems-design.md` (§ Detour).
This doc refines that section into concrete, buildable detail for Plan 3.

## Goal

Add the **"Take me there"** engage step and a **guided detour that overlays the
free ride**. Guidance to a gem is an *ephemeral overlay on the same `.freeRide`
session* — it never changes `Ride.Kind`, so the recorder, stats, and Live Activity
genuinely never restart. On arrival the guidance **detaches** (it does *not* end
the ride) and you are wandering again. The ride ends only when the rider ends it.

Non-goals for this slice (Plan 4): personal "return here" / `SavedPlace.resurface`,
the minimal live feed (Tier ≤ 2), cross-source priority arbitration, and the full
accessibility audit (hairline contrast / Reduce Motion sweep). Plan 3 honors Reduce
Motion on its *own* new transitions but does not re-audit Plan 2's surfaces.

## Key architectural findings (grounding)

These are load-bearing facts confirmed by reading the shipped code:

1. **`GuidanceViewModel` already exposes a settable `onArrive: () -> Void` closure.**
   `AuraKit/Guidance/GuidanceViewModel.swift`: on the `.arrivedAtDestination`
   event it calls `onArrive()` then returns. `NavigateHUDView` sets
   `guidance.onArrive = { endRide() }`. **The detour sets it to a *detach* closure
   instead.** No change is needed to `GuidanceEvent` or the arrival semantics: the gem
   is the detour route's sole (final) destination, so Mapbox fires `ToFinalDestination`
   → `.arrivedAtDestination` exactly as wanted (verified in `MapboxGuidanceSession.swift`
   arrival sink). **One defensive change *is* needed** — see the re-entrancy hardening in
   Review reconciliation §R1: `MapboxGuidanceSession.stop()` queues its teardown
   (`startFreeDrive`) on the *next* main-actor tick, so a rapid re-target that calls
   `start()` again could invoke `startActiveGuidance` on a trip session still in the
   old active-guidance state. The controller creates a **fresh guidance session per
   leg** and `start()` **defensively resets to free-drive** before `startActiveGuidance`.
2. **`RideSessionCoordinator` injects app-target concretes at init**
   (`screen`, `activity`, `workout`) and forwards every `TrackPoint` from its stream
   loop to `groupSink` and `discoverySink`. `finish()` and `cancel()` are the *only*
   ride-terminal calls; `stopStreaming()` nils sinks. This is the clean seam to also
   drive a detour controller and to detach on ride end.
3. **`GemDiscoveryStore.update(at:now:)`** fires `haptics.playGemSurfaced()` and sets
   `activeCard` when the engine surfaces a gem. That is where the detour must gate
   both the peek card and the Tier-3 haptic while guiding.
4. **No `CLHeading` usage exists today.** The map puck uses Mapbox's built-in
   `.heading`. The offline heading branch is *net-new* CoreLocation plumbing,
   `#if os(iOS)`-guarded (the package builds on the macOS host), and a device-verify
   item. `PeerBearing.heading(from:to:)` and `Geo.distance(_:_:)` already exist and
   are reused for arrow angle + straight-line distance.
5. **`GemCategory.arrivalRadiusMeters`** (Plan 2, implementer-invented):
   cafe/mural/landmark 30, water/historic 45, park/viewpoint/climb 70.
6. The process-level Mapbox nav provider (`AuraNavigation.provider`) is a singleton;
   during a free ride the app records from its own `LocationService` (a
   `CLLocationManager`), *not* a Mapbox trip session. Starting active guidance for the
   detour spins the Mapbox trip session up fresh; `teardown()` returns it to
   `startFreeDrive()` (warm, harmless). Two location consumers coexisting during a
   detour is asserted safe by the umbrella spec and is a **device-verify** item.

## Architecture

Layered exactly like the shipped gem stack: pure logic in AuraCore, `@MainActor`
seams in AuraKit, concretes in the app target, an `@Observable` controller driving
SwiftUI.

### Pure core — AuraCore (Sendable, no UIKit/Mapbox, unit-tested)

**`DetourPhase`** — `enum: inactive · routing(Gem) · guiding(Gem) · headingOnly(Gem)`,
`Equatable`, `Sendable`. Carries the target `Gem` in every active case.

**`DetourEvent`** —
`request(Gem)` · `routeReady` · `routeFailedOffline` · `networkRecovered` ·
`arrived` · `cancel` · `retarget(Gem)`.

**`DetourEffect`** —
`startRouting(Gem)` · `startGuidance(Gem)` · `startHeadingOnly(Gem)` ·
`stopGuidance` · `stopHeading` · `confirmArrival(Gem)` · `detached`.

**`DetourMachine`** — pure, static `reduce(_ phase:, on event:) -> (DetourPhase, [DetourEffect])`.
The complete transition table (any unlisted (phase, event) pair is a no-op returning
`(phase, [])`):

| From | Event | To | Effects |
|------|-------|----|---------|
| any | `cancel` | `inactive` | `stopGuidance`, `stopHeading`, `detached` |
| `inactive` | `request(g)` | `routing(g)` | `startRouting(g)` |
| `routing(g)` | `routeReady` | `guiding(g)` | `startGuidance(g)` |
| `routing(g)` | `routeFailedOffline` | `headingOnly(g)` | `startHeadingOnly(g)` |
| `guiding(g)` | `arrived` | `inactive` | `stopGuidance`, `confirmArrival(g)`, `detached` |
| `headingOnly(g)` | `arrived` | `inactive` | `stopHeading`, `confirmArrival(g)`, `detached` |
| `headingOnly(g)` | `networkRecovered` | `routing(g)` | `stopHeading`, `startRouting(g)` |
| `guiding(g)` / `headingOnly(g)` / `routing(g)` | `retarget(g2)` | `routing(g2)` | `stopGuidance`, `stopHeading`, `startRouting(g2)` |

Notes:
- `retarget` to the **same** gem currently active is a no-op (idempotent — guard on id).
- `routeFailedOffline` is only meaningful from `routing`; from other phases it is a no-op.
- The machine is pure: it decides *what* should happen; the AuraKit controller performs
  the Mapbox / heading side-effects. No `Date()`, no timers, no I/O.
- Arrival detection lives *outside* the machine: while `guiding`, the Mapbox
  `.arrivedAtDestination` event maps to `arrived`; while `headingOnly`, the controller
  compares `Geo.distance(rider, gem)` to `gem.category.arrivalRadiusMeters` on each
  location update and emits `arrived` when within radius.

### Seams — AuraKit (`@MainActor` protocols; concretes in the app target)

- **`DetourRouting`** — `func route(from origin: Coordinate, to destination: Coordinate) async throws -> Route`.
  App concrete `MapboxDetourRouting` wraps `MapboxRoutingProvider` with a single-leg
  cycling `RouteRequest`. A thrown error (offline / no route) drives `routeFailedOffline`.
- **`HeadingProviding`** — publishes the device compass heading in degrees (true north).
  `@MainActor`, an `AsyncStream<Double>` or an `@Observable` `currentHeading: Double?`.
  App concrete `CompassHeadingProvider` wraps `CLLocationManager.startUpdatingHeading()`
  / `CLHeading`, `#if os(iOS)`-guarded; a no-op stub elsewhere.
- Reuse **`GuidanceViewModel`** + injected **`GuidanceSession`** (prod =
  `MapboxGuidanceSession` unchanged; tests = `ScriptedGuidanceSession`).

### Controller — AuraKit (`@MainActor @Observable`)

**`GuidanceController`** owns the pure machine's `phase` and orchestrates side-effects.

Published (observable) state:
- `phase: DetourPhase`
- `turn: TurnCardState` — mirrored from the internal `GuidanceViewModel` while guiding.
- `headingArrow: HeadingArrow?` — `{ relativeBearingDegrees, straightLineDistanceMeters }`
  while `headingOnly` (arrow angle = bearing-to-gem − device heading).
- `destinationGem: Gem?` — the active target (nil when inactive).
- `arrivalBanner: Gem?` — set for ~2s by `confirmArrival`, then cleared (drives the
  arrival chip); one soft arrival haptic fired via the existing `HapticPlaying` seam.
- `isGuiding: Bool` — `if case .guiding = phase`. Read by the coordinator/arbiter.
- `isDetouring: Bool` — phase != inactive.

API:
- `requestDetour(_ gem: Gem, from origin: Coordinate)` — feeds `request(gem)`; on the
  `startRouting` effect, checks the per-gem route cache, else awaits
  `routing.route(from:to:)`; success → `routeReady`, throw → `routeFailedOffline`.
- `retarget(_ gem: Gem, from origin: Coordinate)` — feeds `retarget(gem)` (idempotent).
- `cancel()` — feeds `cancel`.
- `detach()` — coordinator-facing alias for `cancel()` used on ride `finish()`/`cancel()`
  (no arrival confirmation on ride end).
- `riderDidUpdate(_ point: TrackPoint)` — while `headingOnly`: recompute
  `headingArrow` (distance + relative bearing) and emit `arrived` when within radius;
  while `guiding`: no-op (Mapbox drives arrival). Also the network-recovery poll hook.
- Effect execution:
  - `startGuidance(g)`: set `guidance.onArrive = { [weak self] in self?.handleArrived() }`,
    `guidance.units`, `guidance.haptics`/`hapticsEnabled` (turn haptics), and
    `guidance.start(route:)`. **`onArrive` detaches; it never calls `finish()`.**
  - `stopGuidance`: `guidance.stop()` (which returns the Mapbox session to free-drive).
  - `startHeadingOnly(g)`: begin consuming `HeadingProviding`; seed `headingArrow`.
  - `stopHeading`: stop consuming heading.
  - `confirmArrival(g)`: set `arrivalBanner = g`, fire one soft haptic, schedule clear.
  - Route cache: keyed `(Gem.ID, quantizedOrigin)` where `quantizedOrigin` rounds the
    request origin to ~25 m; a cached route is reused only if the current origin is
    within ~25 m of the cached one, else refetched. This makes rapid same-spot
    re-toggles free without ever serving a stale route from a since-moved origin (§R5).
- **Networkrecovery** while `headingOnly`: on `riderDidUpdate` (throttled), retry
  `routing.route(...)`; on success feed `networkRecovered` (→ re-route → guiding).

`GuidanceController` imports no Mapbox — it depends only on the AuraKit
`GuidanceViewModel` + the two seams, so it is testable with scripted fakes.

### Coordinator integration — `RideSessionCoordinator`

- Add an **optional `guidance: (any GuidanceControlling)?`** stored property, injected
  at `init` (mirrors `workout`). `RideHUDView` builds a `GuidanceController` from app
  concretes and passes it; `NavigateHUDView` passes `nil`. (A narrow `GuidanceControlling`
  protocol keeps the coordinator free of the concrete + testable with a fake.)
- In the stream loop, after `discoverySink?.rideDidUpdateLocation(point)`, also call
  `guidance?.riderDidUpdate(point)`.
- `finish()` and `cancel()` call `guidance?.detach()` before teardown.
- Expose `var isDetouring: Bool { guidance?.isDetouring ?? false }` (the card/haptic
  arbiter) and `var isGuiding: Bool { guidance?.isGuiding ?? false }` (guiding-only).

### Haptic + card arbitration

`GemDiscoveryStore` gains an injected predicate `detourActive: () -> Bool`
(default `{ false }`), wired by `RideHUDView` to `{ coordinator.isDetouring }`. In
`update(at:now:)`, when `detourActive()` is true the store **suppresses the active
peek card and the Tier-3 gem haptic** for the whole detour — any active phase, not
just `guiding` — (still records the gem as seen and still publishes `visiblePins`, so
pins render and remain tappable → re-target). This keeps the cockpit calm during both
turn-by-turn and compass-only navigation; while `guiding` it additionally prevents
gem haptics from contending with `TurnHapticEngine` turn cues on the wrist. The
coordinator remains the source of truth; the store merely consults it. (`isGuiding`
is still exposed separately for anything genuinely guiding-only.)

### UI — app target (SwiftUI, design-skill-guided)

- **"Take me there" CTA** — a prominent AuraTheme button in `GemDetailSheet`, below
  `why`. Reachable without a hidden swipe (Dynamic Type-safe). On tap: dismiss the
  sheet and invoke an `onTakeMeThere: (Gem) -> Void` closure threaded from
  `RideHUDView`, which calls `requestDetour(gem, from: riderCoordinate)`.
- **Slim detour overlay** in `RideHUDView`, top-slotted so it does not collide with
  the back button or the (now-suppressed) peek card:
  - `guiding`: **turn banner** (reuse `TurnCardView` bound to `guidance.turn`) +
    **destination chip** (gem name · straight-line distance · **Stop** button →
    `cancel()`).
  - `headingOnly`: a **compass arrow** (rotated by `headingArrow.relativeBearing`) +
    straight-line distance + a subtle **"offline heading"** label, + the same Stop chip.
  - arrival: a brief **"Arrived — <gem name>" chip** (~2s auto-dismiss, driven by
    `arrivalBanner`) + one soft haptic.
  - Reduce Motion: arrow rotation and chip transitions degrade to no animation.
- **Detour route line** — `RideMapView` gains `detourRoute: [Coordinate]?`; a new
  `@MapContentBuilder detourPolyline` draws it bright/mint (`AuraTheme.routeUIColor`),
  and the recorded track dims (reduced opacity) while a detour is active, so the two
  lines read distinctly. Camera is never yanked.

### Reuse map

| Need | Reuse |
|------|-------|
| Turn-by-turn guidance | `GuidanceViewModel` (+ `MapboxGuidanceSession`) — set `onArrive` to detach |
| Route fetch | `MapboxRoutingProvider` via a single-leg `RouteRequest` (cycling) |
| Turn banner UI | `TurnCardView`, `ManeuverIcon` (ROH-48) |
| Route line on map | existing `routeRibbon` `@MapContentBuilder` pattern in `RideMapView` |
| Arrival / turn haptics | `HapticPlaying` / `HapticPlayer.shared` (coordinator-arbitrated) |
| Straight-line distance / bearing | `Geo.distance(_:_:)`, `PeerBearing.heading(from:to:)` |
| Offline heading | device `CLHeading` (net-new `HeadingProviding`) |

## Arrival radii — product pass

Keep Plan 2's values except **cafe 30 → 40 m** (on a bike you seldom stop at the exact
door; 40 m reads as "you're here"). Final: cafe 40, mural/landmark 30, water/historic
45, park/viewpoint/climb 70. Used only for the `headingOnly` arrival gate; Mapbox owns
arrival while guiding. Documented as device-tuned `static` constants (already on
`GemCategory`).

## Error handling / edge cases

- **Offline at tap** → routing throws immediately → `headingOnly` from the start.
- **Network recovers mid-`headingOnly`** → controller re-routes; on success upgrades to
  `guiding`; on repeated failure stays `headingOnly` (no thrash — retry is throttled).
- **Re-target** replaces the route immediately (cached per gem); no confirm dialog.
- **Ride ends mid-detour** (`finish()`/`cancel()`) → `detach()` stops guidance/heading
  cleanly, no arrival confirmation.
- **Backgrounding** → guidance (if active) continues; the arrival chip and gem surfacing
  pause while inactive per Plan 2; overlay detaches on ride end.
- **Arrival while already within radius at request time** (you tap a gem you're already
  next to) → `headingOnly`/`guiding` immediately reports `arrived` on the next update →
  a near-instant confirm chip; acceptable.
- **macOS package CI** → `CLHeading` / `CLLocationManager` heading APIs `#if os(iOS)`-guarded;
  `HeadingProviding` has a non-iOS no-op path.

## Testing

- **`DetourMachine`** (Swift Testing, deterministic, table-driven): every row of the
  transition table, plus `retarget`-same-gem idempotency, `routeFailedOffline` no-op
  from non-routing phases, and `cancel` from every phase.
- **`GuidanceController`** (with `ScriptedGuidanceSession` + fake `DetourRouting` +
  fake `HeadingProviding`): request→route→guide happy path; `onArrive` detaches and
  never calls a ride-terminal path; route cache avoids refetch; offline → headingOnly →
  straight-line `arrived` within radius; `networkRecovered` upgrade; retarget swaps route.
- **Arbitration**: with a fake guidance flag true, `GemDiscoveryStore.update` suppresses
  card + T3 haptic but still marks seen + publishes pins.
- **Coordinator**: `finish()`/`cancel()` call `detach()`; each stream point forwards to
  `guidance?.riderDidUpdate`.
- **Device-verify (sim can't drive GPS)** via the route-playback recipe: live
  turn-by-turn on the detour, arrival→detach with the ride still recording and stats
  unbroken, offline heading arrow + affordance, Tier-3 haptic suppression while guiding.
  Spawns Device Verification follow-ups as needed.

## Files (anticipated)

New (AuraCore): `Gems/Detour/DetourPhase.swift`, `DetourEvent.swift`, `DetourEffect.swift`,
`DetourMachine.swift`.
New (AuraKit): `Gems/Detour/DetourRouting.swift`, `HeadingProviding.swift`,
`GuidanceControlling.swift`, `GuidanceController.swift`.
New (app): `Routing/MapboxDetourRouting.swift`, `Ride/CompassHeadingProvider.swift`,
`Ride/DetourOverlay.swift` (turn banner + destination chip + heading arrow + arrival chip).
Edited: `RideSessionCoordinator` (+`guidance`, forward, detach, `isGuiding`),
`GemDiscoveryStore` (+`guidanceActive` predicate), `GemDetailSheet` (+CTA),
`RideHUDView` (build controller, thread CTA, host overlay, pass `detourRoute`),
`RideMapView` (+`detourRoute` + `detourPolyline`, dim track), `GemCategory` (cafe radius).

## v1 scope (this slice)

**In:** `DetourMachine` + `GuidanceController`, `DetourRouting` + `HeadingProviding`
seams, "Take me there" CTA, slim detour overlay (turn banner + destination chip +
Stop), detour route line + dimmed track, gems keep surfacing as *pins* (cards/T3
haptics suppressed while guiding), re-target, detach-on-arrive with brief confirmation
+ soft haptic, offline `headingOnly` fallback with affordance and network-recovery
upgrade, arrival-radius product pass.

**Out (Plan 4):** personal "return here"/`resurface`, minimal live feed, cross-source
priority arbitration, full a11y audit.

## Review reconciliation (2026-07-05 adversarial pass)

Hardened after a 3-lens adversarial spec review (correctness/skeptic, rider-UX/safety,
architecture/edge-case), each with a refuting mandate. Material changes folded in:

**R1 — Mapbox re-entrancy on re-target (was: "no change needed").** `MapboxGuidanceSession.stop()`
finishes the stream and defers teardown (`startFreeDrive`) to the next main-actor tick,
so a rapid stop→start (re-target) could call `startActiveGuidance` on a trip session
still in the prior active-guidance state (shared process singleton `AuraNavigation.provider`).
Mitigation: (a) `GuidanceController` owns a `makeGuidanceViewModel: () -> GuidanceViewModel`
**factory** and builds a *fresh* view-model + session per leg (`startGuidance`), dropping
the old one on `stopGuidance`; and (b) `MapboxGuidanceSession.start()` **defensively calls
`startFreeDrive()` immediately before `startActiveGuidance`** to force a known state
regardless of pending teardown. Both the factory seam and the defensive reset are in scope.
Test: re-target twice in quick succession starts guidance for the *second* gem only.

**R2 — Stale async route completion after cancel/re-target.** `requestDetour`/`retarget`
await `DetourRouting.route(...)`; the phase can change during the await (Stop, or a newer
re-target). The controller MUST, before feeding `routeReady`, verify the phase is still
`routing(g)` **with the same gem id and the same request generation**; otherwise discard
the resolved route as stale. `(inactive, routeReady)` and `(inactive, routeFailedOffline)`
are documented no-ops (reachable only via stale completions). Implement with a monotonic
`requestGeneration` counter bumped on every `request`/`retarget`/`cancel`. Test:
cancel-mid-routing then late route success starts no guidance.

**R3 — `riderDidUpdate` TOCTOU.** Snapshot `(phase, destinationGem, requestGeneration)`
at method entry and use the snapshot throughout, so a concurrent transition can't make it
compute a `headingArrow` for, or emit `arrived` against, a gem that is no longer the target.

**R4 — Effect idempotency.** All `DetourEffect` executions are idempotent: `stopGuidance`
with no live session is a no-op, `stopHeading` with no live consumer is a no-op, a second
`detached` is harmless. The `(any, cancel)` row may fire redundant stops; that is safe by
construction. Stated so implementers don't add guards that hide bugs.

**R5 — Route cache keyed by origin, not gem alone.** See body: `(Gem.ID, quantizedOrigin~25 m)`.

**R6 — `riderCoordinate` threading + nil policy.** `GemDetailSheet` has no store ref, so
the `onTakeMeThere` closure is built in `RideHUDView` (which owns both `coordinator` and
`gems`) and reads `gems.riderCoordinate` at tap time: `onTakeMeThere: { gem in
guard let c = gems?.riderCoordinate else { return }; coordinator.guidance?.requestDetour(gem, from: c) }`.
If `riderCoordinate` is nil (no fix yet), the **"Take me there" button is disabled** with a
subtle "waiting for GPS" state — never route from `Coordinate.zero` (Null Island).

**R7 — `detourActive` predicate isolation.** The predicate is a `@MainActor`-isolated
`() -> Bool` invoked synchronously inside `GemDiscoveryStore.update(at:now:)` (already
`@MainActor`); it must do no async work and only read the coordinator's `isDetouring`
computed property. Documented to avoid a strict-concurrency capture error.

**R8 — `HeadingProviding` lifecycle (pick one).** `HeadingProviding` vends
`func headings() -> AsyncStream<Double>` (degrees, true north). `startHeadingOnly` spawns a
consuming `Task` stored on the controller; `stopHeading` **cancels it** (no leak). App
concrete `CompassHeadingProvider` wraps `CLLocationManager` heading updates, `#if os(iOS)`;
a non-iOS stub yields nothing. The protocol + controller stay CoreLocation-free (macOS CI).

**R9 — Ride-end sequencing.** In `finish()`/`cancel()`, call `guidance?.detach()`
**before** `stopStreaming()`. `detach()` feeds `cancel` (not `arrived`) → no arrival
confirmation on ride end. `onArrive`'s `handleArrived` feeds the `arrived` event to the
machine (drives `confirmArrival` + `detached`); it is only reachable while a leg is live.

**R10 — Sendable / platform.** `DetourPhase`, `DetourEvent`, `DetourEffect`, `HeadingArrow`,
`Gem`, `TurnCardState` are all `Sendable`. Platform guards live only in the app concrete
`CompassHeadingProvider`; the AuraKit protocol/controller are platform-agnostic.

**R11 — Arrival test determinism.** `headingOnly` arrival uses `Geo.distance ≤ radius`;
tests place the arrival sample well inside the radius (≥50% margin) to avoid float-boundary
flake. No schema change (no V5) — the detour and its route are ephemeral, never persisted;
`Ride.track` continues to record every point (detour and wander alike) as one continuous track.

**R12 — Stop ≠ End Ride (safety).** The detour **Stop** control lives on the top
destination chip (not the bottom `ControlCluster`), uses a **neutral/secondary** treatment
(never the pink `.destructive` role of End Ride), and is wired to `guidance?.cancel()`.
VoiceOver label "Stop detour" (distinct from "End ride"). This keeps the ephemeral action
positionally and visually unmistakable from the terminal one.

**R13 — Concrete overlay slot.** Because peek cards are suppressed during a detour (arbiter),
the only top occupants are the corner back button (topLeading) and GPS chip (topTrailing);
the **turn banner sits top-center in the safe area (~8 pt), mirroring `NavigateHUDView`'s
turn card**, with the destination chip directly below it. No collision with the speedometer
(bottom cockpit) or the corner chips. Tapping a visible pin during a detour opens the detail
sheet above the banner → deliberate 2-tap re-target (chosen over 1-tap pin-swap to prevent
accidental route changes while moving).

**R14 — Offline `headingOnly` honesty (safety).** The offline branch is a **direction-and-
distance pointer, explicitly NOT turn-by-turn**: it shows a compass arrow + straight-line
distance + a persistent "Offline · approximate direction" affordance, so a rider never
mistakes crow-flies for street guidance. It upgrades to real guidance on network recovery.
Kept in v1 scope (PO-requested) with this honest framing; it is a primary device-verify item.

**R15 — Deliberate exits only (no auto-abandon).** The detour ends on **arrival, Stop, or
ride end** — there is intentionally no distance/time auto-cancel. Rationale: a rider legitimately
loops a block or backtracks; an auto-give-up would false-positive and annoy. The always-present
one-tap **Stop** is the escape hatch. (A future distance-based "you rode away" nudge is a
possible Plan 4 refinement, explicitly deferred.)

**R16 — Two location consumers (device-verify, not blocker).** During a detour the app's
`LocationService` (its own `CLLocationManager`/`liveUpdates`) keeps feeding the recorder while
Mapbox runs its trip session on *its own* location provider. iOS supports independent
`CLLocationManager` consumers — each owns its accuracy/mode, so there is no shared-instance
clobbering and no second location prompt; the real cost is extra GPS duty-cycle/battery for
the (bounded) detour, which is acceptable. This remains the **top device-verify checkpoint**:
confirm continuous recording, no stats break, and no duplicate-permission UI on a real ride.

### Test list additions (from the pass)
- Stale route after `cancel`/`retarget` → no guidance for the abandoned gem (R2).
- Re-target twice rapidly → guidance targets only the final gem; fresh session per leg (R1).
- `onArrive` detaches and never calls a ride-terminal path; ride keeps recording (R9).
- `finish()`/`cancel()` mid-detour → `detach()` before `stopStreaming()`, no arrival chip (R9).
- `headingOnly` arrival deterministic within radius; `networkRecovered` upgrades to guiding (R11).
- Arbiter: while detouring, `update` suppresses card + T3 haptic but still marks seen + pins (unchanged).
