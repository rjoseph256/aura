# Ride replay — scrub a finished ride back (design)

**Date:** 2026-09-11 (v1, approved by PO in chat; awaiting the 3-reviewer adversarial spec gate)
**Epic:** Summary & Map Polish
**Verification:** Tier 1 (see §9)

## 1. What this is

A finished ride today is a static overview line and numbers. Replay makes the ride a thing
you can watch: the rider marker runs the recorded track across the map while speed,
distance, elapsed time, and elevation track a scrubber. Play, pause, drag to any moment.

It is a playback instrument, not a performance review. Nothing is scored, averaged, or
compared. The bar for "good": a rider who just got home opens the ride, drags once, and
sees the shape of what they did, including the bit where they stopped for ten minutes at
the top of the hill.

Everything it needs is already recorded. No new data, no network, no backend, no schema
change.

## 2. Decisions

Numbered so reviewers and the plan can cite them.

### D1. Entry: one line in the summary, presented as a full-screen cover

`RideSummaryView` gains exactly one line: a `.replayEntry(ride:)` modifier on its existing
`StaticRouteMap`. The modifier lives in a new file and does three things: overlays a small
"Replay" pill (play glyph + word) bottom-trailing on the map, makes the map tappable, and
presents `RideReplayView` in a `.fullScreenCover`.

Why this and not the alternatives:

- The summary is where a rider lands both after a ride (pushed `.rideSummary` route) and
  from a History row (sheet). One insertion covers both.
- A cover is not a NavigationStack path write, so the double-mutation reconciliation trap
  (Tier 2) does not apply. A cover presents fine over a sheet and over a pushed route.
- `RideSummaryView.swift` is on the hot-file list. One inserted line beside the map is a
  trivial merge against anything the open verification queue lands. PR #141 touches only
  the two HUD files. Nothing else in the summary changes.
- History rows gain nothing. Replay is reached through the ride, not beside it.

The pill is present whenever the summary draws a map, which is the same rule as replay
availability (D7). `StaticRouteMap` is `allowsHitTesting(false)`; the modifier's overlay
carries the tap.

### D2. Time model: constant compression, floored and capped

Playback runs ride time at a constant rate. Define:

- `movingSpan` = Σ over segments of (last point timestamp − first point timestamp), for
  segments with ≥ 2 points. Segments with < 2 points contribute 0.
- `pauseCount` = number of boundaries between consecutive *drawable* segments (≥ 2 points).
  Empty or single-point interior segments do not create extra pauses; a run of them between
  two drawable segments is one pause.
- `movingPlayback` = clamp(`movingSpan` / 120, 15 s, 60 s).
- `dwell` = 1.5 s per pause.
- `playbackDuration` = `movingPlayback` + `pauseCount` × `dwell`.
- `rate` = `movingSpan` / `movingPlayback` (ride seconds per playback second). At the floor
  or cap the rate is whatever makes the ride fit; between them it is 120.

Within a segment the marker advances at `rate` × real time, so a fast descent looks fast and
an unpaused stop at a light sits still. That is the shape of the ride. A 30-minute commute
plays in 15 s; a 2-hour ride in 60 s; a 6-hour ride also in 60 s at 360×.

No speed-multiplier control. The scrubber is the rider's control over pace.

### D3. Pauses: a fixed dwell, never a chord

Each pause between drawable segments occupies `dwell` of playback. During the dwell the
marker sits on the last point of the preceding segment in the stopped state, the speed slot
reads "Paused · <duration>" where duration is the wall-clock gap between that point and the
first point of the next drawable segment, formatted with the existing `minutes` rule for
gaps ≥ 60 s and as seconds below that. On the band the dwell is a dimmed strip of width
`dwell / playbackDuration`. When the dwell ends the marker appears at the first point of the
next segment. No position is ever interpolated across a segment boundary, in space or time.

`pausedSeconds` on the ride is not consulted. The recorded timestamps are the truth for each
gap; `pausedSeconds` is a session total and cannot be attributed to individual gaps.

### D4. Scrubber first, play second

The screen opens paused at fraction 0. One accent control, play/pause, centered under the
band. Dragging the band scrubs; if playback is running, a drag pauses it and it stays paused
after the drag. Playing to the end stops at fraction 1; tapping play there restarts from 0.
Tapping the band (no drag) jumps the playhead there.

### D5. What rides with the playhead

Three readouts in an instrument row between the map and the band:

1. **Speed** (hero numeral, `AuraTheme.Typography.metricBrand`, unit below). Computed by the
   pure layer as a windowed geometric mean: the chord distance travelled between the points
   bracketing the window [T − w, T + w] within the current segment, divided by the actual
   timestamp span of those points. `w` = max(5 s, `rate` × 0.25 s), so the number is readable
   at 120× rather than flickering every frame. It never reads
   `TrackPoint.speedMetersPerSecond`, so GPX, simulated, and Health-reconstructed rides
   degrade identically. It reads "—" inside a pause dwell, at `.ended`, or when the window
   contains fewer than two points with a positive time span.
