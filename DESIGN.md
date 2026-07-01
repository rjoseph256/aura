# Design

The visual system is implemented in code and is the source of truth:
`Aura/Sources/Theme/AuraTheme.swift` (roles, scales, typography) built from the
pure `AuraPalette` in AuraCore, with WCAG contrast asserted by unit tests in CI.
This file is the summary for design tooling; when they disagree, the code wins.

## Theme

Dark only. Near-black background, panel surfaces, hairline borders. One electric
lime accent; pink is destructive (end ride) only; amber is warning only. No
gradients anywhere.

## Color roles (AuraTheme)

- background (near-black), surface (panel)
- textPrimary (white 0.92), textSecondary (white 0.62, 7.5:1 on background)
- accent (lime #C8FA4B) with inkOnAccent; destructive (pink #FF4D9D);
  warning (amber); border (hairline white opacity); routeLine (flows from accent)

## Typography

- Chrome and labels: SF Pro Rounded via `Typography.metricBrand()`; semantic text
  styles for Dynamic Type.
- Cockpit numerals: Saira Condensed (bundled, PostScript faces
  SairaCondensed-Medium/SemiBold/Bold) via `Typography.metricCockpit()` and
  `speedHero()`.
- Fixed scale, no fluid sizing; @ScaledMetric where numerals must bound.

## Spacing and radius scales

Spacing: xs 4, sm 8, md 12, lg 16, xl 20, xxl 24, xxxl 32.
Radius: xs 4, sm 8, md 12, lg 16, xl 20.

## Components

- `CTAButtonStyle`: primary (lime fill), secondary (lime stroke), tertiary
  (text-only), destructive (pink fill). 50pt height on filled variants.
- `HUDControlButton`: circular 44pt map-floating control, ultraThinMaterial with
  a solid fallback under Reduce Transparency; normal and destructive roles.
- `SpeedReadout`, `StatPair` (value-over-label, brand or cockpit context).
- List rows on `surface` inside `Radius.lg` rounded groups with hairline dividers
  (see Recents on the plan screen).
- Map-floating text sits on one shared scrim helper, never bare material.

## Motion

State-conveying only, 150-250 ms, ease-out. Hero count-up on ride summary is the
one sanctioned delight moment. Reduce Motion always has a branch.
