# Explore cockpit reinvention — design

**Date:** 2026-07-03
**Linear:** ROH-45 (Chunk 3 — Systematic polish pass), first sub-pass
**Epic:** Interface & Feel
**Status:** approved in brainstorm; reconciled with a 3-reviewer adversarial spec review
(skeptic / UX-PO / architecture-edge)

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
| Start | manual "Start ride" tap | auto-start in `.task` on appear |
| Map style | `settings.mapStyle.mapboxStyle` (**already terrain**) | same |

The map style is already shared, so terrain on the Explore map needs no work.

## Goal

Bring the Explore in-ride cockpit up to the navigate bar so the two ride modes read as one
cockpit family, adapting the shared chassis to a free ride's data (no destination, no ETA,
no turn card) rather than forcing navigate's instruments onto it.

This is the **first sub-pass of ROH-45**, not all of Chunk 3.

## Scope

**In scope**

- The Explore in-ride cockpit: `RideHUDView` (layout, auto-start, controls, back-out, states).
- A shared `InstrumentChassis` extracted from the current `InstrumentPanel`.
- A pure `ExploreInstrumentState` for the instrument values and composed VoiceOver label.
- A pure `RideBackOutGate` for the discard-floor predicate.
- `ControlCluster` gains an optional mute so Explore can drop it.
- A viewport binding on `RideMapView` so the HUD can drive recenter.

**Out of scope** (later Chunk 3 sub-passes)

- Ride summary, History, Settings, destination search, route preview, offline maps,
  group lobby/join/roster, widgets, and the Live Activity's own layout.

**Already satisfied**

- Terrain map style on the Explore map (`RideMapView` applies `settings.mapStyle.mapboxStyle`).

## Design

### Components

**`ExploreInstrumentState` (pure, AuraKit, unit-tested).** Lives in AuraKit because it formats
through `RideStatsFormatter` (AuraKit); it is built from the AuraCore value type `RideStats`
plus elapsed seconds and `DistanceUnits`. It **mirrors the `CruisingState` / `CruisingPresenter`
pattern** navigate uses (a pure presentation state, testable in package CI) — it is not a
structural analogue, since `CruisingState` is destination-centric (street, distance-remaining,
ETA) and this is ride-centric. Shape:

```swift
public struct ExploreInstrumentState: Equatable, Sendable {
    public let distance: String       // e.g. "5.0 mi"
    public let movingTime: String     // e.g. "24:00"
    public let elevationGain: String  // e.g. "340 ft"
    public let accessibilityLabel: String  // "5.0 miles ridden, 24 minutes, 340 feet climbed"
    public init(stats: RideStats, elapsed: TimeInterval, units: DistanceUnits)
}
```

The spoken accessibility label reuses `RideStatsFormatter`'s spoken-unit forms (the same ones
Wave 2 added for the composed cockpit reads), so metric riders hear metric. Its own test file
(`ExploreInstrumentStateTests` in AuraKitTests) covers imperial and metric, zero, and large
values, including elevation. The view holds no formatting.

**`InstrumentChassis` (app target).** Extracted from the current `InstrumentPanel` skeleton
with no visual change: the 150pt Saira speed hero and mint unit, the opaque `AuraTheme.surface`
panel with rounded-top corners and a `hairline(contrast)` bleeding to the bottom edge, the
centered `HStack(hero, column)` layout, the `.dynamicTypeSize(...accessibility1)` cap, and the
speed element's composed-VoiceOver wiring. **The chassis owns the optional top line and applies
the single composed accessibility label across the whole secondary cluster**, so navigate's
one-breath read ("On Stedman Street, 7.2 miles to go, arriving 11:32 PM") is preserved rather
than split across a parent/child boundary. API:

```swift
struct InstrumentChassis<Column: View>: View {
    let currentSpeedMetersPerSecond: Double
    let units: DistanceUnits
    let topLine: String?              // navigate: street name; Explore: nil
    let columnAccessibilityLabel: String  // composed read for the whole secondary cluster
    @ViewBuilder let column: () -> Column // the secondary instruments
}
```

