# Home: Liquid Glass controls + inline weather + action chips

**Linear:** ROH-55 · **Epic:** Interface & Feel · **Date:** 2026-07-03
**Branch:** `claude/wonderful-driscoll-51ed33`

## Context

The Home screen (`Aura/Sources/Home/HomeView.swift`) is the always-mounted Ride-tab
root: a terrain hero canvas with a greeting header, a launch band (primary "Where to?"
+ Explore/Join), and an always-present dashboard sheet (weekly glance + last ride at
peek; saved + recents when expanded). It is shipped, hardened code with deliberate
VoiceOver ordering and a "no uppercase eyebrow" slop gate.

A design exploration (Figma + a `HomeRedesignView.swift` reference) produced three
changes we now want in the real screen, scoped with the PO:

1. **Liquid Glass** on the control layer (iOS 26 material).
2. **Weather** folded into the greeting line.
3. **Action chips** — Explore/Join as compact chips + a new Saved chip.

The weekly glance and the dashboard sheet's structure are explicitly **out of scope**;
they stay as they are.

## Goals

- Adopt iOS 26 Liquid Glass on Home's control layer with a clean pre-iOS-26 fallback.
- Show current conditions inline in the greeting, sourced from real WeatherKit, behind
  a testable seam, degrading silently when unavailable.
- Replace the two full-width secondary launch buttons with Explore / Join a ride /
  Saved chips, wiring Saved to reveal the existing Saved section in the sheet.
- Preserve all existing accessibility semantics (labels, hints, identifiers, sort order)
  and the slop-gate rules.

## Non-goals (YAGNI)

- No change to `WeeklyGlanceView` (no enlarged stats module).
- No change to the dashboard sheet's saved/recents UI or the peek/expand behavior
  beyond adding a programmatic detent selection.
- No Liquid Glass anywhere outside Home; the shared `.hudControl` / `.ctaSecondary` /
  `.ctaPrimary` styles are not modified.
- No weather forecast, no tap-through from the greeting, no weather in the widget/HUD.
- No temperature-unit setting; format per locale (see Weather §).

## Deployment constraint

App deployment target is **iOS 17.0**; the simulator/device used is iOS 26. Every
Liquid Glass API (`.glassEffect`, `.buttonStyle(.glass)`, `GlassEffectContainer`,
`.glassProminent`) must be behind `if #available(iOS 26, *)` with a working fallback,
or the app will not compile/run on < 26.

---

## Feature A — Weather in the greeting

### Behavior

The greeting line becomes: `Good evening · ☀ 72° Clear` — the time-of-day greeting,
a middle dot, an SF Symbol for the condition (mint), the temperature, and a short
condition word. The weather portion appears **only when a snapshot is available**;
otherwise the line is just the greeting, exactly as today. The weather is **read-only**
(no tap target).

### Architecture (seams)

- **Pure model + formatter — AuraCore** (macOS-CI-safe, no WeatherKit import):
  - `WeatherSnapshot`: `temperature: Measurement<UnitTemperature>`,
    `symbolName: String` (SF Symbol), `conditionText: String`, `asOf: Date`,
    `coordinate: RideCoordinate` (or the existing coordinate type).
  - `WeatherGreeting`: pure functions that format a `WeatherSnapshot` for display —
    temperature string (locale-based via `MeasurementFormatter`/`Measurement` with
    `.providedUnit` off so the OS localizes °F/°C), and produce the composed
    accessibility string ("Good evening, 72 degrees, clear"). Nil-safe: returns just
    the greeting when snapshot is nil.
  - A pure mapping `WeatherConditionSymbol` from WeatherKit's `WeatherCondition`
    **raw value / a neutral enum** to an SF Symbol name + short text — defined over a
    plain Aura enum (not WeatherKit types) so it stays in AuraCore and is unit-testable.
- **Seam — AuraKit:**
  - `protocol WeatherProviding { func currentConditions(for coordinate: RideCoordinate) async throws -> WeatherSnapshot }`
- **Provider — app target:**
  - `WeatherKitProvider: WeatherProviding` using `WeatherKit.WeatherService.shared`,
    mapping `CurrentWeather` → `WeatherSnapshot` (temperature, condition → neutral enum
    → symbol/text via the AuraCore mapping).