2. **Distance so far**: cumulative chord distance within segments up to T, interpolated
   inside the current leg. Pause gaps contribute nothing, matching `RideStats`.
3. **Elapsed active time**: ride time elapsed within segments up to T, excluding pause gaps,
   formatted `h:mm:ss` above an hour and `m:ss` below (`RideStatsFormatter.clock` for the
   latter; the hour form is new and lives in `ReplayReadout`).

Nothing else. No averages, no maximums, no comparison to the ride's totals.

### D6. The elevation profile is the scrubber

One band, `ReplayScrubBand`, spanning the playback axis (fraction 0…1 of
`playbackDuration`):

- Ride classifies `.profile` (`ElevationProfile.classify`, unchanged): the silhouette is drawn
  from `ReplayTimeline.profile(sampleCount:)`, which samples elevation at uniform playback
  fractions. Inside a pause dwell the sample repeats the preceding point's elevation. A
  sample whose bracketing points have no elevation repeats the last known value; leading
  samples before any elevation exists take the first known value.
- `.flat` or `.unavailable`: a single hairline baseline at mid-height, same width, same
  dimmed pause strips, same playhead. It still scrubs.
- The playhead is a 2 pt accent vertical line with an accent dot at the silhouette; a small
  elevation tag (`ReplayReadout.elevation`) sits beside it when the sample has elevation.
  The tag is omitted on the flat band.
- Drag anywhere on the band to scrub. The gesture is a `DragGesture(minimumDistance: 0)`
  on the band's full frame, so the touch target is the whole band height (min 88 pt), not
  the 2 pt line.

Because the band and the map both index `ReplayTimeline` by the same fraction, the playhead
and the marker always show the same moment.

### D7. Where it lives, and for which rides

`RideReplayView`, a full-screen cover on `AuraTheme.background`:

- Top bar: close button leading (xmark, dismisses), title = ride date
  (`abbreviated` date, `shortened` time), subtitle = destination name or "Explore"
  (the History row's rule). `UnfinishedRideBadge(style: .full)` under the title when
  `ride.isUnfinished`.
- Map: upper region, fills to ~55% of height. Camera fits `.overview` across all drawable
  segments once on appear (the `StaticRouteMap` rule, padding 24, maxZoom 16). Pan and pinch
  enabled; rotation and pitch disabled so the marker's geographic bearing is its screen
  bearing. One recenter-to-fit control top-trailing, shown only after the camera has been
  moved by the rider; snaps under Reduce Motion, flies otherwise (the `recenter()` rule).
- Instrument row (D5), band (D6), play/pause.

Availability: replay exists for any ride the summary draws a map for, i.e. at least one
segment with ≥ 2 points. There is no separate gate; the modifier attaches to the map view
the summary already conditions on.

- No elevation → flat band (D6).
- Checkpointed / unfinished ride → replays what was recorded, ends where recording ended,
  badge under the title. No special end-of-track marker beyond the badge.
- Very short ride (e.g. 3 points over 10 s) → the 15 s floor makes it play slower than real
  time. Accepted; it is honest.

### D8. Rendering: a screen-space overlay, not map content

The marker is a SwiftUI view in a `ZStack` above the `Map`, positioned each frame by
projecting the sample's coordinate through `MapProxy.map?.point(for:)` (the projection
`NavigateHUDView.project` already uses). The `Map` content (one cased polyline per drawable
segment, as `StaticRouteMap` draws them) has static inputs and is never re-evaluated during
playback. The `TimelineView(.animation)` wraps only the overlay and the instrument row, and
only while playing.

Camera changes from a pan or pinch are received in `.onCameraChanged`, written to an
`@Observable` camera box (the `MapZoomCameraBox` pattern: no view reads it in `body`), and
the overlay reprojects on its next tick; while paused, `.onCameraChanged` bumps a small
reprojection token so the marker follows the map. A one-frame lag during a gesture is
accepted. The marker is clipped to the map's bounds when the rider pans it off.

The marker draws `AuraPuck.ridingBearing` (the white rounded triangle, `static let`, pointer
identity preserved) rotated to the sample bearing while `.moving`, and `AuraPuck.browseTop`
(the white disc) while `.paused` and at `.ended`. It is the two-state puck's showcase without
touching the SDK location puck, which is compass-driven (`PuckBearing.heading`) and cannot
play a track.

Rejected alternatives:

