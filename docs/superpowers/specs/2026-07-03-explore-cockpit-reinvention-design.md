# Explore cockpit reinvention — design

**Date:** 2026-07-03
**Linear:** ROH-45 (Chunk 3 — Systematic polish pass), first sub-pass
**Epic:** Interface & Feel
**Status:** approved in brainstorm; pending adversarial spec review

## Problem

The Interface & Feel epic reinvented Home ("Where to?" plan surfaces, Chunk 1) and the
navigate cockpit (Chunk 2 / ROH-44) around one visual direction: terrain identity in the
map, opaque legible cockpit chrome, a quarter-screen speed-dominant instrument panel, and
Saira Condensed numerals on charcoal with a mint (`#7CF0A8`) signal accent.

The **Explore** ride surface — the renamed free-ride mode that records a GPS track with no
turn-by-turn — was not part of that redesign. It already uses the shared tokens (Saira
numerals, mint units, `AuraTheme`), so it is not the old-old cockpit, but it is a
previous-generation layout sitting under the same map. The visible inconsistency: a rider
who plans a route gets the reinvented cockpit, while a rider who taps Explore gets a lighter,
floating one.

### Where Explore diverges today

`RideHUDView` (`Aura/Sources/Ride/RideHUDView.swift`):

| Aspect | Explore now | Navigate cockpit (redesigned) |
| --- | --- | --- |
| Instrument | floating `SpeedRail`, bottom-trailing | quarter-screen opaque `InstrumentPanel` |
| Speed hero | 62pt | 150pt, dominant |
| Surface | semi-transparent `.mapScrim()` over the map | opaque `AuraTheme.surface` chassis + hairline |
| Controls | one centered Start/End CTA, **no recenter** | 3-button cluster (recenter · mute · end) |
| Map style | `settings.mapStyle.mapboxStyle` (**already terrain**) | same |

The map style is already shared, so terrain on the Explore map needs no work.

## Goal

Bring the Explore in-ride cockpit up to the navigate bar so the two ride modes read as one
cockpit family, adapting the shared chassis to a free ride's data (no destination, no ETA,
no turn card) rather than forcing navigate's instruments onto it.

This is the **first sub-pass of ROH-45**, not all of Chunk 3.

## Scope

**In scope**

- The Explore in-ride cockpit: `RideHUDView`.
- A shared `InstrumentChassis` extracted from the current `InstrumentPanel`.
- A pure `ExploreInstrumentState` for the instrument values and composed VoiceOver label.
- The control cluster (recenter + end), auto-start with a back-out valve, and the edge-state refit.

**Out of scope** (later Chunk 3 sub-passes)

- Ride summary, History, Settings, destination search, route preview, offline maps,
  group lobby/join/roster, widgets, and the Live Activity.

**Already satisfied**

- Terrain map style on the Explore map (`RideMapView` applies `settings.mapStyle.mapboxStyle`).

## Design

### Components

**`ExploreInstrumentState` (pure, AuraKit, unit-tested).** The Explore analogue of
`CruisingState`. Built from `RideStats` + elapsed seconds + `DistanceUnits` through the
existing `RideStatsFormatter`, so units, spoken forms, and the elevation-gain treatment stay
consistent app-wide. Exposes:

- `distance: String` — distance ridden.
- `movingTime: String` — moving/elapsed time.
- `elevationGain: String` — elevation climbed.
- `accessibilityLabel: String` — one composed read, e.g. *"5.0 miles ridden, 24 minutes,
  340 feet climbed"*.

The view holds no formatting; every string is produced here and provable in package CI.

**`InstrumentChassis` (app target).** Extracted from the current `InstrumentPanel` skeleton
with no visual change: the 150pt Saira speed hero and mint unit, the opaque `AuraTheme.surface`
panel with rounded-top corners and a `hairline(contrast)` bleeding to the bottom edge, the
centered `HStack(hero, column)` layout with the outer-margin slack, the
`.dynamicTypeSize(...accessibility1)` cap, and the composed-VoiceOver wiring on the speed
element. Parameters:

