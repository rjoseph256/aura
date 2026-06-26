# Aura Wave 2 — Navigate-HUD cockpit: design

**Goal:** Build the cruising-state cockpit Section 5 of the v1 spec describes. The
navigate HUD gains the current street name, distance remaining, and an arrival ETA in
a slim bottom trip strip, and the scattered mute and end-ride controls collapse with a
new recenter control into one cluster built on `HUDControlButton`. The guidance seam
grows three fields so the trip data flows through the same pure pipeline the turn card
already uses, and the formatting that turns those numbers into display text lives in
AuraKit where CI tests it.

**Status:** approved design, ready to plan.

## Context

Wave 1 (structural foundations) is complete: quality gates, design system,
ride-session coordinator, persistence, and navigation all shipped (PRs #3 through #8,
`main` at `7dbf7c0`). Wave 2 is the first feature wave, and it has four ROADMAP items
that decompose into three separately-shipped sub-projects, in this order:

1. The navigate-HUD cockpit (ROADMAP items 1 and 2): the trip data and the control
   cluster, which are the same screen and which Section 5 treats as one cruising-state
   cockpit. This spec.
2. Composed VoiceOver labels for SpeedRail and TurnCard (ROADMAP item 3).
3. The ride-summary redesign and the app-wide contrast lift (ROADMAP item 4).

This spec covers sub-project 1 only. Sub-projects 2 and 3 are out of scope here.

The app has three compiled layers plus the widget extension:

- `AuraCore`: pure Swift models and protocols, no UIKit, SwiftUI, or CoreLocation. It
  builds on the macOS CI host, so anything added here is unit-tested in CI.
- `AuraKit`: depends on `AuraCore`, may import CoreLocation, imports no SwiftUI. The
  formatting and the presenters live here. Also CI-tested on the macOS host.
- `Aura`: the app target. SwiftUI plus the Mapbox-backed implementations. The cockpit
  views live here.
- `AuraWidgets`: the WidgetKit extension, which reads `GuidanceViewModel.lastUpdate`
  for the Live Activity turn. Adding fields to `GuidanceUpdate` must not break it.

### What the audit found

The 2026-06-24 audit recorded two findings this sub-project answers:

- "The cockpit does not yet match the HUD spec." Section 5 calls for a cruising state
  with speed plus distance remaining plus ETA plus the current street name, a
  persistent recenter control, and the safety states. What shipped is speed plus
  ridden distance, time, and elevation, with no ETA, no street name, and no recenter.
- "Accessibility is strong on motion, weak in the cockpit." The part this sub-project
  carries is the broad contrast care on the floating controls and the new strip; the
  richer composed VoiceOver labels are sub-project 2.

The off-route reroute gap the audit also noted was closed in Wave 0: the navigate HUD
already observes Mapbox's reroute publisher, shows a "Rerouting" cue, and redraws its
polyline from the live route shape. This sub-project keeps that behavior and re-fits it
to the new layout.

### Current state, confirmed in code

- `GuidanceUpdate` (`AuraCore/Sources/AuraCore/Guidance/GuidanceSession.swift`) carries
  only `distanceToManeuverMeters` (the distance to the next maneuver, not the whole
  route) and `instruction`. It does not carry whole-route distance remaining, duration
  remaining, or the current street name. The ROADMAP line "the data already flows
  through `GuidanceViewModel`" is not accurate at the type level: the data exists on
  Mapbox's `RouteProgress` but is discarded in the decode.
- `MapboxGuidanceSession.guidanceUpdate(from:)`
  (`Aura/Sources/Routing/MapboxGuidanceSession.swift`) reads
  `progress.currentLegProgress.currentStepProgress.distanceRemaining` (a step-level
  value) and the upcoming step's `instructions`. The whole-route values sit one read
  away on the same `progress` object.
- `GuidanceViewModel.lastUpdate` already republishes the raw `GuidanceUpdate`, and
  `TurnCardPresenter` (`AuraCore/Sources/AuraKit/TurnCardPresenter.swift`) turns an
  update into a `TurnCardState`. The new trip data follows the same path.
- `NavigateHUDView` (`Aura/Sources/Ride/NavigateHUDView.swift`) lays out a full-bleed
  Mapbox `Map` with a `followPuck` viewport, a `SpeedRail` bottom-trailing (speed hero
  plus a ridden distance / time / elevation row), a `TurnCardView` top-center, a
  `muteButton` (`HUDControlButton`) top-trailing, a `GPSSignalChip` top-leading, the
  "Rerouting" cue top-center, and an `endRideButton` (a full-width `ctaDestructive`
  pink button) bottom-center.
