# Explore — live in-ride nearby gems (ROH-52)

- **Issue:** [ROH-52](https://linear.app/rohun/issue/ROH-52) — Explore discovery, Sub-project 2 (nearby gems)
- **Epic:** Interface & Feel
- **Date:** 2026-07-04
- **Status:** Approved (PO), **hardened by adversarial spec review 2026-07-04** (3 reviewers: feasibility, rider/UX, architecture). See [Review reconciliation](#review-reconciliation).

## Context

The free-ride ("Explore") surface auto-starts a recorded ride and shows the
redesigned cockpit (ROH-49), but a directionless ride leaves most of the screen
as inert terrain map. The umbrella vision (ROH-50) proposed three ways to make
Explore a discovery surface. Fog-of-war coverage (ROH-54) was deprioritized after
the PO cooled on the metaphor. This spec picks up the **nearby gems** pillar,
reframed around a sharper intent from the PO interview:

> Discovery is **live and in-ride**, not plan-then-go. You start cruising like
> today, and as you move the world reveals itself — interesting places surface
> ambiently around you, gently, without ever hijacking the ride.

This reframe **decouples ROH-52 from the parked browsable shell**: the ROH-49
auto-start HUD stays as is, and gem discovery is a layer on top of it.

## Non-goals

- Not fog-of-war / coverage rendering (parked in ROH-54).
- Not a pre-ride browsable "discovery map" shell (the auto-start entry is unchanged).
- Not loop/route generation (ROH-53, its own bet).
- Not gems during a *group* ride in v1 (see [Group rides](#group-rides--annotation-budget)).
- Not live-feed **photos** or the optional chime in v1 (curated photos only; haptic only).

## The experience (approved)

Tapping Explore still auto-starts a free ride (ROH-49 untouched). Layered on top:

**Tiered surfacing.** A gem's rank decides how intrusive it is:

| Tier | Treatment |
|------|-----------|
| 1 | A quiet pin on the map (ambient only) |
| 2 | Rises to a soft, self-dismissing peek card |
| 3 | Peek card **+** a haptic |

Only **curated** gems and **personal** markers can reach Tier 3. **Live-feed gems
cap at Tier 2** — we don't trust their prominence enough to buzz the wrist.

**Pins are persistent and directly tappable.** Every gem in range is a pin. The
pin is the durable, accessible object; the peek card is only a *shortcut* that
rises for Tier 2/3. Tapping **either the pin or the card** opens the detail sheet,
so a missed card-tap never loses a gem — the pin is still there. The peek card has
a **minimum visible floor** (≥ ~6 s) before it may self-dismiss.

**Seen gems look different.** Once a gem has actively surfaced (card/haptic), its
pin renders in a quieter "seen" style (dimmer / hollow) so the map honestly signals
it won't peek again — it stays a tappable pin. Personal markers never enter the
seen-quiet state.

**Rhythm (the restraint model).** Two separate layers:
- *Ambient* — pins populate freely (subject to the annotation cap).
- *Active* — cards/haptics are **one at a time**, **cooldown-spaced**, gated by
  tier, and **never repeated within a ride**. Across rides, a surfaced gem goes
  **pin-only** (personal markers exempt — always Tier 3, always resurface).

**Engage (pin/card → detail → go).**
1. Tap a pin or card → detail sheet: name, category, distance, climb, a photo if
   one exists, a one-line "why".
2. Tap **"Take me there"** → guidance to the gem.

**The detour, not a new trip.** Guidance to a gem is an **ephemeral overlay on
the same `.freeRide` session** — it never changes `Ride.Kind`, so the recorder,
stats, and Live Activity genuinely never restart. Slim turn banner + destination
chip over the unchanged Explore cockpit; gems keep surfacing en route (you can
re-target); on arrival the guidance **detaches** (it does *not* end the ride) and
you're wandering again. The ride ends only when you end it.

**"Return here".** A one-tap "mark this spot" control drops a personal marker at
your current location (no map-precision gesture — unsafe while riding), and the
detail sheet offers "Save to return" for a surfaced gem. Each is a `SavedPlace`
with a `resurface` flag, so it appears in Saved Places *and* behaves as a Tier-3
gem. Auto-named by reverse-geocode with a timestamp fallback; editable later.

## Architecture

Follows shipped patterns: pure logic in AuraCore, `@MainActor` seams in AuraKit,
concrete providers in the app target, an `@Observable` store driving SwiftUI.

### Pure core — AuraCore (Sendable, no UIKit, unit-testable)

- `Gem` — value type: `id` (**stable, source-namespaced `String`** — see
  [Persistence](#persistence--state)), `coordinate` (`Coordinate`), `name`,
  `category` (`GemCategory`), `tier` (`GemTier`), `source`
  (`GemSource`: curated / personal / live), optional `photo` reference (a bundled
  asset name for curated; `nil` otherwise in v1), optional `why`.
- `GemCategory` — viewpoint, water, park, cafe, mural, climb, historic, … each
  with a default tier weight and an **arrival radius** (see edge cases).
- `GemTier` — `.pin` (1) / `.card` (2) / `.cardHaptic` (3), + treatment mapping.
- `GemDiscoveryEngine` — **the heart.** Pure and **timestamp-driven**: its "now"
  is the timestamp of the location sample it's fed (never `Date()`/timers), so it
  is deterministic in tests. Given `(location, sampleTimestamp, candidateGems,
  state)` it returns a `DiscoveryDecision`: `visiblePins` (already capped to
  nearest N) and an optional `activeSurfacing(Gem, treatment)`. Owns proximity
  gating, cooldown, one-at-a-time, don't-repeat, tier→treatment, priority
  arbitration, and the annotation cap.
- `DiscoveryState` — per-ride seen set + last-active timestamp, seeded at ride
  start from the cross-ride `SeenGemStore`.
- Tunables (`proximityRadius`, `approachRadius`, `cooldown`, `pinCap`) are named
  `static let` constants on the engine, documented as device-tuned.

### Detour — a `GuidanceController` on the coordinator (rewritten post-review)

Guidance is **orthogonal to `Ride.Kind`**. The `.freeRide` coordinator gains an
optional `GuidanceController` (the detour lives on `RideSessionCoordinator`, which
already owns the session lifecycle and `finish()`/`cancel()` — *not* on the
discovery store):

- State machine: `wandering → routing → guiding(gem) → wandering`, plus a
  `headingOnly(gem)` branch when routing is unavailable (offline). Pure +
  timestamp-driven; transitions on route-fetched / arrival / cancel / re-target.
- Reuses `GuidanceViewModel` + `MapboxGuidanceSession` + `MapboxRoutingProvider`,
  but with an **`onArrive` that detaches guidance instead of calling `endRide()`**
  (the current `NavigateHUDView` wiring ends the ride — the detour needs a new
  init/config that returns to `wandering`). The process-level Mapbox trip session
  is free during a free ride, so starting/stopping it for the detour is safe.
- **Haptic arbitration lives here:** while `guiding`, the coordinator suppresses
  gem Tier-3 haptics so `TurnHapticEngine` cues own the wrist (both fire through
  `HapticPlayer.shared`; the coordinator is the single arbiter). Gem cards still show.
- Overlay lifecycle is tied to the coordinator: `finish()`/`cancel()` detach any
  live guidance; re-target replaces the route (cached per-gem to avoid refetch on
  toggling).

### Seams — AuraKit (`@MainActor` protocols; impls in the app target)

- `GemProviding` — `func gems(near region:) async -> [Gem]`.
  - `CuratedGemProvider` — decodes a bundled metro gem set (validated at decode;
    invalid tiers/entries dropped, not trusted).
  - `PersonalGemProvider` — resurface-flagged `SavedPlace`s → Tier-3 gems.
  - `LiveGemProvider` — **in v1 (minimal):** OSM Overpass / Mapbox category POIs
    → Tier-1/2 pins, no photos, region-fetched + cached. Keeps the map alive
    everywhere.
  - `CompositeGemProvider` — merges + dedupes on `Gem.id`; region-caches.

### Discovery store — AuraKit (`@Observable @MainActor`)

- `GemDiscoveryStore` — subscribes to the ride's location stream, pulls candidates
  from the composite provider, feeds the engine (passing each sample's timestamp),
  publishes `visiblePins` + `activeSurfacing`, fires the `HapticPlaying` seam for
  Tier 3, and writes the cross-ride seen-set. It **requests** a detour from the
  coordinator's `GuidanceController` but does not own guidance. **Gated off when a
  group session is present** (see below) and while the scene is inactive
  (background): it keeps consuming samples but suppresses active surfacing; pins
  reconcile on resume.

### UI — app target (SwiftUI, design-skill-guided)

- Gem layer in `RideMapView` via `@MapContentBuilder` (`MapViewAnnotation` +
  `GemPinView`, styled by tier/category/seen-state). The store hands over the
  **already-capped** nearest-N list — the render pass never sees the full set.
  Camera is never yanked. During a detour, the gem route draws distinct from the
  recorded track (route bright/mint, track dimmed).
- `GemPeekCard` (min-visible floor, self-dismissing), `GemDetailSheet` (Dynamic
  Type-safe), the slim detour overlay (turn banner + destination chip with "Stop",
  slotted to avoid the existing turn-card/GPS/reroute chips), the one-tap "mark
  this spot" control. Tier-3 haptic + turn cues via `HapticPlaying` /
  `TurnHapticEngine`.

### Reuse map

| Need | Reuse |
|------|-------|
| Personal markers store | `SavedPlace` + `SavedPlacesStore`, `SavedPlaceRecord` — add `resurface` (V3→V4) |
| Detour routing + turn-by-turn | `GuidanceViewModel`, `MapboxGuidanceSession`, `MapboxRoutingProvider` (with detach-on-arrive config) |
| Route line on map | existing `routeRibbon` `@MapContentBuilder` in `RideMapView` |
| Turn cues + Tier-3 haptic | `TurnHapticEngine`, `HapticPlaying` / `HapticPlayer.shared` (coordinator-arbitrated) |
| Maneuver glyphs | `ManeuverIcon` (ROH-48) |
| Offline heading | device `CLHeading` (`TrackPoint` carries no bearing) |

## Data & tiering

- **Curated bundle** (v1 primary magic): JSON `{ id, coordinate, name, category,
  tier, photoAsset?, why? }`, photos as bundled assets, hand-tiered (any tier).
- **Personal markers:** resurface-flagged `SavedPlace` → always Tier 3.
- **Live feed (v1, minimal):** category-weighted, photoless, **capped at Tier 2**.

**Priority arbitration** (when several qualify to actively surface at once):
personal (T3) > curated (by tier) > live (≤ T2); ties break by **nearest**. Only
one surfaces; others remain pins or wait out the cooldown.

## Persistence & state

- **Per-ride seen set** — in memory on `DiscoveryState`.
- **Cross-ride seen set** — a dedicated lightweight SwiftData model
  `SeenGemRecord { gemID: String, firstSeenAt: Date }` (added in the V4 schema).
  Written **on each active surfacing** (not only at ride end) so a mid-ride crash
  can't un-see a gem. Keyed on the stable `Gem.id`.
- **`Gem.id` is a stable, source-namespaced `String`:** curated → authored slug
  in the bundle; personal → `"personal:" + SavedPlace.id`; live → source place id
  (`"osm:<id>"` / `"mbx:<id>"`). Stability is required for dedupe and seen-matching
  across provider refreshes and relaunches.
- **`SavedPlace.resurface`** — added to `SavedPlaceRecord` in V4 as
  `Bool` defaulting to **`false`** (existing saved places do **not** silently
  become gems; only explicit "return here" / toggle sets it true). Additive,
  honors the ROH-13 CloudKit-mirror invariants (default present, no `.unique`,
  no relationships) + a schema-invariant guard test.
- **One V3→V4 migration** adds both the `resurface` attribute and the
  `SeenGemRecord` model; lightweight stage in `RideMigrationPlan`.

## Group rides & annotation budget

`Ride.Kind` has only `.freeRide` / `.navigate`; a group ride is a `.freeRide`
with a `groupSession` attached. So discovery **gates on the presence of a group
session**, not a kind — v1 suppresses gem discovery entirely while in a group
ride. This also means gem pins and peer dots **never co-occur**, dissolving the
map annotation-budget collision. Outside group rides, the store caps visible gem
pins to the nearest ~8–10 before the render pass. (Gems-in-group-rides is a
deliberate later bet.)

## Accessibility

- **Peek card** — announced politely (does not interrupt), but the **persistent
  pin is the durable accessible element**; VoiceOver users engage the pin, not a
  vanishing card.
- **Detail sheet** — Dynamic Type through Accessibility sizes; "why" wraps; photo
  scales or drops gracefully; "Take me there" reachable without a hidden swipe.
- **Slim detour overlay** — turn banner + destination chip read as composed
  elements; gem name truncates gracefully; Reduce Motion honored on surfacing and
  re-target transitions.

## Error handling / edge cases

- Provider failure / offline → silently fall back to curated + personal; discovery
  never blocks or errors mid-ride. Results region-cached.
- Nothing nearby → no pins, no empty-state nag.
- **Arrival radius is per category** (`GemCategory`) — a trailhead vs. a café
  "arrive" at different distances.
- **Offline detour** → `headingOnly` state: a device-compass (`CLHeading`) arrow +
  straight-line distance, with a subtle "offline heading" affordance so the rider
  knows it's approximate; upgrades to full guidance if the network recovers.
- Re-target caches routes per gem; cancel/end-mid-detour resolve through the
  `GuidanceController` and detach cleanly on `finish()`/`cancel()`.
- Backgrounding — engine consumes samples but active surfacing pauses while the
  scene is inactive; guidance (if active) continues; overlay detaches on ride end.
- macOS package CI: iOS-only CoreLocation APIs (`CLBackgroundActivitySession`,
  `CLHeading`, …) `#if os(iOS)`-guarded (package builds on the macOS host).

## Testing

- **`GemDiscoveryEngine`** (Swift Testing, timestamp-driven, deterministic):
  proximity gating, cooldown spacing, one-at-a-time + tie-break, tier→treatment,
  priority arbitration, don't-repeat, seen-goes-quiet, personal-always-loud,
  annotation cap.
- **`GuidanceController` state machine**: wandering → routing → guiding → arrival
  (detach, ride continues) / cancel / re-target / offline `headingOnly`.
- **Providers**: curated decode + validation, category→tier, personal mapping,
  composite merge/dedupe on stable id, group-session gating.
- **Persistence**: `SeenGemRecord` write-on-surface + reseed; `resurface` V3→V4
  migration + schema-invariant guard (ROH-13 lineage) + default-false behavior.
- **Device-verify (sim can't drive):** live-GPS surfacing while moving, on-device
  Tier-3 haptics + arbitration, Mapbox arrival→detach. Spawns Device Verification issues.

## v1 scope

**In:** the engine + `GuidanceController`, curated + personal + **minimal live**
providers, tiered persistent tappable pins / cards / Tier-3 haptic, seen-state pin
styling, detail sheet, slim-overlay detour (detach-on-arrive) with offline heading
fallback, one-tap "return here" via Saved Places, cross-ride seen-set, priority
arbitration, accessibility, group-ride gating.

**Deferred:** live-feed photos, the optional chime, heading-aware surfacing
(proximity-only v1), gems during group rides, a gem line in the Live Activity.

## Open questions (for the plan)

- Exact cooldown / radii / pin-cap values (device-tuned; constants named above).
- "Return here" control placement in the cockpit and whether the resurface flag is
  toggle-visible in the Saved Places UI.
- Live provider choice (OSM Overpass vs. Mapbox POIs) + region-fetch/cache tuning.

## Review reconciliation

Hardened after a 3-reviewer adversarial pass (2026-07-04). Material changes:

1. **Detour re-architected** — guidance is decoupled from `Ride.Kind` and moved
   onto `RideSessionCoordinator` as a `GuidanceController` with detach-on-arrive
   (the original "overlay" claim wasn't a seam the code exposed).
2. **Group rides gated on `groupSession` presence** (there is no `.groupRide`
   kind); this also removes the peer-dot/gem annotation collision.
3. **Persistence made concrete** — V4 migration defines both `resurface`
   (default false) and `SeenGemRecord`; `Gem.id` is a stable source-namespaced
   string; seen-set written per surfacing.
4. **Annotation cap enforced** before the render pass (was assumed).
5. **Time-injection clarified** — the engine's clock is the location sample timestamp.
6. **UX hardening** — persistent tappable pins + card min-floor, visible seen-state,
   a safe one-tap "return here", priority arbitration, an accessibility section,
   per-category arrival radii, and a device-compass offline heading.
7. **Live feed reinstated (minimal, Tier ≤ 2)** in v1 so the map is never dead —
   PO decision after reviewers flagged the curated-only "dead map" risk.