- `currentSpeedMetersPerSecond: Double`
- `units: DistanceUnits`
- a `@ViewBuilder` secondary-instrument column
- the column's composed accessibility label
- an optional top line (navigate's street name); Explore passes none.

**`InstrumentPanel` (navigate) becomes a thin caller** of `InstrumentChassis`, passing its
TO GO / ARRIVE column and street line. No behavior change — same pixels, same VoiceOver
reads; its existing tests still pass.

**`ExploreInstrumentPanel` (new, app target)** — a thin caller passing a three-instrument
column driven by `ExploreInstrumentState`.

### Layout

The Explore cockpit uses the same quarter-screen chassis as navigate.

- **Instrument panel** pinned to the bottom via
  `.containerRelativeFrame(.vertical, count: 4, span: 1)`, opaque, bleeding to the home
  indicator. Same footprint as navigate.
  - **Speed hero** (left): 150pt Saira Condensed current speed + mint unit — the dominant
    element, up from today's 62pt floating readout. Reads the smoothed
    `coordinator.currentSpeedMetersPerSecond`, not the ride average.
  - **Instrument column** (right, stacked beside the hero): three 34pt Saira cockpit numbers
    over caption labels — **DISTANCE**, **TIME**, **CLIMB** — matching navigate's TO GO /
    ARRIVE instrument sizing. **CLIMB** is a word label, not the raw "FT ↑ / M ↑" glyph the
    old rail showed, consistent with the redesigned cockpit's word labels.
  - No street-name top line: a free ride has no current-street context, so the panel starts at
    the hero row.
- **Control cluster** (bottom-trailing, docked above the panel): navigate's geometry minus
  mute — **Recenter** (lights mint when the rider pans off the puck, re-engages `followPuck`
  on tap, exactly as navigate) then **End ride** (destructive pink, behind the
  "Keep riding" / "End ride" confirmation). Both `.hudControl()`.
- **Top chrome:** GPS-signal chip stays top-trailing. The back button behavior is defined by
  the start decision below.
- **Map:** the existing `RideMapView` (terrain style already applied); recenter re-engages
  `followPuck`.

Net: the floating bottom-trailing `SpeedRail` and the separate centered Start/End CTA both
go away, replaced by the anchored instrument panel and the two-button cluster.

### Start behavior and back-out

Entering Explore from Home **auto-starts recording** immediately (parity with how navigate
begins), through the existing `coordinator.start(...)` path.

The back-out valve is a pure, testable predicate on ride progress:

- While the ride has not crossed a small distance floor (~25 m, tunable; near the existing
  10 m HealthKit floor), the **top-leading back button is visible** and discards the ride with
  no summary (`coordinator.cancel()`, already called on disappear — no junk ride is saved).
- Once the ride crosses the floor, the back button retires and the rider **ends through the
  summary** via the cluster's End button.

This gives one-tap consistency with navigate while letting an accidental Explore tap bail
cleanly. The floor predicate lives in the pure layer so the threshold is unit-tested and easy
to tune.

### Edge states

All refit to the new layout with no new behavior.

- **GPS-weak:** the existing `GPSSignalChip` stays top-trailing.
- **Permission denied:** auto-start returns `.permissionDenied`; `LocationPermissionView` is
  presented as today, and back-out remains available.
- **Reduce Transparency / Increase Contrast:** inherited free — the chassis is already opaque
  `AuraTheme.surface` with `hairline(contrast)`.
- **Reduce Motion:** nothing gratuitous. The only motion is the speed's existing
  `.numericText()` content transition and the recenter mint-light.

### Motion

Deliberately restrained. Navigate celebrates turn *completion*; a free ride has no turns, so
there is no bespoke motion. The cockpit is calm; the map is the moving element.

## Testing

Mirrors how the navigate cockpit was proven.

- **Pure (AuraKit/AuraCore):** `ExploreInstrumentState` formatting and composed accessibility
  label across imperial and metric, zero values, and large values; the back-out distance-floor
  predicate at, below, and above the threshold.
- **Regression:** `InstrumentPanel` (navigate) produces the same output after the
  `InstrumentChassis` extraction; existing suites stay green.
- **Simulator/device verify (device-first, via the tunnel):** the free-ride cockpit reads
  correctly through the accessibility tree — speed hero, the three instruments, the recenter
  toggle lighting off-puck, auto-start on entry, back-out discard below the floor, and
  End → summary above it.

## Open questions

None blocking. The distance floor for the back-out valve is set at ~25 m and is tunable during
implementation; it is exercised by a unit test rather than a magic number in the view.

## Out-of-scope follow-ups

The remaining ROH-45 surfaces (summary, History, Settings, search, route preview, offline,
group surfaces, widgets, Live Activity) are separate Chunk 3 sub-passes and are not touched
here.