- `SpeedRail` (`Aura/Sources/Ride/SpeedRail.swift`) is shared with the free-ride HUD
  and renders speed plus the three-stat row, capped at `accessibility1`.
- `HUDControlButton` (`Aura/Sources/Theme/HUDControlButton.swift`) has an `isActive`
  flag that tints the glyph lime, a fixed 44pt circle, and a Reduce Transparency
  fallback to a solid `AuraTheme.surface`. It has no destructive (pink) styling.
- The Mapbox source checkout confirms the three new sources:
  `RouteProgress.distanceRemaining: CLLocationDistance` and
  `RouteProgress.durationRemaining: TimeInterval` are whole-route values, and
  `RouteStep.names: [String]?` on `currentLegProgress.currentStep` is the current road.

The central work is therefore a small, well-bounded seam extension plus two new
cockpit views, with all the number-to-text formatting kept pure in AuraKit so CI
covers it.

## Decisions settled during brainstorming

1. **Wave 2 order: cockpit, then VoiceOver, then summary and contrast.** Items 1 and 2
   ship together because they are one screen. The contrast lift ships last so it can
   sweep the cockpit this sub-project builds.

2. **Separate trip strip, not one merged instrument.** The speed hero stays the lone
   bottom-trailing instrument. A slim full-width strip pinned to the bottom safe area
   carries street name, distance remaining, and ETA. This keeps speed the largest
   glance target (Aura is speed-forward, unlike car nav where ETA leads), matches the
   Apple and Google convention for trip data so it reads instantly, and a horizontal
   strip degrades more gracefully at accessibility type sizes than a tall stacked
   panel. The navigate HUD drops the ridden distance / time / elevation row, which is
   the free-ride concern; the free-ride HUD keeps it unchanged. A single merged panel
   and a top-context layout were both rejected: the merged panel gets tall and crowds
   the map and cluster at large type, and the top-context layout overloads the safe
   area the turn card and GPS chip already share.

3. **ETA is an arrival clock, not a remaining duration.** The strip shows the arrival
   time, for example "4:38 PM", because that is what "ETA" means and what Section 5
   says. Arrival is `now + durationRemaining`, so the formatting needs the current
   time. It stays pure and CI-tested by taking `now` as a parameter rather than reading
   the clock inside the presenter. A remaining-duration reading was considered (it is
   slightly purer to test, needing no injected clock) but it diverges from the spec
   wording; showing both was rejected as too dense for the slim strip.

4. **One three-control cluster, end-ride confirmed.** Recenter, mute, and end-ride
   become three circular `HUDControlButton`s in a bottom-leading cluster, fully
   satisfying ROADMAP item 2. End-ride keeps the reserved pink color and, because it
   shrinks from a full-width labeled button to a small circle, gains a confirmation
   step so a fumbled tap cannot drop a ride. The confirmation is a standard
   `confirmationDialog`, which VoiceOver and Switch Control drive without trouble.
   Keeping end-ride as a separate full-width button was rejected because it only
   partly unifies the controls; a hold-to-end gesture was rejected because hold
   gestures are awkward for assistive technology, which matters in this wave.

5. **Recenter is persistent and state-lit.** The button is always present in the
   cluster (Section 5 calls it a "persistent recenter control"), sits quiet while the
   map follows the puck, and lights lime the moment the rider pans away. Tapping it
   re-engages `followPuck`. A button that changes state in place is calmer for a
   handlebar glance than one that appears and disappears, which would reflow the
   cluster under the rider's thumb. An appear-on-pan button was rejected for that
   reflow.

6. **Pure formatting lives in AuraKit.** A new `CruisingPresenter` and `CruisingState`
   follow the shape of `TurnCardPresenter` and `TurnCardState` (a pure enum with a
   `state(for:)` factory feeding a pure value type): the view hands the presenter a
   `GuidanceUpdate`, the units, and `now`, and gets back display strings. Unlike
   `TurnCardPresenter`, which formats its maneuver distance imperial-only, the cruising
   presenter threads `units` through `RideStatsFormatter` so it honors the rider's
   setting. This keeps the unit conversions, the distance rounding, and the clock
   formatting under the package test suite rather than inside a SwiftUI view CI never
   runs.

## The guidance seam

### `GuidanceUpdate` (AuraCore)

Three fields are added, all optional with a `nil` default so every existing
construction site and the Live Activity keep compiling. `nil` means "not yet known",
distinct from a real zero.

