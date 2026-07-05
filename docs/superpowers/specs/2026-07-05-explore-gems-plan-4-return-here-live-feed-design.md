# Explore nearby gems — Plan 4: return-here + live feed + arbitration + a11y (ROH-60)

Final slice (4/4) of nearby-gem discovery (parent ROH-52). Closes the deferred
scope from Plans 1–3. Branch fresh off main `a0696a4` (Plan 3 merged).

Parent spec: `docs/superpowers/specs/2026-07-04-explore-nearby-gems-design.md`
(§ v1 scope / Data & tiering / Persistence / Accessibility). Plan-3 spec:
`docs/superpowers/specs/2026-07-05-explore-gems-plan-3-detour-design.md`.
Memory: `aura-nearby-gems`.

## Context

Plans 1–3 shipped: curated pins → tiers/peek-cards/detail-sheet/seen-memory →
the detour (`GuidanceController`, detach-on-arrive). The map today is **curated-
only** (a bundled Pittsburgh seed) and gems come from one source. Plan 4 makes
discovery **multi-source and personal**: the rider can mark a spot to return to,
the map is never dead outside the curated metro (a minimal live feed), the
sources merge and dedupe, and one clear arbitration rule decides what surfaces.
It also pays down the deferred Plan-2 accessibility items and the Plan-3 minors.

## Non-goals (deferred, unchanged from parent spec)

- Live-feed **photos** (live gems are photoless).
- The optional arrival **chime**.
- **Heading-aware** surfacing (proximity-only in v1).
- Gems **during group rides** (gated off by group-session presence).
- A gem line in the **Live Activity**.
- Any **map-tap / long-press** gesture to mark a precise point (unsafe mid-ride;
  "mark this spot" uses the current rider coordinate only).

## Decisions (this slice)

- **Live provider = OSM Overpass.** Free public API, plain `URLSession` → lives in
  AuraKit and is unit-testable via a mock `URLProtocol`. OSM tags map almost 1:1
  onto `GemCategory` (scenic/outdoor gems, not commercial POIs). Public-endpoint
  flakiness is contained by a region cache + silent fallback to curated+personal.
- **Reverse-geocode = `CLGeocoder`** (Apple, free, no token/new networking). The
  save is instant with a timestamp fallback name; the real name backfills async.
- **"Mark this spot" = a `ControlCluster` button** (no map gesture). One tap →
  save at the current rider coordinate + soft haptic + a brief confirmation toast.
- **Resurface UX in Saved Places = indicator + swipe-to-toggle-off.** Resurface
  places show a subtle gem indicator; a swipe action turns resurface off (demote
  to a plain saved place, without deleting). Name is editable.
- **Live feed is default-on**, region-fetched + cached, silent on failure.

## Architecture

Mirrors the established seam patterns (`GemProviding`, `WeatherProviding`,
`MapboxDetourRouting`). Pure logic in AuraCore; provider/store seams in AuraKit;
Mapbox/UIKit/CoreLocation concretes in the app target.

### Pure core — AuraCore (Sendable, no UIKit)

- **`SavedPlace.resurface: Bool`** (default `false`) added to the value type;
  carried through `SavedPlacesLogic.add(…)` / `reconciled(…)`. Reconcile keeps
  `resurface == true` if *either* side of a dedup is flagged (a re-save that sets
  resurface must not be lost to a CloudKit merge).
- **`GemDiscoveryEngine.decide`** gains explicit **source-priority arbitration**
  as the primary ordering key, tier as secondary, nearest as tie-break:
  `personal (T3) > curated (by tier) > live (≤ T2)`. Because personal is always
  T3 and live is always ≤ T2, tier already encodes most of this; source is made an
  explicit key so a curated-T3 and a personal-T3 resolve **deterministically to
  personal**. One `activeSurfacing`; pins and cooldown unchanged. Still
  timestamp-driven (no `Date()`).
- **OSM tag → `GemCategory` mapping** is a pure function in AuraCore
  (`OSMGemMapping`), unit-tested independent of any network: viewpoint→viewpoint,
  drinking_water/spring→water, leisure=park→park, amenity=cafe→cafe,
  tourism=artwork→mural, historic=*→historic, tourism=attraction→landmark;
  unmapped tags → dropped. Live tier = `min(category.defaultTier, .card)`.

