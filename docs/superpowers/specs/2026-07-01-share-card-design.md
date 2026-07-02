# Shareable ride-summary card — design

Date: 2026-07-01
Status: Approved (brainstorming); pending adversarial spec review.
Closes: the last unbuilt v1 promise (v1 design spec §4, "Shareable summary card").

## Summary

A rider finishes a ride, lands on the ride-summary screen, taps **Share**, and the
system share sheet appears with a 1080×1350 (4:5 portrait) PNG image of the ride —
route, hero distance, moving time / climbed / top speed, an elevation sparkline when
the ride has elevation, the ride date, the destination (navigate rides), and a small
`AURA` wordmark. On the mono-lime instrument aesthetic, near-black, no gradients.

Scope is the end-of-ride summary only. The card is a static image; there is no motion
and no interactivity on the artifact itself.

## Goals

- Share an on-brand image of a finished ride via the native share sheet (Messages,
  AirDrop, Instagram, Save to Photos, etc.).
- Reuse the existing pure-Canvas route + elevation renderers so the card renders
  correctly offscreen through `ImageRenderer`.
- Keep all display/branching logic in a pure, unit-tested layer (AuraKit); keep only
  the SwiftUI layout, image rendering, and share plumbing in the app target.

## Non-goals (YAGNI — explicitly out of scope)

- An elevation profile on the **live** ride-summary screen (still deferred per ROADMAP;
  the sparkline appears only on the shared card).
- Sharing from History or any past-ride detail (a possible trivial follow-up, not built
  or verified this cycle).
- Average speed on the card (not shown on today's summary; would add a 4th stat and
  crowd the 4:5 layout).
- Custom share copy / marketing text / a logo asset beyond the typographic wordmark.
- Multiple output formats or aspect ratios.

## The card artifact