The chassis renders `topLine` (when non-nil), then the `HStack(speedHero, column)`, and wraps
the top-line + column region in `.accessibilityElement(children: .ignore)` +
`.accessibilityLabel(columnAccessibilityLabel)`. The speed hero stays its own composed element,
exactly as today.

**`InstrumentPanel` (navigate) becomes a thin caller** of `InstrumentChassis`, passing
`topLine: trip.streetName`, `columnAccessibilityLabel: trip.accessibilityLabel`, and a column of
the two `tripInstrument`s (TO GO / ARRIVE). Pixel- and VoiceOver-identical to today.

**`ExploreInstrumentPanel` (new, app target)** — a thin caller passing `topLine: nil`,
`columnAccessibilityLabel: state.accessibilityLabel`, and a column of three cockpit instruments
(DISTANCE · TIME · CLIMB) driven by `ExploreInstrumentState`.

**`ControlCluster` gains an optional mute.** `isMuted` and `onToggleMute` become optional; when
`onToggleMute` is nil the mute button is not rendered. Navigate passes both (unchanged); Explore
passes nil, because a free ride has no turn-by-turn voice to mute. No duplicate cluster view.

**`RideBackOutGate` (pure, AuraCore, unit-tested).** Holds the discard-floor constant and the
predicate:

```swift
public enum RideBackOutGate {
    public static let discardFloorMeters: Double = 25
    public static func canDiscard(distanceMeters: Double) -> Bool { distanceMeters < discardFloorMeters }
}
```

Tested at, below, and above the floor. The floor is one number in one place; ~25 m is a short
block, comfortably above the 10 m HealthKit save gate so a discardable ride is never one that
would have been saved.

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
    old rail showed, consistent with the redesigned cockpit's word labels. (Navigate stacks
    two; Explore stacks three — the extra row is validated for glanceability on device, per
    Testing.)
  - No top line: a free ride has no current-street context, so the panel starts at the hero row.
- **Control cluster** (bottom-trailing, docked above the panel): navigate's geometry with mute
  omitted — **Recenter** (lights mint when the rider pans off the puck) then **End ride**
  (destructive pink, behind the "Keep riding" / "End ride" confirmation). Both `.hudControl()`.
- **Recenter plumbing** mirrors navigate. Navigate does **not** use `RideMapView` — it renders
  its own `Map(viewport:)` and owns the `@State viewport` + `recenter()`. `RideMapView` today
  owns a private `@State viewport` with no external control, so this pass **hoists the viewport
  into `RideHUDView`** and passes it to `RideMapView` as a `@Binding`. `RideHUDView.recenter()`
  re-engages `.followPuck` (snap under Reduce Motion, fly otherwise), and the cluster reads
  `isFollowing: viewport.followPuck != nil` — the same wiring navigate already uses. The plan
  must grep `RideMapView` call sites first to confirm Explore is its only production caller (so
  the binding change carries no group-path risk); if another caller exists, it passes a constant
  binding.
- **Top chrome:** GPS-signal chip stays top-trailing. The back button behavior is defined by the
  start/back-out section below.
- **Map:** the existing `RideMapView` (terrain style already applied), invoked solo (default
  empty `peers`).

Net: the floating bottom-trailing `SpeedRail` and the separate centered Start/End CTA both go
away, replaced by the anchored instrument panel and the two-button cluster. If a grep shows
`SpeedRail` had no caller left after this (navigate already moved to `InstrumentPanel`), the
plan removes it; otherwise it stays.

### Start behavior and back-out

Entering Explore from Home **auto-starts recording** on appear, mirroring navigate: `RideHUDView`
gains a `.task` that calls `coordinator.start(...)`, replacing today's manual "Start ride" tap.
A `.permissionDenied` outcome presents `LocationPermissionView` (as navigate does); the rider can
open Settings from it or dismiss it and back out (the back button is available at zero distance).

The exit model uses an **always-visible top-leading back button** so there is never a dead spot:

- **Below the discard floor** (`RideBackOutGate.canDiscard(distanceMeters:)` true): back
  **discards** the ride with no summary. Discard performs a **full teardown** — `coordinator.cancel()`
  must stop streaming, release screen-wake, **and end the Live Activity**, so an auto-started
  free ride that is discarded leaves no orphaned Lock Screen activity. (This also hardens the
  existing `onDisappear → cancel()` path for both HUDs.) No ride is saved (cancel never calls
  `finish()`).
