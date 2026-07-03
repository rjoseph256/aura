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
- **Instrument panel** (bottom): bumped up from the Wave 2 rail — a confident speed hero
  (~56 pt Saira, between the old 34 pt and a speed-dominant 76 pt), with distance-to-go and ETA
  as a paired block. No climb stat (chosen: the terrain identity is carried by the map, not a
  number).
- **Control rail** (bottom-leading): recenter, mute, end-ride at 44 pt tap targets.
- **GPS chip** (top-leading), unchanged in role.

What is deliberately *not* here: no live blur over the moving map (Chunk 0 Rule 1); cockpit data
sits on opaque `mapScrim` fills. No climb-ahead / grade instrument (that was the climb-hero
option C, not chosen). No peer-dot color-system redesign (deferred to Chunk 3, see Scope).

## Build order — four slices

Each slice is independently reviewable and, where possible, independently shippable. Order is
chosen so the identity foundation lands first and the risky data plumbing is proven before the
view work depends on it.

### Slice 1 — ROH-46: the live authored terrain style

Render the bundled `AuraTerrainStyle.json` on every live `Map`, not just the Home snapshot.

- Add a case to `AuraKit.MapStyle`: `case auraTerrain` (raw value `"auraTerrain"`). It becomes
  the **default** (`SettingsStore` default flips from `.dark` to `.auraTerrain`). Stock `.dark`
  and `.standard` stay as Settings alternates.
- Bridge it in `MapStyle+Mapbox.swift`. The MapboxMaps v11 SwiftUI `Map` accepts a JSON style
  via `MapboxMaps.MapStyle(json:)` (confirmed against the SDK: `MapStyle.swift:92`). The bridge
  loads the same bundled JSON the snapshotter uses:

  ```swift
  case .auraTerrain:
      AuraLiveMapStyle.json().map(MapboxMaps.MapStyle.init(json:)) ?? .dark
  ```

  where `AuraLiveMapStyle.json()` reuses the existing `AuraTerrainStyleLoader` (renamed or
  wrapped so both Home and the live map share one loader; the loader is app-target, the enum is
  AuraKit, so the bridge — already app-target — is the join point). On a missing/unreadable
  asset it falls back to stock `.dark`, exactly as Home falls back today.
- Surfaces covered: navigate HUD (`NavigateHUDView.navigateMapView`), free-ride
  (`RideMapView`), route preview, and Explore. All four already read
  `settings.mapStyle.mapboxStyle`, so the single bridge change reaches them; each is
  device-verified.

Persistence: `MapStyle` already round-trips through `SettingsStore` and KVS sync; adding an enum
case is backward compatible (an unknown stored raw value already falls back). A migration is not
required, but the default flip means existing installs on `.dark` keep `.dark` — acceptable, and
Settings lets them opt into terrain. (Open question for the plan: do we *migrate* existing
`.dark` users to the new default, or only default fresh installs? Recommendation: only fresh
installs, to respect an explicit prior choice — but most users never chose, they inherited the
old default. Resolve in the plan.)

### Slice 2 — structured maneuver data

Give the turn card a real direction to point.

- Extend `AuraCore.GuidanceUpdate` with an optional structured maneuver:
  `var maneuver: Maneuver?` where `Maneuver` is a pure value type carrying a `type` (turn, fork,
  roundabout, merge, depart, arrive, continue, …) and a `modifier` (left, right, slight-left,
  slight-right, sharp-left, sharp-right, straight, uturn). Optional so a stream that cannot
  supply it degrades cleanly.
- Populate it in the app-target `MapboxGuidanceSession` from the Mapbox step's maneuver fields
  (verified as available on the Navigation SDK step in Slice 2's first task; if the current path
  does not expose them, that task surfaces it before any view depends on it).
- A pure `ManeuverIcon.symbol(for: Maneuver?) -> String` (AuraKit) maps type+modifier to an SF
  Symbol name, returning the current generic arrow for `nil` / unknown. This is the single
  source of truth for both the turn card and (scope-lite) the Live Activity.
- `TurnCardState` gains a `maneuver: Maneuver?` (and the derived symbol is read by the view, not
  stored, to keep the state value engine-independent). `TurnCardPresenter` threads the maneuver
  through unchanged otherwise.

All of Slice 2 is pure and macOS-CI-testable except the `MapboxGuidanceSession` population,
which is app-target and device/build-verified.

### Slice 3 — the re-layout

Rebuild the cockpit views against the approved hierarchy.

- `TurnCardView`: directional arrow (from `ManeuverIcon`) + Saira distance + instruction/street.
  Keeps the shipped collapsed/expanded morph (mint fill on imminence, the `.smooth(0.38)`
  master animation, Reduce-Motion crossfade fallback).
- `ThenChip`: a new compact next-maneuver preview. Driven by a pure `NextManeuver` value
  (`ManeuverIcon` symbol + short label), derived by the presenter from the route's *next* step.
  Nil (hidden) when there is no next step or it is unknown.
- `InstrumentPanel`: replaces the navigate-mode `SpeedRail(.speedOnly)` + `TripStripView` pair
  with one bumped panel — speed hero + a right-aligned to-go / ETA block — built on existing
  `SpeedReadout` / `StatPair` / `RideStatsFormatter` tokens and the `mapScrim` opaque fill.
  `SpeedRail`'s free-ride `.full` layout is untouched.
- `ControlRail`: `ControlCluster` re-expressed as a leading vertical rail (recenter / mute /
  end). Same actions, same `HUDControlButton` styling, same accessibility.
- `NavigateHUDView` body recomposed to place band + then-chip at top and the instrument panel +
  control rail at the bottom, preserving every existing lifecycle hook (`.task` start, coordinator
  wiring, summary sheet, permission sheet, group overlays, teardown).