```swift
public struct GuidanceUpdate: Equatable, Sendable {
    public var distanceToManeuverMeters: Double
    public var instruction: String
    /// Whole-route distance remaining to the destination, in meters. nil until known.
    public var distanceRemainingMeters: Double?
    /// Whole-route time remaining to the destination, in seconds. ETA = now + this.
    public var durationRemainingSeconds: Double?
    /// The road the rider is currently on, e.g. "Penn Ave". nil when the engine has
    /// no name for the current step.
    public var currentStreetName: String?

    public init(distanceToManeuverMeters: Double,
                instruction: String,
                distanceRemainingMeters: Double? = nil,
                durationRemainingSeconds: Double? = nil,
                currentStreetName: String? = nil) { ... }
}
```

The defaulted parameters keep this additive: `ScriptedGuidanceSession` scripts, the
`TurnCardPresenter` tests, and the Live Activity all read or build `GuidanceUpdate`
without change, and only the Mapbox decode and the new cruising path set the new
fields.

### The Mapbox decode (app target)

`MapboxGuidanceSession.guidanceUpdate(from:)` reads the three confirmed properties off
the same `RouteProgress` it already has:

```swift
GuidanceUpdate(
    distanceToManeuverMeters: progress.currentLegProgress.currentStepProgress.distanceRemaining,
    instruction: /* upcoming step instructions, unchanged */,
    distanceRemainingMeters: progress.distanceRemaining,
    durationRemainingSeconds: progress.durationRemaining,
    currentStreetName: progress.currentLegProgress.currentStep.names?.first
)
```