Fixed 4:5 portrait. Rendered at a nominal 360×450 pt with `ImageRenderer.scale = 3`,
producing exactly 1080×1350 px. Near-black `background`; one lime accent; SF Pro Rounded
for chrome/labels; **Saira Condensed for the hero distance numeral** (instrument look,
deliberately distinct from the on-screen summary's SF-Rounded hero); everything from
`AuraTheme` tokens (spacing/radius scales, color roles). No gradients.

Composition, top to bottom:

1. **Header row** — `AURA` wordmark (leading), ride date (trailing). Wordmark in Saira;
   date in `secondaryText` via SF Pro Rounded. Quiet.
2. **Route panel (visual hero)** — the route polyline drawn by the pure-Canvas
   `RouteThumbnail` (lime line) on a `surface` panel, `Radius.xl`, hairline border.
   This is the dominant visual. Omitted with clean reflow when the track has ≤ 1 point.
3. **Hero distance** — large Saira Condensed numeral + short unit ("mi"/"km"), with a
   small "distance" label. The numeric anchor.
4. **Elevation band** — a lime area sparkline (reusing `ElevationSparkline`) spanning the
   width at a short fixed height, with a quiet "elevation" caption. **Shown only when the
   ride has ≥ 2 elevation samples**; omitted with reflow otherwise.
5. **Stats row** — moving time · climbed · top speed, as three `StatPair` cells (brand
   context), matching the on-screen summary. Climbed stays here always (a number read that
   the sparkline's shape read complements rather than duplicates).
6. **Destination line** — "to {name}" for navigate rides; omitted when `destinationName`
   is nil (free rides).

### Why this is not the banned hero-metric template

The absolute-bans list forbids the SaaS "big number + small label + supporting stats +
gradient accent" template. This card avoids it: the route panel — not the number — is the
dominant visual anchor; the distance is an instrument-styled Saira readout, not a gradient
stat; the sparkline is functional data, not decoration; there are no gradients anywhere.
The design review will pressure-test this specifically.

## Architecture

Three layers respected. Card image rendering is app-target (ImageRenderer needs
SwiftUI/UIKit); all testable assembly/branching logic is pure (AuraKit).

### AuraKit — `ShareCardContent` (pure, `Sendable`, unit-tested)

New file `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift`.

A value type built from a finished `Ride` plus the rider's `DistanceUnits`, holding
everything the card view needs as already-resolved primitives:

- `distanceValue: String`, `distanceUnit: String`
- `movingTime: String` (e.g. "42 min")
- `climbedValue: String`, `climbedUnit: String`
- `topSpeedValue: String`, `topSpeedUnit: String`
- `dateText: String`
- `destinationName: String?` (nil for free rides / empty names)
- `routeCoordinates: [Coordinate]` (the route to draw; empty when track ≤ 1 point)
- `elevationSamples: [Double]` (empty ⇒ no sparkline; requires ≥ 2 non-nil samples)
- `title: String` ("Nice ride")

Built via
`init(ride:units:locale:timeZone:)` where `locale`/`timeZone` default to `.current` and are
injectable so tests are deterministic. Strings come from `RideStatsFormatter`
(distanceValue/distanceUnit, elevationValue/elevationUnit, speedValue(_:decimals: 1),
minutes(_)). `dateText` is produced with `Date.FormatStyle` (month abbreviated, day, year)
under the injected locale/timeZone. `elevationSamples = ride.track.compactMap(\.elevation)`
when that yields ≥ 2 values, else `[]`. `routeCoordinates = ride.track.map(\.coordinate)`
when `track.count > 1`, else `[]`. Uses `ride.stats ?? .zero` so a stats-less ride still
produces valid (zeroed) strings, though the app gates the Share button on `ride.stats != nil`.

All metric/imperial, has-elevation, has-destination, and has-route branching lives here and
is covered by `AuraKitTests`.

### Aura (app target) — `ShareCardView`

New file `Aura/Sources/Ride/ShareCard/ShareCardView.swift`.

`struct ShareCardView: View { let content: ShareCardContent }`. Fixed-size 4:5 layout
using `AuraTheme` tokens, `RouteThumbnail(coordinates:)` for the route, and
`ElevationSparkline(elevations:stroke:fill:)` for the elevation band. Conditionals mirror the
content's empty arrays (no route ⇒ no panel; no elevation ⇒ no band; nil destination ⇒ no
line). Static — no animation, no `@ScaledMetric` count-up. Explicitly sets fixed point sizes
(not Dynamic-Type-scaled) because the output is a fixed-pixel image.

### Aura (app target) — `RideCardRenderer`

New file `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift`.

`@MainActor enum RideCardRenderer { static func render(_ content: ShareCardContent) -> UIImage? }`.
Wraps `ImageRenderer(content: ShareCardView(content:))`, sets `proposedSize` / frame to
360×450 and `scale = 3`, returns `.uiImage`. Because the card uses only Canvas-based route and
sparkline renderers (never the Mapbox `StaticRouteMap`), it renders correctly offscreen.

### Aura (app target) — wiring in `RideSummaryView`

Modify `Aura/Sources/Ride/RideSummaryView.swift`:

- Add `@State private var shareImage: Image?`.
- In a `.task` (or on appear), build `ShareCardContent(ride:units:)`, call
  `RideCardRenderer.render(...)`, and store `Image(uiImage:)` in `shareImage`. Guarded by
  `ride.stats != nil`.
- Insert a **Share** control directly above the existing Done button:
  - While `shareImage == nil` (rendering) or `ride.stats == nil`: a disabled
    `.ctaSecondary` "Share" button (or omitted entirely when no stats).
  - Once ready: `ShareLink(item: image, preview: SharePreview("Aura ride", image: image))`
    styled `.ctaSecondary`, labeled "Share".
- Done remains the primary `.ctaPrimary`.

The Share button honors Reduce Motion / Increase Contrast exactly like the other CTAs (it is
the same button system); the rendered PNG is unaffected by those settings.

## Data flow

`Ride` (full track, stats) → `ShareCardContent(ride:units:)` [AuraKit, pure] →
`ShareCardView(content:)` [app] → `ImageRenderer` in `RideCardRenderer` [app] → `UIImage` →
`Image` → `ShareLink` → system share sheet.

## Edge cases

- **No elevation** (all `TrackPoint.elevation` nil, or < 2 present) → `elevationSamples` empty
  → elevation band omitted, layout reflows.
- **No route geometry** (`track.count ≤ 1`, e.g. a HealthKit import without GPS) →
  `routeCoordinates` empty → route panel omitted, layout reflows.
- **No destination** (free ride or empty name) → destination line omitted.
- **No stats** (`ride.stats == nil`) → Share button not offered.
- **Custom font in ImageRenderer** — the Saira Condensed faces are bundled/registered; the
  card must render them correctly offscreen. Explicit verification item.
- **Render failure** (`ImageRenderer.uiImage` nil) → Share button stays in its disabled state;
  no crash, no share.

## Testing

- **AuraKitTests — `ShareCardContentTests` (Swift Testing):**
  - metric vs imperial → distance/climbed/top-speed value+unit strings.
  - elevation present (≥ 2 samples) → non-empty `elevationSamples`; absent / single sample →
    empty.
  - route present (track > 1) vs single-point → `routeCoordinates` populated vs empty.
  - destination present vs nil/empty → `destinationName` passthrough vs nil.
  - stats nil → zeroed strings, no crash.
  - `dateText` deterministic under an injected fixed locale + timeZone.
- **App build:** `xcodegen generate` + `xcodebuild` on iPhone 17 sim (also builds AuraWidgets).
- **UI/manual verify:** AXe / Simulator — Share button appears, is labeled, is reachable, and
  the share sheet presents; eyeball the rendered PNG against the mono-lime bar (route, Saira
  hero, sparkline present/absent cases).

## Gates (per task, before "done")

- `cd AuraCore && swift test` green.
- `swiftlint lint --strict` clean (line ≤ 140 warn / 200 err; `void_function_in_ternary` is an
  error).
- App builds via `xcodegen generate` + `xcodebuild` on iPhone 17 sim.

## Files

New:
- `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift`
- `AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift`
- `Aura/Sources/Ride/ShareCard/ShareCardView.swift`
- `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift`

Modified:
- `Aura/Sources/Ride/RideSummaryView.swift` (Share button + pre-render)
- `docs/ROADMAP.md` (retire the unbuilt-v1-promise line when this ships)

## Reuse (no new low-level renderers)

- `RouteThumbnail` (`Aura/Sources/Shared/RouteThumbnail.swift`) — Canvas polyline.
- `ElevationSparkline` (`Aura/Sources/Plan/ElevationSparkline.swift`) — Canvas area sparkline.
- `RideStatsFormatter` (`AuraCore/Sources/AuraKit/Formatting/`) — unit-aware strings.
- `StatPair`, `CTAButtonStyle`, `AuraTheme` — existing components/tokens.
