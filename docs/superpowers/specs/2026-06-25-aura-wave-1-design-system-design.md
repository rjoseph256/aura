# Aura Wave 1 — Design system design

**Goal:** Replace the ad-hoc color sheet (`AuraTheme`, 8 colors + 2 font helpers) with a real design system: semantic color roles, spacing and radius scales, a type ramp, and a small set of extracted components. At the same time, adopt a new visual identity decided through brainstorming and mockups: a single high-vis lime accent on near-black, with two typographic personalities (an instrument cockpit and a calmer chrome).

**Status:** approved design, ready to plan.

## Context

Wave 1 is the structural-foundations wave, broken into five sub-projects. The first, quality gates, shipped. This is the second. It started as a pure tokenization refactor, then the user chose to fold in a visual-direction decision so the tokens encode the identity they actually want rather than formalizing the old one. The direction was chosen against license-checked free assets and a set of mockups, and a critique pass (contrast check plus the impeccable slop detector) ran against those mockups.

Current state, confirmed in code:

- `AuraTheme` (`Aura/Sources/Theme/AuraTheme.swift`, app target, shared into the `AuraWidgets` extension by target membership) holds 8 flat colors (`bg, surface, cyan, violet, pink, route, text, muted`), an `auroraGradient`, and two font helpers (`heroNumber`, `unitLabel`).
- The route polyline color (#2BE08A) is hardcoded as a `UIColor(red: 43/255 …)` `StyleColor` in four Mapbox files (`RoutePreviewView`, `StaticRouteMap`, `RideMapView`, `NavigateHUDView`). `AuraTheme.route` is the same color but is not bridged to Mapbox.
- Corner radii span eight values (4/6/11/12/14/16/18/20); padding and stack spacing are ad-hoc literals.
- Repeated patterns: the CTA button (four divergent copies), the value+label stat pair, the floating HUD control button (three identical `.ultraThinMaterial` 44pt circles with no Reduce Transparency fallback).
- `AuraCore` and `AuraKit` import no SwiftUI, so tokens cannot move into the package; they stay in the app target.
- The whole app and widget build under Swift 6 with the CI `xcodebuild` and SwiftLint gates from the quality-gates sub-project. Those gates are what make a wide view-layer refactor safe.

## Decisions

Settled with the user during brainstorming:

1. **Rationalize to clean scales** rather than aliasing the current spread. Ad-hoc spacing and radius values snap to the nearest scale step (minor pixel shifts are accepted).
2. **Full semantic color roles**, migrating call sites off the raw hue names. Raw values become a private palette.
3. **Hybrid identity by typography and density, not color.** A "cockpit" personality on the live ride screens (condensed numerals, dense instrument layout) and a "chrome" personality on the lean-back screens (rounded numerals, roomier layout).
4. **Mono lime accent.** A single accent, electric lime #C8FA4B, carries brand, route, and active state across the whole app. No gradients anywhere; the old cyan/violet/pink aurora is retired.
5. **Pink stays as the one non-lime semantic color**, used only for the destructive end-ride action so "stop" never reads as "go."
6. **Bundle Saira Condensed (SIL OFL)** for cockpit numerals; use SF Pro Rounded (system) for chrome numerals; use system text styles for labels and headings.
7. **Refined button and weight system** (from the critique pass): a button hierarchy instead of all-filled pills, moderate radii instead of full capsules, and a weight ramp that reserves the heaviest weight for the single hero metric.
8. **Reduce Transparency fallback** is the one accessibility deliverable here. The broader contrast lift and composed VoiceOver labels stay in Wave 2.

## Token architecture

Everything stays in the `AuraTheme` namespace in the app target, shared into `AuraWidgets` by target membership (as today). The raw hex values become a `private` palette; the public surface is roles, scales, and type roles. There is one fixed dark theme and no light mode, so a static namespace is the right tool. No environment-injected theme (that would be unused machinery).

Suggested file shape (the plan finalizes exact splits): `AuraTheme` colors/roles, `AuraTheme.Spacing`, `AuraTheme.Radius`, `AuraTheme.Typography`, and the components in their own files under `Aura/Sources/Theme/` or `Aura/Sources/Components/`. Any new file the widget needs (the theme, the bundled font helper, any component the Live Activity uses) must be added to the `AuraWidgets` target membership.

## Color roles

Public roles (the only color surface views should use):

| Role | Value | Used for |
|---|---|---|
| `background` | #07080C (near-black) | screen backgrounds |
| `surface` | #0E1014 | panels, cards, material base |
| `textPrimary` | `Color(white: 0.92)` | primary text and numerals |
| `textSecondary` | `Color(white: 0.55)` | labels, secondary text |
| `accent` | **lime #C8FA4B** | filled CTAs, active/selection, goal ring, speed unit |
| `routeLine` | **lime #C8FA4B** + `routeStyleColor` (Mapbox `StyleColor`/`UIColor` bridge) | the route, on every map |
| `destructive` | pink #FF4D9D | end-ride only |
| `onAccent` | ink #16210A | text/icons on a lime fill |
| `onDestructive` | ink #2A0314 | text/icons on a pink fill |

The single accent reads in distinct roles because the treatment differs, not the hue: a filled pill is an action, a line is the route, an outline or tint is selection. Retired: `cyan`, `violet`, the old `route` green, and `auroraGradient`. There is no gradient role.

Contrast was verified with a WCAG check; every pair passes AA: lime on background 16.4:1, lime on surface 15.6:1, `onAccent` ink on lime 11.9:1, `textPrimary` 16.6:1, `textSecondary` 5.95:1, pink on background 6.48:1, `onDestructive` ink on pink 6.06:1. The migration preserves these values, so contrast does not regress.

## Typography

- **Cockpit metrics → Saira Condensed (bundled, SIL OFL).** The live speed and HUD/Navigate stats. Sized with `@ScaledMetric` so Dynamic Type still scales them. The OFL license permits app embedding; commit the license file alongside the font.
- **Chrome metrics → SF Pro Rounded (system).** Summary, dashboard, and History numbers via `.system(…, design: .rounded)`. No bundling.
- **Labels and headings → system text styles** (San Francisco), so Dynamic Type and accessibility sizes are free.

Type roles (the recurring patterns, not an exhaustive set): `speedHero` (Saira Condensed, the single heaviest weight, scaled), `metricCockpit` (Saira Condensed, live stats), `metricBrand` (SF Pro Rounded, weight 700), `unit` (small bold, lime), `title` (weight 600–700), `cardTitle`, `label`, `caption`, `cta` (weight 600).

Weight ramp rule (from the critique): the heaviest weight is reserved for `speedHero`; numbers use 700; titles 600; labels regular or medium. No blanket 800 across the app.

## Scales

- **Spacing** (4-pt): `xs 4 / sm 8 / md 12 / lg 16 / xl 20 / xxl 24 / xxxl 32`. Ad-hoc values (6, 7, 14, 18, 28) snap to the nearest step, with generous separation between groups.
- **Radius**: `xs 4 / sm 8 / md 12 / lg 16 / xl 20`. The current eight radii collapse onto these. Buttons use `lg` (16); a full capsule is reserved for chips (the GPS chip), not buttons.

## Components

1. **`CTAButtonStyle`** (a SwiftUI `ButtonStyle`) with variants:
   - `.primary` — filled `accent` (lime), `onAccent` ink, radius `lg`, ~50pt height, weight 600.
   - `.secondary` — transparent fill, 1.5pt outline, `accent` (or neutral) text. Same height/radius.
   - `.tertiary` — text only, `accent`, no fill. Lower height, for low-emphasis actions.
   - `.destructive` — filled `destructive` (pink), `onDestructive` ink.
   - Disabled state dims. Press feedback honors Reduce Motion.
   Replaces the four divergent CTA copies (PlanView, LocationPermissionView, RoutePreviewView, RideHUDView) and gives secondary/tertiary actions a non-heavy treatment.
2. **`HUDControlButton`** (a `ButtonStyle`) for the floating cockpit controls (recenter, mute, back): a 44pt circle, `.ultraThinMaterial` background with `@Environment(\.accessibilityReduceTransparency)` swapping to a solid `surface` fill when reduced, `accent` (lime) when active. Call sites keep their `.accessibilityLabel`. This is where the Reduce Transparency fallback lands.
3. **`SpeedReadout`** (a `View`): the big cockpit speed — `speedHero` numeral plus a lime `unit`, scaled with `@ScaledMetric`.
4. **`StatPair`** (a `View`): a value-over-label metric with a `context`. `.cockpit` uses Saira Condensed (and the hairline instrument row treatment); `.brand` uses SF Pro Rounded. Replaces RideSummaryView's inline `stat()` helper and the HUD stat rows. The string-style stat lines that are formatted sentences (for example a route-preview "12.4 km · 45 min") stay as strings; `StatPair` is for the value+label stack pattern.

## Screen application

- **Cockpit treatment** (Saira Condensed, lime, dense instrument layout, dimmed map, `HUDControlButton`, `SpeedReadout`): `RideHUDView`, `NavigateHUDView`, and the ride Live Activity in `AuraWidgets`.
- **Chrome treatment** (SF Pro Rounded, roomier layout, `CTAButtonStyle`, `StatPair .brand`, the goal ring): `PlanView`, `RoutePreviewView`, `RideSummaryView`, `HistoryView`, the dashboard, `SettingsView`, `OfflineMapsView`, `LocationPermissionView`, `DestinationSearchView`.
- The route color becomes lime via `routeStyleColor` in all four Mapbox files.

## Assets

- **Saira Condensed** bundled: font file(s) under `Aura/Resources/Fonts/`, added to the resource copy phase of both the app and the `AuraWidgets` extension. Because both targets set `GENERATE_INFOPLIST_FILE: NO` and use explicit Info.plist files, the `UIAppFonts` key goes in each target's plist (`Resources/Info.plist` and `Widgets/Info.plist`), not an auto-generated one. Commit the OFL license file. Dynamic Type via `@ScaledMetric`.
- **SF Symbols** stays the icon base. No icon bundle.
- **Custom Mapbox Studio map style** is deferred to a fast-follow (it is a Studio asset and style URL, not code tokens), so this sub-project stays shippable. For now the route recolors to lime on the existing dark Mapbox style.

## Out of scope

- The custom Mapbox map style (fast-follow).
- Composed VoiceOver labels for the SpeedRail and TurnCard, and the broader contrast lift across the app (Wave 2). The palette here already passes AA; this sub-project does not regress it.
- A light mode. There is one fixed dark theme.
- Animation and motion overhaul beyond honoring Reduce Motion on the button press.
- New app-target tests. The app target has no test target and this is view-layer work.

## Testing and verification

- The CI gates from the quality-gates sub-project carry this work: `xcodebuild build -scheme Aura` (app plus the embedded `AuraWidgets`, which catches a missing font-target membership) and `swiftlint --strict`.
- Visual verification on the simulator across both personalities: a cockpit screen (Ride or Navigate HUD) and the chrome screens (Plan, Summary, History), confirming the snap-to-scale shifts and the reskin read as intended. UI work is verified by running the actual screens, not by a clean build alone.
- An impeccable `audit`/`polish` pass against the rendered screens during the build.
- Contrast is already verified AA (above); re-check any new color-on-color pair an implementer introduces.
- No automated unit tests are added; this is view-layer and asset work.

## Risks and mitigations

- **The font must be in both targets.** If Saira Condensed is registered only for the app, the widget build breaks. Mitigated: register in both targets and rely on the CI app-build (which compiles the embedded widget) to catch it.
- **Wide but mechanical migration.** ~120 color sites to roles, fonts to type roles, literals to scale tokens, four route literals to the bridge, four components adopted. Value-preserving except the intended reskin; kept reviewable by sequencing.
- **This is a real visual change, by intent.** Verified on the simulator across both personalities rather than assumed from the build.
- **Single-accent role legibility.** Lime carries action, route, and selection; if the treatments are not kept distinct (filled vs line vs outline) the roles blur. Verified visually.
- **Lime brightness at night.** Lime is used as an accent and for thin route lines, not large fills, so glare is limited; confirm on a real device during the ride.

## Rollout order

The plan sequences the work so each change set is small and independently verifiable:

1. Token foundation: the private palette, public color roles, spacing and radius scales, and type roles, added to `AuraTheme` (and shared into the widget). No call-site changes yet.
2. Bundle Saira Condensed: font files, `UIAppFonts` in both targets, OFL license, and a `Font` helper; verify it loads.
3. Components: `CTAButtonStyle`, `HUDControlButton`, `SpeedReadout`, `StatPair`.
4. Route color bridge: replace the four Mapbox literals with `routeStyleColor` (lime).
5. Migrate the chrome screens to roles, type roles, scales, and the components.
6. Migrate the cockpit screens (Ride and Navigate HUD) to the cockpit roles, type, components, and the Reduce Transparency fallback.
7. The Live Activity in `AuraWidgets` adopts the theme.
8. Verify: build, lint, simulator visual pass across both personalities, and the impeccable audit.
