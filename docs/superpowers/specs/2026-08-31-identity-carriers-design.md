# Identity Carriers — premium map-layer pass (design)

**Date:** 2026-08-31
**Epic:** Interface & Feel — revives [ROH-45](https://linear.app/rohun/issue/ROH-45) (Chunk 3 — Systematic polish pass) as its second sub-pass.
**Status:** PO-approved design (this session's brainstorm); awaiting adversarial spec review.
**Verification:** mixed — Tier 2 for the riding puck and traveled-dim, Tier 1 for everything else (see §8).

## 1. Context

A full UI audit (simulator screenshot tour of every reachable surface + a file-by-file
inventory of the ~60 SwiftUI surfaces) found the design foundation already strong — the
token system, contrast gating, Dynamic Type, VoiceOver composition, and Reduce Motion
coverage clear the premium bar. The gap to Strava/Komoot-class polish is concentrated in
a few systemic tells on the map layer, which every session sees:

1. **The stock blue iOS location puck** renders on every live map (Home, both HUDs) in
   the middle of a fully custom-branded terrain style. Loudest single "not custom" signal
   in the app.
2. **The route line is a flat mint polyline** — no casing, no rounded caps, no
   origin/destination markers, no traveled-vs-ahead distinction while navigating.
3. **Map-floating surfaces have drifted into six treatments** for one job, and the bare
   `.ultraThinMaterial` sites silently drop the Reduce Transparency / Increase Contrast
   branch that `AuraTheme.mapScrim(...)` exists to provide (`DESIGN.md`'s own rule).
4. **Ornament collisions:** the Mapbox scale bar draws over the back button on route
   preview and both HUDs; Home's header gear bleeds through behind the search overlay's
   Cancel; a gem pin can poke out from behind the gem peek card.

This slice fixes exactly these four. Search redesign, the Crew family, Home motion, and
History aggregates are later slices and explicitly out of scope (§9).

## 2. Decisions locked with the PO

- **Two-state puck.** Quiet dot while browsing; directional arrowhead while riding.
- **Dim-behind-rider on navigate only.** The free-ride (Explore) recorded trace is a
  different layer and keeps drawing at full mint. Untouched.
- **Charter holds.** No gradients anywhere; no pulsing/ambient animation on the puck;
  route line is static. Motion in this slice is limited to state changes that already
  exist (viewport transitions).
- **Per-element visual approval.** Nothing rolls out in one sweep. Each visual element
  is rendered in the simulator and screenshotted for PO sign-off before it spreads past
  its first surface (§7). Approval of this spec is not approval of the pixels.

## 3. Workstream A — the Aura puck

### Current state

`Puck2D(bearing: .heading)` with stock imagery at exactly three sites:

- `Aura/Sources/Home/HomeLiveMap.swift:64` (browse)
- `Aura/Sources/Ride/RideMapView.swift:42` (free ride / Explore)
- `Aura/Sources/Ride/NavigateHUDView.swift:291` (navigate)

The route-preview map deliberately has **no puck** ("the preview never follows a puck",
`RoutePreviewView.swift:377`) and this slice does not add one.

### Design

Two fixed per-surface states, both drawn in code from theme tokens (no bundled PNGs, so
the puck can never drift from the palette):

- **Browse puck** (Home live map): mint core, near-black ink ring, soft *static* halo
  (a larger low-opacity mint disc — not `.pulsing`, which stays off), and a small ink
  heading wedge via `bearingImage`.
- **Riding puck** (both HUDs): a mint arrowhead with an ink outline, rotated by heading
  via `bearingImage`, sized to stay glanceable at cockpit zoom 16. No halo — the arrow
  itself is the emphasis; a halo under `followPuck` at speed reads as smear.

Implementation: `Puck2DConfiguration`'s SwiftUI surface (`.topImage` / `.bearingImage` /
`.shadowImage` modifiers on `Puck2D`) with `UIImage`s rendered by a small app-target
`PuckImageRenderer` (UIGraphicsImageRenderer, `AuraTheme` colors). Proportions and sizes
live in a pure `PuckMetrics` type in AuraCore so package tests can pin them (same pattern
as `HUDControlMetrics`). Exact point sizes are settled at the visual gate, not in this
spec; the metrics type is the single place they live.

Accessibility: the halo and ring derive from tokens that already pass WCAG package
tests; Increase Contrast swaps the halo for a solid ring via the existing
`ColorSchemeContrast` resolvers. Reduce Motion needs no branch (nothing animates).

### Error handling

None new — puck imagery is generated, not loaded, and `Puck2D` falls back to showing
nothing before the first fix exactly as today.

## 4. Workstream B — the route-line system

### Current state

Single flat `PolylineAnnotation`, mint, square caps:

- Route preview: `RoutePreviewView.swift:331-339` (width 5)
- Navigate: `NavigateHUDView.swift:296-304` (width 6, redrawn from the live route on reroute)
- Detour (free ride): `RideMapView.swift:120-123` (width 6)

`AuraTheme.routeCasingUIColor` (near-black, built from the `background` token) already
exists for the share card (`AuraTheme.swift:89`) and is reused here — no new color.

### Design

Everywhere a **planned** route draws (preview, navigate, detour):

- **Casing:** a second polyline under the mint line — `routeCasingUIColor`, ~2pt wider
  per side. Declaration order inside the `PolylineAnnotationGroup` puts casing first.
- **Round caps/joins:** `lineCap(.round)` / `lineJoin(.round)` at the group/layer level
  (same level the codebase already documents for `lineDash`, `RideMapView.swift:104-105`).
- **Endpoint markers** (preview and navigate only): an origin dot in the browse-puck
  family (mint core, ink ring) and a destination marker (mint circle, ink glyph) as map
  annotations at the route's ends. The detour adds **no** destination marker — its
  destination is already the surfaced gem/spot pin, and a second marker would double it.

On **navigate only**, the traveled portion dims:

- Split the live route geometry at `routeLengthMeters − distanceRemainingMeters`, using
  `GuidanceUpdate.distanceRemainingMeters` (`GuidanceSession.swift:12`), which the
  cockpit already consumes for "TO GO".
- Ahead of the split: full treatment (casing + mint, width 6). Behind: a thinner
  (width 4), dimmed mint trace (`routeLine` at 0.25 opacity — the value the detour
  already uses to dim the recording, `RideMapView.swift:112`), no casing.
- **Fallback:** `distanceRemainingMeters` is nil until known and transiently on
  reroute — render the full undimmed line whenever it is nil or exceeds the current
  geometry's length. The split recomputes from the live route shape, so reroutes stay
  consistent by construction.
- The split is a pure AuraCore function (`RouteSplit.split(coordinates:atMeters:)`)
  with package tests: zero/route-length/overshoot boundaries, a point exactly on a
  vertex, and a two-point degenerate route.

The recorded free-ride track (`TrackRibbon` pieces) is explicitly untouched.

### Error handling

Degenerate geometry (<2 coordinates) draws exactly what it draws today (nothing). The
split function clamps rather than throws; a nil progress means "no dim", never "no line".

## 5. Workstream C — map-scrim unification

### Current state (the drift)

One job — "a floating surface over the map" — six treatments:

| Treatment | Sites | Honors Reduce Transparency / Increase Contrast? |
|---|---|---|
| `AuraTheme.mapScrim(...)` | GPSSignalChip, PauseControl, GroupToastHost, NavigateHUDView:168 | yes |
| bare `.ultraThinMaterial` | `DetourOverlay.swift:84,101,114,127`, `HomeMapCanvas.swift:45` | **no** |
| `surface.opacity(0.85)` | `ThenChip.swift:28`, `GroupRideMapOverlay.swift:120` | no |
| `surface.opacity(0.9)` | `NavigateHUDView+GroupCrew.swift:45,77,104`, `HomeGlass.swift:72` | no |
| `surface.opacity(0.92)` | `TurnCardView.swift:87` | no |
| manual branch | `GroupLobbyView.swift:158`, `GroupRosterSheet.swift:227` | manually |

### Design

One shared modifier in the Theme folder — `.mapFloating(shape:)` — that applies
`AuraTheme.mapScrim(reduceTransparency:contrast:)` as the fill and
`AuraTheme.hairline(contrast)` as the stroke, reading both environment values itself so
call sites cannot forget the branch. All sites in the table migrate to it. The
`HomeGlass` family keeps its Liquid Glass path (that is a deliberate iOS 26 treatment);
only its *fallback* fill migrates.

Opacity converges on the existing single token `AuraPalette.mapScrimOpacity` (0.85).
If the visual gate shows the turn card genuinely needs more, the token moves for
everyone — no per-site forks. `MarkSpotToast.swift:36`, which defeats the hairline
resolver by passing the literal `.standard`, migrates too.

**Enforcement:** a SwiftLint custom rule bans `ultraThinMaterial` outside
`Aura/Sources/Theme/` and `HomeGlass.swift`, so the drift cannot silently return (same
structural-enforcement philosophy as the async-default-argument rule).

This workstream is convergence, not redesign: before/after screenshots ride along in
the PR, but it carries no PO pixel gate.

## 6. Workstream D — ornament and collision fixes

1. **Scale bar.** Set explicit `OrnamentOptions` per map surface: hidden on both ride
   HUDs (no use mid-ride; it currently draws over the back/GPS area), margin-shifted
   below the back button on route preview, default on Home (no conflict observed).
2. **Search overlay bleed.** Home's header controls (History/Settings gear cluster)
   are removed from the hierarchy while `searchExpanded` — today they render beneath
   the overlay and the gear shows through behind Cancel.
3. **Gem pin vs peek card.** While a gem's peek card is showing, that gem's own map pin
   is hidden — the card *is* that gem's presence, and it is the pin that pokes out from
   behind the card today. Deterministic, no projection math. Collisions between the
   card and *other* gems' pins are camera-dependent and stay best-effort (out).
4. **Map labels under buttons** (e.g. "Troy Hill" beneath the gear): camera-dependent,
   not deterministically fixable — documented as out of scope.

## 7. PO approval gates (process, from the PO directly)

Three visual gates, each a screenshot set delivered before the work spreads:

1. **Puck pair** — browse + riding states rendered in the sim, before the puck rolls
   out beyond its first surface.
2. **Route treatment** — preview (casing + endpoints) and navigate mid-ride (dim
   behind) screenshots, before merge of workstream B.
3. **Whole-slice before/after** — the full screenshot set at branch end, alongside the
   whole-branch review.

A gate failing means the element iterates at that surface; it does not proceed on a
promise to fix later.

## 8. Verification tiers (docs/VERIFICATION.md)

- **Tier 2 (device, queued as a Verification issue):** riding-puck heading behavior
  under real GPS/compass, traveled-dim advancing during real movement, and general
  ride-feel of the new puck under `followPuck`. These merge on CI green with the device
  check queued for the next ride — none are plausibly *wrong* in a way only hardware
  reveals, so no merge holds.
- **Tier 1 (sim-verified by Claude):** browse puck, preview casing/markers, scrim
  migration (including Reduce Transparency and Increase Contrast passes in the sim),
  ornament/collision fixes. Screenshots in each PR.

## 9. Out of scope

Search overlay redesign; Crew/group family; Home motion pass (matchedGeometryEffect
work); History aggregates; token-literal hygiene beyond files this slice already
touches; adding a puck to route preview; map-label/button overlaps; any route-line
animation or gradient.

## 10. Success criteria

1. No stock blue puck renders anywhere in the app.
2. Every planned-route polyline draws cased with round caps; preview and navigate show
   origin/destination markers; navigate dims the traveled portion and falls back to the
   full line whenever progress is unknown.
3. Explore's recorded trace renders byte-identically to today.
4. Zero `.ultraThinMaterial` sites outside Theme/HomeGlass (lint-enforced); every
   migrated surface honors Reduce Transparency and Increase Contrast.
5. The scale bar never overlaps a control; the gear never shows through search; a
   surfaced gem's pin never pokes out from behind its own card.
6. All existing WCAG, palette, and metrics package tests pass; new `RouteSplit` and
   `PuckMetrics` tests pass.
7. `DESIGN.md` is corrected as part of this slice: the stale `SpeedReadout` entry is
   removed, the scrim rule's component name is updated, and the puck + route-line
   treatments are documented.

## 11. Board mechanics

One child issue under ROH-45 per workstream (A–D), created before implementation
starts, moving Todo → In Progress → In Review → Done per the board flow; plus one
Tier-2 Verification issue for the device checks in §8. Suggested build order:
D → C → A → B (hygiene first, then the gated visual work), but the plan stage owns
sequencing.