### Seams + providers — AuraKit

- **`PersonalGemProvider: GemProviding`** — reads resurface-flagged `SavedPlace`s
  (via a small `ResurfacePlacesReading` seam over `SavedPlacesStore`), maps each to
  a `Gem` (`id = "personal:<uuid>"`, `source = .personal`, `tier = .cardHaptic`,
  category from `Place.Category`). Ignores `near:` (personal set is small; the
  engine's proximity gate handles range).
- **`LiveGemProvider: GemProviding`** — Overpass query bounded to a radius around
  `near:`; decodes elements → `OSMGemMapping` → `[Gem]` (`source = .live`, no
  photo). `URLSession` is injected (default `.shared`) so tests drive it with a
  stub `URLProtocol`. **Any** error / decode failure / empty → returns `[]`
  (never throws to the caller). Results served through the region cache.
- **`GemRegionCache`** (`actor`) — caches `[Gem]` keyed by a coarse grid cell
  (~2–3 km) + a staleness timestamp; `LiveGemProvider` refetches only when the
  rider's cell changes or the entry is stale. Injected clock (no wall-clock in the
  pure path).
- **`CompositeGemProvider: GemProviding`** — fans out to `[personal, curated,
  live]` concurrently (`async let` / task group), merges, and **dedupes on stable
  `Gem.id`** with **priority-order first-wins** (personal beats curated beats live
  for the same id). Returns the union of pins.

### Store — AuraKit

- **`GemDiscoveryStore.load()` deferral**: replace the `(0,0)` Null-Island
  sentinel path. `load()` becomes a no-op until `riderCoordinate` is non-nil;
  the first real fix triggers the initial `load()`. Curated is unaffected
  (ignores `near:`) but personal/live are coordinate-sensitive, so they must never
  be queried at (0,0). The existing in-code comment at the load() site is updated
  to describe the deferral (not a warning about the sentinel).
- The store is otherwise unchanged: `visiblePins` / `activeCard` / `seenIDs`,
  `update(at:now:)`, write-seen-on-surface, Tier-3 haptic seam, `detourActive`
  arbiter, group-ride `isSuppressed`.

### UI — app target (SwiftUI, design-skill-guided)

- **`ControlCluster`** gains a "mark this spot" button (SF Symbol, e.g.
  `mappin.and.ellipse`), wired to an `onMarkSpot` closure. Placed in the existing
  vertical cluster; no destructive role. Tap fires the save + soft haptic; a
  transient toast ("Spot saved") confirms without needing the rider to look.
- **`GemDetailSheet`** gains a "Save to return" button (below "why", above/beside
  "Take me there"), calling `onSaveGem`. If the gem is already saved-as-resurface,
  it reads "Saved to return" (disabled/checked) — idempotent, keyed by
  `SavedPlaceKey`.
- **Saved Places list** (`SavedPlaceRow` / list container): resurface places show
  a subtle gem indicator; a swipe action toggles resurface off; name editable.
- **Accessibility** fixes (see below) applied to `GemPinView`, `GemPeekCard`,
  `GemDetailSheet`, `DetourOverlay`.

### Data flow

`RideSessionCoordinator` stream loop → `discoverySink.rideDidUpdateLocation` →
`GemDiscoveryStore.update(at:)`. First real fix → `store.load()` →
`CompositeGemProvider.gems(near:)` → `[personal ∪ curated ∪ live]` deduped →
`engine.decide` (source-priority arbitration) → `visiblePins` + one `activeCard`.
Mark-this-spot / Save-to-return → `SavedPlacesStore.save(resurface: true)` →
next `load()` includes it as a Tier-3 personal gem.

## Persistence & migration

