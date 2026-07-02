# Live Ride-Summary Elevation Profile — Design Spec

**Date:** 2026-07-02
**Status:** Approved (design + adversarial spec review reconciled), pending user sign-off
**Roadmap item:** "Summary and map polish — an elevation profile on the ride summary
(deferred from the Wave 2 redesign)" (docs/ROADMAP.md).

## Goal

Give the ride-summary screen an elevation **profile** whose job is the *effort
story* — make the climbs read as climbs at a glance, answering "how hard was this
ride?" It is a companion to the existing route map and distance hero, not an
analysis tool.

## Product decisions (from PO interview + adversarial spec review)

1. **Job:** effort story. The silhouette should make the ride *felt*, not report data.
2. **Prominence:** a confident, hero-adjacent band. Total climb is called out on it.
   The standalone "climbed" stat leaves the three-stat row (no double-telling).
3. **What "counts" as a climb — cumulative gain, not range.** The profile/flat
   decision keys on **cumulative climb** (`RideStats.elevationGainMeters`), the same
   number shown on the callout — so the label and the number can never disagree.
   (The earlier draft gated on peak-to-trough *range*; review showed range and the
   climbed callout can openly contradict — a net-downhill ride reading "↑ 3 ft
   climbed" under a plunging line, or a rolling loop reading "Mostly flat · 180 ft
   climbed." Gating on gain removes both contradictions. The **share card adopts the
   same gate**, so the two surfaces stay consistent.)
4. **Flat rides:** below the climb floor, a slim "Mostly flat" treatment — never the
   misleading solid-fill blob. Gain-gating inherently excludes the blob: a near-flat
   series can't clear a climb floor, so `.profile` never receives a flat trace.
5. **Interaction:** static for v1. (Drag-to-read/scrub is an explicit *future*
   enhancement, belonging with a dedicated ride-detail view — out of scope here.)
6. **Callouts:** just the silhouette + total climb. Built so a "highlight the big
   climb" accent glow can layer on later without rework. No peak/low/grade in v1.
7. **Scope:** appears anywhere the summary shows — ride finish **and** History
   (History reuses `RideSummaryView`). Shares the share card's visual language,
   scaled up, so a rider's card and summary feel like one family.
8. **Pre-elevation rides show no climb.** Rides recorded before elevation capture
   (fewer than two elevation samples) resolve to `.unavailable` and omit the whole
   section. Those rides only ever computed `0` gain, so this hides a "0 ft climbed"
   that was always noise, not real data. Ratified with the PO.

## Architecture

Three-layer discipline, matching the share card:

- **AuraCore/AuraKit (pure):** all effort logic — the climb classification and climb
  formatting — lives here and is unit tested without the app target.
- **Aura (app target):** a dumb SwiftUI band that projects the view-model; reuses
  the existing pure-Canvas `ElevationSparkline`.

### Shared classifier: `ElevationProfile` (AuraKit)

One pure classifier both the summary and the share card call, so the two silhouettes
can never diverge on what counts as a climb. Location:
`AuraCore/Sources/AuraKit/Plotting/ElevationProfile.swift` (alongside `Sparkline`).

```swift
public enum ElevationProfile {
    /// Minimum cumulative climb (meters) for a ride to headline an elevation profile.
    /// Tunable; settled during the on-device pass (the share card previously used a
    /// 5 m *range* floor — this is a *gain* floor, a different and stricter measure).
    public static let minGainMeters = 10.0

    public enum Kind: Equatable, Sendable {
        case profile([Double])   // gain ≥ floor: draw the silhouette from these samples
        case flat                // ≥2 elevation samples but gain < floor: "Mostly flat"
        case unavailable         // < 2 elevation samples (pre-elevation rides): omit
    }

    /// `gainMeters` is the ride's cumulative ascent (RideStats.elevationGainMeters);
    /// `track` supplies the elevation samples the silhouette is drawn from.
    public static func classify(track: [TrackPoint], gainMeters: Double) -> Kind {
        let elevations = track.compactMap(\.elevation)
        guard elevations.count >= 2 else { return .unavailable }
        return gainMeters >= minGainMeters ? .profile(elevations) : .flat
    }
}
```

`.unavailable` is decided **only** by `elevations.count < 2` — a single non-nil
sample is `.unavailable`, never `.flat`. (This removes the earlier draft's
contradiction where two definitions disagreed on the single-sample case.)

### New pure type: `ElevationProfileContent` (AuraKit)

Location: `AuraCore/Sources/AuraKit/Summary/ElevationProfileContent.swift` (new
`Summary/` folder, sibling to `Sharing/ShareCardContent.swift`). It wraps
`ElevationProfile.classify` and adds display-ready climb text.