Pure presenters (`TurnCardState`, `NextManeuver`, the `ManeuverIcon` table) are TDD'd in AuraKit;
the SwiftUI views are implemented directly and device-verified.

### Slice 4 — motion, edge states, group reflow

- **Motion language** (all `accessibilityReduceMotion`-guarded; zero residual map drift while
  recording, per the Chunk 0 accessibility matrix):
  - Turn arrow swaps via `.contentTransition(.symbolEffect(.replace))` on maneuver change; a
    single `.bounce` on the arrow at the moment the card expands to the imminent state (a rare,
    meaningful event — the one place delight belongs, per the feel review). Under Reduce Motion:
    no bounce, crossfade only.
    (`.symbolEffect` variants used here are iOS 17+; the project targets iOS 26, so all are
    available. `.symbolEffectsRemoved(reduceMotion)` where a residual effect would otherwise
    inherit.)
  - `ThenChip` transitions on next-maneuver change with a move+opacity (or `.blurReplace`)
    transition; when the current turn completes it hands its content up into the main band.
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
  - GPS weak/lost: the existing `GPSSignalChip` escalates to a calm amber chrome treatment when
    signal is poor, so the rider knows guidance may lag. No new location plumbing — reads the
    existing `location.signal`.
- **Group crew reflow**: the roster docks just above the new instrument panel (compact when
  collapsed, expandable), toasts stay top-center below the band, the reconnecting pill stays top.
  Peer dots ride the live terrain map. This slice verifies peer-dot legibility on the authored
  terrain and reflows chrome only; it does **not** redesign the peer-dot color system.

## Components and boundaries

Pure (AuraCore / AuraKit — macOS-CI-tested):

- `Maneuver` (type + modifier value type), `GuidanceUpdate.maneuver`.
- `ManeuverIcon.symbol(for:)` — the SF-Symbol mapping table.
- `TurnCardState.maneuver`, `NextManeuver`, and the presenter changes.
- `MapStyle.auraTerrain` case + the `SettingsStore` default.
- `CruisingPresenter` / `CruisingState`: unchanged (the instrument panel reuses to-go / ETA).

App target (device / build-verified):

- The `MapStyle+Mapbox` JSON bridge + a shared `AuraLiveMapStyle.json()` loader.
- `TurnCardView`, `ThenChip`, `InstrumentPanel`, `ControlRail`, recomposed `NavigateHUDView`.
- `MapboxGuidanceSession` maneuver population.
- Scope-lite: the Live Activity turn glyph reads `ManeuverIcon`.

Unchanged: `RideSessionCoordinator` (ride lifecycle, stats, speed, Live Activity, save), the
guidance event protocol shape, the summary and permission sheets, the group session transport.

## Data flow

`MapboxGuidanceSession` decodes the route step → emits `GuidanceUpdate(maneuver:…)` →
`GuidanceViewModel` derives `TurnCardState` (+ `NextManeuver`) → `TurnCardView` / `ThenChip`
render, reading `ManeuverIcon` for glyphs. The coordinator continues to own stats and feeds the
instrument panel (speed, elapsed, distance) and the Live Activity. `settings.mapStyle` (default
`.auraTerrain`) flows through the one `mapboxStyle` bridge to all four live maps.

## Accessibility

- Every new motion respects Reduce Motion per the Chunk 0 matrix: transforms and the arrow
  bounce drop to crossfades; the map never drifts while recording.
- The turn card, then-chip, and instrument panel each remain a single composed VoiceOver element
  (extending the Wave 2 SP2 pattern): the band reads "In 400 feet, turn right onto Penn Ave,
  then Highland Avenue"; the instrument reads speed and trip figures as one phrase. The directional
  arrow is decorative (`.accessibilityHidden`), its meaning already in the spoken instruction.
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

- Pure unit tests: `ManeuverIcon` symbol table (every type/modifier + the nil/unknown fallback),
  `Maneuver` decode from the engine fixture, `TurnCardState`/`NextManeuver` presenter cases,
  `MapStyle.auraTerrain` default + raw-value round-trip + unknown-value fallback.
- CI: the existing `check-terrain-style.sh` guard already covers the JSON asset; no new asset.
- Device-first (per the epic): all four live map surfaces on the terrain style; the cockpit at
  speed (arrow direction correct, then-chip advancing, instrument legible in sun); Reduce Motion;
  a group ride reflow. XCUITest smoke where automatable.

## Risks

1. **Maneuver fields on the Mapbox step.** If the current `MapboxGuidanceSession` path does not
   expose type+modifier, Slice 2's first task surfaces it before the views depend on it; worst
   case the arrow stays generic and the rest of the chunk still lands.
2. **Live-style frame/thermal cost.** The authored style is heavier than the stock style it
   replaces; measured on device in Slice 1. If it regresses the moving-map budget, the fallback
   is to keep the stock dark style default and offer terrain as an opt-in (degrades ROH-46, does
   not block ROH-44's layout).
3. **Default flip semantics.** Whether to migrate existing `.dark` users; resolved in the plan
   (recommendation: fresh installs only).

## Scope

In scope: the four slices above — live terrain style + default, structured maneuver data +
directional arrows, the turn-forward re-layout, and the motion / edge-state / group-reflow pass.

Out of scope (Chunk 3, ROH-45): the peer-dot color *system* (moving-peer / leader values pinned
against the real style), the terrain-carved summary medal, and systematic polish beyond the
cockpit. Also out: any climb-ahead / grade instrument (the unchosen option C), and any change to
the ride lifecycle, routing, or group transport.
