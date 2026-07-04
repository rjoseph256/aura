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

The weekly glance and the dashboard sheet's structure stay as they are.

## Goals

- Adopt iOS 26 Liquid Glass on Home's control layer with a clean pre-iOS-26 fallback.
- Show current conditions inline in the greeting, sourced from real WeatherKit, behind
  a testable seam, degrading silently when unavailable, without ever shifting layout.
- Replace the two full-width secondary launch buttons with Explore / Join a ride /
  Saved chips, wiring Saved to reveal the existing Saved section in the sheet.
- Preserve all existing accessibility semantics (labels, hints, identifiers, sort order)
  and the slop-gate rules.

## Non-goals (YAGNI)

- No change to `WeeklyGlanceView` (no enlarged stats module).
- No change to the dashboard sheet's saved/recents UI or the peek/expand behavior
  beyond adding a programmatic detent selection + a scroll anchor.
- No Liquid Glass outside Home; the shared `.hudControl` / `.ctaSecondary` /
  `.ctaPrimary` styles are not modified.
- No weather forecast, no tap-through from the greeting, no weather in the widget/HUD.
- No temperature-unit setting; format per device locale.

## Deployment constraint

App deployment target is **iOS 17.0**; verification hardware is iOS 26. Every Liquid
Glass API (`.glassEffect`, `.buttonStyle(.glass)`, `GlassEffectContainer`) must be
behind `if #available(iOS 26, *)` with a working fallback. (These APIs are confirmed
real — the reference view already compiles against the iOS 26.2 SDK.)
`.presentationDetents(_:selection:)` is available **iOS 16.0+**, so it needs no gate on
a 17.0 target (confirm at implementation).

---

## Feature A — Weather in the greeting

### Behavior

The greeting line becomes: `Good evening · ☀ 72° clear` — the time-of-day greeting, a
middle dot, an SF Symbol for the condition (mint), the temperature, and a **lowercase**
condition word. The weather portion appears **only when a display-eligible snapshot
exists**; otherwise the line is just the greeting, exactly as today. The weather is
read-only (no tap target).

### Layout stability (do not shift the header)

The greeting + weather render on **one line** with `.lineLimit(1)` and
`.minimumScaleFactor(0.85)`, so:
- weather arriving/leaving never wraps the line, so the "Aura" wordmark below never
  moves vertically;
- long condition words and large Dynamic Type shrink slightly rather than wrap.

Manual verification covers Dynamic Type from default through the largest accessibility
size, and a long condition ("heavy thunderstorm"), on the narrowest supported width.

### Architecture (seams + isolation)

- **Pure model + formatter — AuraCore** (macOS-CI-safe, never imports WeatherKit):
  - `WeatherSnapshot: Sendable` — `temperature: Measurement<UnitTemperature>`,
    `condition: AuraWeatherCondition`, `asOf: Date`, `coordinate: Coordinate`
    (the existing AuraCore `Coordinate` value type). `Measurement<UnitTemperature>` and
    `Coordinate` are `Sendable`, so the whole snapshot is `Sendable`.
  - `enum AuraWeatherCondition: String, Sendable, CaseIterable` — a neutral, Aura-owned
    set (`clear, mostlyClear, cloudy, mostlyCloudy, fog, drizzle, rain, heavyRain,
    thunderstorm, snow, sleet, hail, windy, hot, cold, unknown`). Includes `unknown` as
    the fallback for any WeatherKit case we don't map.
  - `WeatherGreeting` — pure functions:
    - `symbolName(for:) -> String` and `text(for:) -> String`, **total** over
      `AuraWeatherCondition` (every case returns a non-empty SF Symbol + lowercase text);
      `.unknown → ("cloud", "")` (no weather word rendered).
    - `temperatureText(_ measurement:) -> String` — pure, **no `MeasurementFormatter`**
      (not Sendable). Chooses °F/°C from `Locale.current.measurementSystem`
      (`.us`/`.uk` → Fahrenheit; else Celsius), converts, rounds:
      `"\(Int(value.rounded()))°"`.
    - `accessibilityText(greeting:snapshot:) -> String` — composes
      `"Good evening, 72 degrees, clear"` (spells the unit word); greeting-only when nil.
