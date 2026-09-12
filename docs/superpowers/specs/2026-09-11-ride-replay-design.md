# Ride replay — scrub a finished ride back (design)

**Date:** 2026-09-11 (v2.2: D8 reconciled to the one-layer route during execution; v2.1: v2 was reconciled after the 3-reviewer adversarial spec gate; v1 was
PO-approved in chat the same day; v2.1 folds in the rule changes the two-reviewer plan gate
forced, each marked **(v2.1)** — the plan's reconciliation log has the findings; v2.3: recenter
detection, capsule/pill/fit insets, and the AX-size row stack corrected from the simulator pass)
**Epic:** Summary & Map Polish — [ROH-239](https://linear.app/rohun/issue/ROH-239)
**Verification:** Tier 1, with one queued Verification issue for device smoothness and memory
on a long ride (§9)

## 0. What changed in v2, and why

The gate ran `review-skeptic`, `review-product`, and `review-architecture` independently
against v1. Their findings converged on four things, all of which v2 changes:

1. **v1 rendered pauses, not stops.** Its dwell, strip, label, and disc marker existed only at
   segment boundaries, which the recorder creates only on an explicit Pause tap. The stop the
   PO's bar names ("stopped for ten minutes at the top of the hill") is usually an unpaused
   stop inside one segment, and v1 showed it as a frozen triangle with no signal. v2 detects
   **holds** in the pure layer: pause gaps, stationary runs inside a segment, and lost-signal
   legs. All three get the same treatment (§D3).
2. **v1's marker was a screen-space overlay projected through `MapProxy`.** Three reviewers
   showed it does not survive contact with the SDK: `point(for:)` returns a `(-1, -1)`
   sentinel off-screen, `proxy.map` is nil on the first pass so a paused replay could open
   with no marker, and the "reprojection token" required exactly the `body` read the cited
   pattern forbids. The rejected alternative, a `MapViewAnnotation` inside a `TimelineView`,
   is what `NavigateHUDView` already ships at 30 Hz with a documented reason it is cheap.
   v2 uses it (§D8). The ROH-87 citation was wrong: that issue is a device-verification
   checklist, not a rendering finding.
3. **v1 accumulated the playback fraction inside a view body.** v2 derives it from an anchor
   (§D11), so `body` is idempotent and a pinch during playback cannot change the rate.
4. **v1 trusted `TrackPoint.timestamp` to be monotonic and positive.** Nothing in the
   recorder guarantees it; `RideStatsCalculator` defends itself leg by leg. v2 normalizes the
   time axis once in `init` (§D2).

Smaller changes: Reduce Motion keeps the glide (the peer-dot precedent) instead of stepping;
speed is a trailing window, not a centered one, and is called what it is; the third readout
is "time", not "active time", because the repo has one definition of active time and this is
not it; the entry pill is a real button and the map is not tappable; totals sit beside the
running numbers; the flat band is a scrubber rail, not an empty chart; short accidental
pauses are ignored; the floor and cap on playback length are tighter. Each is marked
**(v2)** where it lands.

## 1. What this is

A finished ride today is a static overview line and numbers. Replay makes the ride a thing
you can watch: the rider marker runs the recorded track across the map while speed,
distance, time, and elevation track a scrubber. Play, pause, drag to any moment.

It is a playback instrument, not a performance review. Nothing is scored or compared, and the
only numbers on screen are the ones the rider is looking at right now and the totals they
already rode. The bar for "good": a rider who just got home opens the ride, drags once, and
sees the shape of what they did, including the bit where they stopped for ten minutes at
the top of the hill, whether or not they pressed Pause.

Everything it needs is already recorded. No new data, no network, no backend, no schema
change.

## 2. Decisions

Numbered so reviewers and the plan can cite them. `Config` values are named so the plan can
pin them in one place.

### D1. Entry: one line in the summary, presented as a full-screen cover

`RideSummaryView` gains exactly one line: `.replayEntry(ride: ride)` applied to
`StaticRouteMap(segments: segs)` **before** the summary's own `.frame`, `.clipShape`,
`.overlay`, and `.opacity(revealed…)` modifiers, so the pill is clipped by the map's rounded
rect and fades in with it. The modifier lives in a new file, `RideReplayEntry.swift`, and:

- Builds `ReplayTimeline(segments:)` and `ReplayBandContent` once in `.task`, into `@State`.
  Until they exist, and whenever `timeline.isReplayable` is false, it draws nothing.
- Overlays a **`Button`** bottom-trailing on the map: `play.fill` glyph + "Replay", accent
  on the ink capsule the map chips use, accessibility label "Replay this ride". **(v2)** The
  map itself is not tappable. ROH-84 taught riders that tapping a map makes it live; the
  summary map stays inert, and the button is the whole affordance.
- Presents `RideReplayView(ride:timeline:band:)` in a `.fullScreenCover`. There is no other
  `fullScreenCover` in the app today; it presents over the History sheet and over the pushed
  ride-end route, and `SettingsStore` reaches it because it is injected at the app root.

Why this and not the alternatives:

- The summary is where a rider lands both after a ride (pushed `.rideSummary` route) and
  from a History row (sheet). One insertion covers both.
- A cover is not a NavigationStack path write, so the double-mutation reconciliation trap
  (Tier 2) does not apply.
- `RideSummaryView.swift` is one of the files the open device-verification queue is editing
  (the brief's constraint list). One inserted line beside the map is a trivial merge; PR #141
  touches only the two HUD files.
- History rows gain nothing in this slice. The cost is stated: from Home it is four taps
  (last-ride card → list → row → summary → Replay). A play badge on the History thumbnail is
  the named follow-up (§8).

Accepted risk: two fast taps on Replay and Share could race two presentations; UIKit drops
one. Not gated.

### D2. Time axis: normalized once, then constant compression

**(v2)** `ReplayTimeline.init` walks every segment once and classifies each **leg** (the
interval between consecutive points of one segment):

- `dt = max(0, next.timestamp − prev.timestamp)`. A backwards or equal stamp is a zero-width
  leg: it keeps its distance, occupies no time, and the search lands on its later point.
- `dt ≥ Config.signalGapSeconds (30 s)`: a **lost-signal leg**. It becomes a hold (§D3), of
  kind `.stopped` if its distance is under `Config.holdDistanceMeters (50 m)`, else
  `.signalLost`.
- Otherwise a moving or stationary leg. Runs of consecutive legs whose implied speed is below
  `Config.stoppedSpeed (0.5 m/s, the `RideStatsCalculator` threshold)` and whose summed `dt`
  is at least `Config.minStopSeconds (45 s)` become a **stationary hold**. Their legs leave
  the moving span; their distance still counts (it is GPS jitter, and `RideStats` counts it,
  which is what keeps the two totals equal).
- Every other leg is a **moving leg**, at real rate.

Boundaries between consecutive drawable segments (≥ 2 points) are **pause gaps** with
`gap = max(0, next.first.timestamp − prev.last.timestamp)`. A gap under
`Config.minPauseSeconds (5 s)` is an accidental tap and produces no hold **(v2)**; the two
segments play as continuous, still with no chord between them. Empty or single-point interior
segments never create extra gaps; a run of them between two drawable segments is one gap.

Then:

- `movingSpan` = Σ `dt` over moving legs.
- `movingPlayback` = clamp(`movingSpan` / `Config.rate (120)`, `Config.minPlayback (10 s)`,
  `Config.maxPlayback (45 s)`). **(v2)** v1 said 15/60; the product review's arithmetic
  (nobody sits through a silent 60 s, and a 12-minute errand should not take 15 s) tightened
  both ends. The PO approved 15/60 in v1; these are two `Config` values and the PO can move
  them back.
- `rate` = `movingSpan` / `movingPlayback`, in ride seconds per playback second.
- Holds get playback width per §D3; `playbackDuration` = `movingPlayback` + Σ hold widths.

Within a moving leg the marker advances at `rate` × real time, so a fast descent looks fast
and a 20-second stop at a light (below `minStopSeconds`) sits still. That is the shape of
the ride.

No speed-multiplier control. The scrubber is the rider's control over pace.

### D3. Holds: every stop the rider remembers, never a chord

**(v2)** A **hold** is one of: a pause gap, a stationary run, a lost-signal leg. Each hold has
a `kind` (`.paused`, `.stopped`, `.signalLost`), a `seconds` (the gap or the run's summed
`dt`), an anchor point (the last point before it), and a playback width:

- `width = clamp(seconds / rate, Config.minHold (1.5 s), Config.maxHold (4 s))`, so a
  40-minute lunch is visibly longer than a 60-second light without eating the band.
- If Σ widths exceeds `Config.maxHoldShare (0.25)` × `movingPlayback`, all widths scale down
  proportionally. This caps a ride with dozens of stops (or a future auto-pause) at a quarter
  of the playback.

During a hold: the marker sits on the anchor point in the stopped state (the white disc), the
speed slot reads "—", a status capsule over the map reads "Stopped · 10 min", "Paused · 10
min", or "No signal · 3 min" (§D5 for the format), and the band draws the hold as a strip.
When the hold ends, the marker appears at the next point. No position is ever interpolated
across a hold, in space or time; a lost-signal leg is a jump, not a glide across the river.

`pausedSeconds` on the ride is not consulted. The recorded timestamps are the truth for each
gap; `pausedSeconds` is a session total and cannot be attributed to individual gaps. Known
inaccuracy, stated: a pause tapped after a stale last fix (a tunnel) reads as the gap between
fixes, which can be longer than the pause. The label says what the data says.

Hold ranges on the playback axis are **half-open** `[start, end)` **(v2)**: the sample at
`start` is the hold, the sample at `end` is moving. `ReplayTimeline.holds` is what the band
draws and `sample(at:).phase` is computed from the same ranges; §4 pins that they agree.

### D4. Scrubber first, play second

The screen opens paused at fraction 0. One accent control, play/pause, centered under the
band. Dragging the band scrubs; if playback was running when the drag began, it **resumes**
when the drag ends **(v2)**, as every media scrubber the rider knows does. Tapping the band
(no drag) jumps the playhead there and leaves playback paused; **(v2.1)** that is one
`ReplayPlayback.tap(to:now:)` call, not an ordering of two, so the rule is tested. Playing
to the end stops at fraction 1; tapping play there restarts from 0.

**(v2.1)** Every playback event takes the live `Date()` from its handler. A `TimelineView`'s
`context.date` is for rendering only: a paused schedule's date is frozen, and anchoring
playback on it starts the ride from wherever the rider hesitated to.

### D5. What rides with the playhead

Three readouts in an instrument row between the map and the band:

1. **Speed** (hero numeral, `AuraTheme.Typography.metricBrand`, unit below). A **trailing
   mean** **(v2)**: the sum of leg distances between the points bracketing `[T − w, T]`
   within the current segment, divided by their timestamp span, with
   `w = max(Config.speedWindowFloor (5 s), rate × Config.speedWindowPlayback (0.1 s))`
   (12 s at 120×; exposed as `speedWindowSeconds`). It trails rather than centers so the
   number never anticipates the marker. **(v2.1)** The window never reaches back across an
   in-segment hold: a lost-signal leg's 900 m over 120 s is not a speed, and D3 forbids
   treating it as one. For the first `w` seconds after a hold the readout is "—".
   It never reads `TrackPoint.speedMetersPerSecond`, so GPX and simulated rides degrade
   identically. It is nil, rendered "—", inside a hold, at `.ended`, at fraction 0, or when
   the window holds fewer than two points with a positive span. It is smoother than the
   summary's top speed by design and will not reproduce it; that is a readout of the moment,
   not a record.
2. **Distance so far**, with the ride total beside it **(v2)**: "2.4 / 12.3" and the unit.
   Cumulative `Geo.distance` over legs within segments up to T, interpolated inside the
   current leg. At fraction 1 it equals `RideStats.distanceMeters` for the same segments.
3. **Time**, with the total beside it **(v2)**: "14:08 / 1:02:11". Ride time elapsed within
   segments up to T: **(v2.1)** Σ of normalized leg `dt` (D2), which excludes pause gaps,
   includes in-segment stops, and counts a backwards stamp as zero for its own leg and in
   full for the leg after it. This is the per-leg clock the readout advances by; it is not
   Σ of segment spans, and on a ride with a backwards stamp the two differ. It is deliberately **not** called active time: the repo has one
   definition of active time (`RideDuration`), guarded by
   `scripts/check-single-active-definition.sh`, and this is a different quantity. Formatted
   by `PauseControlCopy.clock`, which already grows an hours field and clamps negatives.

The row re-samples at 4 Hz while playing (its `now` is quantized to 0.25 s) so the numerals
do not blur at high rate; the marker samples every frame. Hold durations format as
`RideStatsFormatter.minutes` at ≥ 60 s ("10 min", "62 min") and as seconds below that
("45 s").

Nothing else. No averages of the ride, no maximums, no comparison.

### D6. The elevation profile is the scrubber

One band, `ReplayScrubBand`, spanning the playback axis:

- When `ElevationProfile.classify` says `.profile` (unchanged gain gate; classification
  happens once in the entry modifier, never in a `body`), the silhouette is
  `ReplayTimeline.profile(sampleCount: 240)`: elevation sampled at uniform playback
  fractions, repeating the anchor's elevation through a hold and carrying the last known
  value across points without one. It is drawn by a child view whose only input is that
  array, so the per-frame playhead invalidation never re-strokes it.
- `.flat` or `.unavailable` → a **scrubber rail** **(v2)**: a full-width dim track with the
  traversed portion filled accent, same height, same strips, same thumb. It reads as a
  control, not as a chart that failed.
- Holds are strips, minimum 12 pt wide, drawn **above** the silhouette in their own token,
  `AuraTheme.replayHoldStrip` (white at 28%) **(v2.1)**: a hairline-strength fill under the
  silhouette's 18% mint wash collapsed to ~11% and was invisible. PO eyeball owed on the
  simulator pass. A hold of ≥ 120 s gets its duration as a caption centered beneath its
  strip; captions are laid out left to right and a caption whose frame would intersect the
  previous one is dropped **(v2)**. The strip, caption, thumb, and pixel↔fraction rules live
  in `ReplayBandGeometry` (AuraKit) and are tested.
- The playhead is a 2 pt accent line with a **28 pt thumb** at the silhouette **(v2)**, and
  the band is inset horizontally by half the thumb so the thumb never clips at 0 or 1. A
  small elevation tag (`ReplayReadout.elevation`) sits beside the thumb on the silhouette
  band only.
- Drag anywhere on the band: `DragGesture(minimumDistance: 0)` on the full frame (min 88 pt
  tall). Entering a hold during a drag fires `.sensoryFeedback(.selection)` **(v2)** so a
  fast thumb feels the stop it crossed.

Known divergence, stated: the summary's elevation band is index-spaced over
`flattenedPoints` and the replay band is playback-time-spaced, so the two silhouettes of one
ride differ. Feeding the summary from `ReplayTimeline.profile` is the follow-up (§8); the
summary file is not touched in this slice.

### D7. Where it lives, and for which rides

`RideReplayView`, a full-screen cover on `AuraTheme.background`, portrait only (the app's
`Info.plist` supports portrait only):

- Top bar: close button leading (`xmark`), title = ride date (`abbreviated` date,
  `shortened` time), subtitle = destination name, else "Navigated" for a navigate ride, else
  "Explore" (the History row's three-valued rule, reimplemented in `ReplayReadout` and
  tested). `UnfinishedRideBadge(checkpointedAt:style: .full)` under the title when
  `ride.isUnfinished`.
- Map: the remainder of the height after the controls take theirs **(v2)**; the instrument
  row, band, and button have a fixed floor so they are never what clips at large Dynamic
  Type. Camera fits `.overview` across drawable segments once on appear (padding 24,
  maxZoom 16). Pan and pinch enabled; `GestureOptions` with `rotateEnabled = false` and
  `pitchEnabled = false`, applied in the `Map` modifier chain before any generic modifier
  (the repo's Map-modifiers-first rule). One recenter-to-fit control top-trailing, **(v2.3)**
  shown when a camera change arrives through `.onCameraChanged` while no programmatic fit or
  recenter is in flight (`movedOffFit`, the `HomeLiveMap` idiom); the simulator pass showed
  MapboxMaps 11.28 never writes `.idle` back to the binding, so `viewport.isIdle` is kept only
  as a fallback. Snaps under Reduce Motion, `withViewportAnimation` otherwise.
- Status capsule over the map, bottom-leading, during a hold (§D3).
- Instrument row (D5), band (D6), play/pause.

Availability **(v2)**: `ReplayTimeline.isReplayable` = at least one drawable segment, and
normalized `movingSpan ≥ Config.minReplayableSeconds (60 s)`, and total distance ≥
`Config.minReplayableMeters (200 m)`. The pill is hidden otherwise, so a 3-point test ride
gets no replay rather than a slow one, and a zero-span fixture cannot reach the arithmetic.

- No elevation, no stats, or under the gain gate → rail (D6).
- Checkpointed / unfinished ride → replays what was recorded, ends where recording ended,
  badge under the title.

### D8. Rendering: a `MapViewAnnotation` inside a `TimelineView`

**(v2, replaces v1's projected overlay)** `ReplayMap` is:

```
TimelineView(.animation(paused: !playback.isPlaying)) { context in
    Map(viewport: $viewport) {
        routeSource                      // GeoJSONSource, MultiLineString of drawable segments
        routeLayer                       // ONE LineLayer: mint width + the SDK's line border (v2.2)
        MapViewAnnotation(coordinate: sample.coordinate) { ReplayMarkerView(sample) }
            .allowOverlapWithPuck(true)
    }
    .gestureOptions(…).mapStyle(…).ornamentOptions(…)   // Map modifiers first
}
```

where `sample = timeline.sample(at: playback.fraction(at: context.date))`. This is the
`NavigateHUDView` structure: the route is a `GeoJSONSource` under a `LineLayer` rather than a
`PolylineAnnotationGroup`, because the SDK pushes GeoJSON only when `data` differs, so a
frame that moves only the marker re-uploads nothing. **(v2.2)** The casing is the layer's own
`lineBorderColor`/`lineBorderWidth`, one self-bordered stroke, not two stacked layers: that is
the recipe `StaticRouteMap` and `RoutePreviewView` already draw (the numbers `RouteStroke`
shares), and a bordered line renders its caps and joins as one stroke where two stacked
layers show casing seams at self-overlaps. The Task 8 review flagged the sketch's two-layer
wording against the plan's one-layer code; the code stands. Task 12's simulator pass eyeballs
the replay line's ends and joins against the summary map. The source value is rebuilt per pass
from a `[[CLLocationCoordinate2D]]` held in `@State` (mapped once on appear, never from
`ride.segments` in `body`). The marker's identity is structural, so the SDK reuses its
hosting view frame to frame. There is no `Puck2D`, no location provider, no projection, no
camera box, and nothing to clip.

The casing recipe (8 pt mint over 1.5 pt ink border, round caps and joins) currently lives
in `StaticRouteMap` and again in the share card. v2 lifts the numbers into
`AuraTheme.RouteStroke` and points `StaticRouteMap` at them (a constants-only edit, listed
under Changed) so the replay is not a third copy.

`ReplayMarkerView` draws `AuraPuck.ridingBearing` rotated to the sample bearing while
`.moving`, and `AuraPuck.browseTop` while in a hold or at `.ended`. Rotation and pitch are
disabled (D7), so the geographic bearing is the screen bearing. Under Reduce Motion the
bearing rounds to 45° (the peer-pointer rule). Dependency, stated: the riding puck is held
off both live HUDs until PR #141's device heading check lands; the replay shows it first,
which is fine, because here the bearing comes from the track rather than the compass and a
mirrored raster would be obvious against the drawn line.

`ReplayMarkerView` is `accessibilityHidden`; the map's VoiceOver surface is the band.

### D9. Bearing

**(v2.1)** Bearing at T is the course between the endpoints of the same trailing window
D5.1 uses, `PeerBearing.heading(from: p[i], to: p[j])`, when those endpoints are at least
`Config.coincidentMeters (0.5 m)` apart. A per-leg course was 120 heading changes per
playback second at 120×, each the raw course of one 6 m GPS leg; the peer pointer already
applies a deadband for less. Before the window holds two points the sample falls back to
the leg's own course, which holds its previous value across coincident points (the
`PeerInterpolator` rule) and is nil before the first non-coincident leg, in which case the
marker draws the disc. The pure bearing is raw; the 45° Reduce Motion rounding is
`ReplayMarkerStyle` in AuraKit, tested.

### D10. Reduce Motion

**(v2)** Play glides, linearly, exactly as without Reduce Motion: a small marker translating
along a path is not the class of motion the setting targets, and the peer dots already set
this precedent ("still glides, pulse off, pointer snaps to 45°"). What Reduce Motion turns
off: the entrance fade, the recenter flight (snap), any thumb nudge, and continuous bearing
rotation (45° steps). Scrubbing is unchanged. No stepped playback exists, so no step can
skip a hold.

### D11. Where the logic goes

- **AuraCore (pure, Swift Testing):** `ReplayTimeline`, `ReplaySample`, `ReplayPhase`,
  `ReplayHold`, `ReplayTimeline.Config`. All time is a fraction or an injected `Date`.
- **AuraKit (pure, Swift Testing):** `ReplayReadout` (sample + `DistanceUnits` → every
  displayed string and the VoiceOver value/label), `ReplayBandContent` (silhouette array or
  rail, built once), and `ReplayPlayback` **(v2)**: `@MainActor @Observable final class`,
  the `ShareUpgradePresenter` arrangement, holding `anchorFraction`, `anchorDate`,
  `isPlaying`, `resumeAfterScrub`, with event methods `play(now:)`, `pause(now:)`,
  `beginScrub(now:)`, `scrub(to:)`, `endScrub(now:)`, `jump(to:)`, `settle(now:)`, and the
  pure read `fraction(at now: Date) -> Double` =
  `isPlaying ? min(1, anchorFraction + (now − anchorDate) / playbackDuration) : anchorFraction`.
  **No write happens in a view body.** Reaching 1 is observed by the view as a derived Bool
  and reported through `.onChange` → `settle(now:)`, which parks the state at 1, not playing.
  There is no `Task` and no `Timer`; the `TimelineView` is the only clock and dies with the
  view.
- **App target (dumb projection):** `RideReplayView`, `ReplayMap`, `ReplayMarkerView`,
  `ReplayScrubBand`, `ReplayInstrumentRow`, `RideReplayEntry`.

## 3. Pure API

```swift
public struct ReplayTimeline: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        public var rate: Double = 120
        public var minPlayback: TimeInterval = 10, maxPlayback: TimeInterval = 45
        public var minHold: TimeInterval = 1.5, maxHold: TimeInterval = 4, maxHoldShare: Double = 0.25
        public var signalGapSeconds: TimeInterval = 30, holdDistanceMeters: Double = 50
        public var stoppedSpeed: Double = 0.5, minStopSeconds: TimeInterval = 45
        public var minPauseSeconds: TimeInterval = 5
        public var speedWindowFloor: TimeInterval = 5, speedWindowPlayback: TimeInterval = 0.1
        public var coincidentMeters: Double = 0.5
        public var minReplayableSeconds: TimeInterval = 60, minReplayableMeters: Double = 200
        public init()
    }
    public init(segments: [RideSegment], config: Config = .init())
    public let config: Config
    public var isReplayable: Bool
    public var playbackDuration: TimeInterval
    public var rate: Double
    public var totalDistanceMeters: Double
    public var totalSeconds: TimeInterval               // Σ normalized leg dt (v2.1)
    public var speedWindowSeconds: TimeInterval         // D5.1 (v2.1)
    public var drawableLines: [[Coordinate]]            // the one definition of "drawable" (v2.1)
    public var holds: [ReplayHold]                       // in playback order
    public func sample(at fraction: Double) -> ReplaySample   // total; fraction clamped to 0…1
    public func profile(sampleCount: Int) -> [Double]?         // nil when no point has elevation
    public var events: [Double]                          // 0, every hold start/end, every whole km AND mi, 1
}

public struct ReplayHold: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case paused, stopped, signalLost }
    public var kind: Kind
    public var seconds: TimeInterval
    public var range: Range<Double>                      // half-open, on the playback axis
}

public struct ReplaySample: Sendable, Equatable {
    public var coordinate: Coordinate
    public var bearing: Double?
    public var elevation: Double?
    public var speedMetersPerSecond: Double?
    public var distanceMeters: Double
    public var seconds: TimeInterval
    public var phase: ReplayPhase
}

public enum ReplayPhase: Sendable, Equatable {
    case moving
    case hold(ReplayHold.Kind, seconds: TimeInterval)
    case ended
}
```

`init` precomputes, per moving leg, the playback-axis start and end, cumulative distance,
and cumulative seconds, in parallel arrays, so `sample` is a binary search plus one
interpolation and allocates nothing. A 10,800-point ride is the working size; §4 builds one.

`ReplayPlayback` (AuraKit) is described in D11. `ReplayReadout` and `ReplayBandContent`
are value types with a single `init(...)` each and `Equatable`.

## 4. Invariants the tests pin

Each is a test that can fail. Fixtures are synthetic and named for what they exercise.

1. **Duration rule (D2):** one segment under the floor, at 120×, over the cap; two drawable
   segments with a 10-minute gap (one `.paused` hold of `min(600/rate, 4)` s); the same with a
   3 s gap (no hold); empty and single-point interior segments (no extra hold); twelve
   30-second pauses on a 20-minute ride (Σ hold widths == 0.25 × movingPlayback exactly).
2. **Normalization (D2):** a segment whose points all share one timestamp is drawable, has
   `movingSpan == 0`, is not replayable, and still samples without NaN at every fraction; a
   segment with one backwards stamp samples monotonically in `distanceMeters` and `seconds`,
   never produces a negative rate, keeps the zero-width leg's distance, and lengthens the leg
   after the stamp **(v2.1)**. A zero-width leg with a real displacement breaks a stationary
   run rather than joining it.
3. **Holds are what the sample says (D3):** for every hold, `sample(at: range.lowerBound)`
   and `sample(at: mid)` have `phase == .hold(kind, seconds)` with the hold's values and
   `coordinate` equal to the anchor point, `speedMetersPerSecond == nil`, and
   `distanceMeters` equal to the cumulative distance at the anchor; `sample(at:
   range.upperBound)` is `.moving` at the next point. No fraction outside every hold range
   samples as a hold.
4. **Stationary run detection (D3):** 60 s of jitter (< 0.5 m/s) inside a segment is one
   `.stopped` hold of 60 s; 30 s of jitter is none; two runs separated by a moving leg are two
   holds; a 120 s leg spanning 800 m is `.signalLost`; a 120 s leg spanning 10 m is `.stopped`.
5. **Never a chord:** for every fraction, the coordinate lies on a moving leg between two
   consecutive points of one segment, or on a hold anchor. A lost-signal leg is never
   sampled strictly between its endpoints. (The fixture's gap leg crosses a point set no
   other leg touches.)
6. **Speed (D5):** a constant-speed **quarter-circle** segment reads that speed at every
   interior fraction past the first window (so a chord implementation fails); nil at
   fraction 0, inside a hold, and for a window with < 2 points; a window whose points share
   a timestamp reads nil, not infinity. `w` is 12 s at rate 120 and 5 s at rate 30.
7. **Totals agree:** `sample(at: 1).distanceMeters == RideStatsCalculator.stats(segments:)
   .distanceMeters` within 1 e-6 on a 3-segment fixture with a stationary run; `sample(at:
   1).seconds == totalSeconds`; `sample(at: 1).phase == .ended`.
8. **Bearing (D9):** holds across coincident points; nil before the first non-coincident leg.
9. **Profile (D6):** `profile(sampleCount: 240)` has 240 entries, repeats the anchor
   elevation through a hold, carries the last value across a nil, is nil for a no-elevation
   ride, and the sample at index `k` equals the elevation `sample(at: k/239)` reports.
10. **Events (D10/§5):** sorted, deduplicated, start with 0 and end with 1, contain every
    hold's `lowerBound` and `upperBound`, and contain a fraction at each whole km and mi; a
    mark that falls inside a hold's folded distance lands on the hold's start **(v2.1)**.
11. **Replayable (D7):** false for < 60 s moving span, false for < 200 m, false with no
    drawable segment, true for the golden-ride fixture (445 s, > 200 m).
12. **Scale:** a synthetic 10,800-point, 3-hour ride with 4 stops builds, is replayable, and
    invariants 3, 5, and 7 hold on it. Performance is unmeasured and accepted.
13. **Playback (D11):** `fraction(at:)` is `anchorFraction` while paused; advances linearly
    while playing; clamps at 1; `beginScrub`/`endScrub` restore playing iff it was playing
    and re-anchor at the scrubbed fraction; `jump` leaves it paused; `settle` parks at 1 not
    playing; `play` at 1 restarts from 0.
14. **Readout strings (D5/D7):** "—" for nil speed, "2.4 / 12.3" distance, "14:08 / 1:02:11"
    time, "Stopped · 10 min", "Paused · 45 s", "No signal · 3 min", the elevation tag with
    unit, the three-valued subtitle, and the VoiceOver value ("4.2 miles, 22 minutes") and
    label.
15. **Band geometry (D6) (v2.1):** `x(0)`/`x(1)` are inset by half the thumb plus the stroke;
    `fraction(atX:)` inverts `x` and clamps; a degenerate width divides by nothing; the thumb's
    y follows the silhouette and centers on the rail; strips have a 12 pt minimum; captions
    skip holds under 120 s and drop on overlap.
16. **Marker style (D10) (v2.1):** Reduce Motion rounds 100 → 90, 113 → 135, 359 → 0; nil
    stays nil; without Reduce Motion the raw value passes through.

## 5. Interaction and accessibility

- Play/pause button: 56 pt accent circle, `play.fill` / `pause.fill`, the one accent-filled
  control on the screen. VoiceOver "Play replay" / "Pause replay". Identifier
  `RideTestID.replayPlay`.
- Band: `accessibilityAdjustableAction` moves the fraction to the next / previous entry of
  `timeline.events` **(v2)**, so a hold is always reachable in a handful of swipes and never
  skipped; `accessibilityValue` is the short readout value, the label is "Ride scrubber".
  Identifier `RideTestID.replayBand`. Entering a hold during play posts an accessibility
  announcement with the hold label, the only channel a VoiceOver rider has for it.
- Marker, playhead, and silhouette are `accessibilityHidden`; the instrument row is one
  combined element whose label is `ReplayReadout.accessibilityLabel` (spoken once; the band's
  value is the short form, not this string).
- Dismissal while playing: the `TimelineView` dies with the view; there is nothing else.
- Dynamic Type: the row stacks its three readouts vertically at accessibility sizes **(v2.3)**;
  the band height is fixed; the title truncates to two lines; the map takes what is left
  (D7).

## 6. Files

New:

- `AuraCore/Sources/AuraCore/Replay/ReplayTimeline.swift`, `ReplayTimeline+Sample.swift`,
  `ReplaySample.swift`, and `SyntheticRide.swift` **(v2.1)**: the 10,800-point builder lives
  in the library under `#if DEBUG`, not the test target, because the DEBUG seed inserts it
  into the store.
- `AuraCore/Tests/AuraCoreTests/Replay/ReplayTimelineTests.swift`, `ReplayFixtures.swift`
- `AuraCore/Sources/AuraKit/Replay/ReplayReadout.swift`, `ReplayBandContent.swift`,
  `ReplayBandGeometry.swift`, `ReplayMarkerStyle.swift`, `ReplayPlayback.swift`
- `AuraCore/Tests/AuraKitTests/Replay/ReplayReadoutTests.swift`, `ReplayBandGeometryTests.swift`,
  `ReplayPlaybackTests.swift`
- `Aura/Sources/Ride/Replay/RideReplayView.swift`, `ReplayMap.swift`,
  `ReplayMarkerView.swift`, `ReplayScrubBand.swift`, `ReplayInstrumentRow.swift`,
  `RideReplayEntry.swift`

Changed:

- `Aura/Sources/Ride/RideSummaryView.swift`: one line.
- `Aura/Sources/Theme/AuraTheme.swift` (or a new `RouteStroke.swift` beside it): the route
  casing constants.
- `Aura/Sources/Ride/StaticRouteMap.swift` and `Aura/Sources/Plan/RoutePreviewView.swift`:
  read those constants; no behavior change. (The share card's `ShareCardLayout` stroke is a
  Core Graphics centered stroke expressing the same 5 pt core; it stays separate. **(v2.1)**)
- `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`: three identifiers
  (`replayEntry`, `replayPlay`, `replayBand`).
- `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift`: the `-auraSeedLongRide` flag.
- `Aura/Sources/AuraApp.swift`: the DEBUG seed, **ephemeral store only** **(v2.1)**: the
  persistent store mirrors to the developer's real iCloud.

Untouched: `NavigateHUDView`, `RideMapView`, `RideSummaryView+ShareUpgrade`, all group-ride
crew files, `AppRoute`, `SimulatedRideSupport`, `HistoryView`.

The Xcode project is generated: `cd Aura && xcodegen generate` picks up the new files.

## 7. Design language

Mint `#7CF0A8` on near-black. The accent is spent on: the play/pause fill, the playhead and
thumb, the silhouette stroke and its 18% fill (the summary band's values), the rail's
traversed fill, and the Replay pill. The route line is the cased mint polyline the summary
draws, from the shared constants. Numerals use the existing metric typography; units use
`AuraTheme.Typography.unit`. No gradients. Hold strips are `AuraTheme.hairline` fill; the
status capsule is the ink chip surface the map controls use.

## 8. Out of scope, named

Follow-the-rider camera; a speed multiplier or hold-to-fast-forward; gems passed;
time-of-day readout; sharing or exporting a replay; group-ride peers in replay; a
History-row play badge and a last-ride card that opens the ride (the reachability
follow-up); feeding the summary's elevation band from `ReplayTimeline.profile` so the two
silhouettes match; auto-play on open; rendering under Reduce Motion as anything other than
a glide.

## 9. Verification

Tier 1, plus one queued Verification issue.

- Package suites in §4 green in the gate.
- Simulator, two rides: the golden-ride fixture (445 s moving, floor regime, ~44×) and the
  paused fixture (290 s, one pause). Both land on the floor, so they exercise the floor branch
  and the hold path but not the cap. For the cap regime, `-auraSeedLongRide` together with
  `-auraInMemoryRideStore` seeds `SyntheticRide.threeHour` into the in-memory store; the seed
  refuses a persistent store **(v2.1)**. The pass also opens the cover, waits 30 s, taps
  Play, and confirms playback starts at 0. Screenshots: replay at fraction 0 with the marker on the
  first vertex, mid-ride moving with the triangle on the line, mid-hold (capsule, disc,
  strip, caption), `.ended`, after a pinch with the recenter control showing, Reduce Motion
  mid-glide with the 45° pointer, AX3 Dynamic Type, and the summary with the Replay pill in
  both the post-ride and History presentations.
- **Queued (Tier 2, non-blocking):** a `Verification` issue for the 3-hour ride on device:
  memory with the summary and share renderer alive under the cover, marker smoothness at
  60 Hz during playback and under pinch, no map stutter. `docs/VERIFICATION.md` puts
  animation smoothness on hardware in Tier 2, and a Mac GPU is not evidence about a phone's
  memory ceiling. Merge does not wait for it.

## 10. Risks

- **Two live Mapbox maps** (summary under the cover, replay in it) plus the share card's
  offscreen renderer. Expected fine; the queued device check is the evidence.
- **Annotation cost at 60 Hz.** The HUD runs the same structure at 30 Hz with peers and a
  destination flag. If the replay hitches in the simulator on the 3-hour seed, the plan's
  fallback is `.animation(minimumInterval: 1/30)`.
- **A hold caption collides with the thumb.** Captions sit below the band's baseline, the
  thumb sits on the silhouette; they share no vertical space.
- **`viewport.isIdle` means "the viewport manager went idle for any reason"** **(v2.1)**, not
  only a rider gesture. A failed initial fit (empty geometry, zero-size first layout) would
  show the recenter control over an unframed map. Low probability, accepted; the simulator
  pass looks for it at fraction 0. **Superseded in v2.3**: the control now keys off
  `movedOffFit`, not `viewport.isIdle`, so this risk no longer applies to the primary path.
