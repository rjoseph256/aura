# Design

The visual system is implemented in code and is the source of truth:
`Aura/Sources/Theme/AuraTheme.swift` (roles, scales, typography) built from the
pure `AuraPalette` in AuraCore, with WCAG contrast asserted by unit tests in CI.
This file is the summary for design tooling; when they disagree, the code wins.

## Theme

Dark only. Near-black background, panel surfaces, hairline borders. One mint
accent; pink is destructive (end ride) only; amber is warning only. No
gradients anywhere.

## Color roles (AuraTheme)

- background (near-black), surface (panel)
- textPrimary (white 0.92), textSecondary (white 0.62, 7.5:1 on background)
- accent (mint #7CF0A8) with inkOnAccent; destructive (pink #FF4D9D);
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

- `CTAButtonStyle`: primary (mint fill), secondary (mint stroke), tertiary
  (text-only), destructive (pink fill). 50pt height on filled variants.
- `HUDControlButton`: circular 44pt map-floating control, ultraThinMaterial with
  a solid fallback under Reduce Transparency; normal and destructive roles.
- `StatPair` (value-over-label, brand or cockpit context).
- List rows on `surface` inside `Radius.lg` rounded groups with hairline dividers
  (see Recents on the plan screen).

## Map-floating surfaces: the two-tier grammar

**Frosted material is for CONTROLS. Map-floating TEXT CHIPS use `.mapChip`.**

- **Controls — frosted.** `HUDControlButton` and `MapZoomControl` are the only
  sanctioned `.ultraThinMaterial` *control* surfaces in the app outside the widget
  targets (the lobby/roster cards below are the sanctioned non-control exception).
  Both resolve through `AuraTheme.prefersOpaqueSurface(reduceTransparency:_:)` and
  fall back to solid `surface` under Increase Contrast or Reduce Transparency.
- **Text chips — flat scrim.** `.mapChip(_ shape:stroke:)`
  (`Aura/Sources/Theme/MapChip.swift`) fills the caller's shape with
  `AuraTheme.mapScrim(reduceTransparency:_:)` and strokes
  `AuraTheme.hairline(contrast)`, with a `.none` stroke case for surfaces that must
  not gain an outline (peer name tags). The modifier reads both environment values
  itself, so a call site cannot skip the accessibility branch. Live at eleven sites:
  `DetourOverlay` (4), `NavigateHUDView`'s Rerouting cue,
  `NavigateHUDView+GroupCrew` (3), `HomeMapCanvas`, `ThenChip`, and
  `GroupRideMapOverlay` (`stroke: .none`).
- `GPSSignalChip`, `PauseControl` and `GroupToastHost` reach the same `mapScrim`
  fill through their own shapes rather than through the modifier. Same grammar,
  different plumbing — they were already correct and were left alone.

**Documented exceptions.**

- `TurnCardView` keeps its own background logic: `surface.opacity(0.92)` collapsed
  and a solid mint fill when expanded. The most-read surface at speed does not get
  more transparent to satisfy a convergence.
- `MarkSpotToast` is opaque `surface` by design; only its hairline was fixed to read
  the contrast environment.
- `HomeGlass` is Liquid Glass by design. Its non-glass fallback resolves the fill
  through `mapScrim` but keeps the accent stroke, which is identity.
- Group lobby and roster stacked cards (`GroupLobbyView`, `GroupRosterSheet`) keep
  `.ultraThinMaterial` behind a manual accessibility branch. Deliberate and settled —
  the one sanctioned frosted-card treatment outside `Theme/`.

**Enforcement and its two limits.** `.swiftlint.yml`'s `map_material_outside_theme`
custom rule bans the `ultraThinMaterial` identifier outside `Aura/Sources/Theme/`,
`Aura/Widgets/`, and the two lobby/roster files. Two stated limits:

1. It enforces *location*, not the contrast-branch invariant. A file under
   `Theme/` can still ship a material with no accessibility fallback.
2. The regex matches the `ultraThinMaterial` literal, so hoisting a frosted
   treatment into a Theme modifier would let any file adopt frosted surfaces with
   zero lint coverage. Moving material into `Theme/` *widens* the drift surface
   rather than narrowing it — which is the argument for keeping the material at its
   two control call sites rather than generalizing it.

## Map layer

### Puck — "white = me"

Two fixed states, rasterized in `Aura/Sources/Theme/PuckImageRenderer.swift` from
`PuckMetrics` (AuraCore, pure `Double` so the package builds on macOS CI) and theme
tokens. The rider's marker is white, never mint: on the Explore HUD mint is already
the recorded trace, the gem pins and the detour line, and in a crew "white = me,
hued disc = peer" is one grammar with `GroupRideMapOverlay` (self is `textPrimary`).

- **Browse puck** (Home live map): white core, ink outline, mint ring, mint heading
  wedge with an ink backing. The only ambient element is the SDK's real accuracy ring
  (`showsAccuracyRing`, mint at low opacity) — it means something, so it is not a
  decorative halo.
- **Riding puck** (both HUDs): white rounded triangle, ink outline, 2.5pt mint edge.
  No accuracy ring.

Three SDK facts the sites must keep. Only the second is machine-checked — its
geometry is pinned by `PuckMetricsTests`; the other two are conventions a reader has
to hold:

1. **Every image is supplied explicitly.** `Puck2D(bearing:)` initializes from
   `Puck2DConfiguration.makeDefault(showBearing:)`, which ships **three** stock
   images — `topImage`, `bearingImage` and `shadowImage`. A nil `topImage` falls
   back to Mapbox's blue dot drawn *over* the bearing image; the stock shadow disc
   renders as a white halo bulging from behind the Aura triangle. All three sites
   therefore set `topImage`, `bearingImage` and `shadowImage(nil)`.
2. **Paint order is shadow → bearing → top**, so the browse wedge draws *under* the
   core: its tip radius must exceed the core-plus-ring radius, on an oversized
   transparent canvas so rotation about the image center places it correctly.
3. **Images are `static let`.** The SDK diffs puck configurations by `UIImage`
   pointer identity, and the navigate HUD's content can re-evaluate at 30 Hz.

### Route line

Planned routes are **cased**: mint core, near-black `routeCasingUIColor` border,
round caps and joins (both layer-level, so they live on the group). Cased at four
sites — route preview, ride summary (`StaticRouteMap`), detour, and navigate.

> **READ BEFORE CHANGING A WIDTH.** Mapbox draws `lineBorderWidth` **inside**
> `lineWidth`, not outside it: the visible core is `lineWidth − 2 × lineBorderWidth`.
> This is undocumented in Mapbox's SDK and cannot be read out of the source (the
> rendering lives in the compiled `MapboxCoreMaps.xcframework`); it was established
> by measuring rendered frames, after a first pass shipped `5/2` and collapsed the
> mint run to a fifth of its width. Current widths, each preserving the mint core the
> site drew before casing: preview **8/1.5**, summary **8/1.5**, detour **9/1.5**,
> navigate **9/1.5** on both layers.