- **State — app target (or AuraKit if no UIKit deps):**
  - `@Observable final class WeatherStore` holding `private(set) var snapshot: WeatherSnapshot?`
    and a `refresh(near:) async` that calls the provider, with caching: skip refetch if
    the last snapshot is < 15 minutes old **and** the location moved < ~2 km. Injected
    via `@Environment`. Never throws to the UI; on error it leaves `snapshot` unchanged
    (or nil) and the greeting simply omits weather.

### Data flow

`HomeView.task` / `onChange(of: location.authorization)` → `WeatherStore.refresh(near:)`
with the current `LocationService` coordinate → provider fetch → `snapshot` set →
greeting re-renders with weather. If there is no location authorization or the fetch
fails, `snapshot` stays nil and the greeting is unchanged.

### States / edge cases

- No location permission → no fetch, weather hidden.
- Fetch failure / WeatherKit not provisioned → weather hidden, no error UI, logged only.
- Loading (first fetch in flight) → weather hidden until it lands (no spinner in the
  greeting).
- Snapshot older than a staleness bound (e.g. 60 min) with no successful refresh →
  keep showing last known (acceptable) OR hide; **decision: keep last known up to 60
  min, then hide.** Simpler and avoids flicker.

### Accessibility

The greeting `HStack` uses `.accessibilityElement(children: .combine)` (or an explicit
composed label) so VoiceOver reads "Good evening, 72 degrees, clear" as one element,
preserving `accessibilitySortPriority` currently on the greeting block. The condition
symbol is decorative (`.accessibilityHidden(true)`).

### Entitlement

Add `com.apple.developer.weatherkit` to `Aura/Resources/Aura.entitlements`. The
WeatherKit **service capability on the App ID** is a PO/account task (see Risks); until
enabled, fetches fail and weather stays hidden — non-blocking.

---

## Feature B — Action chips

### Behavior

`HomeLaunchBand` keeps the full-width mint **"Where to?"** primary (`.ctaPrimary`,
VoiceOver priority 3). Below it, the two full-width secondary buttons are replaced by a
**chip row**: `Explore`, `Join a ride`, and (conditionally) `Saved`.

- Explore → existing `onExplore` (`router.push(.freeRide)`).
- Join a ride → existing `onJoin` (`router.push(.joinRide)`).
- Saved → new `onSaved`; **rendered only when `!savedPlaces.places.isEmpty`**.
- All chips carry `accessibilitySortPriority(1)` (unchanged secondary priority), so the
  VoiceOver order stays: primary (3) → glance (2) → chips (1) → utilities (-1).

### Saved → expand sheet

`HomeSheet`'s `.presentationDetents([.height(peek), .fraction(0.55), .large])` gains a
`selection` binding: `.presentationDetents(_, selection: $selectedDetent)`. `HomeView`
owns `@State selectedDetent: PresentationDetent = .height(peekHeight)`. `onSaved` sets
it to `.large`. The Saved section is already the first child of the sheet's scroll body,
so expanding reveals it without needing scroll-to-anchor. (If reveal proves unreliable
without scrolling, a `ScrollViewReader` + `.id("saved")` anchor is the fallback — noted,
not built by default.)

### Chip component