- `MapViewAnnotation` inside `Map {}` driven by a `TimelineView`: re-evaluates the polyline
  group on every frame, the ROH-87 watch item at 60 fps.
- Overriding the SDK puck's `LocationProvider` with `.course` bearing: relies on SDK
  interpolation behavior this repo has not verified, and heading-dependent rendering is
  Tier 2 by policy. Not worth a device pass for a couch feature.

### D9. Bearing

Bearing at T is the course from the earlier bracketing point to the later one
(`Geo`/`PeerBearing.heading`). When the two are within 0.5 m (the `PeerInterpolator`
coincident rule) the bearing holds its previous value; at a segment's first sample with no
previous value it takes the first non-coincident leg's course, or nil, in which case the
marker draws the disc. The view applies no deadband: the rate makes per-frame jitter
invisible, and scrubbing should feel exact.

### D10. Reduce Motion

Play still works but steps instead of glides: a 0.5 s repeating tick advances the fraction by
1/40 of the ride (a 20 s stepped playback regardless of `playbackDuration`); the marker
snaps, no implicit animation on its position; bearing rounds to the nearest 45° (the peer
pointer rule). Scrubbing is unchanged: the rider is the one moving it. Entrance transitions
are off; recenter snaps.

### D11. Where the logic goes

- **AuraCore (pure, Swift Testing):** `ReplayTimeline` (built once from `[RideSegment]`),
  `ReplaySample`, `ReplayPhase`. All time is a fraction or an injected `Date`; nothing reads
  a clock.
- **AuraKit (pure, Swift Testing):** `ReplayReadout` — sample + `DistanceUnits` → the exact
  strings the row and tag display, plus the combined VoiceOver label (the
  `ElevationProfileContent` pattern).
- **App target (dumb projection):** `RideReplayView`, `ReplayMap`, `ReplayScrubBand`,
  `ReplayInstrumentRow`, `ReplayMarker`, `RideReplayEntry` (the modifier),
  `ReplayPlayback` (`@Observable`: `fraction`, `isPlaying`, and the wall-clock-to-fraction
  step; the arithmetic delegates to a pure `ReplayClock` in AuraCore so the step rule is
  tested).

## 3. Pure API

```swift
public struct ReplayTimeline: Sendable, Equatable {
    public init(segments: [RideSegment], config: Config = .init())
    public struct Config { rate: 120, minPlayback: 15, maxPlayback: 60, dwell: 1.5,
                           speedWindowFloor: 5, speedWindowPlaybackSeconds: 0.25 }
    public var playbackDuration: TimeInterval       // D2
    public var isEmpty: Bool                        // no drawable segment
    public func sample(at fraction: Double) -> ReplaySample   // fraction clamped to 0…1
    public func profile(sampleCount: Int) -> [Double?]         // D6, on the playback axis
    public var pauses: [ClosedRange<Double>]        // dwell strips as fraction ranges, for the band
}

public struct ReplaySample: Sendable, Equatable {
    public var coordinate: Coordinate
    public var bearing: Double?                     // D9; nil → disc
    public var elevation: Double?
    public var speedMetersPerSecond: Double?        // D5; nil → "—"
    public var distanceMeters: Double
    public var activeSeconds: TimeInterval
    public var phase: ReplayPhase
}

public enum ReplayPhase: Sendable, Equatable {
    case moving
    case paused(gapSeconds: TimeInterval)
    case ended
}

public enum ReplayClock {                           // D10 + normal play, pure
    static func advance(fraction: Double, elapsed: TimeInterval,
                        playbackDuration: TimeInterval) -> Double
    static func step(fraction: Double, steps: Int = 40) -> Double
}
```

`sample(at:)` for an empty timeline is never called: the view is not presented (D7).
`ReplayTimeline` precomputes per-segment cumulative distance and time once in `init` so
`sample` is O(log n) by binary search on the playback axis; a 10,800-point ride must sample
at 60 Hz without allocation.

## 4. Invariants the tests pin

1. `playbackDuration` follows D2 exactly for: one segment under the floor, at 120×, over the
   cap; two drawable segments (one dwell); empty and single-point interior segments
   (no extra dwell).
2. `sample(at:)` is monotonic in `distanceMeters` and `activeSeconds` over fraction.
3. Inside a dwell range, `coordinate` equals the preceding segment's last point exactly,
   `phase == .paused(gap)` with `gap` equal to the timestamp difference across the boundary,
   `speedMetersPerSecond == nil`, and `distanceMeters` equals the segment's cumulative total.
   The first sample after the dwell equals the next segment's first point. No sample lies
   strictly between the two.
4. Never a chord: for every fraction, the sampled coordinate lies on a leg between two
   consecutive points of a single segment (or on a point).
