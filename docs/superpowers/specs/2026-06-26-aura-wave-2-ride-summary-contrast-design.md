# Aura Wave 2 — Ride-summary redesign and contrast lift: design

**Goal:** Rebuild the ride summary from its centered three-up-plus-orphan stat
stack into a map-led recap, and lift the borderline contrast values across the
app so text and key UI stay legible in sunlight. Both changes live inside the
existing mono-lime `AuraTheme`: no new palette, no gradients, lime `#C8FA4B` on
near-black `#07080C`, pink `#FF4D9D` reserved for ending a ride.

**Status:** approved design, ready to plan.

## Context

This is the third and final sub-project of Wave 2, after the navigate-HUD
cockpit (PR #9) and the composed VoiceOver labels (PR #10). It closes the two
audit findings those left open. Unlike the VoiceOver work, this sub-project is
allowed to change layout and visuals (that is the point), but it stays inside
the Wave 1 design system and its tokens. Finishing it completes Wave 2.

The design forks were settled with the user through brainstorming, with mockups
for the layout choice. The contrast values were measured, not guessed: a sweep
of every `opacity(0.…)`, `textSecondary`, and material use across the app fed a
WCAG ratio calculation, so the design acts on real numbers.

## What the audit found

Two findings from the 2026-06-24 audit remain open, and this sub-project closes
both.

- **"There is no design system, only a color sheet."** Wave 1 resolved the bulk
  of this, but flagged the ride summary's centered stat grid as worth a second
  look. The summary lays out three stats in a centered row (distance, moving
  time, elevation) with the fourth (max speed) stranded on its own line below,
  the orphaned stat stack.
- **"Accessibility is strong on motion, weak in the cockpit."** Wave 1 added the
  Reduce Transparency fallback and Wave 2's second sub-project added composed
  VoiceOver labels. The remaining open piece is the broad contrast lift.

## Current state, confirmed in code

- `RideSummaryView` (`Aura/Sources/Ride/RideSummaryView.swift`) is a `ScrollView`
  of a centered `VStack`: an optional `StaticRouteMap` at 240pt, a "Nice ride"
  title with an optional "to {destination}" line, an optional "Longest ride yet"
  accolade, a `saveFailed` warning, then the stats. The stats are an
  `HStack` of three centered `StatPair`s and a fourth `StatPair` on its own line
  beneath, all `alignment: .center`. A `Done` CTA closes the screen. The stat
  helper already combines value and label into one VoiceOver element.
- `AuraTheme` (`Aura/Sources/Theme/AuraTheme.swift`, in the app target and
  shared into `AuraWidgets` by source inclusion) defines a private `Palette` of
  raw color values and the public roles built from it: `textPrimary`
  (`Color(white: 0.92)`), `textSecondary` (`Color(white: 0.55)`), `background`
  (`#07080C`), `surface` (`#0E1014`), `accent`/`routeLine` (lime), `destructive`
  (pink), `onAccent`/`onDestructive` (the inks), and `border`
  (`Color.white.opacity(0.08)`).
- `StatPair` already takes an `alignment` parameter (`.leading` default,
  `.center` for the summary today). `SpeedReadout` is the cockpit speed hero.
- The `AuraWidgets` extension links both `AuraCore` and `AuraKit` and compiles
  `AuraTheme.swift` as a shared source, so the theme can read pure values from
  `AuraCore` without breaking the widget build or the macOS CI `swift test`.
- Both modules build under Swift 6 with the CI `xcodebuild` and SwiftLint gates.

### Measured contrast (the numbers this design acts on)

Relative-luminance WCAG ratios, with alpha values composited over the base they
sit on. Body text needs ≥4.5:1; large or bold text and meaningful UI need ≥3:1.

| Pair | Now | After |
|---|---|---|
| `textSecondary` on `background` | 5.97:1 | 7.48:1 (white 0.62) |
| `textSecondary` on `surface` | 5.68:1 | 7.12:1 |
| LastRideCard date `textSecondary.opacity(0.85)` on `surface` | **4.26:1** | 7.12:1 |
| Free-ride secondary labels over a bright map, scrim 0.55 | **1.91:1** | 5.35:1 (scrim 0.85) |
| RoutePreview selected metrics `onAccent.opacity(0.7)` on lime | 5.61:1 | 13.72:1 (full ink) |
| `border` hairline over `background` | 1.17:1 | 1.41:1 (white 0.14) |
| lime on `background` (identity) | 16.43:1 | unchanged |
| accolade lime on `accent.opacity(0.14)` | 12.24:1 | kept |

Two pairs are genuine sub-4.5:1 failures: the double-faded date and secondary
text sitting over the translucent cockpit scrim on a bright sunlit map. The
ink-on-lime metrics the inventory flagged as critical in fact pass; the fix
there removes a fragile opacity stack rather than a violation. The `border`
hairline cannot reach 3:1 without going bright enough to wreck the dark
identity (22% white is still only 1.88:1), so it stays decorative (boundaries
also come from surface-fill contrast) and firms up only for sunlight.

## Decisions settled during brainstorming

1. **Map-led summary (direction C).** The route map is the hero of the recap;
   the distance leads the stats with a touch more weight; moving time, climbed,
   and top speed sit in an even row beneath. This retires the orphan, earns the
   end-of-ride moment, and avoids the hero-metric template that a big-number
   layout (direction B) would have been.
2. **Map-only hero.** No elevation profile. The climb stays a stat
   ("741 ft climbed"). Keeps the sub-project a focused redesign plus contrast
   pass rather than a feature add.
3. **A light, Reduce-Motion-safe entrance.** A staggered fade-and-rise of the
   title, hero, and stats, plus a count-up on the hero distance. Content is
   visible by default; Reduce Motion shows the final values instantly.
4. **Hybrid contrast lift.** Nudge the app-wide tokens for a sunlight margin,
   and fix the per-view failures the inventory found.
5. **A scoped Increase-Contrast path.** Read `colorSchemeContrast` in the
   high-value spots so foregrounds strengthen when the rider turns on Increase
   Contrast, keeping a restrained default and a strong high-contrast mode.

## The redesign

`RideSummaryView` becomes a left-aligned column inside the `ScrollView`, which
breaks the all-centered layout the audit flagged.

- **Hero route map.** `StaticRouteMap` stays at the top, full-width, rounded at
  `Radius.xl`, with the firmed border. Shown only when the ride has a track
  (`ride.track.count > 1`); a track-less ride drops straight to the title.
- **Title block.** "Nice ride" in `largeTitle.bold`, `textPrimary`; the
  "to {destination}" line in `subheadline`, `textSecondary`. This block flips
  from its current centered alignment to leading (the destination line drops
  `.multilineTextAlignment(.center)`), as do the "Longest ride yet" accolade and
  the `saveFailed` warning, which keep their meaning and move under the title.
- **Hero distance.** The distance value in SF Pro Rounded at a display size via
  `@ScaledMetric` (the chrome personality, not cockpit Saira), with
  `monospacedDigit()` so the count-up does not jitter and the glyphs align. The
  unit reads in `textSecondary` to match the chrome stat treatment, with a small
  "distance" label beneath. Lime stays on the route line, the `Done` CTA, and
  the accolade, not on the hero number.
- **Supporting stats.** A single evenly-spaced row of three `StatPair`s
  (`alignment: .leading`): moving time, climbed, top speed. At accessibility
  text sizes the row reflows so nothing clips. `StatPair` keeps its plain
  `AuraTheme.textSecondary` label (7.12:1 after the bump); it is intentionally
  not put on the Increase-Contrast resolver, since it already clears the target.
- **Zero-stat / track-less ride.** A ride with no track drops the map and
  anchors on the hero distance; a statless ride (`stats ?? .zero`) reads "0.0",
  and the count-up from zero is a no-op. Both are acceptable, not special-cased.
- **Done CTA.** Unchanged: `.ctaPrimary`, full width.
- **Motion.** The title, hero, and stat row fade and rise in a short stagger on
  appear. The hero distance counts up by animating one `@State` Double from 0 to
  `stats.distanceMeters` (a `.task`/`onAppear`-driven `withAnimation`), formatted
  every frame with the same `fmt.distanceValue` the static screen uses, so the
  final frame is byte-identical to the static value (no visible snap). With
  `accessibilityReduceMotion` on, the Double is set straight to the final value
  and the fade/rise collapse to an instant appearance. The map is not animated;
  the motion is on the chrome.

## The contrast lift

### Centralized palette and a CI-enforced contrast guard

The raw numeric palette moves into a pure `AuraPalette` in `AuraCore` (plain
`Double` components, white levels, and opacities, with no SwiftUI). `AuraTheme`
builds its `Color` roles from `AuraPalette` instead of inline literals. A pure
`WCAGContrast` helper in `AuraCore` (relative luminance, the contrast ratio, and
alpha compositing) backs a test suite that asserts the lifted pairs clear their
targets. Because the tokens and the tests now read the same numbers, the guard
is real: lowering a token below its target fails CI. This is the pure,
CI-testable logic the sub-project contributes; the rest is view work.

### Token changes

- `textSecondary` white 0.55 → 0.62 (5.97:1 → 7.48:1), still clearly secondary
  against `textPrimary` at ~16:1.
- `border` white opacity 0.08 → 0.14 (firmer hairline; decorative, not a 3:1
  target).
- A named map-scrim opacity, 0.85, replacing the ad-hoc 0.55/0.6 on the
  cockpit-over-map surfaces.
- Increase-Contrast variants: `textSecondary` → white 0.80 (12.46:1), `border`
  → 0.24, the map scrim → solid.

### The Increase-Contrast path

`AuraTheme` gains small resolver functions that take a `ColorSchemeContrast` and
return the standard or strengthened value:

- `AuraTheme.secondaryText(_ contrast:)` → 0.62 standard, 0.80 increased.
- `AuraTheme.hairline(_ contrast:)` → 0.14 standard, 0.24 increased.
- `AuraTheme.mapScrim(reduceTransparency:contrast:)` → a solid surface when
  either Reduce Transparency or Increase Contrast is on, otherwise
  `surface.opacity(0.85)`.

The resolvers are deliberately named apart from the `textSecondary` / `border`
constants (rather than overloading the same name) so a call site can't silently
fall back to the non-responsive default by forgetting the argument. The plain
`AuraTheme.textSecondary` / `AuraTheme.border` constants stay for the many call
sites that already pass and do not need the responsive path. Only the high-value
spots read `@Environment(\.colorSchemeContrast)` and call the resolvers, so the
path stays scoped.

### Per-view fixes

- `LastRideCard` drops the redundant `.opacity(0.85)` on the date (4.26:1 →
  7.12:1 once the base is bumped).
- `RoutePreviewView` selected route metrics and the sparkline use full
  `onAccent` instead of the 0.7/0.75 opacity stack (5.61:1 → 13.72:1).
- The cockpit-over-map surfaces that have no Reduce Transparency branch today
  (the free-ride `SpeedRail` stat backing, `GPSSignalChip`, and the
  `NavigateHUDView` "Rerouting" cue) move onto `AuraTheme.mapScrim(…)`, which
  raises the scrim to 0.85 and goes solid under Reduce Transparency or Increase
  Contrast. `TripStripView` and `HUDControlButton` already branch Reduce
  Transparency; they adopt the Increase-Contrast arm of the same helper.
- The summary's own accolade (12.24:1) is kept; it is restyled only as part of
  the redesign, not for contrast.

## Architecture and placement

- **`AuraCore`:** `AuraPalette` (raw values) and `WCAGContrast` (pure math),
  both `Sendable`, no SwiftUI, building on the macOS CI host. iOS-only code is
  not involved here, so no `#if os(iOS)` guards are needed for these files.
- **App target / shared with `AuraWidgets`:** `AuraTheme` reads `AuraPalette`
  and gains the contrast resolvers. `RideSummaryView` is rebuilt. The per-view
  fixes touch `LastRideCard`, `RoutePreviewView`, `SpeedRail`, `GPSSignalChip`,
  `NavigateHUDView`, `TripStripView`, and `HUDControlButton`. No files are added
  to or removed from the app target, so no `xcodegen` regeneration is required;
  the new `AuraCore` files are auto-globbed by the package.
- **No new dependencies, no new palette, no light mode, no map-style change.**

## Accessibility, Dynamic Type, and Reduce Motion

- The summary stays chrome: SF Pro Rounded driven by `@ScaledMetric`, no
  double-scaling, the cockpit Saira `relativeTo:` rule untouched.
- The hero and the supporting row reflow at accessibility text sizes; the build
  verifies no clipping at the largest sizes.
- VoiceOver: each `StatPair` already reads as one element; the hero distance
  reads as one element ("Distance, 12.4 miles"). The accolade and warning keep
  their labels.
- Reduce Motion: the entrance and count-up collapse to an instant appearance.
- Increase Contrast: the resolvers strengthen the scoped foregrounds; verified
  in the simulator with Increase Contrast on and off.

## Testing

- `WCAGContrast` unit tests in `AuraCore` cover the math (known ratios, the
  symmetry of the ratio, compositing) and assert the design's lifted *token-derived*
  pairs clear their targets, reading the same `AuraPalette` numbers the app ships:
  `textSecondary` and `textPrimary` on `background`/`surface`, `onAccent` on
  `accent`, and lime on `background`. The over-map scrim composite depends on an
  arbitrary (worst-case bright) map pixel rather than a fixed token, so it is
  verified in the simulator, not asserted as a unit test.
- The CI gates carry the view work: the package tests, the `xcodebuild` build of
  the app and the embedded `AuraWidgets`, and SwiftLint `--strict`. The
  whole-repo lint runs at every task gate, not only at the end.
- Visual verification on the iPhone 17 / iOS 26 simulator: real pixel
  screenshots of the redesigned summary and the contrast-lifted screens (reboot
  the simulator if a screenshot's md5 matches the prior frame), a measured
  contrast-ratio audit, and Increase Contrast, Reduce Motion, and accessibility
  Dynamic Type passes. A final holistic review runs on the most capable model.

## Risks and mitigations

- **The count-up must land on the exact formatted value.** It animates a value
  and formats per frame, but snaps to the real formatted string on completion,
  and Reduce Motion shows the final value with no animation. Verified visually.
- **The scrim bump must not over-darken the cockpit on a dark map.** 0.85 is
  checked over both a bright and a dark map area in the simulator.
- **The palette move could break the widget build.** `AuraWidgets` already links
  `AuraCore` and compiles `AuraTheme.swift`; the CI app build (which builds the
  embedded widget) catches any miss. The move is value-preserving except for the
  intended token bumps.
- **Wide but shallow edits.** The per-view contrast fixes touch several files;
  each is a small, value-preserving change kept reviewable by sequencing and
  guarded by the lint and build gates.

## Out of scope

- An elevation profile on the summary (deferred).
- Any new palette, gradient, light mode, or Mapbox map-style change.
- A polyline-draw animation on the hero map (motion is on the chrome).
- App-target test infrastructure; the app target still has no test target, and
  the pure contrast logic that can be tested lives in `AuraCore`.

## Rough task order

1. `AuraCore`: `WCAGContrast` helper and tests (TDD).
2. `AuraCore`: `AuraPalette` raw values, with the contrast tests asserting the
   lifted pairs.
3. `AuraTheme`: build roles from `AuraPalette`, apply the token bumps, add the
   contrast resolvers.
4. Per-view contrast fixes (LastRideCard, RoutePreview, SpeedRail,
   GPSSignalChip, NavigateHUD, TripStrip, HUDControlButton).
5. Rebuild `RideSummaryView` into the map-led layout with the supporting row.
6. Add the entrance animation and the hero count-up, Reduce-Motion-safe.
7. Simulator verification: screenshots, the measured contrast audit, Increase
   Contrast, Reduce Motion, and Dynamic Type.
8. Mark the sub-project shipped and Wave 2 complete in the ROADMAP.