- **Schema V5** (`RideSchemaV5`): **redeclare** its own `SavedPlaceRecord` class
  (a copy of V3's + `resurface: Bool = false`) rather than mutating the class
  declared in `RideSchemaV3` (which V3/V4 still reference — mutating it in place
  would retroactively change what V3/V4 mean and break migration identity). V5's
  `models` lists `RideRecord`, `RideSchemaV5.SavedPlaceRecord`, `SeenGemRecord`.
  Register V5 in `RideMigrationPlan.schemas` + a **lightweight** `migrateV4toV5`
  stage. The `ModelContainer` current schema, and `SavedPlacesStore`'s
  `init(_:)`/`.value` mapping, repoint to `RideSchemaV5.SavedPlaceRecord`.
  (See Review reconciliation §V5 for the exact mechanics.)
- **ROH-13 CloudKit invariants** hold: `resurface` has a default, is not
  `.unique`, adds no relationship. `SchemaInvariantTests` is extended to assert
  against **V5** (every attribute optional-or-defaulted; no unique/relationships;
  model set present) — the machine-checked guard.
- **Default-false behavior test**: an existing saved place migrated V4→V5 has
  `resurface == false` (does not silently become a gem).
- `SavedPlacesStore` maps `resurface` in `init(_ SavedPlace)` and `.value`;
  `save(_:subtitle:resurface:)` gains the flag (defaulted false for existing
  callers). A resurface toggle-off path persists `resurface = false`.

## Accessibility (absorbs deferred Plan-2 items)

- **Gem pin hairline** uses a fixed `.standard` stroke — remove any
  `@Environment(\.colorSchemeContrast)`-conditional hairline.
- **Reduce Motion**: every gem/detour `.animation` is gated on
  `@Environment(\.accessibilityReduceMotion)` (no animated surfacing / re-target
  transitions when on; state still changes, just without motion).
- **Peek card**: announced **politely** (does not interrupt); the persistent
  **pin is the durable accessible element** VoiceOver users engage.
- **Detail sheet**: Dynamic Type through Accessibility sizes; "why" wraps; photo
  scales/drops gracefully; both CTAs reachable without a hidden swipe.
- **Detour overlay**: turn banner + destination chip read as **composed**
  elements; gem name truncates gracefully; the offline "approximate direction"
  affordance is labeled ("Offline, approximate direction").

## Error handling / edge cases

- Live provider offline / rate-limited / decode-fail → `[]`; discovery falls back
  to curated + personal; never blocks or errors mid-ride. Region-cached.
- Nothing nearby → no pins, no empty-state nag.
- **Mark this spot** before a first fix (no `riderCoordinate`) → the control is
  disabled until a fix exists (can't mark Null Island).
- **Reverse-geocode failure / slow** → the timestamp fallback name stays; no error
  surfaced. Name is user-editable regardless.
- **Duplicate save** (same spot twice, or Save-to-return on an already-saved gem)
  → idempotent via `SavedPlaceKey`; re-save keeps/sets `resurface = true`.
- **50-place cap** (`SavedPlacesLogic`): a mark-this-spot at the cap surfaces the
  existing "saved places full" path (no silent drop).
- macOS package CI: any iOS-only CoreLocation/UIKit APIs (`CLGeocoder` usage,
  haptics) stay in the app target or are `#if os(iOS)`-guarded; AuraKit providers
  are pure `URLSession` + SwiftData (build on the macOS host).

## Plan-3 deferred minors (folded in)

- **`networkRecovered` e2e test**: drive `GuidanceController` offline → `headingOnly`
  → `probeNetworkRecovery` fix-count throttle → recovery → full guidance upgrade.
- **`GuidanceController.cacheKey`**: apply real `cos(lat)` longitude scaling so the
  ~25 m quantization holds at latitude (fix the math, not just the comment).
- **CTA vertical padding (8 vs 14)**: decided on device during device-verify, not
  guessed in code.

## Testing

- **`GemDiscoveryEngine`**: source-priority arbitration (personal>curated>live),
  tie-break nearest, personal-T3-beats-curated-T3, one-at-a-time, cooldown/seen
  unchanged (regression).
- **`OSMGemMapping`** (pure): each tag→category, tier cap at `.card`, unmapped→drop.
- **`LiveGemProvider`** (mock `URLProtocol`): happy-path decode→gems, error→[],
  malformed→[], radius bounding; **`GemRegionCache`**: hit within cell/staleness,
  miss on cell change / stale.
- **`CompositeGemProvider`**: union, dedupe-on-id with priority first-wins,
  one-source-empty, all-empty.
- **`PersonalGemProvider`**: resurface places → Tier-3 personal gems; non-resurface
  excluded; id = `personal:<uuid>`.
- **`GemDiscoveryStore`**: `load()` deferred until first fix (no query at (0,0)).
- **Persistence**: V4→V5 lightweight migration; schema-invariant guard on V5;
  default-false behavior; `resurface` round-trips through the record; toggle-off
  persists false.
- **`SavedPlacesLogic`**: resurface carried through add; reconcile keeps
  `resurface == true` if either side is flagged.
- **Device-verify (sim can't drive):** detour arrival + turn haptics by hand;
  offline compass pointer + affordance + recovery/upgrade; live-feed pins outside
  the curated metro; mark-this-spot → Tier-3 resurface behavior. Spawns Device
  Verification issues as needed.

## v1 scope (this slice)

**In:** `SavedPlace.resurface` + V5 migration + guard test; cockpit mark-this-spot
(CLGeocoder auto-name) + GemDetailSheet Save-to-return; resurface indicator +
toggle-off in Saved Places; `PersonalGemProvider`; `LiveGemProvider` (OSM
Overpass) + `GemRegionCache`; `OSMGemMapping`; `CompositeGemProvider` merge/dedupe;
`load()` deferral past first fix; source-priority arbitration in `decide`; the a11y
audit; the three Plan-3 minors; device-verify of the Plan-3 tails + new surfaces.

**Deferred:** live-feed photos, arrival chime, heading-aware surfacing, gems in
group rides, a gem line in the Live Activity (all unchanged from the parent spec).

## Review reconciliation (Plan 4 adversarial pass, 2026-07-05)

Hardened after a 3-lens adversarial spec review (correctness / rider-UX /
architecture-concurrency). Material changes below are authoritative; the plan
must implement them.

**§Arbitration (correctness-CRITICAL).** The shipped `GemDiscoveryEngine.decide`
sorts by `(tier↓, distance↑)` only — so a curated-T3 and a personal-T3 tie
resolves to *nearest*, which can hand the surface to curated when the spec wants
personal. Fix: sort eligible gems by an explicit tuple **`(sourceOrder↑, tier↓,
distance↑)`** where `sourceOrder = personal(0) < curated(1) < live(2)`. Since
personal is always T3 and live always ≤ T2, tier already encodes most ordering;
`sourceOrder` as the primary key makes personal-T3-beats-curated-T3 deterministic.
Add a regression test asserting a *farther* personal-T3 beats a *nearer*
curated-T3, and that existing tier/distance/cooldown/seen tests still pass.

**§CompositeGemProvider dedupe (correctness-HIGH).** Id-only dedupe misses the
real collision: a personal "return here" café (`personal:<uuid>`) that is *also*
an OSM POI (`osm:<id>`) has two different ids → it double-surfaces (two pins, two
detail sheets, same physical spot). Two-pass dedupe: (1) exact `Gem.id`, higher
`sourceOrder`-priority wins; (2) **coordinate-proximity cluster** — gems within
**~25 m** (`Geo.distance`) collapse to the single highest-priority
(personal>curated>live) member. 25 m matches the region-cache grain and the
`cacheKey` quantization. Test: personal+live at the same coord → one personal pin.

**§CompositeGemProvider concurrency (architecture-HIGH).** A slow/offline Overpass
must never block the map. `personal` and `curated` resolve immediately (local);
`live` runs under a **~2 s timeout** — on timeout/error/empty it contributes `[]`
and the composite returns curated+personal without waiting further. Fan-out via
`async let` (three concurrent), `[Gem]` is `Sendable`. No `Task.sleep` as a test
barrier — drive the timeout path with an injected stub provider that never
returns, plus an injected clock, not wall-clock.

**§load() deferral + timestamp clock (correctness/architecture-HIGH).** The store
currently calls `provider.gems(near: riderCoordinate ?? Coordinate(0,0))` and then
`update(at:, now: Date(timeIntervalSince1970: 0))` — both a Null-Island query risk
and a wall-clock/epoch violation of the timestamp-driven contract. Fix the exact
sequence: `init` does **not** `load()`; `update(at:now:)` is fed the **location
sample's timestamp** as `now` (threaded from the ride stream, never `Date()`); on
the **first** `update` with a non-nil coordinate the store triggers a **one-time**
`load()` (guard a `didLoad` flag so it fires once, not per-sample, and never at
(0,0)). Curated stays first-fix-independent; personal/live are only ever queried
at a real coordinate. Test: no `gems(near:)` call before the first fix; exactly
one `load()` across many updates.

**§V5 schema mechanics (correctness/architecture-MEDIUM).** `SavedPlaceRecord` is
declared in `RideSchemaV3` and *referenced* by V4 — mutating that class to add
`resurface` would retroactively change V3/V4 and corrupt migration identity.
Correct pattern: `RideSchemaV5` **declares its own** `SavedPlaceRecord` (V3's
fields + `resurface: Bool = false`, same init/`.value` shape). `RideSchemaV3`'s
class is left untouched. `RideMigrationPlan.schemas` appends V5; `migrateV4toV5`
is a **lightweight** stage. `RideStore.persistent()`/`.inMemory()` `ModelContainer`
and `SavedPlacesStore`'s `init(_:)`/`.value` mapping switch to
`RideSchemaV5.SavedPlaceRecord`. `SchemaInvariantTests` targets **V5** and adds
`resurface` to the optional-or-defaulted assertion (default `false`). Migration
test: a V4 store with an existing place opens under V5 with `resurface == false`.

**§CLGeocoder backfill without clobbering user edits (UX/architecture-HIGH).**
Reverse-geocode is **app-target only** (CoreLocation is iOS-only; AuraKit stays
pure `URLSession`+SwiftData). Flow: on mark/save, persist immediately with a
**provisional** name (`"Marked spot"`); the app fires `CLGeocoder`
asynchronously; on success it calls a `SavedPlacesStore.updateName(id:to:)` seam
**only if the stored name still equals the provisional string** (so a user rename
made in the interim is never overwritten). Failure/offline → the provisional name
stays; the name is always user-editable. No second schema field needed. The
Saved Places row shows the real name when present and a relative-time subtitle
("marked 2h ago"); the async backfill updates the row in place.

**§Mark-this-spot safety (UX-CRITICAL).** The one-tap control must **not** sit
adjacent to the destructive End-Ride button in the cockpit cluster (fat-finger →
silent unwanted save). Separate it visually (its own position / spacing away from
End Ride), and the confirmation toast carries an **Undo** affordance that deletes
the just-saved place (in-ride, no home-dashboard round-trip). The control is
**disabled until a first fix** exists (can't mark Null Island). At the 50-place
cap it surfaces the existing "saved places full" path.

**§Curated-vs-live differentiation (UX-HIGH).** Live (OSM) pins/cards must be
visually distinct from hand-curated gems so the curation signal isn't diluted:
curated/personal render full-strength; **live** renders quieter (dimmer/hollow
pin, and the peek card carries a small OSM source label). The OSM label doubles as
the **ODbL attribution** OpenStreetMap requires. Pin styling keys on `Gem.source`,
not just `tier`/`isSeen`; add a styling test.

**§Resurface discoverability (UX-MEDIUM).** Beyond the swipe action, `SavedPlaceRow`
gets an explicit **menu item** ("Stop returning here") when `resurface == true`,
and a subtle indicator + hint ("Resurfaces when you ride past"). VoiceOver users
reach the toggle via the menu, not a hidden swipe.

**§Minor hardening.** (a) `GemDiscoveryStore.update` snapshots `detourActive()`
**once** at the top (avoid a mid-update re-entrancy flip). (b) `SeenGemStore`
caches its id set in memory (seed at init) instead of re-fetching per surfacing,
and logs (not `try?`-swallows) a save failure. (c) `PersonalGemProvider` returns
**all** resurface places unsorted — proximity is the engine's job. (d) Enumerate
`#if os(iOS)` needs: none in the new AuraKit providers (pure); CLGeocoder + the
mark-spot haptic live in the app target.

**Judgment calls (PO veto welcome).** (1) **U5 personal-nag:** kept the parent
spec's "personal exempt from cross-ride seen-quiet" (that *is* "return here"); the
per-ride cooldown/don't-repeat caps it at once-per-ride. A cross-ride resurface
throttle (`lastResurfacedAt`) is **deferred** to post-v1 pending device feedback,
to hold this final slice to the single additive field `resurface`. (2) **Dedupe
radius = 25 m**, matching the cache grid + `cacheKey` quantization.

**Non-issues after code read.** The three providers, `resurface` field, and
arbitration "not existing yet" (flagged CRITICAL by the architecture lens) are the
*intended implementation work* of this slice, not spec defects — captured as plan
tasks, not spec changes.