5. Speed window: a constant-speed synthetic segment reads that speed at every interior
   fraction; a segment with one point in the window reads nil; a segment with two
   coincident timestamps reads nil rather than infinity.
6. Bearing holds across coincident points; rounds to 45° only in the view (D10), so the
   pure bearing is raw.
7. `profile(sampleCount:)` returns `sampleCount` entries, repeats elevation through a dwell,
   and returns all-nil when no point has elevation.
8. Unfinished ride (segments present, ride `checkpointedAt` set) builds and samples like any
   other; the timeline does not know about the marker.
9. `ReplayClock.advance` clamps at 1 and is linear in elapsed; `step` reaches exactly 1.0
   after 40 steps from 0 with no floating-point overshoot.
10. `ReplayReadout` strings: speed "—" for nil, `h:mm:ss` at ≥ 3600 s, "Paused · 10 min"
    and "Paused · 45 s" forms, elevation tag with the unit, and the VoiceOver label.

## 5. Interaction details

- Play/pause button: 56 pt accent circle, `play.fill` / `pause.fill`, the one accent-filled
  control on the screen. VoiceOver "Play replay" / "Pause replay".
- Band: `accessibilityAdjustableAction` increments/decrements the fraction by 1/40 so
  VoiceOver users can scrub; value reads the readout's label.
- The marker and playhead are `accessibilityHidden`; the instrument row is one combined
  element whose label is `ReplayReadout.accessibilityLabel`.
- Dismissal while playing stops the clock (the `TimelineView` is torn down with the view;
  `ReplayPlayback` holds no `Task`).
- Dynamic Type: the instrument row wraps to two lines at accessibility sizes (speed on its
  own line); the band height is fixed; the title truncates to two lines.

## 6. Files

New:

- `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift`, `ReplaySample.swift`,
  `ReplayClock.swift`
- `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift`, `ReplayClockTests.swift`
- `AuraCore/Sources/AuraKit/Replay/ReplayReadout.swift`
- `AuraCore/Tests/AuraKitTests/ReplayReadoutTests.swift`
- `Aura/Sources/Ride/Replay/RideReplayView.swift`, `ReplayMap.swift`, `ReplayMarker.swift`,
  `ReplayScrubBand.swift`, `ReplayInstrumentRow.swift`, `ReplayPlayback.swift`,
  `RideReplayEntry.swift`

Changed:

- `Aura/Sources/Ride/RideSummaryView.swift`: one line, `.replayEntry(ride: ride)` on
  `StaticRouteMap`.
- `Aura.xcodeproj` only if the target does not use folder-synchronized groups (check first).

Untouched: `NavigateHUDView`, `RideMapView`, `RideSummaryView+ShareUpgrade`, all group-ride
crew files, `AppRoute`, `StaticRouteMap`, `SimulatedRideSupport`.

## 7. Design language

Mint `#7CF0A8` on near-black. The accent is spent on: the play/pause fill, the playhead, the
silhouette stroke and its 18% fill (the summary band's values), and the Replay pill on the
summary. Route line is the cased mint polyline the summary already draws. Numerals use the
existing metric typography; units use `AuraTheme.Typography.unit`. No gradients. The
pause strip on the band is `AuraTheme.textSecondary` at 12%.

## 8. Out of scope

Follow-the-rider camera, a speed multiplier, gems passed, time-of-day readout, sharing or
exporting a replay, group-ride peers in replay, History-row entry, a replay on the Home
map, auto-play on open.

## 9. Verification

Tier 1. Evidence:

- Package suites in §4 green in the gate.
- Simulator: a ride recorded via the golden-ride harness (`scripts/golden-ride.sh`) and a
  paused fixture with at least one pause ≥ 60 s. Screenshots: replay at fraction 0, mid-ride
  moving, mid-dwell ("Paused · N min", disc marker), `.ended`, after a pinch with the
  recenter control showing, Reduce Motion mid-step, accessibility Dynamic Type (AX3), and the
  summary with the Replay pill in both the post-ride and History presentations.
- Nothing in this feature depends on GPS, heading, camera rotation, the location puck, two
  phones, or the NavigationStack path, so no Verification issue is queued.

## 10. Risks

- **Projection lag under gesture.** The overlay reprojects after `.onCameraChanged`, one
  frame behind the map. Accepted for a paused or slow-moving marker; if it reads as
  swimming in the simulator, the plan's fallback is to hide the marker during an active
  gesture and reveal on gesture end.
- **Two live Mapbox maps** (summary under the cover, replay in it). The share card already
  renders a third offscreen; memory is expected fine, verified by the simulator pass on a
  three-hour ride fixture.
- **`.fullScreenCover` over a `.sheet`.** Supported; the cover inherits the sheet's
  environment (`SettingsStore` for map style and units is injected at the app root, so it
  is present).
