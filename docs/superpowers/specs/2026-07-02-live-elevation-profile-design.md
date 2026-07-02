# Live Ride-Summary Elevation Profile — Design Spec

**Date:** 2026-07-02
**Status:** Approved (design), pending adversarial spec review
**Roadmap item:** "Summary and map polish — an elevation profile on the ride summary
(deferred from the Wave 2 redesign)" (docs/ROADMAP.md).

## Goal

Give the ride-summary screen an elevation **profile** whose job is the *effort
story* — make the climbs read as climbs at a glance, answering "how hard was this
ride?" It is a companion to the existing route map and distance hero, not an
analysis tool.

## Product decisions (from PO interview)

1. **Job:** effort story. The silhouette should make the ride *felt*, not report data.
2. **Prominence:** a confident, hero-adjacent band. Total climb is called out on it.
   The standalone "climbed" stat leaves the three-stat row (no double-telling).
3. **Flat rides:** show the real profile only above a relief threshold; below it, a
   slim "Mostly flat" treatment. Never the misleading solid-fill blob.
4. **Interaction:** static for v1. (Drag-to-read/scrub is an explicit *future*
   enhancement, belonging with a dedicated ride-detail view — out of scope here.)
5. **Callouts:** just the silhouette + total climb. Built so a "highlight the big
   climb" accent glow can layer on later without rework. No peak/low/grade in v1.
6. **Scope:** appears anywhere the summary shows — ride finish **and** History
   (History reuses `RideSummaryView`). Shares the share card's visual language,
   scaled up, so a rider's card and summary feel like one family.

## Architecture

Three-layer discipline, matching the share card:

- **AuraCore/AuraKit (pure):** all effort logic — the relief gate, the
  profile/flat/unavailable fork, and climb formatting — lives here and is unit
  tested without the app target.
- **Aura (app target):** a dumb SwiftUI band that projects the view-model; reuses
  the existing pure-Canvas `ElevationSparkline`.

### New pure type: `ElevationProfileContent` (AuraKit)

Location: `AuraCore/Sources/AuraKit/Summary/ElevationProfileContent.swift` (new
`Summary/` folder, sibling to `Sharing/ShareCardContent.swift`).

```swift
public struct ElevationProfileContent: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case profile([Double])   // real relief ≥ threshold: draw the silhouette
        case flat                // elevation recorded but < threshold: "Mostly flat"
        case unavailable         // no elevation samples at all: omit the section
    }
    public let state: State
    public let climbedValue: String   // formatted total climb, e.g. "1,240"
    public let climbedUnit: String    // "ft" or "m"

    public init(ride: Ride, units: DistanceUnits) { ... }
}
```

Resolution rules in `init`:

- `elevations = ride.track.compactMap(\.elevation)`
- `elevations.isEmpty || elevations.count < 2` → `state = .unavailable`
- else if `elevations.max()! - elevations.min()! >= threshold` → `state = .profile(elevations)`
- else → `state = .flat`
- `climbedValue`/`climbedUnit` come from `RideStatsFormatter(units:)` over
  `(ride.stats ?? .zero).elevationGainMeters` — always populated (the `.flat` line
  needs it; `.profile` uses it for the callout; `.unavailable` ignores it).

### Shared relief gate (no drift with the share card)

Extract the threshold + relief test into one pure helper both the card and the
summary call, so the two silhouettes always agree on "has relief."

Location: `AuraCore/Sources/AuraKit/Plotting/` (alongside `Sparkline`).

```swift
public enum ElevationRelief {
    /// Minimum peak-to-trough range (meters) to treat a ride as having real relief.
    public static let minRangeMeters = 5.0

    /// The elevation samples to plot, or [] when the ride is flat/absent.
    /// (count > 1 AND max-min >= minRangeMeters).
    public static func profileSamples(from track: [TrackPoint]) -> [Double]
}
```

`ShareCardContent` is refactored to call `ElevationRelief.profileSamples(from:)`
instead of its private `minElevationRangeMeters` + inline gate. Its existing tests
must stay green (behavior identical). `ElevationProfileContent` uses the same
helper to decide `.profile` vs `.flat` (it additionally distinguishes
`.unavailable` by whether *any* samples exist).

## The on-screen band (app target)

New view: `Aura/Sources/Ride/ElevationProfileBand.swift`, taking an
`ElevationProfileContent`. Rendered by `RideSummaryView` in a new slot.

**Placement.** Reading order in `RideSummaryView` becomes:
map → titleBlock → **heroDistance** → **elevation band** → supportingStats.
(The band sits *after* the distance hero and *above* the stat row — hero-adjacent
weight without displacing the greeting or dethroning the distance numeral.)

