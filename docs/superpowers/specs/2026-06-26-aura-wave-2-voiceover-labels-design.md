# Aura Wave 2 — Composed VoiceOver labels: design

Date: 2026-06-26
Status: approved (brainstorming), pending written-spec review
Sub-project: Wave 2, item 3 (the second of three Wave 2 sub-projects)

## Context

Wave 2 builds the cockpit the v1 design spec promised, in three separately shipped
sub-projects: (1) the navigate-HUD cockpit (shipped, PR #9, main `8a02332`), (2) composed
VoiceOver labels for the SpeedRail and TurnCard (this one), and (3) the ride-summary redesign
plus the app-wide contrast lift. The decomposition and order are already settled; this spec
covers only sub-project 2 and does not touch sub-project 3.

This is the accessibility sub-project. It is a VoiceOver and semantics pass over the cockpit's
display elements, not a layout or visual change. The mono-lime `AuraTheme` is untouched, and no
view changes size, position, color, or motion.

## What the audit found

The 2026-06-24 audit's accessibility finding was "strong on motion, weak in the cockpit." Wave 1
closed part of it: the floating controls run through `HUDControlButton` with a Reduce Transparency
fallback, and the speed and stat readouts combine their value and label into one VoiceOver element.
The cockpit sub-project (SP1) then gave the new recenter, mute, and end-ride controls correct
labels and values. What remains open is the part this sub-project owns: the SpeedRail and the
TurnCard, the two most important cockpit elements, still have no composed labels. They read as
several mechanical fragments instead of one coherent utterance.

## Current state, confirmed in code

`TurnCardView` (`Aura/Sources/Ride/TurnCardView.swift`) has no accessibility wiring at all. VoiceOver
lands on three stops: the maneuver arrow (an `Image(systemName:)` with no description), the distance
text ("390 ft"), and the instruction ("Right onto Penn Ave"). The arrow is a fixed
`arrow.turn.up.right` symbol that never changes with the maneuver direction, so it carries nothing
the instruction text does not.

`SpeedRail` (`Aura/Sources/Ride/SpeedRail.swift`) has two layouts. The navigate layout (`.speedOnly`)
shows just the speed hero, combined today into "24, mph". The free-ride layout (`.full`) adds three
`StatPair` metrics, each its own combined element, so VoiceOver reads four mechanical stops. The
elevation one reads worst: its visible label is "FT ↑", so the combined element speaks the up-arrow
glyph ("340, F T, up arrow"). The displayed speed is the ride average
(`stats.averageSpeedMetersPerSecond`), which drifts slowly rather than ticking every second.

`TripStripView` (`Aura/Sources/Ride/TripStripView.swift`) shows the street, distance remaining, and
ETA as three separate `Text` views with no accessibility wiring, so VoiceOver reads "Penn Ave",
"2.1 mi", and "4:38 PM" as three stops.

One correctness gap sits underneath the turn card. `TurnCardPresenter`
(`AuraCore/Sources/AuraKit/TurnCardPresenter.swift`) formats its distance imperial-only: it always
converts to feet or miles and never reads the units setting. A rider set to metric sees and would
hear "390 ft" on the turn card, even though the trip strip, the ride stats, and the Live Activity
all say meters and kilometers for them. The unit-aware helper already exists and is tested:
`RideStatsFormatter.maneuverDistance`, whose own doc comment notes it was written so the Live
Activity could honor the distance-units setting, which implies the turn card never did. The imperial
branch of `maneuverDistance` rounds identically to `TurnCardPresenter` (nearest 10 ft below 1000 ft,
one decimal mile above), so moving the turn card onto it preserves the current imperial output exactly.

`TurnCardPresenter.state` has two callers in source: `GuidanceViewModel` (`...run()`, line 75) and the
XCTest suites. `GuidanceViewModel` is constructed only in `NavigateHUDView` (line 38) plus its tests.
`DistanceUnits` is an AuraKit type (`Settings/SettingsStore.swift`), available to both presenters.

## Decisions settled during brainstorming

1. **TurnCard reads as a single composed label, distance first**: "In 390 feet, Right onto Penn Ave."
   This matches turn-by-turn voice convention. The two degraded states read their prompt text. The
   arrow is hidden as decorative.
2. **The turn card becomes unit-aware**, in both the visible distance and the spoken label, by moving
   onto `RideStatsFormatter.maneuverDistance`. The spoken distance always equals the visible distance.
   This fixes the metric-rider bug as a side effect. It is the only way to honor the units setting in
   speech without speech diverging from the screen.
3. **The SpeedRail is two elements**: speed is its own element so its live (slow-moving average) value
   re-announces alone, and distance, time, and elevation compose into one second element. The navigate
   `.speedOnly` layout has only the speed element. This answers the "do not re-announce the whole rail
   on every tick" concern directly: the changing value is isolated, the slower trio is not dragged into
   it, and nothing is hidden behind a rotor.
4. **The TripStrip is in scope** and gets one composed label, even though item 3 names only the
   SpeedRail and TurnCard. It is the same cockpit gap, it sits between the other two elements, and its
   `CruisingState` and `CruisingPresenter` already live in AuraKit and are unit-aware and CI-tested, so
   composing it is small and fully testable. Leaving it as three mechanical stops between two composed
   elements would read as inconsistent.

## The composed reads

Units honor the rider's setting throughout. Abbreviations are spelled to their speakable form, since
a label's job is the spoken text, not the on-screen glyph: "ft" becomes "feet", "mi" becomes "miles",
"m" becomes "meters", "km" becomes "kilometers", "mph" becomes "miles per hour", "km/h" becomes
"kilometers per hour". Street and instruction strings come from Mapbox verbatim; road-suffix expansion
("Ave" to "Avenue") is deliberately not done, because it would make the spoken text diverge from the
visible text and the suffix set is open-ended.

Plurals are always safe for distance. The maneuver rounding never yields a bare "1": feet and meters
round to the nearest 10, and miles and kilometers carry one decimal ("1.0 miles"), so
"feet/miles/meters/kilometers" read correctly without singular handling. The spoken distance is the
`maneuverDistanceSpoken` value interpolated verbatim, including the "1000 feet" boundary string with no
thousands separator, so it always matches the visible "1000 ft".

### TurnCard (one `accessibilityLabel`)

- Normal: `"In {spoken distance}, {instruction}"`
  - Imperial: "In 390 feet, Right onto Penn Ave." / "In 0.2 miles, Right onto Penn Ave."
  - Metric: "In 120 meters, Right onto Penn Ave." / "In 0.3 kilometers, Right onto Penn Ave."
- `.starting`: "Starting navigation." (the visible text keeps its ellipsis; the label drops it)
- `.unavailable`: "Navigate to destination."
- The arrow is marked `.accessibilityHidden(true)`.

### SpeedRail (speed element, both layouts)

- Label: "Speed"
- Value: `"{speed value} {spoken speed unit}"` — "24 miles per hour" (imperial) / "24 kilometers per
  hour" (metric). Speed is the value because it is the changing quantity, so a focused element
  re-announces only the value.

### SpeedRail (stats element, free-ride layout only)

One element reading distance, then time, then elevation:

- `"Distance {d}, time {elapsed spoken}, elevation gain {e}"`
  - "Distance 5.0 miles, time 12 minutes 30 seconds, elevation gain 340 feet"
  - Metric: "Distance 8.0 kilometers, time 12 minutes 30 seconds, elevation gain 104 meters"

Elapsed is spoken from the elapsed seconds, not the "m:ss" glyph. With `m = seconds / 60` and
`s = seconds % 60`: `m == 0` reads "{s} seconds", `s == 0` reads "{m} minutes", otherwise
"{m} minutes {s} seconds". Unlike the rounded distances, elapsed can land on exactly one, so the minute
and second words are singularized ("1 minute", "1 second"), and a just-started ride at 0 s reads
"0 seconds". Examples: 750 s reads "12 minutes 30 seconds", 45 s reads "45 seconds", 720 s reads
"12 minutes", 61 s reads "1 minute 1 second". This matches the existing minutes-and-seconds clock (which
has no hours component) and stays deterministic for tests. The app is not localized, so the spoken words
are English, consistent with the rest of the spoken vocabulary.

### TripStrip (one `accessibilityLabel`)

- Full: "On Penn Ave, 2.1 miles to go, arriving 4:38 PM."
- No street (unnamed trail): "2.1 miles to go, arriving 4:38 PM."
- Missing distance or ETA: the missing clause is omitted ("On Penn Ave, arriving 4:38 PM." /
  "On Penn Ave, 2.1 miles to go.").
- `.starting`: "Starting navigation."

The ETA keeps the format `CruisingPresenter` already produces (a locale-aware short clock, with the
narrow no-break space before "PM" on recent OSes). VoiceOver reads it correctly as a time.

## Architecture and placement

All string composition lives in the package (`AuraCore` and `AuraKit`) so it is unit-tested in CI. The
SwiftUI views only apply the strings. This follows the brainstorming decision to put the label logic on
the presenters or a sibling, not in the views.

### Shared spoken vocabulary (`RideStatsFormatter`, AuraKit)

`RideStatsFormatter` already centralizes the unit-aware short formatting. It gains the spoken unit
words so all three elements spell consistently:

```swift
public var speedUnitSpoken: String     { metric ? "kilometers per hour" : "miles per hour" }
public var distanceUnitSpoken: String  { metric ? "kilometers" : "miles" }
public var elevationUnitSpoken: String { metric ? "meters" : "feet" }
```

`distanceUnitSpoken` covers the whole-route distance remaining (trip strip) and the ride distance
(SpeedRail stats), which are always miles or kilometers. The maneuver distance is different: under
1000 short units it is feet or meters and above it rolls up to miles or kilometers, so it owns its own
unit selection. To keep that imperial/metric rounding from drifting between the short turn-card string
and its spoken form, `maneuverDistance` is refactored to pick the value and unit once and expose both a
short form ("390 ft") and a spoken form ("390 feet") from the same rounding path:

```swift
public func maneuverDistance(_ meters: Double) -> String        // unchanged signature, short form
public func maneuverDistanceSpoken(_ meters: Double) -> String  // same value, spoken unit
```

### TurnCard (`TurnCardPresenter` and `TurnCardState`, AuraKit)

`TurnCardState` gains a stored composed label:

```swift
public var accessibilityLabel: String
```

`TurnCardPresenter.state` gains a required `units` parameter and uses `maneuverDistance` for the
visible `distanceText` and `maneuverDistanceSpoken` for the label:

```swift
public static func state(distanceToManeuverMeters: Double,
                         instruction: String,
                         units: DistanceUnits,
                         expandWithinMeters: Double = 150) -> TurnCardState
public static func state(for update: GuidanceUpdate,
                         units: DistanceUnits,
                         expandWithinMeters: Double = 150) -> TurnCardState
```

The static `.starting` and `.unavailable` set their own `accessibilityLabel` ("Starting navigation." /
"Navigate to destination."). The existing XCTest call sites add `units: .imperial`, which preserves
their current assertions because the imperial path is unchanged.

`GuidanceViewModel` gains a `units` input so it can pass it through:

```swift
public var units: DistanceUnits = .imperial   // set by the view; default keeps existing tests green
```

In `run()`, `turn = TurnCardPresenter.state(for: update, units: units)`. Nothing observes `units`, so it
can be `@ObservationIgnored`. `NavigateHUDView` already reads `settings.units` live for the SpeedRail and
the trip strip (both recompute every render), so only the cached `turn` needs help: the view sets
`guidance.units = settings.units` in `.task` before `guidance.start(route:)` and keeps it current with a
`.onChange(of: settings.units)` that feeds only the view model. A mid-ride units change repaints the card
on the next progress event (about one second), which is acceptable.

### TripStrip (`CruisingState` and `CruisingPresenter`, AuraKit)

`CruisingState` gains a stored composed label, populated by `CruisingPresenter` from the raw meters and
seconds it already holds (so the spoken distance is spelled from the real value, not re-parsed from the
short string):

```swift
public var accessibilityLabel: String
```

`.starting` sets it to "Starting navigation."

### SpeedRail (new pure composer, AuraKit)

SpeedRail has no presenter today; it formats inline in the view. A new pure sibling composes its
element strings from the same inputs the view already has:

```swift
public enum SpeedRailVoice {
    public static func speedValue(_ stats: RideStats, units: DistanceUnits) -> String   // "24 miles per hour"
    public static func statsLabel(_ stats: RideStats, elapsed: TimeInterval,
                                  units: DistanceUnits) -> String                       // "Distance ..., time ..., elevation gain ..."
}
```

It reuses `RideStatsFormatter` for the numbers and the spoken unit words. The speed label "Speed" is a
constant in the view.

## VoiceOver mechanics

- **Label versus value**: only the fast value (speed) splits into a static label plus a changing value.
  The turn card, the stats element, and the trip strip are single composed labels, because they change
  slowly or only at a turn.
- **Traits**: all three are read-only static text. They get no interactive traits. Children are replaced
  with `.accessibilityElement(children: .ignore)` plus an explicit label (and value, for speed), so
  nothing double-exposes or nests. The existing `.accessibilityElement(children: .combine)` calls in
  `SpeedRail` are replaced.
- **No proactive announcements**: this sub-project does not post `UIAccessibility` announcements on a
  turn. The existing AVSpeech voice prompt already speaks the live maneuver; posting a VoiceOver
  announcement on top would double-speak. VoiceOver users get the composed read on focus.
- **Voice Control**: the three composed elements are non-interactive, so they need no input labels. The
  interactive cluster (recenter, mute, end ride) already received labels in SP1; the sim pass confirms
  they are speakable and unique.
- **Dynamic Type**: the composed label reads the full text even when the visible street truncates, so a
  VoiceOver user hears "Boulevard of the Allies" where the screen shows "Boulevard of the Alli…". The
  existing accessibility-size caps stay.

## Behavior preservation

- The visible layout, fonts, colors, motion, and Reduce Motion and Reduce Transparency handling are
  unchanged for both ride modes.
- The free-ride SpeedRail visuals and the navigate `.speedOnly` visuals are unchanged.
- The turn card's imperial output is unchanged for imperial riders; only metric riders see a different
  (now correct) visible distance.
- The Live Activity, the coordinator, and the routing and reroute paths are untouched.

## Testing

CI unit tests carry the weight, since the strings are pure:

- `RideStatsFormatter`: extend `RideStatsFormatterTests` for `maneuverDistanceSpoken` (imperial and metric,
  including the ft-to-mi and m-to-km rollover spelling its unit) and the spoken-unit vars. The existing
  `maneuverDistance` imperial and metric fixtures stay unchanged, protecting the two widget callers.
- TurnCard: extend `TurnCardPresenterTests` and `TurnCardPresenterEdgeTests` for unit-aware visible
  distance (metric and imperial) and the composed `accessibilityLabel`, including the `.starting` and
  `.unavailable` labels. Keep the existing imperial assertions (now passing `units: .imperial`).
- TripStrip: extend `CruisingPresenterTests` for the composed label across the full, no-street,
  missing-distance, missing-ETA, and `.starting` cases, both unit systems, reusing the existing
  fixed-clock and U+202F-tolerant ETA approach.
- SpeedRail: a new `SpeedRailVoiceTests` suite for the speed value and the stats label, both unit
  systems, plus the elapsed-spoken edge cases (zero minutes, zero seconds).
- `GuidanceViewModel`: confirm the pipeline still drives `turn` with the injected units.

Empirical simulator verification (the point of the accessibility wave): on the iPhone 17 / iOS 26
simulator, confirm each element's actual `label`, `value`, and `traits` through the accessibility tree
(`axe describe-ui` or `ui_describe_*`), not just a green build:

- Navigate HUD: the turn card reads as one composed element, the speed element reads "Speed, 24 miles
  per hour", and the trip strip reads as one composed element with a live street, distance, and ETA.
- Free-ride HUD: the SpeedRail reads as two elements (speed, then the stats trio) with no "F T up
  arrow".
- Degraded states: `.starting` and `.unavailable` turn-card reads, and the `.starting` trip strip.
- Regression: the free-ride full rail and the navigate speed-only rail still render correctly.

Install the build produced from this worktree's `TARGET_BUILD_DIR` (from `xcodebuild -showBuildSettings`),
not a build picked by mtime, and reboot the simulator if a screenshot md5 matches a prior frame.

## Risks and mitigations

- Threading `units` into the turn-card path touches `GuidanceViewModel` (CI-built). Mitigated by the
  default `.imperial` (keeps existing VM tests green) and the metric sim check.
- `.accessibilityElement(children: .ignore)` mis-scoped could swallow a sibling. Mitigated by the
  per-element accessibility-tree verification.
- Refactoring `maneuverDistance` to share a rounding path could shift the short output, which two shipped
  widget callers depend on (`Aura/Widgets/RideLiveActivity.swift` and `Aura/Widgets/RideLockScreenView.swift`,
  both through `turnDistanceText`). The refactor must keep `maneuverDistance` byte-identical for both
  imperial and metric. Mitigated by the existing `RideStatsFormatterTests` imperial and metric fixtures,
  which must still pass unchanged.

## Out of scope

- The ride-summary redesign and the app-wide contrast lift (sub-project 3).
- Any layout, font, color, or motion change.
- Road-suffix expansion in spoken strings.
- Proactive VoiceOver turn announcements.
- App localization (the spoken vocabulary is English, consistent with the rest of the app).

## Rough task order

1. `RideStatsFormatter`: spoken unit words and the shared `maneuverDistance` value/unit refactor with a
   spoken form. Tests.
2. `TurnCardPresenter` and `TurnCardState`: unit-aware distance and the composed `accessibilityLabel`.
   Update existing call sites and tests; add metric and label tests.
3. `GuidanceViewModel`: the `units` input and the pass-through.
4. `CruisingPresenter` and `CruisingState`: the composed `accessibilityLabel`. Tests.
5. `SpeedRailVoice`: the new composer. Tests.
6. `TurnCardView`: apply the label, hide the arrow.
7. `SpeedRail`: apply the two-element structure (speed label/value, stats label), replacing the combine
   calls.
8. `TripStripView`: apply the composed label.
9. `NavigateHUDView`: set `guidance.units` from settings.
10. Simulator accessibility-tree verification.
11. Mark the sub-project shipped in `docs/ROADMAP.md`.