- **Origin ring — preview only.** A hollow mint ring on an ink seat, deliberately
  *not* in the puck vocabulary: the preview's origin can be the denied-permission
  fallback coordinate, and a puck-alike there would falsely assert "you are here".
- **Destination marker** — preview, navigate and detour (not the summary). Filled
  mint disc with an ink flag glyph, `.allowOverlapWithPuck(true)` because the default
  would hide it exactly on final approach.
- **Traveled dim — navigate only, paint-only.** One `GeoJSONSource` with
  `lineMetrics = true` under two `LineLayer`s: dim below (`AuraPalette.routeDimOpacity`),
  cased bright above, the bright one trimmed by `lineTrimOffset`. Identical stroke on
  both, so the trim boundary is a change in weight, not in shape. `lineMetrics` is
  required — without it `lineTrimOffset` fails with a shader error that erases the
  bright line, which is also why this is a style source and not a
  `PolylineAnnotationGroup`. A progress tick moves one paint property; the geometry
  is re-uploaded only on a reroute.
- **The dim is frozen across the whole reroute window.** `trimEnd` renders 0 (full
  bright line) while `guidance.isRerouting` or while `fractionTraveled` is nil.
  Both guards are load-bearing: a route *refresh* can change the route id with no
  preceding fetch, and a session can yield progress before `.rerouted` inside one
  sink call. `GuidanceEvent.reroutingAborted` covers Mapbox's `Interrupted` and
  `Failed` outcomes — without it an aborted reroute would strand `isRerouting` and
  hold the line full-bright for the rest of the ride.
- The recorded free-ride track (`TrackRibbon`) is untouched.

### Ornaments

Three map surfaces, three different scale-bar rules. This is not one rule with
exceptions — each surface's top-left is owned by something different, so each gets
the treatment that space allows.

- **Navigate HUD** — scale bar **always hidden**, no margin. The turn card owns the
  top-left in every state and its height varies (collapsed vs expanded, one vs two
  instruction lines), so no fixed margin can reliably clear it: panned off the puck,
  the card still covers most of the bar. This is the same argument that hides the
  compass here — another element already owns that space.
- **Explore HUD** (`RideMapView`) — hidden while following, `.adaptive` when panned
  off-follow, with the `MapOrnamentMetrics.belowTopControlMargin` top margin. This
  HUD's top-left really is free once the rider pans off, and the bar reads cleanly
  there below the back control.
- **Route preview** — margin only. The bar is never conditionally hidden, and the
  compass here is deliberately untouched.

`MapOrnamentMetrics.belowTopControlMargin` is safe-area-relative (SDK contract) and
composed from `HUDControlMetrics` — `topControlPadding + size + controlClearance` —
not a device-tuned literal, so it holds on an SE as well as on the tuning device.

Compass hidden on the two HUDs only; the recenter cluster owns orientation on a
course-up map. Mapbox logo and attribution are never touched and stay visible
everywhere. `ornamentOptions` returns `Map`, so it must precede
`.ignoresSafeArea()` — the same constraint the codebase documents for
`.onCameraChanged`.

## Motion

State-conveying only, 150-250 ms, ease-out. Hero count-up on ride summary is the
one sanctioned delight moment. Reduce Motion always has a branch.
