# Aura Wave 2 — Ride-summary redesign and contrast lift Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the ride summary into a map-led recap (retiring the orphaned stat stack) and lift the borderline contrast values across the app, inside the existing mono-lime `AuraTheme`.

**Architecture:** A pure `WCAGContrast` helper and a centralized `AuraPalette` move into `AuraCore`; `AuraTheme` builds its SwiftUI `Color` roles from `AuraPalette` so a CI test suite guards the token contrast targets. The summary screen is rebuilt in the app target; a small set of cockpit-over-map surfaces gain a scoped Increase-Contrast path.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, XcodeGen, SwiftLint 0.64.1.

## Global Constraints

- Swift 6.2 / Xcode 26; iPhone 17 / iOS 26.x simulator (iPhone 15 is NOT installed).
- SwiftLint 0.64.1 pinned, `--strict`. Run `scripts/lint.sh` (whole repo) at EVERY task gate, not only at the end. No tuples with 3+ members (`large_tuple`); no aligned multi-space before `{` (`opening_brace`); lines ≤140 chars.
- NEVER `git add AuraCore/Package.resolved`; if a build dirties it, `git checkout -- AuraCore/Package.resolved`.
- Do NOT commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored). Stage only the files each task names.
- New files under `AuraCore/Sources/**` are auto-globbed by SwiftPM — no `xcodegen`. This plan adds NO app-target files (the only new SwiftUI type, `CountUpText`, is file-private inside `RideSummaryView.swift`) and deletes none, so `xcodegen generate` is NOT required.
- Mono-lime identity only: lime `#C8FA4B`, near-black `#07080C`, pink `#FF4D9D` for ending a ride. No new palette, no gradients.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- AuraCore/AuraKit import no SwiftUI/UIKit and build on the macOS CI host. The new `AuraPalette`/`WCAGContrast` are plain values + math (no SwiftUI). `AuraTheme.swift` lives in the app target and is also compiled into `AuraWidgets`; both link `AuraCore`, so `import AuraCore` in `AuraTheme.swift` is build-safe.

## File structure

- Create `AuraCore/Sources/AuraCore/Theme/WCAGContrast.swift` — `RGBColor` value + pure WCAG luminance/ratio/composite math.
- Create `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift` — the raw mono-lime numbers (hues, white levels, opacities), the single source of truth.
- Create `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift` — math tests + token-pair contrast guarantees.
- Modify `Aura/Sources/Theme/AuraTheme.swift` — build roles from `AuraPalette`; token bumps; contrast resolvers.
- Modify `Aura/Sources/Plan/LastRideCard.swift` and `Aura/Sources/Plan/RoutePreviewView.swift` — drop redundant opacity stacks.
- Modify `Aura/Sources/Ride/SpeedRail.swift`, `Aura/Sources/Ride/GPSSignalChip.swift`, `Aura/Sources/Ride/NavigateHUDView.swift`, `Aura/Sources/Ride/TripStripView.swift`, `Aura/Sources/Theme/HUDControlButton.swift` — cockpit-over-map scrim unification + Increase-Contrast arm.
- Modify `Aura/Sources/Ride/RideSummaryView.swift` — the map-led redesign + count-up + entrance.
- Modify `docs/ROADMAP.md` — mark SP3 shipped and Wave 2 complete.

---

### Task 1: `WCAGContrast` pure helper (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Theme/WCAGContrast.swift`
- Test: `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift`

**Interfaces:**
- Produces: `public struct RGBColor: Equatable, Sendable { let red, green, blue: Double; init(red:green:blue:) }`; `public enum WCAGContrast` with `static func white(_:) -> RGBColor`, `relativeLuminance(_:) -> Double`, `ratio(_:_:) -> Double`, `composite(_:over:alpha:) -> RGBColor`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import AuraCore

struct WCAGContrastTests {
    @Test func whiteOnBlackIsMaxRatio() {
        #expect(abs(WCAGContrast.ratio(.white(1), .white(0)) - 21) < 0.001)
    }

    @Test func sameColorIsOne() {
        #expect(abs(WCAGContrast.ratio(.white(0.5), .white(0.5)) - 1) < 1e-9)
    }

