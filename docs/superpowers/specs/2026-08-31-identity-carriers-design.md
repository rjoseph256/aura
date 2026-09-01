# Identity Carriers — premium map-layer pass (design)

**Date:** 2026-08-31 (v2, reconciled after the 3-reviewer adversarial spec gate)
**Epic:** Interface & Feel — revives [ROH-45](https://linear.app/rohun/issue/ROH-45) (Chunk 3 — Systematic polish pass) as its second sub-pass.
**Status:** implemented on `claude/identity-carriers-handoff-b8341f` (commits
`dade599..58524f3`). PO gates 1a, 1b, 2 and 3 passed; gate 4 (whole-slice set) and the
whole-branch review are the controller's. §10 sweep: **6 met, 2 partly met, 0 not met.**
Partly met: §10.3 — the traveled-dim behavior and its CI non-coverage are both verified, but
its "and its PR says so" clause is outstanding because no PR is open yet; §10.6 — the navigate
HUD's panned-off scale bar is correct by construction and photographed on the identical Explore
HUD, but has no navigate-HUD frame of its own. The riding puck keeps its Tier-2 merge hold on
the device heading check (§8); traveled-dim feel and accuracy-ring behavior under real GPS stay
queued as ROH-224.
**Verification:** mixed — Tier 2 with a merge hold for the riding puck, Tier 2 queued for
traveled-dim feel, Tier 1 for everything else (see §8).

## 1. Context

A full UI audit (simulator screenshot tour of every reachable surface + a file-by-file
inventory of the ~60 SwiftUI surfaces) found the design foundation already strong. The gap
to Strava/Komoot-class polish is concentrated in systemic tells on the map layer:

1. **The stock blue iOS location puck** renders on every live map (Home, both HUDs) in
   the middle of a fully custom-branded terrain style.
2. **The route line is a flat mint polyline** — no casing, no rounded caps, no
   origin/destination markers, no traveled-vs-ahead distinction while navigating.
3. **Map-floating chip surfaces have drifted** into several one-off treatments. The bare
   `.ultraThinMaterial` sites skip Aura's *Increase Contrast* solid-surface branch and
   the token system (system materials do adapt to Reduce Transparency on their own — the
   spec gate corrected an earlier overclaim here; the loss is the contrast branch and
   consistency, and that is still worth fixing).
4. **Ornament collisions and stock ornaments:** the Mapbox scale bar draws over the back
   button on route preview and both HUDs; the stock adaptive compass renders on the
   course-up HUDs; Home's header bleeds through behind the search overlay.

This slice fixes exactly these. Search redesign, the Crew family, Home motion, and
History aggregates are later slices (§9).

## 2. Decisions locked with the PO

- **Two-state puck.** Quiet marker while browsing; directional arrowhead while riding.
- **"White = me."** *(v2, from the spec gate.)* The rider's marker is **not mint**: on
  the Explore HUD it would sit in the same hue as the recorded trace, up to ten gem
  pins, and a detour line. The codebase already encodes the answer — group-ride self is
  deliberately `textPrimary` white (`GroupRideMapOverlay.swift`, `PeerDotView.headColor`)
  and `AuraPalette.riderHues` pointedly excludes mint. The puck is white-cored with an
  ink outline and a mint ring accent; in a crew, "white = me, hued disc = peer" is one
  grammar.
- **Dim-behind-rider on navigate only.** The free-ride (Explore) recorded trace keeps
  its current rendering; on overlapping legs (out-and-back, loops) the bright
  ahead-layer draws above the dim layer, so shared streets read as "ahead" — the right
  failure mode, and now a stated one.
- **Charter holds.** No gradients; no pulsing; the route line is static paint. The
  browse puck's ambient ring is the SDK's **real accuracy ring** (flat low-opacity mint
  fill via `showsAccuracyRing` + themed colors), not a decorative halo — it means
  something, and a flat fill is not a gradient.
- **Per-element visual approval.** Nothing rolls out in one sweep. Every workstream —
  including C — carries a PO gate (§7). Approval of this spec is not approval of pixels.

## 3. Workstream A — the Aura puck

### Current state

`Puck2D(bearing: .heading)` with stock imagery at exactly three sites —
`HomeLiveMap.swift:64`, `RideMapView.swift:42`, `NavigateHUDView.swift:291`. The
route-preview map deliberately has no puck (`RoutePreviewView.swift:378`) and this slice
does not add one.

### Design

Two fixed per-surface states, drawn in code from theme tokens:

- **Browse puck** (Home live map): white core, near-black ink outline, thin mint ring;
  heading wedge via `bearingImage`; the SDK accuracy ring (mint, low opacity, themed via
  `accuracyRingColor`/`accuracyRingBorderColor`) as the only ambient element. Home's map
  is north-up, so the wedge is the part that rotates and informs.
- **Riding puck** (both HUDs): white ROUNDED TRIANGLE, ink outline, 2.5pt mint edge
  (gate 1a locked 2026-08-31: PO rejected the notched dart, picked the rounded
  triangle from a four-variant sheet, and bumped the mint edge from 1.5pt). Honest
  rationale (gate finding): under `followPuck(bearing: .heading)` the map rotates and
  the arrow points screen-up almost always — its value is the "this is me, moving"
  grammar plus correct rotation whenever the rider pans off-follow. No accuracy ring.

**SDK constraints the implementation must obey** (verified against the resolved SDK at
`Puck2DRenderer.swift:333,127-129,78-85`; all three become `PuckMetrics` invariants):

1. **`topImage` is mandatory on both states.** A nil `topImage` falls back to Mapbox's
   stock blue dot rendered *on top of* the bearing image. The riding state supplies the
   arrow as `bearingImage` plus an explicitly transparent `topImage`.
2. **Paint order is shadow → bearing → top**, so the browse wedge (a `bearingImage`)
   draws under the core: its tip radius must exceed the core's outer radius, on an
   oversized transparent canvas so rotation about the image center places it correctly.
3. **One `scale` feeds all three image sizes** — core/ring/wedge relationships are
   ratios baked into the bitmaps, not independent sizes.
4. **Images must be identity-stable** (`static let`): the SDK diffs configurations by
   `UIImage` pointer identity, and a fresh image per body pass re-uploads bitmaps every
   frame inside the navigate HUD's 30 Hz `TimelineView`.

`PuckMetrics` (AuraCore, `Double`-only — the package builds on macOS CI) pins invariants
1–3 as *rules* (wedge-tip radius > core radius; ratio relationships), not point-size
literals; exact sizes are settled at the visual gate and recorded in the metrics type.
`PuckImageRenderer` (app target) consumes it.

## 4. Workstream B — the route-line system

### Current state

Flat single `PolylineAnnotation`, mint, square caps, at four sites: route preview
(`RoutePreviewView.swift:331-339`), navigate (`NavigateHUDView.swift:296-304`, redrawn
from the live route on reroute), detour (`RideMapView.swift:120-123`), and the ride
summary's `StaticRouteMap.swift:29-34` — the gate added the fourth; the summary is the
most-looked-at map in the app, and the share card already draws the same ride cased
(`ShareMapSnapshotter.swift`), so leaving the summary flat would ship a one-tap
inconsistency.

### Design — casing and endpoints

- **Native casing, not a second polyline** *(v2)*: `lineBorderColor` (=
  `routeCasingUIColor`) + `lineBorderWidth` (~2pt) at the annotation/group level — one
  layer, z-correct by construction. Where two line layers must stack (navigate's dim
  under-layer), the plan review traced the SwiftUI content tree's layer ordering and
  found it deterministic and re-asserted every pass — the stack is declared in content
  order, with an explicit acceptance check (and a slot-based fallback) for the one
  relationship outside that chain: the puck must draw above the route line.
- **Round caps/joins** at the group level (`lineCap(.round)` / `lineJoin(.round)` —
  both verified group-level in the resolved SDK).
- Honest framing (gate finding): on the dark default styles the near-black casing adds
  little separation — its value is legibility over bright map features, the `.standard`
  style, and parity with the share card. The visual gate judges the effect, not the
  mechanism.
- **Endpoint markers:**
  - *Origin* — **preview only** *(v2)*: a small hollow mint ring, deliberately **not**
    in the puck vocabulary — route preview's origin can be a fallback coordinate when
    location is denied (`LocationService.current()` returns a hardcoded Pittsburgh
    center), and a puck-like dot there would assert "you are here" falsely. On navigate
    the origin marker bought ~30 seconds of visibility and a stacked-under-the-puck
    moment; cut.
  - *Destination* — preview, navigate, **and detour** *(v2)*: a filled mint marker with
    an ink glyph. The gate showed the detour's "its gem pin is already there" premise is
    false — the target can fall out of the 10-pin proximity cap and renders in the
    calmer seen style the moment it surfaces. Markers are `MapViewAnnotation`s with
    `.allowOverlapWithPuck(true)` (the default `false` would hide the destination
    marker exactly on final approach).

### Design — traveled-dim on navigate (v2: paint-only trim, no geometry splitting)

The v1 `RouteSplit` mechanism is dead — the gate refuted it three ways (its nil-fallback
can never fire in production; `routeLength − distanceRemaining` subtracts across
different geometries after a reroute; and re-splitting geometry at the HUD's 30 Hz
timeline cadence is real main-actor cost). Replacement:

- **Progress source:** `GuidanceUpdate` gains `fractionTraveled: Double?`, fed from the
  SDK's `RouteProgress.fractionTraveled` — dimensionless, computed by the engine against
  the same route it navigates, already `.safeValue()`-guarded. A small pure mapper in
  AuraCore (`RouteTrim`, beside `GuidanceUpdate`) clamps to [0, 1] with non-finite
  values → nil (tested; `max(0, .nan)` traps from the gate noted).
- **Rendering (v2.1, from the plan review):** style primitives, NOT annotation groups —
  a `GeoJSONSource` with **`lineMetrics = true`** under two `LineLayer`s (dim below,
  cased bright above with `lineTrimOffset`). `PolylineAnnotationGroup` cannot set
  `lineMetrics`, and without it line-trim fails with a shader error that erases the
  bright line entirely (mapbox-maps-ios#1927) — Mapbox's own vanishing route line uses
  exactly this raw-layer pattern. Dim = mint at `AuraPalette.routeDimOpacity` (new
  token, gate-tunable inside a WCAG-tested band). Paint-property update only; the
  geometry source rebuilds only on reroute. Trim quantized (~0.5% steps).
- **Reroute honesty (v2.1):** while `guidance.isRerouting` is true, trim renders 0
  (full bright line), never a wrong dim. The plan review found this was
  unimplementable as inherited: `GuidanceViewModel.applyProgress` cleared
  `isRerouting` on EVERY progress tick (Mapbox keeps publishing old-route progress
  throughout a reroute fetch), and the stale fraction survived the geometry swap. The
  slice therefore fixes the view model (its own TDD task): `isRerouting` survives
  progress ticks and clears only on `.rerouted` (or a terminal event), and `.rerouted`
  nils the stale `fractionTraveled` so no frame pairs an old-route fraction with new
  geometry. Trim resumes on the first post-reroute fraction.
- **Drawn-route ≠ guided-route fix** (gate blocker): `MapboxGuidanceSession`'s registry
  fallbacks (`selectingAlternativeRoute` nil; registry miss re-fetch,
  `MapboxGuidanceSession.swift:138-160`) can navigate a route other than the one the
  HUD draws — invisible today, kilometers wrong once progress becomes a position on the
  line. Fix inside this workstream: when the session ends up navigating anything other
  than the registry's selected route, it emits the navigated geometry immediately (the
  existing `.rerouted` path, no longer suppressed for that case), so the drawn line is
  always the guided line.
- **Coverage honesty:** the golden-ride E2E uses `ScriptedGuidanceSession`, which never
  emits progress — the trim path does not execute in CI, and the PR must say so.
  Its exercise lives in gate 2's location playback and the Tier-2 device check.

The recorded free-ride track (`TrackRibbon` pieces) is untouched: no code changes to its
colors, widths, or piece derivation (the v1 "byte-identical" phrasing was unverifiable;
this is a code-level claim). The detour polyline gains casing, which overdraws slightly
more of the dimmed track beneath it — accepted, noted.

## 5. Workstream C — map-chip scrim convergence (v2: rescoped)

The v1 "migrate all sites in one sweep" contradicted §2's no-sweep rule and would have
flattened surfaces that are deliberately different. Rescoped:

**The articulated grammar** (this is the fix — a rule, not just a migration):
*Frosted material is for controls; flat scrim is for chips/text.* `HUDControlButton` and
`MapZoomControl` (both already honor the contrast branch) stay frosted **by rule**.
Map-floating *text chips* use one shared component.

**The component:** `.mapChip(stroke:)` in the Theme folder — fill =
`AuraTheme.mapScrim(...)`, stroke defaulting to `AuraTheme.hairline(contrast)` with a
`.none` case, reading both environment values itself.

**Migrates** (unconditional chip surfaces only): `DetourOverlay.swift:84,101,114,127`
(note :101 is a RoundedRectangle, not a Capsule); `HomeMapCanvas.swift:45`;
`ThenChip.swift:28`; the hand-rolled Rerouting chip at `NavigateHUDView.swift:168`
(already scrim+hairline by hand — converging it leaves the DESIGN.md rule without
hand-rolled exceptions); `NavigateHUDView+GroupCrew.swift:45,77,104` (navigate-HUD
chrome, not Crew-flow work — their manual border overlays are deleted, or the modifier
double-strokes them); `GroupRideMapOverlay.swift:120` (with `stroke: .none` — no new
outline on peer name tags). Opacity converges on `AuraPalette.mapScrimOpacity` (0.85,
WCAG-gated).

**Explicitly does NOT migrate** *(v2)*:
- `TurnCardView.swift:87` — conditional (expanded = accent fill, no stroke); keeps its
  own logic **and its 0.92**: the most-read surface at speed does not get more
  transparent to satisfy a convergence.
- `MarkSpotToast.swift:34` — opaque by design; only its `hairline(.standard)` literal
  is fixed to read the environment.
- `HomeGlass.swift` — Liquid Glass by design; its fallback keeps the accent stroke
  (identity), migrating the fill resolver only.
- `PauseControl`, `GPSSignalChip`, `GroupToastHost` — already on `mapScrim`.
- `GroupLobbyView.swift:158` / `GroupRosterSheet.swift:227` — lobby/sheet cards, not
  map-floating; out of scope (Crew slice).

**Enforcement:** SwiftLint custom regex rule banning `ultraThinMaterial` with
`match_kinds` limited to identifiers (the gate's probe showed it firing on comments),
excluding `Aura/Sources/Theme/`, the group lobby/roster files (each carries a
justifying comment), and `Aura/Widgets/` (pre-emptive: materials are idiomatic on
widget surfaces, and `Aura/Widgets` is inside `.swiftlint.yml`'s `included:`). The v2
`HomeGlass` exclusion was dropped at plan review — the file contains no bare material,
so the exclusion was inert; its fallback *fill* still migrates to the scrim resolver
(accent stroke kept). Known limit, stated: the rule enforces *location*, not the
contrast-branch invariant.

**Gate** *(v2)*: workstream C now carries a PO gate — before/after screenshots of the
navigate HUD (chips + turn card + controls in one frame) and the detour chrome.

## 6. Workstream D — ornaments and collisions

1. **Scale bar:** hidden **while following** on both HUDs, shown when the rider pans
   off-follow (`viewport.followPuck != nil` already drives the recenter control —
   same condition, for free); on route preview, margin-shifted below the back button
   with the offset derived from safe-area inset + `HUDControlMetrics` in an AuraCore
   metrics type (not a view literal — an iPhone-17-tuned constant is wrong on an SE).
   Home is re-checked in the `.live` map phase before claiming success (the audit
   screenshotted `.idle`).
2. **Compass:** the stock adaptive compass currently renders on both course-up HUDs — a
   second stock-Mapbox tell the audit missed (gate finding). Hidden on the HUDs (the
   recenter cluster owns orientation); untouched elsewhere. PO can veto at gate 3.
3. **Attribution/logo:** stated requirement — the Mapbox logo and attribution button
   remain visible on every surface. (Structurally safe: both default `.visible` and the
   ornament API defaults omitted fields; the pre-existing bottom-leading placement
   behind the cockpit is a separate concern, out of scope, noted for the board.)
4. **Search overlay bleed:** the **entire header** (greeting + wordmark + controls)
   AND the location hint are removed from the hierarchy while `searchExpanded` — the
   v1 gear-only fix would have left the wordmark ghosting at 40% through the scrim
   (`SearchOverlay.swift:16`), and the hint is the same top-anchored chrome under the
   same scrim (v2.1 widening, reconciled at plan review).
5. **Gem pin vs peek card:** *(v2)* **dropped.** The gate showed the hide-the-pin fix
   contradicted the card's own documented rationale ("the pin remains the durable
   object; this card is a shortcut", and its a11y announcement pattern depends on the
   pin staying focusable), and the colliding pin is generally a *different*, far-away
   gem — the same camera-dependent class §6's label rule already declares out of scope.
   A direction cue on the peek card belongs to the Explore slice.
6. `ornamentOptions` is a `Map`-returning modifier and must precede `.ignoresSafeArea()`
   (same constraint the codebase documents for `.onCameraChanged`).

## 7. PO approval gates

1. **Puck pair** — browse + riding rendered in the sim for proportions/color, **plus**
   the Tier-2 device check for heading rotation before the riding puck's PR merges (§8).
2. **Route treatment** — preview stills (casing + endpoints) and a **location-playback
   recording** of a navigate ride including one deliberate off-route deviation, per
   VERIFICATION.md's own Tier-1 rule ("geometry rather than sensor feel — drive them
   with simulated location playback, not by staring at a static screen"). Stills cannot
   show the reroute behavior, which is the risk.
3. **Chips + ornaments** — navigate HUD + detour chrome before/after set (workstream C)
   and the workstream-D set (scale bar placement, compass-free HUDs, search header) in
   the same review.
4. **Whole-slice before/after** — full screenshot set at branch end, with the
   whole-branch review.

**Wait protocol** (gate finding): while a gate awaits PO sign-off the workstream's PR is
marked blocked on the board with a Linear comment; the branch rebases on main before
merge if it waited. A gate failing means the element iterates at that surface.

## 8. Verification tiers (docs/VERIFICATION.md)

- **Tier 2 with a merge hold — riding puck (workstream A2).** The simulator delivers no
  `CLHeading`; a sim screenshot shows the arrow at bearing 0 only. The rotation
  convention of a hand-rasterized `bearingImage` (up vs right, mirrored, 90° off) is
  exactly a hardware-only defect, and the policy's Tier-2 list opens with this class
  (ROH-213). The riding-puck PR merges only after a device heading check. The v1 claim
  that nothing here warranted a hold was wrong, and the gate said so.
- **Tier 2, queued (no hold):** traveled-dim feel during real movement, accuracy-ring
  behavior under real GPS. Queued as a Verification issue for the next ride.
- **Tier 1 (sim):** browse puck statics (A1 ships separately from A2), casing/markers,
  chip convergence (with Increase Contrast + Reduce Transparency sim passes), ornaments,
  search-header fix. Evidence per §7; screenshots or playback recordings in each PR.

## 9. Prerequisite and out of scope

**Prerequisite task (P0, v2.1 strategy):** pin **`MapboxNavigation` exactly** (each
release exact-pins its `mapbox-maps-ios` version, so maps lands on exactly 11.28.0
transitively — pinning maps independently risks an unresolvable graph) and align
`MapboxSearch`'s exact pin (its `mapbox-common` exact pin must match maps'). Today
`project.yml` floats on `majorVersion: 11.0.0`, no app `Package.resolved` is tracked,
and CI regenerates the project — so CI builds whatever 11.x is newest, while the code
comments claim a pin (11.27.0; the resolved checkout is 11.28.0+). Every SDK behavior
this spec verified (`lineBorderColor`, `lineTrimOffset`, `resolvedTopImage`,
`allowOverlapWithPuck`, `ornamentOptions`) was verified against a floating dependency.
Pin it, fix the stale comment, and note the `lineTrimColor` caveat: the trim *color* API
is `@_spi(Experimental)` — this design deliberately avoids it (the dim comes from the
under-layer, trim only reveals it), so no SPI import ships.

**Out of scope:** search overlay redesign; Crew/group family (incl. lobby/roster cards);
Home motion; History aggregates; the Explore trace's rendering; a puck on route preview;
peek-card direction cue; map-label/button overlaps; attribution placement; any route
animation or gradient; copy fixes ("Start RIDE") — Tier C hygiene slice.

## 10. Success criteria

1. No stock blue puck — and no stock fallback `topImage` — renders anywhere; "white =
   me" holds on solo and group rides.
2. Preview, navigate, detour, and summary route lines draw cased with round caps via
   native border properties; preview shows the origin ring; preview/navigate/detour
   show the destination marker, visible over the puck on approach.
3. On navigate, the ridden portion reads dim behind the rider, driven by
   `fractionTraveled`; while rerouting the full bright line shows; the golden-ride E2E
   does not exercise this path and its PR says so.
4. No code changes to `TrackRibbon`; Explore's trace derivation is untouched.
5. Every migrated chip honors Increase Contrast and Reduce Transparency in a sim pass;
   the turn card keeps 0.92 and its expanded accent state; the lint rule is green with
   its stated exemptions.
6. Scale bar never overlaps a control in ANY state — following or panned-off (the
   panned state needs its own margin; plan-review finding); compass absent on HUDs
   only; logo and attribution remain visible wherever they are visible today (their
   pre-existing placement behind the cockpit is unchanged and out of scope); no
   header or hint ghosting behind search.
7. Package tests: `PuckMetrics` invariants (wedge/core/ratio rules), the
   `fractionTraveled` mapper (clamp, non-finite → nil), existing WCAG suite plus the new
   `routeDimOpacity` token composited over the dark and bright basemaps.
8. `DESIGN.md` corrected: stale `SpeedReadout` entry removed; the scrim rule rewritten to
   the two-tier grammar (frosted controls / flat chips) with the component named; puck
   and route-line treatments documented.

## 11. Board mechanics

Child issues under ROH-45: P0 (SDK pin), A1 (browse puck), A2 (riding puck, merge-held
on device heading check), B (route-line system incl. the guided-route-emission fix), C
(chip convergence), D (ornaments/collisions) — created before implementation, statuses
driven per the board flow; plus one Tier-2 Verification issue for the queued device
checks. Suggested order: P0 → D → C → A1 → B → A2; the plan stage owns final sequencing.
