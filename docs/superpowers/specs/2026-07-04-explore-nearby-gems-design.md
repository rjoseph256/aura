# Explore — live in-ride nearby gems (ROH-52)

- **Issue:** [ROH-52](https://linear.app/rohun/issue/ROH-52) — Explore discovery, Sub-project 2 (nearby gems)
- **Epic:** Interface & Feel
- **Date:** 2026-07-04
- **Status:** Design approved (PO), pending adversarial spec review

## Context

The free-ride ("Explore") surface auto-starts a recorded ride and shows the
redesigned cockpit (ROH-49), but a directionless ride leaves most of the screen
as inert terrain map. The umbrella vision (ROH-50) proposed three ways to make
Explore a discovery surface. The first-drafted one — fog-of-war coverage
(ROH-54) — was deprioritized after the PO reviewed mockups and cooled on the
metaphor. This spec picks up the second pillar, **nearby gems**, and reframes it
around a sharper intent from the PO interview:

> Discovery is **live and in-ride**, not plan-then-go. You start cruising like
> today, and as you move the world reveals itself — interesting places surface
> ambiently around you, gently, without ever hijacking the ride.

This reframe **decouples ROH-52 from the parked browsable shell**: the ROH-49
auto-start HUD stays exactly as is, and gem discovery is a layer on top of it.

## Non-goals

- Not fog-of-war / coverage rendering (parked in ROH-54).
- Not a pre-ride browsable "discovery map" shell (the auto-start entry is unchanged).
- Not loop/route generation ("go-here suggestions" — that's ROH-53, its own bet).
- Not a live POI feed in v1 — see [v1 scope](#v1-scope-cut). The seam is designed
  for it; the implementation is a fast-follow.
- Not gems during a *group* ride in v1 (solo free ride only).

## The experience (approved)

Tapping Explore still auto-starts a free ride (ROH-49 untouched). Layered on top:

**Tiered surfacing.** A gem's rank decides how intrusive it is:

| Tier | Treatment |
|------|-----------|
| 1 | A quiet pin on the map (ambient only, never interrupts) |
| 2 | Rises to a soft, self-dismissing peek card |
| 3 | Peek card **+** a haptic (optional quiet chime deferred) |

**Rhythm (the restraint model).** Two separate layers:
- *Ambient* — pins populate freely; however many gems are genuinely nearby show
  as pins (subject only to the map annotation cap).
- *Active* — cards and haptics are rationed: **one active surfacing at a time**,
  a **cooldown** between them so they never become constant pings, gated by tier,
  and **never re-surfaced within a ride**.

**Memory.** Once a gem has *actively* surfaced (card/haptic) to you, on future
rides it stays a **pin** but won't peek/buzz again — the active layer always
feels fresh. **Personal "return here" markers are the deliberate exception:**
always Tier 3, they resurface actively by design.

**Engage (two taps to commit).**
1. Peek card → **first tap** opens a detail view: name, category, distance,
   climb, a photo if one exists, a one-line "why".
2. **Second tap "Take me there"** → turn-by-turn guidance to the gem.

**The detour, not a new trip.** Guidance to a gem *overlays the existing free
ride*. It is one continuous recorded wander — the recorder, stats, and Live
Activity never restart. Gems keep surfacing en route (you might spot something
better and re-target). On arrival the guidance quietly falls away and you are
back to open wandering. The ride ends only when *you* end it.

**"Return here".** A personal marker you drop while out, meaning "resurface this
to me later." It **is a `SavedPlace`** flagged to resurface, so it appears in
your existing Saved Places *and* behaves as a Tier-3 gem. Two ways to create one:
drop at current location, or "Save to return" from a gem's detail sheet.

## Architecture

Follows shipped patterns: pure logic in AuraCore, `@MainActor` protocol seams in
AuraKit, concrete providers in the app target, an `@Observable` store driving
SwiftUI (mirrors WeatherProviding/WeatherStore, WorkoutWriting, HapticPlaying).

### Pure core — AuraCore (Sendable, no UIKit, unit-testable)

- `Gem` — value type: `id`, `coordinate` (`Coordinate`), `name`, `category`
  (`GemCategory`), `tier` (`GemTier`), `source` (`GemSource`: curated / personal
  / live), optional `photo` reference, optional `why` blurb.
- `GemCategory` — viewpoint, water, park, cafe, mural, climb, historic, … Each
  carries a default tier weight.
- `GemTier` — `.pin` (1) / `.card` (2) / `.cardHaptic` (3), with the treatment
  mapping above.
- `GemDiscoveryEngine` — **the heart.** Push-driven and **time-injected** (no
  `Date()`/timers inside — same discipline as the group-ride `RideSession`), so
  it is deterministic in tests. Given `(location, timestamp, candidateGems,
  state)` it returns a `DiscoveryDecision`: the set of `visiblePins` and an
  optional `activeSurfacing(Gem, treatment)`. Owns proximity gating, cooldown /
  spacing, one-active-at-a-time, don't-repeat-within-ride, tier→treatment, and
  the annotation cap (nearest N).
- `DiscoveryState` — per-ride seen set + last-active timestamp; seeded at ride
  start from cross-ride memory (which gems have peeked before).
- **Detour state machine** — extends the free-ride session with a `GuidanceOverlay`:
  `wandering → routing → guiding(gem, route, progress) → wandering`
  (back on arrival / cancel / re-target). Pure and time-injected; reuses the
  existing `GuidanceSession` (AuraCore) for maneuver/progress modeling.

### Seams — AuraKit (`@MainActor` protocols; impls in the app target)

- `GemProviding` — `func gems(near region:) async -> [Gem]`.
  - `CuratedGemProvider` — decodes a bundled metro gem set (JSON + photo assets).
  - `PersonalGemProvider` — reads `SavedPlace`s flagged to resurface, maps each
    to a Tier-3 `Gem`.
  - `LiveGemProvider` — **deferred** (OSM Overpass / Mapbox category POIs;
    capped at Tier 2 when it lands).
  - `CompositeGemProvider` — merges + dedupes across providers; region-caches.

### Store — AuraKit (`@Observable @MainActor`)

- `GemDiscoveryStore` — subscribes to the ride's location stream, pulls candidate
  gems from the composite provider, feeds the engine, and publishes `visiblePins`
  + `activeSurfacing` to the HUD. Fires the `HapticPlaying` seam for Tier 3,
  persists the cross-ride seen set, and owns the detour (requests a route via
  `MapboxRoutingProvider`, attaches/detaches the `GuidanceOverlay`).

### UI — app target (SwiftUI, design-skill-guided)

- Gem layer in `RideMapView` via `@MapContentBuilder` (`MapViewAnnotation` +
  `GemPinView`, styled by tier/category); camera is never yanked.
- `GemPeekCard` (self-dismissing), `GemDetailSheet` (first tap), the slim
  detour overlay (turn banner + destination chip with "Stop"), and a "return
  here" control. Tier-3 haptic + turn cues through the existing `HapticPlaying`
  and `TurnHapticEngine`.

### Reuse map

| Need | Reuse |
|------|-------|
| Personal markers store | `SavedPlace` (AuraCore) + `SavedPlacesStore` (AuraKit), `SavedPlaceRecord` in schema — add a `resurface` flag (V3→V4 lightweight migration) |
| Detour routing + turn-by-turn | `GuidanceSession` (AuraCore), `GuidanceViewModel` (AuraKit), `MapboxRoutingProvider`, `MapboxGuidanceSession` |
| Route line on map | existing `routeRibbon` `@MapContentBuilder` in `RideMapView` |
| Turn cues + Tier-3 haptic | `TurnHapticEngine`, `HapticPlaying` / `HapticPlayer` |
| Maneuver glyphs in the banner | `ManeuverIcon` (ROH-48) |

## Data & tiering

**Curated bundle** (v1 primary source): a JSON gem set for the launch metro,
each entry `{ id, coordinate, name, category, tier, photoAsset?, why? }`, with
photos as bundled assets. Hand-tiered so the magic is guaranteed.

**Personal markers:** every resurface-flagged `SavedPlace` → a Tier-3 `Gem`.

**Live feed (deferred):** category-weighted, usually photoless; **capped at
Tier 2** — we don't trust its prominence signal enough to buzz the wrist.

**Tier assignment rule (approved):** only **curated** gems and **personal**
markers can reach **Tier 3**. Curated tiers come from curation; personal are
always Tier 3; live (later) never exceeds Tier 2.

## Pacing / restraint (engine rules)

- **Proximity** — a gem becomes a candidate pin within a radius; it becomes
  eligible to *actively* surface only within a tighter approach radius.
- **Cooldown** — a minimum interval between active surfacings (tuned in the plan;
  starting point ~60–90 s), so cards/haptics never stack.
- **One at a time** — at most one active surfacing live; others wait or stay pins.
- **Don't-repeat within a ride** — a gem surfaces actively at most once per ride.
- **Seen-goes-quiet across rides** — a previously-surfaced gem is pin-only on
  later rides (personal markers exempt).
- **Annotation cap** — visible pins capped at the nearest ~8–10 (shared budget
  with the rider puck and, later, peer dots), culling the rest.

## The detour (depth)

- **Additive, nothing restarts.** The free-ride session gains one optional
  `GuidanceOverlay`. Recorder / stats / screen-wake / Live Activity keep running;
  `.freeRide` is never swapped for `.navigate`. It all happens inside the HUD.
- **Slim overlay UI (approved).** The Explore cockpit (SPEED / DIST / TIME /
  CLIMB) is unchanged. Added: a slim turn banner (maneuver glyph + street +
  distance) and a compact destination chip ("<gem> · heading there · <dist> ·
  Stop"). "Stop" ends only the guidance; the ride continues.
- **Discovery keeps breathing**, with one arbitration rule: **while guiding,
  gem Tier-3 haptics are suppressed** — turn haptics own the wrist so a buzz is
  never ambiguous. Gems still show cards.
- **Re-target** — tapping a different gem's "Take me there" replaces the target.
- **Arrival is a moment, then dissolves** — Mapbox arrival → a gentle "you made
  it" beat → overlay detaches → wander resumes → the gem is marked seen. No
  summary; the ride never ended.
- **Offline fallback** — turn-by-turn needs the network (offline *routing* is out
  of scope, ROH-33). If routing is unavailable, "Take me there" degrades to a
  **heading breadcrumb** (direction arrow + live distance).
- **Camera** — gentle follow during guidance (recenter available); not the
  aggressive nav pitch.

## Persistence & state

- **Per-ride seen set** — in memory on `DiscoveryState`.
- **Cross-ride seen set** — lightweight persistence (small SwiftData record or a
  keyed store) of gem ids that have actively surfaced, so seen-goes-quiet holds
  across launches.
- **Personal markers** — `SavedPlace` + `resurface` flag (schema V3→V4, additive,
  lightweight migration; honors the CloudKit-mirror invariants from ROH-13:
  new attribute has a default, no `.unique`/relationships).

## Error handling / edge cases

- Provider failure / offline → silently fall back to curated + personal; discovery
  never blocks or shows an error mid-ride. Results region-cached.
- Nothing nearby → no pins, no empty-state nag. Silence is valid.
- No photo → detail sheet adapts (category glyph / terrain snippet), never a
  broken image.
- Route fetch fails → heading-breadcrumb fallback.
- Re-target / cancel / end-mid-detour all resolve through the state machine;
  ending the ride ends everything with the normal summary.
- macOS package CI: any iOS-only CoreLocation API used by the store must be
  `#if os(iOS)`-guarded (the package builds on the macOS host).

## Testing strategy

- **`GemDiscoveryEngine`** (Swift Testing, time-injected, deterministic):
  proximity gating, cooldown spacing, one-at-a-time, tier→treatment,
  don't-repeat, seen-goes-quiet, personal-always-loud, annotation cap.
- **Detour state machine**: wandering → routing → guiding → arrival / cancel /
  re-target transitions.
- **Providers**: curated JSON decode, category→tier, personal mapping, composite
  merge/dedupe.
- **Persistence**: cross-ride seen set; `SavedPlace` resurface flag + V3→V4
  migration + schema-invariant guard (ROH-13 lineage).
- **Device-verify (can't be proven on the simulator):** live-GPS surfacing while
  moving, Tier-3 haptics on device, and Mapbox arrival detection (ROH-9/10
  lineage). These spawn Device Verification issues.

## v1 scope cut

**In:** `GemDiscoveryEngine`, `CuratedGemProvider` + `PersonalGemProvider` (+
`CompositeGemProvider` seam), tiered pins / cards / Tier-3 haptic, `GemDetailSheet`,
slim-overlay detour with turn-by-turn (+ offline heading fallback), "return here"
via Saved Places, cross-ride memory.

**Deferred (fast-follows):** the live POI feed (`LiveGemProvider`, Tier-2 cap),
live-feed photos, the optional chime (haptic-only v1), heading-aware surfacing
(proximity-only v1), gems during group rides, and a gem line in the Live Activity.

**Accepted tradeoff:** away from the curated metro and personal markers, the map
is quiet in v1. A small set of genuinely great gems beats a map full of noise.

## Open questions / follow-ups

- **"Return here" affordance** — exact gesture/control to drop a marker mid-ride
  (dedicated HUD control vs. long-press map) and auto-naming (reverse-geocode vs.
  timestamp), refined in the plan.
- **Saved Places surfacing** — how (and whether) the resurface flag is shown/toggled
  in the existing Saved Places UI.
- **Cooldown / radii values** — starting points above; tuned during build + device pass.
- **Live feed** — provider choice (OSM Overpass vs. Mapbox) and region-fetch/caching
  strategy, specced when the fast-follow starts.
