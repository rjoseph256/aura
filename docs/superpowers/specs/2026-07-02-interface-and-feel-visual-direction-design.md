# Interface & Feel — Chunk 0: visual direction

**Date:** 2026-07-02
**Status:** Revised after adversarial spec review (three independent reviewers). Pending
final user sign-off and a device spike (below).
**Linear:** ROH-42 (epic: Interface & Feel)
**Program:** This is Chunk 0 of the Interface & Feel epic, the north star that gates
Chunks 1 through 3 (Home reinvention, navigate-cockpit reinvention, systematic polish). It
produces a direction, not app code. Each later chunk applies this direction under its own
spec, review, plan, and build.

## Why this exists

Wave 1 gave Aura a real design system: semantic token roles, spacing and radius scales, a
type ramp, and the mono-lime-on-near-black identity with Saira Condensed cockpit numerals
against SF Pro Rounded chrome. The critical ride path is already richly animated. What the
current look lacks is a point of view strong enough to be *ownable*. A flat dark screen with
a lime accent is not specific to cycling, to terrain, or to Aura.

The goal for this epic is to push the ceiling, not just tidy the edges. So the first move is
to settle what Aura should *feel* like before any surface is rebuilt.

## The decision

We explored three directions (Instrument, Terrain, Kinetic) and four palettes on the chosen
one. The locked direction is **Terrain, lime-signaled** with one correction that came out of
adversarial review: **the terrain identity lives in the map and the structure, not in
decoration that has to hide.**

The first draft of this spec put the identity in contour *textures* and frosted *glass*, then
required both to recede during navigation for legibility and performance. Three independent
reviewers converged on the same flaw: that puts the signature look on the surfaces a rider
glances at for seconds (Home, summary) and strips it from the cockpit, where a rider lives for
an hour. The engineering reviewer added that a live blur over a continuously moving Metal map
cannot be pre-composited and is one of the most expensive operations on iOS, so the recede was
not optional. The fix below moves the identity to where it survives: the map itself.

### Where the identity lives (the reframe)

1. **The map is the terrain.** A **custom Mapbox Studio style** (ROH-6, promoted from a
   fast-follow to a core deliverable of this direction) tuned to the palette: hillshade and a
   readable relief, a charcoal-green land, water and parks in the system's tones, and the lime
   route line sitting on top. This is the one place terrain belongs *at speed*, because the
   rider is on it. It is also the least pre-owned move in the direction: generic nav apps do
   not art-direct their terrain.
2. **The base color.** `nearBlack` becomes a deep charcoal-green / slate. This carries the
   world onto every surface, cockpit included, without a texture that fights data.
3. **Cockpit chrome.** The non-data edges of the cockpit (the turn-card material edge, the
   trip-strip backing) carry a quiet terrain-derived treatment. The *data* stays opaque and
   legible (see Rule 1).

### Where the signature material lives

**Frosted translucent glass is reserved for calm surfaces** where the map is static or absent:
Home, the ride summary, idle and empty states, sheets. There it can sample and blur real
content, which is what gives it depth, and its cost is affordable because nothing is moving.
It does **not** run as a live blur over the moving cockpit map.

### Where the texture lives

**Contour texture is decorative and calm-surface-only**, never behind live cockpit data and
never directly behind body text (see Rule 4).

### Signal (unchanged, and validated by review)

**Electric lime `#C8FA4B` stays as the single signal accent:** the route line, the weekly-goal
ring, and key numerals. All three reviewers accepted this. The reasoning:

1. **No semantic collision.** `amber` already means *warning / stopped* (the GPS-weak chip, the
   stopped-peer dot) and `pink` already means *destructive / end ride*. Promoting a warm accent
   would overload a color that already carries mid-ride meaning.
2. **Glanceability.** Lime on dark is loud and legible at speed, which is what a route line and a
   speed numeral need at 20 mph.
3. **Ownability does not depend on it.** With the map carrying the fresh, ownable identity, the
   accent no longer has to be novel to make the app distinct. That removes the earlier draft's
   contradiction (citing lime as non-specific, then keeping it): the distinctiveness now comes
   from the art-directed terrain map, not the color. A cool cyan/alpine accent is therefore not
   needed and is dropped from scope rather than deferred.

### Register: the land under the city

Topographic motifs read as backcountry/hiking, and Aura's dominant ride is urban Pittsburgh,
speed, and group. The honest reconciliation is that **Pittsburgh is genuinely, famously hilly**,
so terrain here means the elevation *within* an urban ride, not a mountain you traverse slowly.
The direction leans into that: relief and climb as the story of a city ride. The fast/social
register is carried by motion (Rule 5) and by the group layer (Constraint B), so the app does
not read as a contemplative trail app when the actual ride is a sprint to a meetup.