```swift
public struct ElevationProfileContent: Equatable, Sendable {
    public let kind: ElevationProfile.Kind
    public let climbedValue: String   // formatted cumulative climb, e.g. "1,240"
    public let climbedUnit: String     // "ft" or "m"
    public let climbedUnitSpoken: String  // e.g. "feet" — for the VoiceOver label
    public let isTrivialClimb: Bool    // gain rounds to ~0: drop the climb clause

    public init(ride: Ride, units: DistanceUnits) {
        let stats = ride.stats ?? .zero
        let fmt = RideStatsFormatter(units: units)
        kind = ElevationProfile.classify(track: ride.track,
                                         gainMeters: stats.elevationGainMeters)
        climbedValue = fmt.elevationValue(stats.elevationGainMeters)
        climbedUnit = fmt.elevationUnit
        climbedUnitSpoken = fmt.elevationUnitSpoken   // exists (RideStatsFormatter)
        isTrivialClimb = climbedValue == "0"           // formatted climb reads zero ⇒ no climb clause
    }
}
```

Because the callout number and the `.profile`/`.flat` decision are both cumulative
gain, `.flat` always carries a climb **below** the floor — so "Mostly flat · X
climbed" can never show a large number. When the gain rounds to zero
(`isTrivialClimb`), the flat line drops the climb clause entirely ("Mostly flat"),
matching the "0 ft climbed is noise" rationale used for `.unavailable`.

### Share card refactor

`ShareCardContent` migrates its inline range gate to `ElevationProfile.classify`:
`elevationSamples` becomes the `.profile(samples)` payload, or `[]` for `.flat`/
`.unavailable`. This is a **behavior change**, not a no-op: the card now gates on
cumulative gain instead of 5 m of range, so borderline single-bump rides (e.g. a
6 m climb) move from silhouette to plain stat. Its existing boundary tests are
**updated to the gain semantics** (not assumed unchanged), and a new parity test
pins that the card and the summary classify the same ride identically.

## The on-screen band (app target)

New view: `Aura/Sources/Ride/ElevationProfileBand.swift`, taking an
`ElevationProfileContent`. Its per-state rendering is a `switch` over `kind` — **not
a ternary** (avoids the `void_function_in_ternary` SwiftLint error). Rendered by
`RideSummaryView` in a new slot. (`ElevationSparkline` already lives in the same app
target and is used cross-folder by `ShareCardView`; no move or target-membership
work is needed.)

**Placement.** Reading order in `RideSummaryView` becomes:
map → titleBlock → **heroDistance** → **elevation band** → supportingStats.
(The band sits *after* the distance hero and *above* the stat row — hero-adjacent
weight without displacing the greeting or dethroning the distance numeral.)

**Treatment (per-state):**

- `.profile([Double])` — an open, editorial element (NOT a bordered card; the map
  is already one). Full container width, ~110 pt tall, silhouette baseline-anchored
  to a thin hairline rule. `ElevationSparkline(elevations:, stroke: accent/route
  line, fill: accent at low opacity)` with a **self-scaling** range (single ride →
  own min…max). A modest top-left callout `↑ {climbedValue} {climbedUnit} climbed`
  in the accent color, caption/subhead weight — deliberately not hero-sized
  (distance stays the one giant numeral).
- `.flat` — no silhouette. A slim single line in the band's slot:
  `Mostly flat · {climbedValue} {climbedUnit} climbed` (secondary weight, accent
  tick), or just `Mostly flat` when `isTrivialClimb`. Keeps layout rhythm; this is
  the case that would otherwise blob.
- `.unavailable` — the band renders nothing (the whole section is omitted).

**Self-scaling is an accepted v1 tradeoff — silhouette = shape, number = magnitude.**
Because each ride self-scales to its own min…max, a mountain ride and a gentle ride
can fill the band with equally dramatic silhouettes; the **climb callout carries the
true magnitude** ("3,000 ft" vs "180 ft"), so a rider comparing History entries is
never misled by the number even when the shapes look similar. A shared/absolute
vertical scale across History is noted as a future enhancement, not v1.

**Motion.** Joins the existing staggered reveal (opacity + 8 pt rise). Inserting the
band between `heroDistance` and `supportingStats` **shifts the stagger**: band takes
`.delay(0.15)` and `supportingStats` moves from `0.15` to `.delay(0.20)`, so the
cadence stays sequential rather than the band and stats firing together. No count-up
(static, matching the static map). Reduce Motion already covered by the pattern.