- **Seam — AuraKit:** `protocol WeatherProviding: Sendable { func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot }`.
- **Provider — app target:** `final class WeatherKitProvider: WeatherProviding` using
  `WeatherKit.WeatherService.shared`. `nonisolated func currentConditions(...)` awaits
  the service and maps **only raw Sendable values** — `current.temperature`
  (`Measurement<UnitTemperature>`) and `current.condition` (`WeatherKit.WeatherCondition`)
  → `AuraWeatherCondition` via a total switch with `default: .unknown`. No WeatherKit
  reference types leak into the snapshot. (The WeatherKit→neutral switch lives in the
  **app target**, never in AuraCore.)
- **State — AuraKit** (`AuraCore/Sources/AuraKit/Weather/WeatherStore.swift`), beside
  `SettingsStore`/`SavedPlacesStore`. It holds only a `WeatherProviding` (the seam) plus
  AuraCore types, so it **never imports WeatherKit** and builds/tests on macOS CI.
  **Invariant:** the store has NO default WeatherKit provider — the app composition root
  injects `WeatherKitProvider`. (Only the provider, in the app target, imports WeatherKit.)
  A guard test asserts AuraKit sources contain no `import WeatherKit`.

  ```swift
  @MainActor @Observable public final class WeatherStore {
      public private(set) var snapshot: WeatherSnapshot?
      private let provider: WeatherProviding
      private let now: () -> Date          // injected for deterministic tests
      public init(provider: WeatherProviding, now: @escaping () -> Date = Date.init) { … }

      /// Display-eligible snapshot (nil past the 60-min staleness bound).
      var displaySnapshot: WeatherSnapshot? { … using now() … }

      func refresh(near coordinate: Coordinate) async {
          // cache: skip if snapshot < 15 min old AND Geo.distance(last, coordinate) < 2000 m
          // else fetch; on success set snapshot on the main actor; on throw leave unchanged
      }
  }
  ```

  `refresh` never throws to the UI; failures leave `snapshot` unchanged (logged only).
  Staleness (`displaySnapshot`) and cache decisions are computed from the injected
  `now()` and `Geo.distance`, so they are unit-testable without `Date()`/sleeps.

### Data flow

`HomeView.task` and `.onChange(of: location.authorization)` call
`WeatherStore.refresh(near:)` with the current `LocationService` coordinate (both are
`@MainActor`; no isolation boundary is crossed). The greeting reads
`weatherStore.displaySnapshot`. No authorization / fetch failure / not-yet-provisioned
→ nil → greeting shows no weather.

### States / edge cases

- No location permission → no fetch, weather hidden.
- Fetch failure / WeatherKit capability not yet enabled → weather hidden, no error UI.
- Loading → hidden until the first snapshot lands (no spinner in the greeting).
- Snapshot > 60 min old with no successful refresh → `displaySnapshot` returns nil
  (hidden). Under 60 min, last-known is shown to avoid flicker.

### Accessibility

The greeting `HStack` gets an explicit `.accessibilityElement(children: .ignore)` +
`.accessibilityLabel(WeatherGreeting.accessibilityText(...))` so VoiceOver reads one
element ("Good evening, 72 degrees, clear"), preserving the greeting block's
`accessibilitySortPriority`. The condition `Image` is `.accessibilityHidden(true)` so
"sun max" is never read separately.

### Entitlement — deferred (keeps the branch device-ready with no PO dependency)

Adding `com.apple.developer.weatherkit` before the App ID has the WeatherKit capability
would break code-signing (device/CI). WeatherKit **code compiles and links without the
entitlement**; only the runtime fetch fails (→ graceful hide). So **the entitlement is
NOT added in this branch.** Turning weather on is one PO step done together: enable the
WeatherKit capability on the App ID **and** add the entitlement. Until then, everything
ships and installs; weather simply stays hidden.

---

## Feature B — Action chips

### Behavior

`HomeLaunchBand` keeps the full-width mint **"Where to?"** primary (`.ctaPrimary`,
VoiceOver priority 3). Below it, the two full-width secondary buttons are replaced by a
**chip row**: `Explore`, `Join a ride`, and (conditionally) `Saved`.

- Explore → existing `onExplore` (`router.push(.freeRide)`), id `home.explore`.
- Join a ride → existing `onJoin` (`router.push(.joinRide)`), id `home.join`.
- Saved → new `onSaved`, id `home.saved`; **rendered only when `!savedPlaces.places.isEmpty`**,
  wrapped in `.transition(.opacity)` so its appearance/disappearance animates rather than
  snapping (mitigates the 2↔3 chip reflow).