    @Test func ratioIsSymmetric() {
        let a = WCAGContrast.white(0.6), b = WCAGContrast.white(0.1)
        #expect(WCAGContrast.ratio(a, b) == WCAGContrast.ratio(b, a))
    }

    @Test func luminanceBounds() {
        #expect(WCAGContrast.relativeLuminance(.white(0)) == 0)
        #expect(abs(WCAGContrast.relativeLuminance(.white(1)) - 1) < 1e-9)
    }

    @Test func compositeEndpointsAreFgAndBg() {
        let fg = RGBColor(red: 1, green: 0, blue: 0)
        let bg = WCAGContrast.white(0)
        #expect(WCAGContrast.composite(fg, over: bg, alpha: 1) == fg)
        #expect(WCAGContrast.composite(fg, over: bg, alpha: 0) == bg)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter WCAGContrastTests`
Expected: FAIL — build error, `cannot find 'WCAGContrast'`/`RGBColor` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// An sRGB color as plain components (0...1), with no SwiftUI/UIKit dependency so it
/// builds on the macOS CI host and the contrast math is unit-testable.
public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Pure WCAG 2.x relative-luminance and contrast math.
public enum WCAGContrast {
    /// A grayscale color, mirroring SwiftUI's `Color(white:)`.
    public static func white(_ level: Double) -> RGBColor {
        RGBColor(red: level, green: level, blue: level)
    }

    public static func relativeLuminance(_ color: RGBColor) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    public static func ratio(_ a: RGBColor, _ b: RGBColor) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Straight-alpha composite of a translucent foreground over an opaque background.
    public static func composite(_ fg: RGBColor, over bg: RGBColor, alpha: Double) -> RGBColor {
        RGBColor(red: fg.red * alpha + bg.red * (1 - alpha),
                 green: fg.green * alpha + bg.green * (1 - alpha),
                 blue: fg.blue * alpha + bg.blue * (1 - alpha))
    }

    /// One sRGB component (0...1) linearized per the WCAG formula.
    private static func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter WCAGContrastTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Lint**

Run: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 6: Commit**

```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add AuraCore/Sources/AuraCore/Theme/WCAGContrast.swift AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift
git commit -m "feat(core): pure WCAGContrast luminance/ratio helper

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `AuraPalette` raw values + contrast guarantees (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Theme/AuraPalette.swift`
- Test: `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift` (append a suite)

**Interfaces:**
- Consumes: `RGBColor`, `WCAGContrast` (Task 1).
- Produces: `public enum AuraPalette` with `RGBColor` constants `nearBlack`, `panel`, `lime`, `pink`, `inkOnLime`, `inkOnPink`, and `Double` constants `textPrimaryWhite`, `textSecondaryWhite`, `textSecondaryWhiteHighContrast`, `borderWhite`, `borderWhiteHighContrast`, `mapScrimOpacity`.

- [ ] **Step 1: Write the failing test** (append to `WCAGContrastTests.swift`)

```swift
struct AuraPaletteContrastTests {
    @Test func secondaryTextClearsBodyContrast() {
        let s = WCAGContrast.white(AuraPalette.textSecondaryWhite)
        #expect(WCAGContrast.ratio(s, AuraPalette.nearBlack) >= 4.5)
        #expect(WCAGContrast.ratio(s, AuraPalette.panel) >= 4.5)
    }

    @Test func liftedSecondaryHasSunlightMargin() {
        // The 0.55 baseline was 5.97:1; the lift targets >=7:1 on background. This locks
        // the bump: reverting textSecondaryWhite to 0.55 (5.97) fails here.
        #expect(WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhite), AuraPalette.nearBlack) >= 7.0)
    }

    @Test func primaryTextClearsBodyContrast() {
        #expect(WCAGContrast.ratio(.white(AuraPalette.textPrimaryWhite), AuraPalette.nearBlack) >= 4.5)
    }

    @Test func inkOnLimeClearsBodyContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.inkOnLime, AuraPalette.lime) >= 4.5)
    }

    @Test func inkOnPinkClearsBodyContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.inkOnPink, AuraPalette.pink) >= 4.5)
    }

    @Test func limeOnBackgroundClearsContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.lime, AuraPalette.nearBlack) >= 4.5)
    }

    @Test func increasedContrastSecondaryIsStronger() {
        let std = WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhite), AuraPalette.nearBlack)
        let inc = WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhiteHighContrast), AuraPalette.nearBlack)
        #expect(inc > std)
        #expect(inc >= 7.0)
    }

    @Test func liftedSecondaryHoldsOverBrightMapScrim() {
        // Worst-case: secondary text over the map scrim (surface @ mapScrimOpacity) on a
        // bright sunlit map pixel. Documents the design's over-map target; >=4.5.
        let brightMap = WCAGContrast.white(0.75)
        let scrim = WCAGContrast.composite(AuraPalette.panel, over: brightMap, alpha: AuraPalette.mapScrimOpacity)
        let secondary = WCAGContrast.white(AuraPalette.textSecondaryWhite)
        #expect(WCAGContrast.ratio(secondary, scrim) >= 4.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter AuraPaletteContrastTests`
Expected: FAIL — `cannot find 'AuraPalette' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The raw mono-lime palette as plain values (no SwiftUI). The SwiftUI `AuraTheme` in
/// the app target builds its `Color` roles from these, and the `WCAGContrast` tests read
/// the same numbers, so lowering a token below its contrast target fails CI.
public enum AuraPalette {
    // Hues
    public static let nearBlack = RGBColor(red: 0.027, green: 0.031, blue: 0.047) // #07080C
    public static let panel     = RGBColor(red: 0.055, green: 0.063, blue: 0.078) // #0E1014
    public static let lime      = RGBColor(red: 0.784, green: 0.980, blue: 0.294) // #C8FA4B
    public static let pink      = RGBColor(red: 1.0, green: 0.302, blue: 0.616)   // #FF4D9D
    public static let inkOnLime = RGBColor(red: 0.086, green: 0.129, blue: 0.039) // #16210A
    public static let inkOnPink = RGBColor(red: 0.165, green: 0.012, blue: 0.078) // #2A0314

    // Grayscale text levels (mirror SwiftUI `Color(white:)`).
    public static let textPrimaryWhite = 0.92
    public static let textSecondaryWhite = 0.62             // lifted from 0.55 (5.97 -> 7.48 on bg)
    public static let textSecondaryWhiteHighContrast = 0.80 // Increase Contrast

    // Decorative hairline (white opacity over the dark background).
    public static let borderWhite = 0.14                    // firmed from 0.08
    public static let borderWhiteHighContrast = 0.24

    // Cockpit scrim over the map: surface opacity in the non-opaque branch.
    public static let mapScrimOpacity = 0.85
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter AuraPaletteContrastTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Lint**

Run: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 6: Commit**

```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add AuraCore/Sources/AuraCore/Theme/AuraPalette.swift AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift
git commit -m "feat(core): centralize AuraPalette with CI-guarded contrast targets

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `AuraTheme` builds from `AuraPalette`, token bumps, contrast resolvers

**Files:**
- Modify: `Aura/Sources/Theme/AuraTheme.swift` (full rewrite of the color section; spacing/radius/typography unchanged)

**Interfaces:**
- Consumes: `AuraPalette`, `RGBColor` (Task 2).
- Produces: unchanged role names (`background`, `surface`, `textPrimary`, `textSecondary`, `accent`, `routeLine`, `destructive`, `onAccent`, `onDestructive`, `border`, `routeUIColor`); new `static func secondaryText(_:) -> Color`, `hairline(_:) -> Color`, `prefersOpaqueSurface(reduceTransparency:_:) -> Bool`, `mapScrim(reduceTransparency:_:) -> Color` (all taking `ColorSchemeContrast`).

- [ ] **Step 1: Rewrite the color section** (replace lines 1–28, the imports through `routeUIColor`; keep `Spacing`/`Radius`/`CockpitFace`/`Typography` exactly as they are). This deletes the existing `private enum Palette` block (lines 4–12) — the roles now build from `AuraPalette`, so a leftover `Palette` enum would be dead code.

```swift
import SwiftUI
import AuraCore

enum AuraTheme {
    // MARK: - Color roles
    // Built from the pure `AuraPalette` so the `WCAGContrast` tests in AuraCore guard the
    // exact values the app ships. Views use these roles, never raw colors.
    private static func rgb(_ c: RGBColor) -> Color {
        Color(red: c.red, green: c.green, blue: c.blue)
    }

    static let background    = rgb(AuraPalette.nearBlack)
    static let surface       = rgb(AuraPalette.panel)
    static let textPrimary   = Color(white: AuraPalette.textPrimaryWhite)
    static let textSecondary = Color(white: AuraPalette.textSecondaryWhite)
    static let accent        = rgb(AuraPalette.lime)
    static let routeLine     = rgb(AuraPalette.lime)
    static let destructive   = rgb(AuraPalette.pink)
    static let onAccent      = rgb(AuraPalette.inkOnLime)
    static let onDestructive = rgb(AuraPalette.inkOnPink)
    static let border        = Color.white.opacity(AuraPalette.borderWhite)

    // MARK: - Contrast-aware resolvers
    // Scoped to high-value over-map / sunlight spots. Named apart from the constants above
    // so a call site can't silently fall back to the standard value by omitting the argument.
    static func secondaryText(_ contrast: ColorSchemeContrast) -> Color {
        Color(white: contrast == .increased
              ? AuraPalette.textSecondaryWhiteHighContrast
              : AuraPalette.textSecondaryWhite)
    }

    static func hairline(_ contrast: ColorSchemeContrast) -> Color {
        Color.white.opacity(contrast == .increased
                            ? AuraPalette.borderWhiteHighContrast
                            : AuraPalette.borderWhite)
    }

    /// Whether a floating cockpit surface should drop transparency and render solid.
    static func prefersOpaqueSurface(reduceTransparency: Bool, _ contrast: ColorSchemeContrast) -> Bool {
        reduceTransparency || contrast == .increased
    }

    /// The scrim fill for a non-material cockpit surface over the map: solid when transparency
    /// is reduced or contrast increased, otherwise a high-opacity surface that holds secondary
    /// text even over a bright sunlit map.
    static func mapScrim(reduceTransparency: Bool, _ contrast: ColorSchemeContrast) -> Color {
        prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast)
        ? surface
        : surface.opacity(AuraPalette.mapScrimOpacity)
    }

    // MARK: - Mapbox bridge
    /// `routeLine` as a UIColor so Mapbox `StyleColor(_:)` accepts it; built from the same
    /// lime token as `accent` (was a separate 200/250/75 literal; now consistent).
    static let routeUIColor = UIColor(red: AuraPalette.lime.red,
                                      green: AuraPalette.lime.green,
                                      blue: AuraPalette.lime.blue, alpha: 1)

    // ... Spacing / Radius / CockpitFace / Typography unchanged below ...
}
```

- [ ] **Step 2: Build the app (compiles the embedded widget too)**

Delegate to the apple-platform-build-tools:builder subagent: build scheme `Aura` for `platform=iOS Simulator,name=iPhone 17`, `CODE_SIGNING_ALLOWED=NO` (the builder regenerates `Aura.xcodeproj` via xcodegen only if it is missing; no files were added, so file membership is unchanged and xcodegen is not otherwise required). Then `git checkout -- AuraCore/Package.resolved` if dirtied.
Expected: BUILD SUCCEEDED for both `Aura` and `AuraWidgets`.

- [ ] **Step 3: Lint**

Run: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 4: Commit**

```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Theme/AuraTheme.swift
git commit -m "feat(theme): build AuraTheme from AuraPalette; lift tokens; add contrast resolvers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Drop redundant opacity stacks (LastRideCard, RoutePreview)

**Files:**
- Modify: `Aura/Sources/Plan/LastRideCard.swift:32`
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift:320,329`

**Interfaces:**
- Consumes: the lifted `AuraTheme.textSecondary`/`onAccent` (Task 3). No new symbols.

- [ ] **Step 1: LastRideCard — remove the double-fade** (line 32)

Replace:
```swift
                        .foregroundStyle(AuraTheme.textSecondary.opacity(0.85))
```
with:
```swift
                        .foregroundStyle(AuraTheme.textSecondary)
```

- [ ] **Step 2: RoutePreviewView — full ink on the selected metrics + sparkline stroke** (lines 320, 329)

Replace line 320:
```swift
                        .foregroundStyle(isSelected ? AuraTheme.onAccent.opacity(0.7) : AuraTheme.textSecondary)
```
with:
```swift
                        .foregroundStyle(isSelected ? AuraTheme.onAccent : AuraTheme.textSecondary)
```

Replace line 329:
```swift
                        stroke: isSelected ? AuraTheme.onAccent.opacity(0.75) : AuraTheme.accent,
```
with:
```swift
                        stroke: isSelected ? AuraTheme.onAccent : AuraTheme.accent,
```

(Leave line 330's `fill:` as-is — it is a faint decorative area fill behind the sparkline, not text or a meaningful boundary.)

- [ ] **Step 3: Build + lint**

Delegate the app build to the builder subagent (scheme `Aura`, iPhone 17 sim, `CODE_SIGNING_ALLOWED=NO`); run `./scripts/lint.sh`.
Expected: BUILD SUCCEEDED, 0 lint violations.

- [ ] **Step 4: Commit**

```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Plan/LastRideCard.swift Aura/Sources/Plan/RoutePreviewView.swift
git commit -m "fix(contrast): drop redundant opacity on faded text and ink-on-lime

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Cockpit-over-map scrim unification + Increase-Contrast arm

**Files:**
- Modify: `Aura/Sources/Ride/SpeedRail.swift`
- Modify: `Aura/Sources/Ride/GPSSignalChip.swift`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift`
- Modify: `Aura/Sources/Ride/TripStripView.swift`
- Modify: `Aura/Sources/Theme/HUDControlButton.swift`

**Interfaces:**
- Consumes: `AuraTheme.mapScrim(reduceTransparency:_:)`, `AuraTheme.prefersOpaqueSurface(reduceTransparency:_:)` (Task 3), and `@Environment(\.colorSchemeContrast)`, `@Environment(\.accessibilityReduceTransparency)`.

- [ ] **Step 1: SpeedRail — read the environments and use the scrim helper**

Add the environment reads after the stored properties (after `var layout: Layout = .full`):
```swift
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
```
Replace the `.background(...)` (line 39):
```swift
        .background(AuraTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg))
```
with:
```swift
        .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast),
                    in: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg))
```

- [ ] **Step 2: GPSSignalChip — read the environments and use the scrim helper**

Add after `let signal: SignalQuality`:
```swift
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
```
Replace the `.background(...)` (line 15):
```swift
                .background(AuraTheme.surface.opacity(0.55), in: Capsule())
```
with:
```swift
                .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast), in: Capsule())
```
And firm the border under Increase Contrast (line 16):
```swift
                .overlay(Capsule().strokeBorder(AuraTheme.border))
```
becomes:
```swift
                .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
```

- [ ] **Step 3: NavigateHUDView — the rerouting cue**

Confirm `NavigateHUDView` reads the two environments; if absent, add alongside the existing `@Environment(\.accessibilityReduceMotion)`:
```swift
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
```
Replace the rerouting cue background (line 106):
```swift
                    .background(AuraTheme.surface.opacity(0.6), in: Capsule())
```
with:
```swift
                    .background(AuraTheme.mapScrim(reduceTransparency: reduceTransparency, contrast), in: Capsule())
```
And firm the border (line 107):
```swift
                    .overlay(Capsule().strokeBorder(AuraTheme.border))
```
becomes:
```swift
                    .overlay(Capsule().strokeBorder(AuraTheme.hairline(contrast)))
```

- [ ] **Step 4: TripStripView — go solid under Increase Contrast too**

Add after the existing `@Environment(\.accessibilityReduceMotion)`:
```swift
    @Environment(\.colorSchemeContrast) private var contrast
```
Replace the background branch condition (line 58):
```swift
        if reduceTransparency {
```
with:
```swift
        if AuraTheme.prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast) {
```

- [ ] **Step 5: HUDControlButton — go solid under Increase Contrast too**

Add after the existing `@Environment(\.accessibilityReduceMotion)`:
```swift
    @Environment(\.colorSchemeContrast) private var contrast
```
Replace the background branch condition (line 31):
```swift
        if reduceTransparency {
```
with:
```swift
        if AuraTheme.prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast) {
```

- [ ] **Step 6: Build + lint**

Delegate the app build to the builder subagent (scheme `Aura`, iPhone 17 sim). Run `./scripts/lint.sh`.
Expected: BUILD SUCCEEDED (app + widget), 0 lint violations.

- [ ] **Step 7: Commit**

```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Ride/SpeedRail.swift Aura/Sources/Ride/GPSSignalChip.swift Aura/Sources/Ride/NavigateHUDView.swift Aura/Sources/Ride/TripStripView.swift Aura/Sources/Theme/HUDControlButton.swift
git commit -m "fix(contrast): unify cockpit-over-map scrims with an Increase-Contrast arm

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Rebuild `RideSummaryView` (map-led layout + hero count-up + entrance)

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift` (full rewrite; adds a file-private `CountUpText`)

**Interfaces:**
- Consumes: `AuraTheme` roles + `Typography.metricBrand`, `StatPair(value:label:context:alignment:)`, `StaticRouteMap(coordinates:)`, `RideStatsFormatter` (incl. `distanceValue`, `distanceUnit`, `distanceUnitSpoken`, `minutes`, `elevationValue`, `speedValue(_:decimals:)`), `RideAggregator.isLongest`. No symbols produced for other tasks.

- [ ] **Step 1: Replace the whole file**

```swift
import SwiftUI
import AuraCore
import AuraKit

struct RideSummaryView: View {
    let ride: Ride
    /// When true, the ride finished but couldn't be persisted — warn the rider rather
    /// than letting it silently vanish from History.
    var saveFailed: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Environment(RideStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isLongest = false
    @State private var animatedMeters: Double = 0
    @State private var revealed = false

    // Brand (SF Pro Rounded) is fixed-size, so @ScaledMetric drives Dynamic Type for the
    // hero. (Cockpit Saira self-scales via relativeTo: — not used here.)
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44

    private var stats: RideStats { ride.stats ?? .zero }
    private var fmt: RideStatsFormatter { RideStatsFormatter(units: settings.units) }
    private var metric: Bool { settings.units == .metric }
    private var hasRoute: Bool { ride.track.count > 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xl) {
                if hasRoute {
                    StaticRouteMap(coordinates: ride.track.map(\.coordinate))
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AuraTheme.Radius.xl, style: .continuous)
                                .strokeBorder(AuraTheme.hairline(contrast), lineWidth: 1)
                        )
                        .padding(.top, AuraTheme.Spacing.lg)
                        .opacity(revealed ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: revealed)
                }

                titleBlock
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.05), value: revealed)

                heroDistance
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.10), value: revealed)

                supportingStats
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.15), value: revealed)

                Button("Done") { dismiss() }
                    .buttonStyle(.ctaPrimary)
                    .padding(.top, AuraTheme.Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AuraTheme.Spacing.xl)
            .padding(.bottom, AuraTheme.Spacing.xxxl)
        }
        .background(AuraTheme.background.ignoresSafeArea())
        .onAppear {
            computeRecord()
            startAppearance()
        }
    }

    // MARK: Sections

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
                Text("Nice ride").font(.largeTitle.bold()).foregroundStyle(AuraTheme.textPrimary)
                if let name = ride.destinationName, !name.isEmpty {
                    Text("to \(name)")
                        .font(.subheadline)
                        .foregroundStyle(AuraTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            if isLongest {
                Label("Longest ride yet", systemImage: "trophy.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AuraTheme.accent)
                    .padding(.horizontal, AuraTheme.Spacing.lg).padding(.vertical, AuraTheme.Spacing.sm)
                    .background(AuraTheme.accent.opacity(0.14), in: Capsule())
            }
            if saveFailed {
                Label("Couldn't save this ride — it won't appear in History.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(AuraTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The hero metric: distance, leading the recap. Counts up to the formatted value, with
    /// the unit and a "distance" label. Reads as one VoiceOver element using the final value.
    private var heroDistance: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
                Group {
                    if reduceMotion {
                        Text(fmt.distanceValue(stats.distanceMeters))
                    } else {
                        CountUpText(meters: animatedMeters, format: fmt.distanceValue)
                    }
                }
                .font(AuraTheme.Typography.metricBrand(heroSize))
                .monospacedDigit()
                .foregroundStyle(AuraTheme.textPrimary)

                Text(fmt.distanceUnit)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AuraTheme.textSecondary)
            }
            Text("distance")
                .font(.caption)
                .foregroundStyle(AuraTheme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Distance, \(fmt.distanceValue(stats.distanceMeters)) \(fmt.distanceUnitSpoken)")
    }

    /// The three supporting stats in an even row that reflows to a vertical stack at
    /// accessibility text sizes so nothing clips.
    private var supportingStats: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
                supportingCells
            }
            VStack(alignment: .leading, spacing: AuraTheme.Spacing.md) {
                supportingCells
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var supportingCells: some View {
        stat(fmt.minutes(stats.movingTimeSeconds), "moving")
        stat(fmt.elevationValue(stats.elevationGainMeters), metric ? "m climbed" : "ft climbed")
        stat(fmt.speedValue(stats.maxSpeedMetersPerSecond, decimals: 1), metric ? "km/h top" : "mph top")
    }

    /// One value+label metric, left-aligned, combined into a single VoiceOver element.
    private func stat(_ value: String, _ label: String) -> some View {
        StatPair(value: value, label: label, context: .brand, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    // MARK: Behavior

    private func startAppearance() {
        if reduceMotion {
            revealed = true
            animatedMeters = stats.distanceMeters
        } else {
            // `revealed` drives the per-section staggered reveal via their .animation(value:)
            // modifiers; the count-up animates the Animatable CountUpText separately.
            revealed = true
            withAnimation(.easeOut(duration: 0.7)) { animatedMeters = stats.distanceMeters }
        }
    }

    /// "Longest ride yet" when this ride's distance is the max across all saved rides (and
    /// there's more than one). Reads the lightweight `summaries()` projection rather than
    /// faulting every ride's externally-stored track.
    private func computeRecord() {
        let summaries = (try? store.summaries()) ?? []
        isLongest = RideAggregator.isLongest(rideID: ride.id,
                                             distanceMeters: stats.distanceMeters,
                                             among: summaries)
    }
}

/// A number that ticks up to its target: SwiftUI interpolates `meters` (its `animatableData`)
/// each frame and the body re-formats with the screen's own formatter, so the final frame is
/// byte-identical to the static value (no visible snap). Reduce Motion uses a plain Text instead.
private struct CountUpText: View, Animatable {
    var meters: Double
    var format: (Double) -> String

    var animatableData: Double {
        get { meters }
        set { meters = newValue }
    }

    var body: some View { Text(format(meters)) }
}
```

- [ ] **Step 2: Build the app**

Delegate to the builder subagent: build scheme `Aura` for iPhone 17 sim, `CODE_SIGNING_ALLOWED=NO`. `git checkout -- AuraCore/Package.resolved` if dirtied.
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Lint**

Run: `./scripts/lint.sh`
Expected: 0 violations.

- [ ] **Step 4: Commit**

```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(summary): map-led ride summary with hero distance count-up

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Simulator verification (visual + measured + accessibility)

**Files:** none (verification only).

This task is not complete until the screens are seen, not just built. Delegate simulator
operations to the builder subagent; pin the install path from `showBuildSettings`, not mtime.

- [ ] **Step 1: Install the freshly built app**

Get the authoritative path: `cd Aura && xcodebuild -showBuildSettings -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' | grep -m1 TARGET_BUILD_DIR`. Install that `Aura.app` onto the booted iPhone 17 (UDID from `xcrun simctl list devices booted`). The bundle id is `app.aura.ios`.

- [ ] **Step 2: Drive to the ride summary and screenshot**

Launch the app, start and end a free ride (or use the GPX sample) to reach `RideSummaryView`. Capture a real screenshot. If the screenshot md5 matches a prior frame, `xcrun simctl shutdown <udid> && xcrun simctl boot <udid>`, relaunch, and re-capture. Confirm: hero distance leads, the three supporting stats sit in one row, the layout is left-aligned, no orphan, the count-up settled on the correct value.

- [ ] **Step 3: Accessibility + Dynamic Type passes**

Via the accessibility tree and screenshots, confirm: VoiceOver reads the hero as one element ("Distance, …"); at the largest accessibility Dynamic Type size the supporting row reflows to a vertical stack with no clipping; with Reduce Motion on, the summary appears instantly with the final distance; with Increase Contrast on, the cockpit scrims render solid and `textSecondary` strengthens (compare a Navigate HUD / free-ride HUD screenshot with Increase Contrast off vs on).

- [ ] **Step 4: Measured contrast audit**

Re-run the WCAG numbers for the shipped tokens (the `AuraPaletteContrastTests` already assert these in CI) and spot-check the over-map cockpit text against a bright map screenshot region using the Accessibility Inspector or a sampled-pixel ratio. Record the numbers.

- [ ] **Step 5: Note results**

Write a short pass/fail note (what was seen, the screenshots, the measured ratios). No commit.

---

### Task 8: Mark the sub-project shipped in the ROADMAP

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Update the Wave 2 bullet and header**

In the Wave 2 section, replace the open SP3 line:
```
- Redesign the ride summary away from the orphaned stat stack into a balanced grid or a
  true hero metric, and lift the borderline contrast values across the app.
```
with a SHIPPED bullet describing what landed (map-led summary retiring the orphan; the hybrid contrast lift: AuraPalette + WCAGContrast CI guard, textSecondary 0.55→0.62, border firmed, cockpit-over-map scrims unified, a scoped Increase-Contrast path; verified on the iPhone 17 / iOS 26 sim). Update the Wave 2 heading to `### Wave 2 — The cockpit the spec promised — COMPLETE (2026-06-26)` and note all four items / three sub-projects shipped. Also update the two audit-finding paragraphs ("There is no design system…" and "Accessibility is strong on motion…") to mark their remaining open pieces resolved.

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): mark the ride-summary redesign + contrast lift shipped; Wave 2 complete

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage:**
- Map-led summary + hero distance + supporting row + retire orphan → Task 6. ✓
- Light Reduce-Motion-safe entrance + count-up → Task 6 (`CountUpText`, `revealed`, `reduceMotion`). ✓
- Token bumps (textSecondary 0.62, border 0.14, scrim 0.85) → Task 2 (`AuraPalette`) + Task 3 (`AuraTheme`). ✓
- Increase-Contrast resolvers + scoped application → Task 3 + Task 5. ✓
- Per-view fixes (LastRideCard, RoutePreview, cockpit scrims) → Tasks 4–5. ✓
- Pure WCAGContrast + AuraPalette with CI-guarded contrast → Tasks 1–2. ✓
- Verification (screenshots, measured audit, Increase Contrast, Reduce Motion, Dynamic Type) → Task 7. ✓
- ROADMAP / Wave 2 complete → Task 8. ✓
- StatPair stays on the static token (not the resolver) → honored in Task 6 (`StatPair` unchanged; uses `AuraTheme.textSecondary`). ✓
- Title/warning flip centered→leading → Task 6 (titleBlock is `.leading`; destination drops `.multilineTextAlignment`). ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; no "similar to Task N".

**Type consistency:** `RGBColor`/`WCAGContrast` (Task 1) consumed by `AuraPalette` (Task 2) and `AuraTheme` (Task 3); resolver signatures (`secondaryText(_:)`, `hairline(_:)`, `prefersOpaqueSurface(reduceTransparency:_:)`, `mapScrim(reduceTransparency:_:)`) defined in Task 3 and used verbatim in Task 5; `CountUpText(meters:format:)` defined and used within Task 6; `fmt.distanceUnitSpoken` exists (added in the Wave 2 VoiceOver sub-project).

**Lint pre-check:** No 3+ member tuples (used `RGBColor`); single spaces before `{`; lines ≤140.

## Execution handoff

Plan complete and saved. Execution: subagent-driven-development (fresh subagent per task + per-task spec-compliance and code-quality reviews), per the session's autonomous mandate.