**Accessibility.** The `Canvas` stays `accessibilityHidden` (already true in
`ElevationSparkline`). The band exposes ONE combined element:
- `.profile` → "Elevation. Climbed {climbedValue} {climbedUnitSpoken}."
- `.flat` → "Mostly flat. Climbed {climbedValue} {climbedUnitSpoken}." (or
  "Mostly flat." when `isTrivialClimb`).
- `.unavailable` → not present.

*(Visual craft pass — exact spacing, weights, the hairline, callout position —
goes through `impeccable` + `swiftui-layout-components` during implementation.)*

## Stat row change

`supportingCells` in `RideSummaryView` drops the "climbed" cell. The row becomes
two stats: `moving · top speed`, in every state (climb now lives in the band or its
flat line; `.unavailable` rides legitimately have no climb to show). No filler third
stat is added (YAGNI); the `ViewThatFits` horizontal→vertical reflow already handles
two items. Confirmed with the PO: pre-elevation rides show climb nowhere on the
summary (they only ever computed 0).

## Small-screen check

The band adds ~110 pt between the hero and the stats. On an SE/mini-class device —
especially with the "Longest ride yet" badge and/or the `saveFailed` warning already
adding height — verify the stats are still reachable with minimal scrolling and the
first-glance moment still lands. Everything is inside a `ScrollView`, so nothing is
truly cut off, but the band must stay compact and the layout must be checked at the
smallest supported width, not asserted.

## Testing

**`ElevationProfileTests` (Swift Testing, AuraKit) — the classifier:**
- Gain ≥ 10 m with ≥2 elevation samples → `.profile` carrying the samples.
- ≥2 samples but gain < 10 m → `.flat`.
- Fewer than 2 elevation samples (0 or 1) → `.unavailable`.
- Boundary: gain exactly 10 m → `.profile` (inclusive).
- Net-downhill (big range, gain < floor) → `.flat` — the regression case, so no
  "plunging silhouette + tiny-climb callout."
- Rolling ride (gain ≥ floor) → `.profile` — no "Mostly flat · big number."

**`ElevationProfileContentTests`:**
- `climbedValue`/`climbedUnit`/`climbedUnitSpoken` correct in metric and imperial.
- `isTrivialClimb` true when gain rounds to ~0 (drives the flat line dropping the
  climb clause); false otherwise.
- **Parity cross-check:** the same ride fed to `ShareCardContent` and
  `ElevationProfileContent` classifies identically (both delegate to
  `ElevationProfile.classify`) — the guard against the two silhouettes drifting.

**`ShareCardContent` tests:** updated to the gain-gate semantics (a 6 m single-bump
ride now classifies `.flat`/empty samples; a real-climb ride stays `.profile`), plus
the parity test above. Not assumed unchanged.

**On-device visual pass (sim, via History since seeded rides live there):**
- A `.flat` ride renders the slim line and NOT a solid bar (the I1 regression that
  only surfaced visually last time).
- A real hilly ride shows the silhouette + climb callout that agree with each other.
- A pre-elevation ride shows no band.
- Small-screen (SE/mini) layout check per the section above.

## Out of scope (v1)

- Drag-to-read / scrubbing (future; ride-detail view).
- Shared/absolute vertical scale across History (future; v1 self-scales, number
  carries magnitude).
- Highlighting the single biggest climb / grade coloring (the `.profile` view is
  built so this can layer on later).
- Peak/low elevation callouts, max grade, average grade.
- Adding the profile to widgets or the Live Activity.

## Global Constraints

- 3-layer architecture: pure logic in AuraCore/AuraKit (no UIKit/SwiftUI/SwiftData/
  Mapbox in the pure layer); band view in the app target.
- Reuse the existing pure-Canvas `ElevationSparkline` (offscreen-safe); do NOT
  introduce Swift Charts or Mapbox for the profile.
- One shared classifier (`ElevationProfile.classify`, `minGainMeters` floor) drives
  BOTH the summary and the share card — the two must never disagree.
- The profile/flat gate and the climb callout are the **same measure** (cumulative
  gain), so the label and the number can never contradict on screen.
- Static in v1; no interactivity.
- Per-state rendering is a `switch`, never a ternary (`void_function_in_ternary` is a
  SwiftLint error). Watch interpolated label lines against the 140-col limit
  (warnings are build-gating).
- Run `xcodegen generate` before building locally (the `.xcodeproj` is gitignored and
  regenerated); new files under `Aura/Sources/**` are picked up only after regen.
- `swift test` (AuraCore) green; `swiftlint --strict` clean (line ≤140 warn/200 err);
  app builds on the iPhone 17 sim.
- Local-only until the user says "push."