## The rules that make it work

### 1. Cockpit legibility beats atmosphere (the load-bearing rule)

Split the earlier "terrain recedes" rule into two honest halves:

- **Texture and live blur are cut from the cockpit.** No contour texture behind moving data, no
  live `.ultraThinMaterial` over the moving map. Cockpit data surfaces (turn card, speed readout,
  trip strip, distance remaining) are **opaque or near-opaque by default while navigating**,
  built on the already-shipped `mapScrim` opacity fill, not a live blur.
- **Identity is mandated in the cockpit, through legible vectors:** the custom terrain map style,
  the charcoal-green base, the lime route line, and a quiet terrain treatment on non-data chrome.
  The cockpit must still read as Aura. Chunk 2's review gate is: does the identity survive the
  Start transition, so Home and the cockpit feel like one product?

### 2. Frosted glass must degrade honestly, and its contrast is device-verified

- Frosted surfaces keep the existing `prefersOpaqueSurface()` / `mapScrim()` fallback and go
  opaque under Reduce Transparency and Increase Contrast. The new material extends that path
  rather than bypassing it.
- **CI does not and cannot verify frosted-glass contrast.** The pure `WCAGContrast` harness
  composites a foreground over a single opaque background at a fixed alpha; it has no model of a
  Gaussian blur over live, unbounded-luminance map content, and `.ultraThinMaterial`'s
  coefficients are system-defined and vary by iOS version. So: any text on a frosted surface sits
  on an **opaque or near-opaque text plate** (not bare glass), and *that* plate's contrast is what
  CI guards, as a conservative opaque-equivalent. Text legibility on the glass itself is a
  device-verified property, not a CI-verified one. (Follow-up: the shipped `TripStripView` and
  `HUDControlButton` already render `.ultraThinMaterial` while CI guards a `0.85` opaque proxy;
  that divergence is noted for Chunk 2/3 to reconcile, not widened.)
- WCAG targets for the opaque token pairs still pass. The new charcoal-green base and any new
  opaque plate colors are added to the existing suite.

### 3. Performance and thermal budget (falsifiable)

- **Target:** sustained 60 fps (120 on ProMotion) with a bounded hitch ratio over a 30-minute
  recorded ride on the oldest supported device. **Instrument:** Instruments Core Animation FPS
  plus MetricKit `MXAnimationMetric` / hitch ratio.
- **Energy/thermal:** measured over a long recorded ride (MetricKit `MXCPUMetric` +
  `MXAnimationMetric`, Energy Log). The treatment responds to `ProcessInfo.thermalState`: at
  `.serious` / `.critical`, blur and motion drift shed automatically. This gives the cockpit a
  runtime reason to stay lean, on top of the design-time one in Rule 1.
- Because the cockpit already excludes live blur (Rule 1), the expensive case is contained to
  calm surfaces where the map is static.

### 4. Texture is decorative, bounded, and never under text

- Contour texture appears only on calm surfaces, sits **behind an opaque text plate wherever body
  text appears** (never text directly on bare contour), and **attenuates toward zero at large
  Dynamic Type sizes** so dense bands never land behind wrapped lines.
- Texture contrast against the base is capped (a bounded delta-luminance), so it reads as tactile,
  not busy.
- The asset strategy is a named Chunk-1 deliverable, not a one-liner: decide raster (with an
  @2x/@3x + base / opaque-fallback / increase-contrast variant matrix and a memory budget) versus a
  `Canvas`/shader treatment (with its own frame cost checked against Rule 3). Raster is the default
  unless the shader proves cheaper.

## First-class constraints (were missing; now locked into the direction)

### A. The signature moment

The direction is not "good" until it produces one frame someone would post unprompted. The named
signature moment is the **ride-complete summary as a terrain-carved medal**: the route line embossed
into a contour relief matched to *that ride's* actual elevation profile, the hero distance counting
up, share-ready by construction (it reuses the existing map-led summary and the offscreen share-card
renderer). This is the acceptance test for the whole direction, owned by Chunk 3 (summary) with the
share card. If no chunk produces a postable hero frame, the ceiling was not pushed.

### B. The group-ride live layer

Group rides (peer dots, roster, converging riders) are Aura's real differentiator and the surface
that most stresses the palette, so the direction cannot lock without them. Locked here:

- **Peer-dot color system over the terrain-tinted map:** *you* (a clear neutral, e.g. white), a
  *moving peer*, a *stopped peer* (`amber`, existing), and the *host/leader* (a distinct treatment),
  all legible over the charcoal-green relief and never colliding with the lime route line. The exact
  moving-peer and leader values are pinned in Chunk 3 against the real map style, but the slots and
  their non-collision with lime/amber are fixed now.