- **At or above the floor:** back opens the **same "Keep riding" / "End ride" confirmation** the
  cluster's End button uses, so the button is never dead and there is always one obvious exit.
  Ending routes through `coordinator.finish()` → the `finishedRide` summary sheet, unchanged.
- `swipeBackEnabled` is matched to the back button: enabled while the ride can be discarded,
  disabled once it can only be ended (so a stray edge-swipe can't drop a real ride, but a
  just-started one can still be swiped away).

The discard predicate is the pure `RideBackOutGate`, read from `coordinator.stats.distanceMeters`.
There is a benign race: points stream asynchronously, so a tap taken at 24 m may land after the
recorder crosses 25 m. The cost is one extra tap (the back turns into the End confirmation
instead of a silent discard) — acceptable, and the always-visible-button model means the rider
always has a working exit either way.

### Edge states

All refit to the new layout with no new behavior unless noted.

- **GPS-weak:** the existing `GPSSignalChip` stays top-trailing.
- **Permission denied:** auto-start returns `.permissionDenied`; `LocationPermissionView` is
  presented; the back button (at zero distance) discards cleanly on dismissal.
- **Group rides:** Explore is **solo only**. A group ride uses navigate; `RideMapView` is invoked
  with the default empty `peers`, so no crew chrome appears here and the group path is untouched.
- **Reduce Transparency / Increase Contrast:** inherited free — the chassis is already opaque
  `AuraTheme.surface` with `hairline(contrast)`.
- **Reduce Motion:** nothing gratuitous. The only motion is the speed's existing
  `.numericText()` content transition, the recenter (snaps under Reduce Motion), and the
  recenter mint-light.

### Motion

Deliberately restrained. Navigate celebrates turn *completion*; a free ride has no turns, so
there is no bespoke motion. The cockpit is calm; the map is the moving element.

## Testing

Mirrors how the navigate cockpit was proven.

- **Pure (AuraKit/AuraCore):**
  - `ExploreInstrumentState` formatting and composed accessibility label across imperial and
    metric, zero values, and large values, including elevation gain (its own AuraKit test file).
  - `RideBackOutGate.canDiscard` at, below, and above the 25 m floor (AuraCore).
- **Regression (navigate chassis extraction):** the app-target views (`InstrumentPanel`,
  `InstrumentChassis`) are not unit-tested, so the "no behavior change" claim is proven by
  (a) the unchanged `CruisingPresenter` / `CruisingState` suites staying green, and (b) a
  device/simulator VoiceOver check that navigate's panel reads its composed label identically
  before and after the extraction. The regression proof is explicit manual verification, not an
  existing suite covering the view.
- **Simulator/device verify (device-first, via the tunnel):** the free-ride cockpit reads
  correctly through the accessibility tree — speed hero, the three instruments (glanceability of
  three-vs-two judged here), the recenter toggle lighting off-puck and re-centering, auto-start on
  entry, back-out **discard** below the floor (no summary, no orphaned Live Activity), and the
  **End confirmation** above the floor → summary. Group navigate is re-checked once (peers still
  render) to confirm the `RideMapView` viewport-binding change did not disturb it.

## Open questions

None blocking. The 25 m discard floor is one constant in `RideBackOutGate`, exercised by a unit
test rather than a magic number in the view, and is tunable during implementation.

## Reviewer dissents recorded but held

The UX-PO reviewer argued to drop auto-start for an explicit Start button and to make distance
(not speed) the hero for a free ride. Both reverse decisions made deliberately in brainstorm
(one-tap parity with navigate; the same speed-dominant chassis for a single cockpit family, with
distance/time/climb kept as strong secondaries). Held on purpose. The reviewer's real catch — the
silently vanishing back button — is fixed by the always-visible back-out model above.

## Out-of-scope follow-ups

The remaining ROH-45 surfaces (summary, History, Settings, search, route preview, offline, group
surfaces, widgets, Live Activity) are separate Chunk 3 sub-passes and are not touched here. If the
summary later grows a quick-discard affordance (a UX-reviewer suggestion), that belongs to the
summary sub-pass, not this one.