**Treatment (per-state):**

- `.profile([Double])` — an open, editorial element (NOT a bordered card; the map
  is already one). Full container width, ~110pt tall, silhouette baseline-anchored
  to a thin hairline rule. `ElevationSparkline(elevations:, stroke: AuraTheme
  route-line/accent, fill: accent at low opacity)` with a **self-scaling** range
  (single ride → own min…max). A modest top-left callout `↑ {climbedValue}
  {climbedUnit} climbed` in the accent color, caption/subhead weight —
  deliberately not hero-sized (distance stays the one giant numeral).
- `.flat` — no silhouette. A slim single line in the band's slot:
  `Mostly flat · {climbedValue} {climbedUnit} climbed`, secondary weight, accent
  tick. Keeps layout rhythm; this is the case that would otherwise blob.
- `.unavailable` — the band renders nothing (the whole section is omitted). Older
  rides that predate elevation capture simply don't show it; "0 ft climbed" would
  be noise and there is nothing honest to draw.

**Motion.** Joins the existing staggered reveal (opacity + 8pt rise) at the band's
delay slot. No count-up (static, matching the static map). Reduce Motion already
covered by the screen's pattern.

**Accessibility.** The `Canvas` stays `accessibilityHidden` (already true in
`ElevationSparkline`). The band exposes ONE combined element:
- `.profile` → "Elevation. Climbed {climbedValue} {climbedUnit spoken}."
- `.flat` → "Mostly flat. Climbed {climbedValue} {climbedUnit spoken}."
- `.unavailable` → not present.

*(Visual craft pass — exact spacing, weights, the hairline, callout position —
goes through `impeccable` + `swiftui-layout-components` during implementation,
consistent with the rest of the summary.)*

## Stat row change

`supportingCells` in `RideSummaryView` drops the "climbed" cell. The row becomes
two stats: `moving · top speed`, in every state (climb now lives in the band or
its flat line; `.unavailable` rides legitimately have no climb to show). No filler
third stat is added (YAGNI); the `ViewThatFits` horizontal→vertical reflow already
handles two items.

## Testing

**`ElevationProfileContentTests` (Swift Testing, AuraKit):**
- Relief ≥ 5 m → `.profile` carrying the elevation samples.
- Elevation present (≥ 2 samples) but < 5 m relief → `.flat`.
- No elevation samples (or a single sample) → `.unavailable`.
- Boundary: exactly 5 m of relief → `.profile` (gate is inclusive, matching card).
- GPS-noise jitter (sub-threshold wiggle across many samples) → `.flat`, not a
  fake jagged profile.
- `climbedValue`/`climbedUnit` correct in metric and imperial.
- **Cross-check:** the same ride fed to `ShareCardContent` and
  `ElevationProfileContent` agrees on relief-vs-flat (guards against the two
  silhouettes drifting; enforced by the shared `ElevationRelief` helper).

**`ElevationReliefTests`:** `profileSamples(from:)` returns [] below threshold and
for < 2 points; returns the samples at/above threshold.

**Regression:** `ShareCardContent` tests stay green after the refactor to the
shared helper (identical behavior).

**On-device visual pass (sim, via History since seeded rides live there):**
- A `.flat` ride renders the slim line and NOT a solid bar (the exact I1
  regression that only surfaced visually last time).
- A real hilly ride shows the silhouette + climb callout.
- A pre-elevation ride shows no band.

## Out of scope (v1)

- Drag-to-read / scrubbing (future; ride-detail view).
- Highlighting the single biggest climb / grade coloring (the `.profile` view is
  built so this can layer on later).
- Peak/low elevation callouts, max grade, average grade.
- Any change to the share card's rendering (it only gains the shared helper).
- Adding the profile to widgets or the Live Activity.

## Global Constraints

- 3-layer architecture: pure logic in AuraCore/AuraKit (no UIKit/SwiftUI/SwiftData/
  Mapbox in the pure layer); band view in the app target.
- Reuse the existing pure-Canvas `ElevationSparkline` (offscreen-safe); do NOT
  introduce Swift Charts or Mapbox for the profile.
- Relief threshold = 5.0 m, shared with the share card via one helper — the two
  must never disagree.
- Static in v1; no interactivity.
- `swift test` (AuraCore) green; `swiftlint --strict` clean (line ≤140 warn/200
  err; `void_function_in_ternary` is an error); app builds on the iPhone 17 sim.
- Local-only until the user says "push."