- **Roster panels follow the calm-surface rule** (frosted) when docked/expanded over a mostly static
  frame, and the cockpit-legibility rule (opaque) for any live data they show over the moving map.

### C. Ownability gate (testable)

"Ownable" is defined so Chunk 0 can pass or fail: an **unbranded screenshot of Home or the cockpit
should be identifiable as Aura**, and a side-by-side against the nearest competitors (Gaia, Komoot,
AllTrails, FATMAP, onX) must yield one sentence of what is unmistakably ours. The current answer: the
art-directed live terrain map plus the terrain-carved summary medal, neither of which those apps do.
A short competitive teardown is a Chunk-1 pre-req; if the direction cannot produce that sentence on
device, it does not clear its own bar.

## Accessibility matrix (all three new layers, not just panels)

Each new layer has a defined behavior under each accessibility flag. The existing helper covers
panels only; texture and the map/backdrop motion are added explicitly.

| Layer | Reduce Transparency | Increase Contrast | Reduce Motion |
| --- | --- | --- | --- |
| Frosted material | opaque surface | opaque surface | n/a |
| Contour texture | off | off (recede to zero) | n/a |
| Map/backdrop motion (parallax, terrain-drift) | static | static | **zero residual drift** (fully static, not merely reduced) |

Reduce Motion matters most: parallax tied to motion is a vestibular trigger even at small
amplitude, so its fallback is fully static, and continuous drift is off by default during a
recorded ride regardless of the flag.

## What stays

- **Typography:** Saira Condensed for cockpit numerals, SF Pro Rounded for chrome. Revisit only if
  it fights the new material, not preemptively.
- **The token architecture:** semantic roles, spacing and radius scales, the `AuraPalette` to
  `AuraTheme` bridge, and the four extracted components (`CTAButtonStyle`, `HUDControlButton`,
  `SpeedReadout`, `StatPair`). This direction changes token *values*, adds a map style, and adds a
  calm-surface material and texture layer. It does not throw out the system.

## Motion language

Keep the shipped, Reduce-Motion-guarded motion (turn-card collapse and expand, summary count-up, ring
arc-fill, roster expand and collapse). Add, guarded and per the matrix above:

- a gentle parallax / terrain-drift on calm-surface backdrops (Home hero), never during cockpit
  navigation,
- staggered reveals consistent with the summary's existing entrance,
- a kinetic accent on speed and social moments (start, peer arrival) so the fast/urban register is
  represented, kept clear of legibility-critical cockpit data.

Detailed motion decisions belong to Chunks 1 and 2 (carried by the emil-design-eng and
swiftui-animation skills).

## Token-change summary (proposed, for Chunks 1 through 3 to apply)

Direction-level intentions, not final hex values; exact values are pinned against the WCAG guard when
each surface is built.

- **`AuraPalette.nearBlack` becomes a deep charcoal-green / slate base** (re-run through the existing
  contrast tests, which already guard primary/secondary/lime against it).
- **New: a custom Mapbox Studio terrain style** tuned to the palette (ROH-6), the core carrier of the
  identity in the cockpit.
- **`AuraPalette.panel` gains a frosted-glass treatment for calm surfaces only,** with an opaque
  fallback; contour texture is a separate calm-surface asset behind text plates.
- **`AuraPalette.lime` (`#C8FA4B`), `amber` (warning), `pink` (destructive): unchanged.**
- **New peer-dot slots:** moving-peer and host/leader colors, non-colliding with lime and amber.
- **`textPrimaryWhite` / `textSecondaryWhite`: revalidated** against the new base and any opaque text
  plate. The Wave 2 lift (secondary at 0.62 white) is a floor.

## Scope

In scope: the direction, the rules, the constraints, and the token intentions above. Out of scope: any
surface redesign (Chunks 1 through 3) and final hex values. No app code changes land under this spec.

## Chunk 0 exit: a device spike before final lock

Because the direction gates three chunks and the user now has a real device, the two questions most
likely to invalidate it are answered on device *before* Chunk 1 builds against them (device-first, per
the epic):

1. The custom terrain map style plus lime route line, read in bright sun at a sub-second glance while
   moving (a static style export is enough to judge).
2. Frosted-glass frame and thermal cost on a calm surface (Home), to confirm the calm-only scoping
   holds on real hardware.

The earlier "cool accent A/B" question is dropped (accent decided: lime). These fold into the
device-first verification the epic already commits to; the user opens the tunnel when we run them.