`currentStep.names` is `[String]?`, so `names?.first` is `nil` for both a nil and an
empty array. The `CruisingPresenter` additionally maps an empty or whitespace-only name
to `nil`, so the strip omits the street label rather than rendering a blank, which is a
real case on unnamed trails (exactly Aura's use case).

### `CruisingPresenter` and `CruisingState` (AuraKit)

A pure value type and a pure presenter, next to `TurnCardPresenter`:

```swift
public struct CruisingState: Equatable, Sendable {
    public var streetName: String?        // current road; nil omits the label
    public var distanceRemaining: String? // e.g. "2.1 mi"; nil shows a placeholder
    public var eta: String?               // arrival clock, e.g. "4:38 PM"; nil placeholder

    /// Before the first progress update, every field is nil and the strip reads calm.
    public static let starting = CruisingState(streetName: nil,
                                               distanceRemaining: nil, eta: nil)
}

public enum CruisingPresenter {
    public static func state(for update: GuidanceUpdate,
                             units: DistanceUnits,
                             now: Date,
                             calendar: Calendar = .current) -> CruisingState
}
```

- **Distance remaining** composes the two strings the existing
  `RideStatsFormatter(units:)` returns separately, `distanceValue` ("2.1") and
  `distanceUnit` ("mi"), into "2.1 mi". It honors the rider's `DistanceUnits` setting
  (`.imperial` or `.metric`) and matches how the route preview shows total distance,
  for example "2.1 mi" or "3.4 km".
- **ETA** is `now.addingTimeInterval(durationRemainingSeconds)` formatted to a
  locale-aware short time. The format comes from a `DateFormatter` built with
  `dateFormat(fromTemplate: "jmm", ...)` against `calendar.locale`, so a 12-hour
  locale gets "4:38 PM" and a 24-hour locale gets "16:38". `calendar.timeZone` and
  `calendar.locale` make the output deterministic when a test passes a fixed calendar.
- **Street name** passes through verbatim.
- Any `nil` input field yields a `nil` output field; the strip renders those as a quiet
  placeholder rather than a zero.

`GuidanceViewModel` needs no change: it already exposes `lastUpdate`, which the strip
reads. The view calls `CruisingPresenter.state(for:units:now:)` with `Date()` at render
time. Because `lastUpdate` changes on every progress event (roughly once per second
during active guidance), the ETA recomputes often enough to stay current without a
timer.

## The trip strip

A new app-target view, `Aura/Sources/Ride/TripStripView.swift`:

```swift
struct TripStripView: View {
    let state: CruisingState
    // reads AuraTheme; Reduce Transparency via @Environment
}
```

Layout: a single horizontal row pinned full-width to the bottom safe area.

- **Street name** leads, in SF Pro Rounded semibold (it is a name, not a metric), with
  `lineLimit(1)`, `truncationMode(.tail)`, and a layout priority so a long road like
  "Boulevard of the Allies" truncates before it pushes the metrics off-screen.
- **Distance remaining** and **ETA** sit trailing, their values in Saira cockpit
  numerals (they are metrics) with small SF Pro labels, matching the type-and-density
  split the design system already uses for cockpit versus chrome.
- The background is the translucent `AuraTheme.surface` over the map, with the same
  Reduce Transparency fallback to a solid surface that `HUDControlButton` uses, so the
  strip stays legible when transparency is reduced.
- Dynamic Type is capped at `accessibility1`, matching `SpeedRail`, since the strip is
  a glance target rather than a reading surface. At the cap the street name truncates
  while the metrics hold their place.
- Placeholder rule, made explicit so it is testable: before the first progress update,
  when `state == .starting` (all three fields nil), the strip shows a single centered
  "Starting…" label. Once any real field arrives it switches to the street-plus-metrics
  layout; a nil street omits the label, and a still-nil metric shows the same short-dash
  placeholder the turn card uses for an unknown distance. The strip never renders a zero
  as if it were a real value.

`TripStripView` is a new app-target file, so adding it runs `xcodegen generate`.

## The control cluster

### `HUDControlButton` gains a destructive role (app target)

The component stays one button style and grows a `role` so end-ride can be pink while
recenter and mute stay neutral or lime-active:

```swift
struct HUDControlButton: ButtonStyle {
    enum Role { case normal, destructive }
    var role: Role = .normal
    var isActive = false
    var size: CGFloat = 44
    // foreground: role == .destructive → AuraTheme.destructive,
    //             else isActive ? AuraTheme.accent : AuraTheme.textPrimary
    // background + Reduce Transparency fallback: unchanged
}

extension ButtonStyle where Self == HUDControlButton {
    static var hudControl: HUDControlButton { .init() }
    static func hudControl(active: Bool) -> HUDControlButton { .init(isActive: active) }
    static func hudControl(role: HUDControlButton.Role) -> HUDControlButton { .init(role: role) }
}
```

This is the one Theme component change. The existing `.hudControl` and
`.hudControl(active:)` call sites are untouched.

### `ControlCluster` (app target)

A new view, `Aura/Sources/Ride/ControlCluster.swift`, a bottom-leading vertical stack
of three buttons:

```swift
struct ControlCluster: View {
    let isFollowing: Bool          // recenter lights when false
    let isMuted: Bool
    var onRecenter: () -> Void
    var onToggleMute: () -> Void
    var onEndRide: () -> Void      // opens the confirm; the HUD owns the dialog
}
```

- **Recenter**: `Image(systemName: "location.fill")`, `.hudControl(active: !isFollowing)`,
  so it is lime exactly when the rider has panned off the puck. Its accessibility value
  reflects whether the map is following. The exact glyph is settled in the plan.
- **Mute**: the existing speaker glyph, `.hudControl(active: isMuted)`. The glyph swap
  upgrades to `.contentTransition(.symbolEffect(.replace))` for a clean morph between
  `speaker.wave.2.fill` and `speaker.slash.fill`.
- **End ride**: `Image(systemName: "stop.fill")`, `.hudControl(role: .destructive)`,
  pink. Its action calls `onEndRide`, which sets the HUD's confirm flag.

`NavigateHUDView` owns the confirmation so the cluster stays a dumb control:

```swift
.confirmationDialog("End ride?", isPresented: $showEndConfirm, titleVisibility: .visible) {
    Button("End ride", role: .destructive) { endRide() }
    Button("Keep riding", role: .cancel) { }
}
```

`ControlCluster` is a new app-target file, so adding it runs `xcodegen generate`.

### What the navigate HUD loses

The old `muteButton` overlay (top-trailing) and the `endRideButton` full-width CTA
(bottom-center) are removed; both behaviors move into the cluster. `SpeedRail` gains a
navigate variant that shows the speed hero alone, so the ridden distance / time /
elevation row no longer appears under navigation:

```swift
struct SpeedRail: View {
    enum Layout { case full, speedOnly }
    var layout: Layout = .full   // free-ride keeps .full; navigate passes .speedOnly
}
```

The default keeps `RideHUDView` (free ride) unchanged. In the `speedOnly` layout only
the `SpeedReadout` hero remains, so its existing `accessibilityElement(children: .combine)`
is the surviving VoiceOver element and the speed still reads as one stop ("24, mph"); the
three-stat row and its combines simply do not render, so nothing dangles.

## Recenter camera behavior

The map stays `Viewport.followPuck(zoom: 16, bearing: .heading)` by default. When the
rider gesture-pans, Mapbox moves the bound `viewport` out of the `followPuck` state.
`NavigateHUDView` derives `isFollowing` from the bound viewport as
`viewport.followPuck != nil` (the SwiftUI `Viewport` exposes
`var followPuck: FollowPuckOptions?`, which is non-nil only in the follow state) and
passes it to the cluster, which lights recenter when it is false. Tapping recenter
re-engages following:

```swift
withViewportAnimation(.easeOut(duration: 0.4)) {
    viewport = .followPuck(zoom: 16, bearing: .heading)
}
```

Under Reduce Motion the camera is set without the animation wrapper, so it snaps rather
than flies. If a future SDK changes that read, the button falls back to always-enabled,
which still re-centers correctly.

## Motion

Every transition stays at or under 250ms with an ease-out or `.snappy` curve and no
bounce: a cockpit reads best crisp and fast, not playful. Each motion has a Reduce
Motion branch that crossfades or sets instantly with no transform, matching the turn
card's existing discipline.

- Recenter active state: `.snappy` color and a small scale on `isFollowing`, gated by
  `reduceMotion`.
- Button press feedback: a `scale(0.97)` on press, added to `HUDControlButton`
  alongside its existing press-opacity dim (the scale joins the opacity, it does not
  replace it).
- Mute glyph: `.contentTransition(.symbolEffect(.replace))`.
- Distance-remaining and ETA values: `.contentTransition(.numericText())` so the
  digits roll rather than cut, paired with a narrow `.animation(.snappy, value:)`.
- The recenter camera return uses `withViewportAnimation(.easeOut(duration: 0.4))`,
  instant under Reduce Motion.

## Edge and safety states

These are already present from Wave 0 and stay, re-fitted to the new layout rather than
rebuilt:

- **GPS weak or lost**: the `GPSSignalChip` stays top-leading.
- **Off-route**: the "Rerouting" cue stays; it sits above the trip strip so the two do
  not collide.
- **Permission denied**: the `.task` start gate still presents
  `LocationPermissionView` when the coordinator returns anything but `.started`.
- **Guidance unavailable**: when the session cannot establish a route, `lastUpdate`
  stays nil, so `CruisingState` stays `.starting` and the strip shows its calm
  placeholder while the map and recording keep working, mirroring how the turn card
  degrades to its "Navigate to destination" prompt.

## Behavior preservation

| Behavior | Before | After |
| --- | --- | --- |
| Speed readout | `SpeedRail` full panel, bottom-trailing | `SpeedRail` speed-only, bottom-trailing |
| Ridden distance / time / elevation in navigate | shown in the rail | not shown (free-ride concern) |
| Distance remaining, ETA, street name | absent | new bottom trip strip |
| Mute | top-trailing `HUDControlButton` | in the bottom-leading cluster |
| End ride | full-width pink CTA, bottom-center, one tap | pink cluster button, confirmed |
| Recenter | absent | persistent cluster button, lit when panned off |
| Map follow | `followPuck` default, no manual re-center | `followPuck` default, recenter re-engages it |
| Turn card | top-center, expand-on-approach | unchanged |
| GPS chip, Rerouting cue, permission gate | present | unchanged, re-fitted around the strip |
| Free-ride HUD | `SpeedRail` full panel | unchanged |
| Live Activity turn | reads `lastUpdate` | unchanged (new fields ignored) |

## Testing

New tests are Swift Testing, matching the coordinator, persistence, and navigation
precedent, and they live in `AuraCore/Tests/AuraKitTests/` next to the existing
`TurnCardPresenter` tests, since `CruisingPresenter` is an AuraKit type. They run in
the package job on the macOS host.

- `CruisingPresenter`: distance remaining formats to miles and to kilometers per the
  units setting; ETA arrival clock with a fixed `now` and a fixed `Calendar` produces
  the expected 12-hour and 24-hour strings and rounds to the minute; a nil distance,
  nil duration, or nil street name each yields a nil output field; an empty or
  whitespace-only street name also yields a nil street field; an update with all three
  fields set yields all three strings.
- `GuidanceUpdate`: the new fields round-trip through the memberwise initializer and
  default to nil when omitted, so existing call sites are unaffected and equality still
  holds.

The package suite stays green and gains these cases; confirm the new total with
`swift test`.

The app target has no test target, so the cockpit is verified on the iPhone 17 /
iOS 26 simulator through the accessibility tree, per the text-before-pixels rule:

- During a simulated or scripted navigated ride, the trip strip populates with a street
  name, a distance remaining, and an ETA, and updates as the ride progresses.
- The control cluster lays out bottom-leading with recenter, mute, and end-ride.
- Panning the map lights recenter; tapping recenter re-centers on the puck.
- Mute toggles and silences the next prompt.
- End-ride opens the confirmation; confirming ends the ride to the summary, and
  declining keeps riding.
- The strip stays legible with Reduce Transparency on, and the cluster lays out at an
  accessibility Dynamic Type size without clipping.

If a pixel capture is needed and its md5 matches the prior frame, reboot the simulator
before trusting it, per the known screenshot-freeze gotcha.

## Risks and mitigations

- **The whole-route Mapbox values read wrong.** `distanceRemaining` and
  `durationRemaining` are confirmed on `RouteProgress` in the source checkout, but a
  reroute or a leg boundary could momentarily report odd values. Mitigation: the strip
  treats nil and non-positive values as "not yet known" and shows the placeholder, and
  the simulated-ride check watches the strip across a reroute.
- **The street name is missing or noisy.** `currentStep.names` is optional and can be
  empty on unnamed paths or trails, exactly Aura's use case. Mitigation: a nil or empty
  name omits the label cleanly rather than showing a blank or a guess; the metrics keep
  their place.
- **End-ride friction.** Adding a confirmation changes a one-tap action into two.
  Mitigation: this is a deliberate trade for the smaller target, it is the standard
  pattern for destructive actions, and the confirm is a single extra tap, not a modal
  flow.
- **The recenter follow-state read is SDK-specific.** `isFollowing` reads
  `viewport.followPuck != nil`, which is a real property on the SwiftUI `Viewport`.
  Mitigation: the current HUD already binds the same `followPuck` viewport, so the read
  is on a value the view already owns; if a future SDK changes it, the button falls back
  to always-enabled, which still re-centers correctly.
- **The strip crowds the map at large type.** Mitigation: the street name truncates,
  the metrics are fixed, and Dynamic Type is capped at `accessibility1` like the speed
  rail; the accessibility-size layout is checked on the simulator.
- **A regressed live-ride flow.** The rewire touches the navigate HUD's controls and
  the speed rail variant, which the package tests do not cover end to end. Mitigation:
  the simulated-ride check drives the full navigate flow to the summary and back before
  the PR.

## Out of scope

- Composed VoiceOver labels for SpeedRail and TurnCard (sub-project 2). This
  sub-project keeps the existing combined labels and adds correct labels and values to
  the new controls, but does not build the richer composed reads.
- The ride-summary redesign and the broad contrast lift across the app (sub-project 3).
- Any free-ride HUD change. `SpeedRail` keeps its full layout there by default.
- A single hoisted Mapbox map shared across the flow (a documented Wave 1 fast-follow).
- A remaining-duration reading alongside the arrival ETA; the strip shows the arrival
  clock only.
- Any new identity. `AuraTheme`, its mono-lime roles, and the Saira cockpit numerals
  are reused as they are.

## Rough task order

1. `GuidanceUpdate`: add the three optional fields and their round-trip test.
2. `CruisingPresenter` and `CruisingState` in AuraKit, with the formatting tests
   (distance, ETA clock with an injected calendar, nil handling).
3. `MapboxGuidanceSession`: decode the three new values into `GuidanceUpdate`.
4. `HUDControlButton`: add the `role` (destructive) and the press-scale feedback.
5. `TripStripView`, then wire it into `NavigateHUDView` reading
   `CruisingPresenter.state(for: guidance.lastUpdate ?? ...)`.
6. `ControlCluster`, the `SpeedRail` speed-only variant, and the `NavigateHUDView`
   rewire: remove the old mute and end-ride controls, add the cluster, the recenter
   viewport re-engage, and the end-ride confirmation.
7. Simulator verification of the full navigate flow and the edge states.
8. `docs/ROADMAP.md`: mark the cockpit sub-project shipped.

Commits follow the repo conventions: `feat(core)` or `refactor(core)` for the package,
`feat(app)` or `refactor(app)` for the app, staging only the files each task names,
never `AuraCore/Package.resolved` or the generated `Aura.xcodeproj`, and not the
gitignored `Aura/Resources/MapboxAccessToken`. App-target file adds run
`xcodegen generate`. The branch ships through a PR into `main` like #3 through #8,
after CI is green, with a reconcile of local `main` to `origin/main`.
