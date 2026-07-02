# Shareable ride-summary card — design

Date: 2026-07-01
Status: Approved (brainstorming + adversarial spec review applied).
Closes: the last unbuilt v1 promise (v1 design spec §4, "Shareable summary card").

## Summary

A rider finishes a ride, lands on the ride-summary screen, taps **Share**, and the
system share sheet appears with a 1080×1350 (4:5 portrait) PNG of the ride — rendered as
an **instrument-cluster artifact**, not a fitness stat block. The route is the dominant
edge-to-edge field; the hero distance and a date · destination context line sit over it
HUD-style; below it a lean readout carries moving time and an elevation sparkline
(captioned with the climb) when the ride has elevation; an `AURA` wordmark signs off at the
bottom. Mono-lime on near-black, no gradients, Saira Condensed numerals throughout.

Scope is the end-of-ride summary only. The card is a static image; no motion, no
interactivity on the artifact.

## Goals

- Share an on-brand image of a finished ride via the native share sheet (Messages,
  AirDrop, Instagram, Save to Photos, etc.).
- Read unmistakably as an Aura instrument artifact — route-forward, not a Strava-style
  metric grid (PRODUCT.md anti-reference: "Strava-style fitness-metric density and
  leaderboard energy").
- Reuse the existing pure-Canvas route + elevation renderers so the card renders
  correctly offscreen through `ImageRenderer`.
- Keep all display/branching logic in a pure, unit-tested layer (AuraKit); keep only the
  SwiftUI layout, image rendering, and share plumbing in the app target.

## Non-goals (YAGNI — explicitly out of scope)

- An elevation profile on the **live** ride-summary screen (still deferred per ROADMAP;
  the sparkline appears only on the shared card).
- Sharing from History or any past-ride detail (a possible trivial follow-up).
- **Top speed and average speed on the card** — dropped deliberately. Top speed is the
  most leaderboard-flavored metric and off-audience for the target casual rider; average
  speed isn't on today's summary either. The card leads with the route and where/when.
- Custom share copy / marketing text / a logo asset beyond the typographic wordmark.
- Multiple output formats or aspect ratios.

## The card artifact

Fixed 4:5 portrait, rendered from a SwiftUI view pinned to an explicit
`.frame(width: 360, height: 450)` at `ImageRenderer.scale = 3`, producing exactly
1080×1350 px. Near-black `background`; one lime accent spent only on the route line and
the elevation trace; **Saira Condensed for every numeral** (hero and readouts) — this is a
cockpit instrument artifact, so it speaks the cockpit numeral voice; SF Pro Rounded only for
short labels and the wordmark. Everything from `AuraTheme` tokens. No gradients.

### Composition — instrument field

1. **Route field (dominant, ~top 56%, edge-to-edge).** The route polyline drawn by the
   pure-Canvas `RouteThumbnail` (lime line) directly on the near-black field — full-bleed,
   not a bordered panel floating in a stack. This is the visual anchor.
2. **HUD overlay (lower-left of the field).** A date · destination context line
   ("JUL 1 · TO MILLVALE") above the **hero distance** (large Saira numeral + short unit).
   Legibility over the route is guaranteed by a solid scrim behind just this text block —
   the sanctioned "map-floating text sits on one shared scrim helper" pattern from
   DESIGN.md (a solid `surface` at the existing scrim opacity, **not** a gradient).
   Destination is promoted here as the postable hook, not stranded at the bottom.
3. **Readout band (below the field).**
   - **Elevation sparkline** (full width, short fixed height) via `ElevationSparkline`,
     captioned with the climb ("↑ 240 ft"). Shown only when the ride has ≥ 2 elevation
     samples. The climb is represented **once**, here — it is not also a separate stat.
   - **Moving time** as a quiet Saira readout (`StatPair`, `.cockpit` context).
   - When the ride has **no elevation**, the sparkline is omitted and the climb falls back
     to a plain `StatPair` readout next to moving time.
4. **Wordmark sign-off (bottom).** `AURA` in Saira SemiBold, letter-spaced, `textPrimary`
   white (~0.92) — a confident maker's mark, bottom-anchored so it survives feed cropping,
   unpaired from the date. Not lime (accent is reserved), not secondary gray (would vanish
   at thumbnail scale).

### No-route variant (deliberate, not a collapse)

When there is no route geometry (`track.count ≤ 1`, e.g. a HealthKit import without GPS),
the card is **not** a broken empty field. It renders a deliberate centered composition: the
context line, a large centered Saira hero distance as the intentional focal element, the
moving-time (and climbed) readout, and the bottom wordmark — composed with intentional
negative space so it reads as a clean instrument readout card. This variant is verified
separately.

### Why this is not the banned hero-metric template

The route is the dominant edge-to-edge field the readout sits on, not a thumbnail glued
above a stat grid. Metrics are lean (distance + moving time + climb) and quiet, led by the
route and where/when rather than a competitive stat row; top speed is dropped. The hero
distance is an instrument-styled Saira readout overlaid HUD-style, not a gradient stat.
No gradients anywhere. The design review pressure-tested the earlier stacked layout and
this composition is the response to it.

## Architecture

Three layers respected. Card image rendering is app-target (ImageRenderer needs
SwiftUI/UIKit); all testable assembly/branching logic is pure (AuraKit).

### AuraKit — `ShareCardContent` (pure, `Sendable`, unit-tested)

New file `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift`. (Note: `DistanceUnits`
and `RideStatsFormatter` both live in the **AuraKit** module, so `ShareCardContent` sits
alongside them.)

A value type built from a finished `Ride` plus the rider's `DistanceUnits`, holding
everything the card view needs as already-resolved primitives:

- `distanceValue: String`, `distanceUnit: String`
- `movingTime: String` (e.g. "42 min")
- `climbedValue: String`, `climbedUnit: String`
- `dateText: String`
- `destinationName: String?` (nil for free rides / empty names)
- `routeCoordinates: [Coordinate]` (empty when track ≤ 1 point ⇒ no-route variant)
- `elevationSamples: [Double]` (empty ⇒ no sparkline, climb shown as a plain stat)

Built via `init(ride:units:locale:timeZone:)` where `locale`/`timeZone` default to
`.current` and are injectable so tests are deterministic. Strings come from
`RideStatsFormatter` (`distanceValue`/`distanceUnit`, `elevationValue`/`elevationUnit`,
`minutes(_)`). `dateText` is produced with `Date.FormatStyle` (month abbreviated, day, year)
under the injected locale/timeZone. `elevationSamples = ride.track.compactMap(\.elevation)`
when that yields ≥ 2 values, else `[]`. `routeCoordinates = ride.track.map(\.coordinate)`
when `track.count > 1`, else `[]`. Uses `ride.stats ?? .zero` so a stats-less ride still
produces valid (zeroed) strings, though the app gates the Share button on `ride.stats != nil`.

There are **no top-speed fields** (top speed is out of scope). All metric/imperial,
has-elevation, has-destination, and has-route branching lives here and is covered by
`AuraKitTests`.

### Aura (app target) — `ShareCardView`

New file `Aura/Sources/Ride/ShareCard/ShareCardView.swift`.

`struct ShareCardView: View { let content: ShareCardContent }`. The instrument-field layout
above, using `AuraTheme` tokens, `RouteThumbnail(coordinates:)` for the route field, and
`ElevationSparkline(elevations:stroke:fill:)` for the elevation trace. Conditionals mirror
the content's empty arrays: `routeCoordinates` empty ⇒ no-route centered variant;
`elevationSamples` empty ⇒ no sparkline, climb rendered as a plain readout.

**Fixed-pixel determinism (from the platform review):**
- Root pinned to explicit `.frame(width: 360, height: 450)` — `proposedSize` alone is not
  enough for a Canvas-bearing view.
- The renderer pins `.environment(\.dynamicTypeSize, .large)` on the card so the reused
  `StatPair` (`@ScaledMetric`) and Saira `relativeTo:` faces render at a single, invariant
  size regardless of the rider's Dynamic Type setting.
- Card numerals use `StatPair(context: .cockpit)` (Saira, label-only SF Rounded), keeping
  the whole card in one numeral voice.
- Static — no animation, no count-up.

### Aura (app target) — `RideCardRenderer`

New file `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift`.

`@MainActor` renderer that builds the shareable payload:

- Renders `ShareCardView(content:)` (wrapped with the fixed frame + pinned dynamicTypeSize)
  through `ImageRenderer` with `scale = 3` → `UIImage`.
- Writes the `UIImage.pngData()` to a stable temp file URL (e.g.
  `FileManager.default.temporaryDirectory.appending(path: "Aura ride.png")`, overwritten
  each render — gives the share sheet a real `.png` file with a clean name, which is the
  robust payload for Photos/Instagram/Messages; sharing a bare SwiftUI `Image` is
  unreliable and is **not** used).
- Returns a small value `RideShareImage { let fileURL: URL; let preview: Image }` (the
  `preview` is `Image(uiImage:)` for the share-sheet thumbnail). Returns `nil` on render or
  write failure.

Because the card uses only Canvas-based route and sparkline renderers (never the Mapbox
`StaticRouteMap`), it renders correctly offscreen. Saira resolves offscreen because it is
registered via `UIAppFonts` (`Aura/Resources/Info.plist`) and addressed by PostScript name.

### Aura (app target) — wiring in `RideSummaryView`

Modify `Aura/Sources/Ride/RideSummaryView.swift`:

- Add `@State private var shareImage: RideShareImage?`.
- In a `.task` (MainActor; `RideCardRenderer` is `@MainActor`, no actor hop), when
  `ride.stats != nil`, build `ShareCardContent(ride:units: settings.units)`, call
  `RideCardRenderer.make(...)`, and store the result.
- Insert a **Share** control directly above the existing Done button:
  - While `shareImage == nil` (rendering, or no stats): a **disabled `Button("Share")`**
    styled `.ctaSecondary`. (A `ShareLink` can't be constructed without its item, so the
    disabled-Button-then-swap pattern is required — there is no "disabled ShareLink".)
  - Once ready: swap to
    `ShareLink(item: shareImage.fileURL, preview: SharePreview("Aura ride", image: shareImage.preview))`
    styled `.ctaSecondary`, labeled "Share".
- Done remains the primary `.ctaPrimary`.

The Share button honors Reduce Motion / Increase Contrast like every other CTA (same button
system). The rendered PNG is a fixed artifact and is unaffected by those settings — which is
exactly why the card always uses the **high-contrast** secondary text value (below).

## Data flow

`Ride` (full track, stats) → `ShareCardContent(ride:units:)` [AuraKit, pure] →
`ShareCardView(content:)` [app] → `ImageRenderer` in `RideCardRenderer` [app] → `UIImage` →
temp PNG file URL + preview `Image` → `ShareLink` → system share sheet.

## Contrast (card-specific, from the design review)

CI asserts WCAG contrast for text on `background`, but the card places text on the near-black
field and over a `surface` scrim, and the fixed PNG can never receive the user's
Increase-Contrast setting. Therefore:

- The card **always** uses the high-contrast secondary text value
  (`AuraPalette.textSecondaryWhiteHighContrast`, 0.80) for its labels/context line — never
  the standard 0.62 — since it can't offer a runtime toggle.
- Add a WCAG unit test asserting the card's secondary-text value clears 4.5:1 against
  **`surface`** (the scrim), not only against `background` — the pairing CI doesn't currently
  cover.
- Labels are sized to survive feed-thumbnail scale (no `caption2`-tier text that turns to
  mush when the card is a ~120–150 pt thumbnail); labels are enlarged relative to the values
  or dropped.

## Edge cases

- **No elevation** (all `TrackPoint.elevation` nil, or < 2 present) → `elevationSamples`
  empty → sparkline omitted, climb shown as a plain readout.
- **No route geometry** (`track.count ≤ 1`) → `routeCoordinates` empty → the deliberate
  centered no-route variant renders (not an empty field).
- **No destination** (free ride or empty name) → context line shows the date only.
- **No stats** (`ride.stats == nil`) → Share button not offered (stays disabled/omitted).
- **Render or PNG-write failure** → `RideCardRenderer.make` returns nil → Share button stays
  disabled; no crash, no share.

## Testing

- **AuraKitTests — `ShareCardContentTests` (Swift Testing):**
  - metric vs imperial → distance/climbed value+unit strings.
  - elevation present (≥ 2 samples) → non-empty `elevationSamples`; absent / single sample →
    empty.
  - route present (track > 1) vs single-point → `routeCoordinates` populated vs empty.
  - destination present vs nil/empty → `destinationName` passthrough vs nil.
  - stats nil → zeroed strings, no crash.
  - `dateText` deterministic under an injected fixed locale + timeZone.
  - no top-speed field exists (compile-level; the type simply has none).
- **AuraCoreTests (or AuraKitTests) — WCAG:** card secondary-text value ≥ 4.5:1 on `surface`.
- **App build:** `xcodegen generate` + `xcodebuild` on iPhone 17 sim (also builds AuraWidgets).
- **UI / manual verify:** AXe / Simulator — Share button appears, is labeled, reachable, and
  the share sheet presents. Eyeball the rendered PNG against the mono-lime bar for: (a) a
  route+elevation ride, (b) a route-without-elevation ride, (c) the **no-route** variant.

## Gates (per task, before "done")

- `cd AuraCore && swift test` green.
- `swiftlint lint --strict` clean (line ≤ 140 warn / 200 err; `void_function_in_ternary` is
  an error).
- App builds via `xcodegen generate` + `xcodebuild` on iPhone 17 sim.

## Files

New:
- `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift`
- `AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift`
- `Aura/Sources/Ride/ShareCard/ShareCardView.swift`
- `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift`

Modified:
- `Aura/Sources/Ride/RideSummaryView.swift` (Share button + pre-render)
- WCAG test file (add the `surface` secondary-text assertion)
- `docs/ROADMAP.md` (retire the unbuilt-v1-promise line when this ships)

## Reuse (no new low-level renderers)

- `RouteThumbnail` (`Aura/Sources/Shared/RouteThumbnail.swift`) — Canvas polyline.
- `ElevationSparkline` (`Aura/Sources/Plan/ElevationSparkline.swift`) — Canvas area sparkline.
- `RideStatsFormatter` (`AuraCore/Sources/AuraKit/Formatting/`) — unit-aware strings.
- `StatPair` (`.cockpit` context), `CTAButtonStyle`, `AuraTheme`, the map-scrim pattern —
  existing components/tokens.