A new Home-scoped `HomeChip` (icon + label) with the glass/fallback treatment from
Feature C. Icons: Explore `safari`, Join `person.2.badge.plus` (match existing), Saved
`bookmark`. Labels are sentence-case (slop gate). Mint content on glass; on the < iOS 26
fallback, a capsule with `AuraTheme.surface` fill + mint hairline + mint content
(matching the reference view's fallback).

---

## Feature C — Liquid Glass (control layer)

### Scope of surfaces

- **Header HUD buttons** (History, Settings) → glass on iOS 26, `.hudControl` fallback.
- **Chip row** → each chip glass on iOS 26 (`.buttonStyle(.glass)` tinted mint),
  capsule fallback; the row wrapped in a `GlassEffectContainer` so the chips blend.
- **Primary "Where to?"** stays `.ctaPrimary` (solid mint) on all versions — unchanged.
- **Dashboard sheet** stays solid (`AuraTheme.surface`) — unchanged.

### Home-scoped helper (no shared-style changes)

Add `Aura/Sources/Home/HomeGlass.swift`:

- `GlassGroup` — a container view that is `GlassEffectContainer(spacing:)` on iOS 26 and
  a plain pass-through `content()` otherwise (gates the availability check once).
- `homeGlassControl(shape:)` / a small view-builder or `ButtonStyle`-agnostic modifier
  that applies `.buttonStyle(.glass)` (+ `.buttonBorderShape(.circle)` for the circular
  HUD buttons, `+ .tint` for chips) on iOS 26, and the passed-in fallback style
  otherwise. Implemented so call sites read cleanly without inline `#available` blocks.

The shared `.hudControl`, `.ctaSecondary`, and `.ctaPrimary` styles in
`Aura/Sources/Theme/` are **not touched** — the blast radius stays on Home. Other
screens using `.hudControl` (the HUDs) are unaffected.

### Accessibility / robustness

- Liquid Glass automatically honors Reduce Transparency; the fallback path uses the
  existing solid styles which already handle Reduce Transparency / Motion / Contrast.
- All existing `.accessibilityLabel/Hint/Identifier/sortPriority` on the HUD buttons are
  carried onto the glass variants verbatim. New chips get labels/identifiers to match
  the existing pattern (`home.explore`, `home.join`, `home.saved`).

---

## Files touched (planned)

**New**
- `AuraCore/Sources/AuraCore/Weather/WeatherSnapshot.swift`
- `AuraCore/Sources/AuraCore/Weather/WeatherGreeting.swift` (formatter + condition→symbol map + neutral condition enum)
- `AuraKit/…/WeatherProviding.swift` (seam) — location per existing AuraKit layout
- `Aura/Sources/Weather/WeatherKitProvider.swift` (provider)
- `Aura/Sources/Weather/WeatherStore.swift` (`@Observable` state)
- `Aura/Sources/Home/HomeGlass.swift` (glass helper + `HomeChip`)
- Tests: `AuraCore` weather tests; `WeatherStore` tests with a mock provider.

**Modified**
- `Aura/Sources/Home/HomeView.swift` (greeting inline weather; wire `WeatherStore`, `selectedDetent`, `onSaved`)
- `Aura/Sources/Home/HomeLaunchBand.swift` (chip row)
- `Aura/Sources/Home/HomeSheet.swift` (detent `selection` binding)
- `Aura/Resources/Aura.entitlements` (WeatherKit)
- App composition root (inject `WeatherStore` into the environment)

`HomeRedesignView.swift` (the standalone reference) stays as a reference and is not
wired in; it can be deleted once the real screen lands (decided at whole-branch review).

## Testing strategy (TDD)

- **Unit (AuraCore, macOS-CI-safe):**
  - `WeatherGreeting` — temperature formatting for °F and °C locales; nil snapshot →
    greeting only; composed accessibility string; each neutral condition → expected
    symbol + short text; staleness (fresh vs > 60 min → hidden).
  - condition→symbol mapping total over the neutral enum (no missing case).
- **Unit (WeatherStore, mock `WeatherProviding`):**
  - first refresh sets snapshot; provider throw leaves snapshot nil/unchanged and does
    not surface an error; cache hit (< 15 min, < 2 km moved) skips a second fetch;
    cache miss (moved / stale) refetches.
- **Chip visibility logic:** Saved hidden when saved empty, shown otherwise — pure where
  possible (a small helper) or a lightweight view test.
- **Not unit-tested:** Liquid Glass visuals, live WeatherKit fetch, detent animation —
  verified manually on device. Optional XCUITest: chips exist with identifiers; tapping
  Saved raises the sheet (best-effort, may be deferred).

## Risks & dependencies

1. **WeatherKit App ID provisioning (PO).** The capability must be enabled for the
   bundle ID for real data. Non-blocking: weather hides until then; everything else
   ships. Flag at handoff.
2. **Glass only renders on iOS 26.** Target is 17.0; < 26 devices get the current look.
   Acceptable and expected.
3. **Detent `selection` reveal.** Expanding to `.large` should reveal the Saved section
   (first in the scroll body); if it doesn't reliably, add a `ScrollViewReader` anchor.
4. **WeatherKit `WeatherService` requires a network + entitlement**; on simulator it may
   fail without provisioning — the silent-hide path covers this.
5. **`RideCoordinate` type name** used above is a placeholder for whatever coordinate
   value type AuraCore already exposes; the plan will pin the exact type during
   implementation (do not invent a new coordinate type).

## Rollout

Single branch `claude/wonderful-driscoll-51ed33`, full pipeline, whole-branch review,
then device verification (History/Settings glass, chips, Saved-expands-sheet; weather
appears once WeatherKit is provisioned). Merge per the local main workflow when approved.