- All chips carry `accessibilitySortPriority(1)`; VoiceOver order stays primary (3) →
  glance (2) → chips (1) → utilities (-1). The row is grouped with an
  `.accessibilityLabel("Quick actions")` container? — No; keep flat sibling buttons to
  match the current model (each chip is its own element), consistent with the existing
  Explore/Join buttons.

### Saved → expand sheet (with a real scroll anchor)

1. `HomeSheet` gains a `selection: Binding<PresentationDetent>` passed through to
   `.presentationDetents(_, selection:)` (iOS 16+). `HomeView` owns
   `@State selectedDetent: PresentationDetent = .height(peekHeight)`.
2. The sheet body is wrapped in a `ScrollViewReader`; the Saved section gets `.id("saved")`.
3. `onSaved` behavior (idempotent):
   - if `searchExpanded`, set `searchExpanded = false` first;
   - set `selectedDetent = .large`;
   - `withAnimation { proxy.scrollTo("saved", anchor: .top) }` (via an `.onChange(of:
     selectedDetent)` inside the sheet, or a shared trigger) so Saved is revealed even
     if the body had been scrolled to Recents.

   Building the anchor is **default scope**, not deferred — reviewers confirmed detent
   expansion alone does not reset the inner scroll position.

`homeDashboardSheet` is only called from `HomeView` (verify with a grep before merge);
the new `selection` parameter is therefore a safe signature change.

### Chip component

A new Home-scoped `HomeChip` (icon + sentence-case label) with the glass/fallback
treatment from Feature C. Icons: Explore `safari`, Join `person.2.badge.plus` (matches
the current `HomeLaunchBand`), Saved `bookmark`.

---

## Feature C — Liquid Glass (control layer)

### Surfaces

- **Header HUD buttons** (History, Settings) → glass on iOS 26, `.hudControl` fallback.
- **Chip row** → each chip glass on iOS 26 (`.buttonStyle(.glass)` tinted mint), capsule
  fallback; the row wrapped in a `GlassEffectContainer` so chips blend.
- **Primary "Where to?"** stays `.ctaPrimary` (solid mint) on all versions.
- **Dashboard sheet** stays solid — unchanged.

### Home-scoped helper (no shared-style changes)

Add `Aura/Sources/Home/HomeGlass.swift`:
- `GlassGroup` — `GlassEffectContainer(spacing:)` on iOS 26, plain pass-through
  otherwise (gates `#available` once).
- A control/chip wrapper that applies `.buttonStyle(.glass)` (+ `.buttonBorderShape(.circle)`
  for circular HUD buttons, `+ .tint(AuraTheme.accent)` for chips) on iOS 26, and the
  passed-in fallback style otherwise — so call sites carry no inline `#available`.

The shared `.hudControl`, `.ctaSecondary`, `.ctaPrimary` styles in `Aura/Sources/Theme/`
are **not touched**; other screens using `.hudControl` (the HUDs) are unaffected.

### Accessibility / robustness

- **Do not rely on glass auto-behavior alone for the tinted content.** When
  `accessibilityReduceTransparency` is on **or** `colorSchemeContrast == .increased`, the
  helper uses the **solid fallback styles** (the shipped `.hudControl` / capsule) even on
  iOS 26 — those already meet contrast over the map. Plain-glass (no custom tint) can
  keep the system material.
- All existing `.accessibilityLabel/Hint/Identifier/sortPriority` on the HUD buttons are
  carried onto the glass variants verbatim. New chips get matching labels/identifiers.
- Device verification includes a bright-map / sunlight legibility check and an
  Increase-Contrast pass.

---

## Files

**New**
- `AuraCore/Sources/AuraCore/Weather/WeatherSnapshot.swift` (+ `AuraWeatherCondition`)
- `AuraCore/Sources/AuraCore/Weather/WeatherGreeting.swift`
- `AuraCore/Sources/AuraKit/Weather/WeatherProviding.swift` (seam)
- `AuraCore/Sources/AuraKit/Weather/WeatherStore.swift` (`@MainActor @Observable`, no WeatherKit import)
- `Aura/Sources/Weather/WeatherKitProvider.swift` (the only WeatherKit importer)
- `Aura/Sources/Home/HomeGlass.swift` (glass helper + `HomeChip`)
- Tests: AuraCore weather tests; AuraKit/app `WeatherStore` tests with a mock provider.

