# Ride-summary elevation profile — design

Board card: [#52](https://github.com/rjoseph256/aura/issues/52) (Epic: Summary & Map
Polish). Sprint 1, P1. Status at write time: In Progress.

## Context

The finished-ride summary (`Aura/Sources/Ride/RideSummaryView.swift`) is map-led: a
static route map, a hero distance count-up, then a supporting-stats row (moving time,
elevation climbed, top speed). It renders from a full `Ride` (`ride.track: [TrackPoint]`,
each point carrying an optional `elevation: Double?`).

An elevation profile already exists, but only on the shareable card
(`ShareCardView` → `ElevationSparkline`, a Canvas line+fill component in
`Aura/Sources/Plan/ElevationSparkline.swift`, fed raw `ride.track.compactMap(\.elevation)`).
The live summary has no profile. This adds one — the last piece of the Wave 2 summary
redesign that was deferred.

## Goal

A quiet, glanceable **Elevation** section on the ride summary that reads as data, honors
the instrument-cluster identity (near-black, one lime accent, no gradients, everything
from `AuraTheme` tokens), and is honest about distance.

## Non-goals (this sprint)

- No touch interaction / scrub-to-read (possible later `delight` pass).
- No grade-based color segments.
- No change to `ElevationSparkline` or the share card (its compact by-index sparkline is
  fine at 48pt). Sharing the new distance-accurate path with the card is an optional
  follow-up, explicitly out of scope here.
- No new charting dependency. Canvas only (Swift Charts stays absent from the app), which
  the offscreen `ImageRenderer` share path also requires.
- No load-time motion. The hero count-up remains the single arrival moment (product
  register discourages load choreography).

## Behavior

- The section renders **only when the ride has meaningful elevation**, reusing the share
  card's exact gate: at least 2 track points carry elevation **and** the peak-to-trough
  range is ≥ 5 m. Otherwise the section is omitted entirely — no empty chart, no
  placeholder. (Total climb still appears in the stats row and on the share card, so
  nothing is lost when the profile is hidden.)
- Layout order is unchanged above it: map → hero distance → supporting stats → **Elevation
  section** → existing actions (Share).

## The one correctness upgrade — distance-accurate X-axis

The share-card sparkline plots elevation by sample **index**. GPS is time-sampled, so
index-plotting stretches the stretches of a ride where the rider was slow or stopped: a
hill climbed slowly looks artificially wide. The summary chart plots elevation against
**cumulative distance** so the profile is proportionally honest.

This is a small pure, deterministic, unit-tested helper in **AuraCore** (the "pure logic,
tested" layer), sketched:

```swift
// AuraCore
public struct ElevationProfile: Equatable, Sendable {
    public let samples: [Double]     // elevation in meters, evenly spaced by distance
    public let minMeters: Double
    public let maxMeters: Double
}

public enum ElevationProfileBuilder {
    /// Returns nil when the ride lacks a meaningful profile (the gate).
    public static func make(
        track: [TrackPoint],
        sampleCount: Int = 96,       // matches ElevationSampling's max
        minRangeMeters: Double = 5
    ) -> ElevationProfile?
}
```

Algorithm: keep track points that carry elevation; compute cumulative great-circle
distance along their coordinates (reuse the existing distance helper the stats layer uses —
the plan confirms the exact symbol); if fewer than 2 kept points or `max - min <
minRangeMeters`, return `nil`; otherwise sample `sampleCount` positions evenly across
`0...totalDistance`, linearly interpolating elevation at each. The resulting `samples`
feed the existing `Sparkline.points(values:in:inset:)` normalizer unchanged.

`sampleCount` (default 96) bounds the Canvas segment count so a long, dense ride does not
draw thousands of segments.

## Composition

- **Pure (AuraCore):** `ElevationProfile` + `ElevationProfileBuilder` above. Plus a small
  formatter-facing accessor for min/max already available on the value type.
- **View (Aura app):** a new `ElevationProfileSection` view under `Aura/Sources/Ride/`
  that composes:
  - a quiet section label "Elevation" (SF Pro Rounded chrome, `AuraTheme.textSecondary`,
    sentence case — not a tracked all-caps eyebrow),
  - the existing `ElevationSparkline(elevations: profile.samples, stroke: AuraTheme.accent,
    fill: AuraTheme.accent.opacity(0.15), lineWidth: 2.5)` at ~100pt height,
  - two `textSecondary` min/max elevation labels and quiet start / distance-end labels,
    all unit-formatted.
- **Wiring:** `RideSummaryView` calls `ElevationProfileBuilder.make(track: ride.track)`
  once; if non-nil, it inserts `ElevationProfileSection` after the supporting-stats row.
  `ElevationSparkline` itself is untouched (share card unaffected).

## Units & accessibility

- **Units:** every displayed value (min, max, distance-end) goes through
  `RideStatsFormatter` so metric riders see meters/km and imperial riders feet/miles —
  honoring the metric-rider bug lesson from Wave 2.
- **VoiceOver:** the section is one composed element via
  `accessibilityElement(children: .ignore)`, reading e.g. "Elevation profile. Climbed 340
  feet, from 1,120 to 1,360 feet." The composed string is built by a pure, unit-aware
  helper so it is unit-tested, not assembled in the view.
- **Dynamic Type:** labels use semantic styles and scale; the chart height is fixed but its
  labels reflow. **Reduce Motion:** nothing animates, so it is a no-op. **Increase
  Contrast:** the fill opacity and secondary label color route through the existing scoped
  Increase-Contrast path used by the other map-adjacent summary surfaces.
- WCAG: lime-on-near-black is already asserted in the `AuraPalette`/`WCAGContrast` CI
  suite; no new pair is introduced.

## Testing

- **AuraCore (Swift Testing):** `ElevationProfileBuilder` — a hilly ride resamples to the
  requested count with correct min/max; the gate returns `nil` for a flat ride (range <
  5 m), for a ride with < 2 elevation points, and for an empty track; distance-weighting is
  proven by a track that clusters many points over a short slow stretch (index-plot and
  distance-plot must differ, and the distance-plot must not over-widen the slow stretch);
  linear interpolation hits known values at known distances. The composed-VoiceOver-string
  helper — imperial and metric phrasings.
- **Simulator (iPhone 17 / iOS 26):** the summary showing a hilly ride's profile; a flat
  ride hiding the section; metric vs imperial labels; Dynamic Type at an accessibility
  size; Reduce Motion (no change). Verified by the accessibility tree reading the section
  as one composed utterance.

## Edge cases

- Ride with elevation on only some points: only elevation-carrying points are used for both
  distance and value; if that leaves < 2 points or range < 5 m, the section hides.
- Very short ride (near-zero distance) with elevation range ≥ 5 m: total distance may be
  ~0; the builder guards against divide-by-zero by falling back to even index spacing for
  that degenerate case (still a valid, if not distance-weighted, tiny profile).
- Negative/lowland elevations (below sea level): handled — min/max are computed from the
  data, not assumed non-negative.

## Out of scope / possible follow-ups

- A subtle trace draw-on synced to the hero count-up (`delight` pass).
- Upgrading the share card to the distance-accurate path (shared helper) for parity.
- Grade-colored segments and scrub-to-read (a richer, interactive profile).
- An elevation Y-gridline or a second reference tick, if the min/max labels prove
  insufficient on device.
