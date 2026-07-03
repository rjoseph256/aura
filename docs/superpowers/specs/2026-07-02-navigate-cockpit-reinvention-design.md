# Interface & Feel — Chunk 2: navigate cockpit reinvention

**Date:** 2026-07-02
**Status:** Approved in brainstorming; pending adversarial spec review and user sign-off of this document.
**Linear:** ROH-44 (epic: Interface & Feel), folding in ROH-46 (live terrain style) as its first slice.
**Predecessors:** ROH-42 (Chunk 0 direction, done), ROH-6 + ROH-43 (terrain style + Home, merged at PR #66).

## Why this exists

Chunk 0 locked the direction: the identity lives in the map, the cockpit stays opaque and
legible, and the app is mono-mint on near-black terrain. Chunk 1 rebuilt Home against that
direction. The navigate cockpit — where a rider actually lives for an hour — is still the
Wave 2 layout on a *stock* Mapbox style. Two gaps stand out:

1. The live map renders `settings.mapStyle.mapboxStyle`, which only offers stock `.dark` /
   `.standard`. The authored terrain style (the identity carrier) never reaches the surface a
   rider stares at while moving. This is ROH-46.
2. The turn card's maneuver arrow is hardcoded `arrow.turn.up.right` regardless of the actual
   turn, because `GuidanceUpdate` carries only an instruction *string*. The single most
   valuable at-speed glance — which way am I turning — is not actually rendered.

The brainstorming decision was the biggest of the three offered swings: a ground-up re-layout,
not a restyle. The chosen hierarchy is **turn-forward** (the maneuver is the hero of the
glance), with the authored terrain map carrying the identity underneath, and a bumped bottom
instrument panel for speed and trip figures.

## The cockpit, redesigned

Layout, top to bottom:

- **Maneuver band** (top): a real directional arrow driven by structured maneuver data, a Saira
  distance-to-turn numeral, and the maneuver instruction / current street. This is the hero.
- **Then-chip**: a compact next-maneuver preview ("then Highland Ave") beneath the band, so the
  rider can plan one turn ahead.
- **Terrain map** (full-bleed, behind everything): the authored `AuraTerrainStyle.json`, live,
  with the mint route line on top. The identity carrier.
- **Instrument panel** (bottom): a full-bleed cockpit gauge filling the bottom ~quarter of the
  screen. A speed-*dominant* Saira hero (~150 pt — the number owns the panel, since realistic
  cycling speeds are only 1–2 digits) sits beside a stacked to-go / ETA pair, the two grouped as
  one centered cluster so the panel's slack falls to the outer margins instead of a gap down the
  middle. The current street reads as a slim caption above. No climb stat (chosen: the terrain
  identity is carried by the map, not a number). *Proportion and hierarchy were locked on-device
  with the PO on 2026-07-02 — see the reconciliation note at the end.*
- **Control rail** (bottom-leading): recenter, mute, end-ride at 44 pt tap targets.
- **GPS chip** (top-leading), unchanged in role.

What is deliberately *not* here: no live blur over the moving map (Chunk 0 Rule 1); cockpit data
sits on opaque fills — the quarter-screen instrument panel on `AuraTheme.surface`, smaller chrome
on `mapScrim`. No climb-ahead / grade instrument (that was the climb-hero option C, not chosen).
No peer-dot color-system redesign (deferred to Chunk 3, see Scope).

## Build order — four slices

Each slice is independently reviewable. Slice 1 is also independently shippable (it is ROH-46 and
touches only the map style). Slices 2 through 4 are serially dependent: Slice 3's views need Slice
2's maneuver data, and Slice 4's motion and states need Slice 3's layout. Order is chosen so the
identity foundation lands first and the risky data plumbing is proven before the view work depends
on it.

### Slice 1 — ROH-46: the live authored terrain style

Render the bundled `AuraTerrainStyle.json` on every live `Map`, not just the Home snapshot. This
slice is **independently shippable** and has no dependency on Slices 2 through 4 (the map style is
orthogonal to the turn card).

- Add a case to `AuraKit.MapStyle`: `case auraTerrain` (raw value `"auraTerrain"`). Stock `.dark`
  and `.standard` stay as Settings alternates.
- Bridge it in `MapStyle+Mapbox.swift` (app target). The MapboxMaps v11 SwiftUI `Map` accepts a
  JSON style via `MapboxMaps.MapStyle(json:)` (confirmed against the SDK: `MapStyle.swift:92`).
  The bridge calls the **existing app-target loader** directly — no new loader type:

  ```swift
  case .auraTerrain:
      AuraTerrainStyleLoader.json().map(MapboxMaps.MapStyle.init(json:)) ?? .dark
  ```

  `AuraTerrainStyleLoader.json()` (`Aura/Sources/Home/`) already loads the bundled
  `AuraTerrainStyle.json` via `TerrainStyle.authoredStyleResource`; it is a stateless static, so
  Home and the live map sharing it does not couple the two features. On a missing/unreadable asset
  the bridge falls back to stock `.dark`, exactly as Home falls back today. (`MapStyle+Mapbox`
  already imports both `AuraKit` and `MapboxMaps`; it gains an import of the app-target loader,
  which is legal — both are app target.)
- Surfaces covered: **three** live-map call sites, each reading `settings.mapStyle.mapboxStyle`
  today, so the one bridge change reaches all three: navigate HUD
  (`NavigateHUDView.navigateMapView`), free-ride / **Explore** (`RideMapView` — "Explore" is the
  Chunk-1 rename of free ride, not a separate surface), and route preview (`RoutePreviewView`).
  The Home backdrop is a snapshot, not a live map, and is already on the authored style. Each of
  the three is device-verified.

**Default semantics (resolved — no migration code).** `SettingsStore.init` resolves the style at
read time: `MapStyle(rawValue: defaults.string(forKey: Key.mapStyle) ?? "") ?? .dark`. Init
assignment does not fire `didSet`, so a rider who never opened the map-style setting has **no
stored key**. Flipping only this read-time fallback from `.dark` to `.auraTerrain` therefore flips
exactly the never-chose riders (who inherited the old default, never picked it) to terrain, while
anyone who explicitly stored `.dark` or `.standard` keeps their choice. Adding the enum case is
parse-backward-compatible (an unknown raw value still falls back). KVS sync is unaffected: a device
with an explicit stored value syncs that value; a never-chose device syncs nothing and each end
resolves the same new fallback. No `applyRemoteMapStyle` change, no first-launch flag, no divergence
across a synced account.

**Performance acceptance (gates the default).** Before `.auraTerrain` becomes the live default it
must clear, on device: sustained 60 fps (120 on ProMotion) with a bounded hitch ratio over a
30-minute recorded ride at speed, measured on the reference device (Rohun's iPhone 13 Pro Max, the
oldest hardware in the loop) via Instruments Core Animation + MetricKit `MXAnimationMetric`, and no
sustained `.serious`/`.critical` `thermalState` attributable to the style. If the authored style
misses that budget, the response is to **simplify the style** (shed relief/label layers until it
passes), not to silently keep stock dark as the default — the identity-in-the-map thesis requires
terrain to be what a rider actually sees. Keeping stock dark as the shipped default is the last
resort, recorded as Risk 2, not the planned outcome.

### Slice 2 — structured maneuver data (current + next)

Give the turn card a real direction to point, and give the then-chip a real next turn.

- **First task is a Mapbox field audit** (no view depends on it): confirm the Navigation v3
  `RouteStep` exposes `maneuverType` + `maneuverDirection` (skeptic-review found it does:
  `mapbox-directions-swift RouteStep.swift`), and that `RouteProgress.currentLegProgress` exposes
  both `.currentStep` and `.upcomingStep` (it does — `MapboxGuidanceSession.swift:181` already
  reads `upcomingStep`). If any field is absent the audit surfaces it here, and the arrow / then-chip
  degrade to their nil fallbacks without blocking the rest of the chunk.
- Extend `AuraCore.GuidanceUpdate` with **two** optional structured maneuvers:
  `var maneuver: Maneuver?` (the current/upcoming turn) and `var nextManeuver: Maneuver?` (the turn
  after it, for the then-chip). `Maneuver` is a pure value type (AuraCore) carrying a `kind`
  (turn, fork, roundabout, rotary, merge, onRamp, offRamp, depart, arrive, continue, endOfRoad,
  uTurn) and a `modifier` (left, right, slightLeft, slightRight, sharpLeft, sharpRight, straight,
  uTurn, none), plus an optional short label (e.g. the next street, or a roundabout exit ordinal
  where the SDK supplies one). Both fields optional so a stream that cannot supply them degrades.
- Populate both in the app-target `MapboxGuidanceSession.guidanceUpdate()`: `maneuver` from
  `currentLegProgress.upcomingStep` (the turn being approached — same step that drives the
  co-located `instruction`/`distanceToManeuver`), and `nextManeuver` from the step *after* it
  (`remainingSteps.dropFirst().first`, since `remainingSteps.first == upcomingStep`). The
  `Route` model has no step list, so the then-chip is driven by this event field, **not** derived
  from `Route` (the earlier draft's wording was wrong). `nextManeuver` is nil when there is no
  step after the upcoming one (final leg), which hides the then-chip.
- Thread both fields through `ScriptedGuidanceSession` and every guidance test that emits
  `.progress`, so the scripted double can seed current + next for presenter and view tests.
- A pure `ManeuverIcon.symbol(for: Maneuver?) -> String` (AuraKit) maps kind+modifier to an SF
  Symbol name (a plain `String`, no SwiftUI/UIKit import, so it stays pure and macOS-CI-testable),
  returning the current generic arrow for `nil` / unknown. It is the single source of truth for
  the turn card, the then-chip, and (via a pushed glyph string, see Slice 4) the Live Activity.
  The full kind×modifier → symbol table and the then-chip behavior per kind are pinned in the
  **Maneuver taxonomy appendix** below.
- `TurnCardState` gains `maneuver: Maneuver?`; a new pure `NextManeuver` value (symbol + short
  label) is derived by `TurnCardPresenter` from `update.nextManeuver`. The derived SF-Symbol name
  is read by the views from `ManeuverIcon`, not stored on the state, to keep the state value
  engine- and rendering-independent.

Test fixtures: `Maneuver` is hand-authored in AuraCore tests (it is a pure value type, no SDK
import), covering every kind×modifier the taxonomy table lists plus the nil/unknown fallback; a
table-completeness test asserts `ManeuverIcon` returns a non-generic symbol for every enumerated
kind×modifier, so an added case can't silently fall through to the generic arrow. Everything in
Slice 2 is pure and macOS-CI-testable **except** the `MapboxGuidanceSession` population, which is
app-target and device/build-verified.

### Slice 3 — the re-layout

Rebuild the cockpit views against the approved hierarchy.

- `TurnCardView`: directional arrow (from `ManeuverIcon`) + Saira distance + instruction/street.
  Keeps the shipped collapsed/expanded morph (mint fill on imminence, the `.smooth(0.38)`
  master animation, Reduce-Motion crossfade fallback).
- `ThenChip`: a new compact next-maneuver preview. Driven by the pure `NextManeuver` value from
  Slice 2 (`ManeuverIcon` symbol + short label). Hidden when `nextManeuver` is nil. It is
  **decorative for VoiceOver** (`.accessibilityHidden(true)`): its "then Highland Avenue" content
  is composed by `TurnCardPresenter` into the turn card's single `accessibilityLabel`
  (extending the Wave 2 SP2 one-composed-element contract), so VoiceOver reads
  "In 400 feet, turn right onto Penn Ave, then Highland Avenue" as one stop, never two.
- These views are **navigate-only**: free ride (`RideHUDView` / `RideMapView`) has no turn card,
  then-chip, or maneuver band, so nothing here touches the free-ride path.
- `InstrumentPanel`: replaces the navigate-mode `SpeedRail(.speedOnly)` + `TripStripView` pair
  (`TripStripView` is deleted — its street / to-go / ETA fold into this panel) with one
  quarter-screen gauge: a speed-dominant ~150 pt Saira hero beside a stacked to-go / ETA pair,
  the two centered as a single cluster, with a slim street caption above. Built on
  `RideStatsFormatter` + `AuraTheme.Typography.speedHero` / `.metricCockpit` over an opaque
  `AuraTheme.surface` fill with a hairline top edge and rounded top corners; sized via
  `containerRelativeFrame(.vertical, count: 4, span: 1)`. `SpeedRail`'s free-ride `.full` layout
  is untouched.
- `ControlRail`: `ControlCluster` re-expressed as a leading vertical rail (recenter / mute /
  end). Same actions, same `HUDControlButton` styling, same accessibility.
- `NavigateHUDView` body recomposed to place band + then-chip at top and the instrument panel +
  control rail at the bottom, preserving every existing lifecycle hook (`.task` start, coordinator
  wiring, summary sheet, permission sheet, group overlays, teardown).

Pure presenters (`TurnCardState`, `NextManeuver`, the `ManeuverIcon` table) are TDD'd in AuraKit;
the SwiftUI views are implemented directly and device-verified.

### Slice 4 — motion, edge states, group reflow

- **Motion language** (all `accessibilityReduceMotion`-guarded; zero residual map drift while
  recording, per the Chunk 0 accessibility matrix). The celebrated moment is turn **completion**,
  not turn imminence — a rider passes ~10 turns an hour, so the imminence morph must not carry a
  per-turn flourish that reads as a gimmick (feel-review frequency rule):
  - Turn imminence: keep the shipped collapsed→expanded morph to the mint fill (`.smooth(0.38)`),
    with **no** added bounce. The mint fill still appears under Reduce Motion (it is a state
    change, legibility-relevant), but without the scale/morph — crossfade only.
  - Turn completion (the maneuver advances and the then-chip promotes into the band): this is the
    forward-momentum beat. The arrow swaps via `.contentTransition(.symbolEffect(.replace))` and
    the band gets a single subtle pulse/scale settle. Under Reduce Motion: opacity crossfade only,
    no transform. (`.symbolEffect` is iOS 17+, the project targets iOS 26;
    `.symbolEffectsRemoved(reduceMotion)` guards any inherited effect.)
  - `ThenChip` transitions on `nextManeuver` change with move+opacity; under Reduce Motion it uses
    `.transition(.opacity)` only (no slide). Hidden→shown and shown→hidden both crossfade.
  - Speed / ETA / to-go: `.numericText()` paired with `.snappy` (already the cockpit pattern). No
    per-tick animation — speed updates too often to animate (feel rule: don't animate the
    frequent).
  - Arrival: a single mint route-pulse as the cockpit hands off to the summary. The signature
    terrain-carved *medal* remains Chunk 3's; this is only a light close.
  - Recenter viewport fly unchanged (snaps under Reduce Motion, as today).
  - Motion sheds under `ProcessInfo.thermalState` at `.serious` / `.critical` (Chunk 0 Rule 3).
- **Edge states**, restyled to the new chrome:
  - Pre-guidance (`.starting`) and guidance-unavailable (`.unavailable`): existing states,
    re-skinned into the new band.
  - Rerouting: the existing cue, restyled; the mint route redraw animates in where cheap, else
    instant (verified for frame cost).
  - GPS weak/lost: navigation **does not pause** — the turn card holds the last maneuver and the
    route stays drawn; the existing `GPSSignalChip` escalates to a calm amber chrome treatment so
    the rider knows guidance may lag until the fix returns. No new location plumbing — reads the
    existing `location.signal`.
- **Group crew reflow**: the roster docks above the new instrument panel (compact when collapsed,
  expandable), toasts stay top-center below the band, the reconnecting pill stays top. Because the
  new `InstrumentPanel` + `ControlRail` change the bottom-stack height that
  `GroupRosterSheet`'s `.padding(.bottom, .xxxl)` assumes, this slice defines explicit spacing so
  the collapsed roster, the expandable roster's max height, and the instrument+rail block all clear
  each other within the safe area, and **device-verifies roster reachability** one-handed on a
  handlebar mount. Peer dots ride the live terrain map: this slice verifies their legibility on the
  authored terrain and applies a minimal contrast fix if any status color washes out, so there is
  no broken intermediate state — but it does **not** redesign the peer-dot color *system* (the
  moving-peer/leader value pinning stays Chunk 3, per Chunk 0 Constraint B).
- **Ownability gate (device, PO-decided).** Capture the HUD chrome alone (turn card + then-chip +
  instrument + rail, map hidden) and judge against Chunk 0 Constraint C: is it identifiably Aura?
  If yes, the cockpit's identity holds on Saira + mint + the opaque chrome + the terrain map, and
  nothing is added. If no, add one small **non-climb** identity signal here (e.g. a terrain-contour
  motif on the panel edge or a signature route/speed treatment — the climb stat stays out, per the
  approved layout). The gate is a Slice 4 acceptance item, resolved on device with the PO.
- **Glanceability gate (device).** Device-verify the cockpit at 20+ mph in sunlight, one-handed:
  the arrow direction is correct at a sub-second glance and the then-chip aids rather than adds
  dwell. If the then-chip reads as clutter, gate it to imminence (show only within N seconds of the
  turn) rather than always-on. This is an acceptance gate on Slice 3/4, not a claim taken on faith.

## Components and boundaries

Pure (AuraCore / AuraKit — macOS-CI-tested):

- `Maneuver` (kind + modifier + optional label value type), `GuidanceUpdate.maneuver` and
  `GuidanceUpdate.nextManeuver`.
- `ManeuverIcon.symbol(for:)` — the SF-Symbol mapping table (returns a plain `String`, no UI import).
- `TurnCardState.maneuver`, `NextManeuver`, and the presenter changes.
- `MapStyle.auraTerrain` case + the `SettingsStore` default.
- `CruisingPresenter` / `CruisingState`: unchanged (the instrument panel reuses to-go / ETA).

App target (device / build-verified):

- The `MapStyle+Mapbox` JSON bridge, calling the existing app-target `AuraTerrainStyleLoader.json()`.
- `TurnCardView`, `ThenChip`, `InstrumentPanel`, `ControlRail`, recomposed `NavigateHUDView`.
- `MapboxGuidanceSession` maneuver + next-maneuver population.
- Scope-lite Live Activity: the `RideLiveActivityController` (app target, imports AuraKit) derives
  the glyph via `ManeuverIcon.symbol(...)` and pushes it as a new `turnGlyphSystemName: String?` on
  the activity `ContentState`; the widgets extension (a separate target that cannot import app code)
  renders `Image(systemName:)` from the decoded state. This keeps `ManeuverIcon` the single source
  of truth without adding it to the extension's target membership.

Unchanged: `RideSessionCoordinator` (ride lifecycle, stats, speed, Live Activity, save), the
guidance event protocol shape, the summary and permission sheets, the group session transport.

## Data flow

`MapboxGuidanceSession` reads `currentLegProgress.upcomingStep` (→ `maneuver`) and the step
after it (→ `nextManeuver`) → emits `GuidanceUpdate(maneuver:…, nextManeuver:…)` → `GuidanceViewModel` derives `TurnCardState`
(+ a `NextManeuver` from `update.nextManeuver`) → `TurnCardView` / `ThenChip` render, reading
`ManeuverIcon` for glyphs. The coordinator continues to own stats and feeds the instrument panel
(speed, elapsed, distance) and the Live Activity. `settings.mapStyle` (read-time default
`.auraTerrain`) flows through the one `mapboxStyle` bridge to the three live maps.

## Accessibility

- Every new motion respects Reduce Motion per the Chunk 0 matrix: the completion pulse and the
  then-chip slide drop to crossfades, the mint fill still appears without its morph, and the map
  never drifts while recording.
- The turn card + then-chip read as a single composed VoiceOver element, and the instrument panel
  as another (extending the Wave 2 SP2 pattern): the band reads "In 400 feet, turn right onto Penn
  Ave, then Highland Avenue" (the then-chip is `.accessibilityHidden`, its suffix composed into the
  card's label by the presenter); the instrument reads speed and trip figures as one phrase. The
  directional arrow is decorative, its meaning already in the spoken instruction.
- Contrast: cockpit surfaces keep the opaque `mapScrim` / `prefersOpaqueSurface` path and its WCAG
  guard; the terrain base and any new opaque plate colors join the existing contrast suite. Text
  legibility over the *live* terrain is a device-verified property (CI cannot model it), consistent
  with Chunk 0 Rule 2.
- Dynamic Type: cockpit numerals self-scale via Saira `relativeTo:`; the panel caps at
  `.accessibility1` like the shipped rail so it never swamps the map.

## Performance

- No live blur over the moving map. Cockpit data is opaque `mapScrim`. This keeps the expensive
  case (frosted glass) confined to calm surfaces, per Chunk 0.
- Target: sustained 60 fps (120 on ProMotion) with a bounded hitch ratio over a recorded ride;
  motion sheds under thermal pressure. The authored style's live cost (vs the stock style it
  replaces) is measured on device in Slice 1 before the layout depends on it.

## Testing

- Pure unit tests: the `ManeuverIcon` kind×modifier table including a **completeness test** (every
  enumerated kind×modifier returns a non-generic symbol) plus the nil/unknown fallback;
  `TurnCardState` and `NextManeuver` presenter cases (current + next, and the composed VoiceOver
  label carrying the "then…" suffix); `MapStyle.auraTerrain` read-time default, raw-value
  round-trip, and unknown-value fallback.
- CI: the existing `check-terrain-style.sh` guard already covers the JSON asset; no new asset.
- Device-first (per the epic): the three live map surfaces on the terrain style; the **performance
  gate** (Slice 1 acceptance criteria on the iPhone 13 Pro Max); the **glanceability gate** and
  **ownability gate** above; the cockpit at speed (arrow direction correct, then-chip advancing,
  instrument legible in sun); Reduce Motion; a group-ride reflow with reachable roster and legible
  peer dots. XCUITest smoke where automatable.

## Risks

1. **Maneuver fields on the Mapbox step.** Lowered by the spec-review audit: `RouteStep` exposes
   `maneuverType` + `maneuverDirection` and `currentLegProgress` exposes `.currentStep` +
   `.upcomingStep`, so the data is retrievable. Residual risk is coverage (does every kind — e.g.
   roundabout exit ordinals — come through cleanly); Slice 2's first task confirms per-kind before
   the views depend on it. Worst case a kind falls back to the generic arrow and the chunk still
   lands.
2. **Live-style frame/thermal cost.** The authored style renders continuously on a moving map, not
   as a one-shot raster like Home's snapshot, so it is a genuinely different workload. Slice 1
   gates the default on the explicit acceptance criteria above (60/120 fps, 30-min recorded ride,
   iPhone 13 Pro Max, no sustained thermal pressure). Primary response to a miss is to simplify the
   style until it passes; keeping stock dark as the shipped default is the last resort, and it
   degrades ROH-46 without blocking ROH-44's layout.
3. **Slice coupling.** Slice 1 is independent and shippable alone. Slices 2→3→4 are serially
   dependent (3's views need 2's data; 4's motion/states need 3's layout). The plan sequences them
   accordingly rather than treating them as parallel.

(The earlier "default flip migration" risk is resolved in Slice 1 — the read-time-fallback flip
needs no migration code and cannot diverge a synced account.)

## Scope

In scope: the four slices above — live terrain style + default, structured maneuver data +
directional arrows, the turn-forward re-layout, and the motion / edge-state / group-reflow pass.

Out of scope (Chunk 3, ROH-45): the peer-dot color *system* (moving-peer / leader values pinned
against the real style), the terrain-carved summary medal, and systematic polish beyond the
cockpit. Also out: any climb-ahead / grade instrument (the unchosen option C), and any change to
the ride lifecycle, routing, or group transport.

## Appendix — Maneuver taxonomy

`ManeuverIcon.symbol(for:)` maps a `Maneuver` (kind × modifier) to an SF Symbol. The then-chip
shows the same glyph plus a short label. `nil` / unknown → the generic `arrow.turn.up.right`. The
kind/modifier vocabulary follows the Mapbox Directions maneuver model so `MapboxGuidanceSession`
maps 1:1. Exact symbol picks are finalized in the plan against what is available and legible at a
glance; the point of the table is that every enumerated case has a defined, tested mapping and
then-chip behavior — no silent generic fallback for a known kind. The completeness test enforces
this.

| Kind | Modifier(s) | Arrow glyph (indicative) | Then-chip label |
| --- | --- | --- | --- |
| turn | left / right / slightLeft / slightRight / sharpLeft / sharpRight | `arrow.turn.up.{left,right}` variants; slight/sharp use the nearest directional symbol | "then \<street\>" |
| continue / straight | straight / none | `arrow.up` | "then \<street\>" |
| fork | left / right | `arrow.triangle.branch` (mirrored by side) | "then keep \<side\>" |
| merge / onRamp / offRamp | left / right / slight | `arrow.merge` / ramp-appropriate | "then \<street\>" |
| roundabout / rotary | exit side; exit ordinal when the SDK supplies one | `arrow.clockwise.circle` (or an exit-annotated glyph) | "then exit \<n\>" when the ordinal is present, else "then \<street\>" |
| uTurn | uTurn | `arrow.uturn.down` | "then \<street\>" |
| endOfRoad | left / right | `arrow.turn.up.{left,right}` | "then \<street\>" |
| depart | none | `location.fill` / start glyph | (usually no chip) |
| arrive | none / left / right | `flag.checkered` / `mappin` | (no chip — final) |

When the Mapbox step does not supply a needed field for a kind (e.g. no roundabout exit ordinal),
the chip falls back to the street-name form or hides, never renders a placeholder.

## Reconciliation with the adversarial spec review (2026-07-02)

Three independent reviewers (executability/skeptic, rider-experience, architecture) reviewed the
first draft with a refuting mandate. Resolved into the spec above:

- **"Explore" is not a fourth live map** — it is the Chunk-1 rename of free ride (`RideMapView`).
  Corrected to three live-map surfaces (Slice 1).
- **Then-chip had no data source** — `Route` has no step list and `GuidanceUpdate` had no next
  step. Added `nextManeuver` to `GuidanceUpdate`, populated from the step *after* `upcomingStep`
  (`remainingSteps.dropFirst().first`), threaded through `ScriptedGuidanceSession` + tests
  (Slice 2, Data flow). The Mapbox fields are confirmed available.
- **Default-flip migration** — resolved to a read-time-fallback flip that needs no migration code
  and cannot diverge a synced account (Slice 1). Removed the punted open question.
- **`AuraLiveMapStyle` was undefined** — dropped it; the bridge calls the existing
  `AuraTerrainStyleLoader.json()` (Slice 1, Components).
- **Live Activity target boundary** — glyph pushed as a `ContentState` string, not by importing
  `ManeuverIcon` into the extension (Components).
- **VoiceOver ownership of the then-chip suffix** — composed into the turn card's single label;
  chip is `.accessibilityHidden` (Slice 3, Accessibility).
- **Group roster ↔ new bottom layout collision + reachability** — explicit spacing + a device
  reachability gate; peer-dot legibility fixed minimally so there is no broken intermediate state,
  color system still Chunk 3 (Slice 4).
- **Performance stated as a hand-wave** — concrete acceptance criteria that gate the default, with
  layer-shedding (not silent opt-in) as the response to a miss (Slice 1, Risk 2).
- **Motion budget on the wrong beat** — completion, not per-turn imminence, is the celebrated
  moment; the per-turn bounce is cut (Slice 4).
- **Maneuver coverage (roundabouts/forks/no-next)** — taxonomy appendix + completeness test.
- **GPS-loss behavior** — navigation continues on the last route; chip escalates (Slice 4).
- **Ownability gate** — PO-decided: device-test the HUD-only chrome in Slice 4, add a non-climb
  identity signal only if it fails (Slice 4).

Filtered as non-issues: metric units (already handled by the unit-aware `RideStatsFormatter`); a
"free-ride maneuver band" (free ride has no turn card — the new views are navigate-only).