**Modified**
- `Aura/Sources/Home/HomeView.swift` — greeting inline weather (layout-stable + a11y);
  `headerControls` migrated to the glass helper; own `selectedDetent`; wire `WeatherStore`
  and `onSaved`.
- `Aura/Sources/Home/HomeLaunchBand.swift` — chip row (replaces the secondary buttons).
- `Aura/Sources/Home/HomeSheet.swift` — add `selection` binding + `ScrollViewReader` +
  `.id("saved")` reveal.
- App composition root — inject `WeatherStore` (with `WeatherKitProvider`) into the env.

**Deleted**
- `Aura/Sources/Home/HomeRedesignView.swift` — the Figma-exploration reference; removed
  before merge so there is no parallel screen to drift. (History preserves it.)

## Testing strategy (TDD)

- **Unit (AuraCore, macOS-CI-safe):**
  - `WeatherGreeting.temperatureText` — °F for a US locale, °C for a metric locale;
    rounding.
  - `symbolName`/`text` **total** over `AuraWeatherCondition` (every case non-empty
    symbol; `.unknown` yields empty text); condition text is lowercase.
  - `accessibilityText` — composed string with unit word; greeting-only when nil.
- **Unit (`WeatherStore`, mock `WeatherProviding`, injected `now`):**
  - first refresh sets snapshot;
  - provider throw leaves snapshot unchanged and surfaces no error;
  - cache hit (< 15 min via injected `now`, < 2 km via `Geo.distance`) → no second fetch;
  - cache miss (moved ≥ 2 km, or ≥ 15 min) → refetch;
  - `displaySnapshot` nil past 60 min; non-nil under it.
- **Chip visibility:** Saved hidden when saved empty, shown otherwise (pure helper).
- **Not unit-tested (manual/device):** Liquid Glass visuals + contrast, live WeatherKit
  fetch, detent+scroll reveal animation, greeting layout across Dynamic Type sizes.
  Optional XCUITest: chips exist with identifiers; tapping Saved raises the sheet.

## Risks & dependencies

1. **WeatherKit provisioning (PO, deferred + non-blocking).** Weather turns on when the
   PO enables the WeatherKit capability on the App ID **and** the `com.apple.developer.weatherkit`
   entitlement is added (done together, as a follow-up). Adding the entitlement earlier
   would break signing, so it is intentionally left out of this branch. Until then the
   app ships and weather stays hidden.
2. **Glass only renders on iOS 26.** Target is 17.0; < 26 gets the current look.
3. **`presentationDetents(_,selection:)`** — iOS 16+; confirm at implementation. If it
   ever fails, the scroll anchor still reveals Saved; only programmatic expansion would
   need a different mechanism.
4. **`homeDashboardSheet` signature change** — verified single caller (HomeView) before
   merge.

## Rollout

Single branch `claude/wonderful-driscoll-51ed33`, full pipeline, whole-branch review,
then device verification (History/Settings glass, chips, Saved-expands-sheet + scroll,
greeting layout stability; weather appears once WeatherKit is provisioned). Merge per the
local main workflow when approved.

---

## Adversarial spec review — reconciliation (2026-07-03)

Three independent reviewers (correctness, product/UX/a11y, architecture) ran with a
refuting mandate. Accepted and folded in above: WeatherKit kept out of the package via
the seam (the reviewers' "app-target-only store" is refined to **AuraKit store + app-target
provider** — the store never imports WeatherKit, so its deterministic tests run in CI,
guarded by a no-`import WeatherKit` assertion); `@MainActor @Observable` + injected clock; `WeatherProviding: Sendable` mapping raw
values; no `MeasurementFormatter`; `Coordinate` + `Geo.distance`; neutral
`AuraWeatherCondition` with `.unknown` fallback + total tested map + lowercase text;
greeting single-line layout stability + explicit composed a11y; ScrollViewReader anchor
built by default + idempotent `onSaved`; Increase-Contrast/Reduce-Transparency solid
fallback on iOS 26 too; delete `HomeRedesignView.swift`; **defer the WeatherKit
entitlement** to keep the branch device-ready with no PO dependency.

Dismissed after verification: "`presentationDetents(_,selection:)` needs iOS 18" (it is
iOS 16+); "iOS 26 Glass APIs are speculative" (already compiled against the 26.2 SDK).
