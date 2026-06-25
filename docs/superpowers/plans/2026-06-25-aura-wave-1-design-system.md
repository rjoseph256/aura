# Wave 1 design-system implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ad-hoc `AuraTheme` color sheet with a real design system (semantic color roles, spacing/radius scales, a type ramp, four extracted components) and adopt the new mono-lime identity, migrating every screen.

**Architecture:** Additive then migratory. First add the new token API and components alongside the old symbols so the app keeps compiling, then migrate screens file-group by file-group (each change set builds and lints green), then delete the deprecated symbols last. The new identity is one accent (lime) on near-black, pink reserved for end-ride, no gradients; cockpit vs chrome differ by type and density, not color.

**Tech stack:** SwiftUI (iOS 26 / Swift 6), XcodeGen + xcodebuild, SwiftLint, Saira Condensed (SIL OFL, bundled), SF Pro Rounded + SF Symbols (system), Mapbox.

**Relevant skills:** @impeccable (design quality / audit / polish), @all-ios-skills:swiftui-patterns (ButtonStyle, ViewModifier, view composition), @all-ios-skills:ios-accessibility (Reduce Transparency, Dynamic Type), @all-ios-skills:swiftui-layout-components, @apple-platform-build-tools:builder (delegate the app build/verify).

---

## Reconnaissance baseline (trust this; measured on this worktree)

- **Toolchain:** Swift 6.2.4 / Xcode 26.3, iPhone 17 / iOS 26.3 simulator present. SwiftLint 0.64.1. The CI `xcodebuild build -scheme Aura` + `swiftlint --strict` gates exist (from the quality-gates sub-project).
- **`AuraTheme.swift`** (app target, `Aura/Sources/Theme/AuraTheme.swift`, shared into `AuraWidgets` by membership) currently exposes: `bg, surface, cyan, violet, pink, route, text, muted, auroraGradient, heroNumber(_:), unitLabel`.
- **Token usage to migrate (~180):** muted 41, text 35, cyan 23, surface 17, route 16, bg 14, auroraGradient 10, pink 6, violet 5, unitLabel 2, heroNumber 1.
- **Route color literals (4 files):** `RoutePreviewView.swift:68`, `StaticRouteMap.swift:25`, `RideMapView.swift:21`, `NavigateHUDView.swift:187` — each `StyleColor(UIColor(red: 43/255, green: 224/255, blue: 138/255, alpha: 1))`.
- **`.ultraThinMaterial` (3 floating circle controls, no RT fallback):** `RoutePreviewView.swift:87` (close), `RideHUDView.swift:93` (info/back), `NavigateHUDView.swift:230` (close/mute).
- **Info.plist:** both `Aura/Resources/Info.plist` and `Aura/Widgets/Info.plist` exist, both `GENERATE_INFOPLIST_FILE: NO`, neither has `UIAppFonts`.
- **Saira Condensed** available (HTTP 200) at `https://raw.githubusercontent.com/google/fonts/main/ofl/sairacondensed/` — `OFL.txt`, `SairaCondensed-Medium.ttf`, `SairaCondensed-SemiBold.ttf`, `SairaCondensed-Bold.ttf`.

## Cross-cutting rules

- **Stage only the files each task names.** NEVER `git add AuraCore/Package.resolved`; revert it if `xcodebuild` dirties it (`git checkout -- AuraCore/Package.resolved`). Do not commit `Aura/Aura.xcodeproj` (generated) or `Aura/Resources/MapboxAccessToken` (gitignored).
- **Keep the gates green.** Every task ends with `xcodebuild build -scheme Aura` succeeding and `./scripts/lint.sh` clean before committing. Migration tasks also do a simulator visual spot-check of the screens they touched (boot iPhone 17, launch `app.aura.ios`, eyeball or screenshot).
- **Commit messages** end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- **Build command** (run from `Aura/`, after `xcodegen generate` if project.yml changed): `xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`. Delegate to @apple-platform-build-tools:builder to keep logs out of context, or run directly with a long timeout (Mapbox build is heavy).
- **Behavior preserved; look intentionally changes.** No functional/logic changes — only theming, token, and component swaps. Verify visually.

## Migration map (reference for Tasks 6-9)

| Old symbol | New role | Notes |
|---|---|---|
| `AuraTheme.bg` | `AuraTheme.background` | value refines #08090F → #07080C |
| `AuraTheme.surface` | `AuraTheme.surface` | same name, value updated |
| `AuraTheme.text` | `AuraTheme.textPrimary` | |
| `AuraTheme.muted` | `AuraTheme.textSecondary` | |
| `AuraTheme.cyan` | `AuraTheme.accent` | cyan → lime (the reskin) |
| `AuraTheme.violet` | `AuraTheme.accent` (or `.textSecondary`) | per context; violet retired |
| `AuraTheme.pink` | `AuraTheme.destructive` | end-ride/delete; pink kept as destructive only |
| `AuraTheme.route` | `AuraTheme.routeLine` | green → lime |
| `AuraTheme.auroraGradient` | solid `AuraTheme.accent` (via `CTAButtonStyle` for buttons; lime stroke for the ring) | gradient retired |
| `AuraTheme.heroNumber(_:)` | `SpeedReadout` (cockpit) or `AuraTheme.Typography.metricBrand(_:)` (chrome) | |
| `AuraTheme.unitLabel` | `AuraTheme.Typography.unit` | |
| numeric `cornerRadius`/literal | nearest `AuraTheme.Radius.*` | 6→sm(8), 11→md(12), 14→lg(16)or md, 18→xl(20)or lg |
| numeric `.padding`/`spacing:` | nearest `AuraTheme.Spacing.*` | snap to nearest 4-pt step |
| `.font(...)` literal | nearest `AuraTheme.Typography` role | |

---

## Task 1: Token foundation (additive)

Add the new token API to `AuraTheme` without removing the old symbols, so the app keeps compiling. Consult @all-ios-skills:swiftui-patterns.

**Files:** Modify `Aura/Sources/Theme/AuraTheme.swift`

- [ ] **Step 1: Rewrite AuraTheme additively.** Replace the file with:

```swift
import SwiftUI

enum AuraTheme {
    // MARK: - Private palette (raw values — views use the roles below, never these)
    private enum Palette {
        static let nearBlack = Color(red: 0.027, green: 0.031, blue: 0.047) // #07080C
        static let panel     = Color(red: 0.055, green: 0.063, blue: 0.078) // #0E1014
        static let lime      = Color(red: 0.784, green: 0.980, blue: 0.294) // #C8FA4B
        static let pink      = Color(red: 1.0,   green: 0.302, blue: 0.616) // #FF4D9D
        static let inkOnLime = Color(red: 0.086, green: 0.129, blue: 0.039) // #16210A
        static let inkOnPink = Color(red: 0.165, green: 0.012, blue: 0.078) // #2A0314
    }

    // MARK: - Color roles
    static let background    = Palette.nearBlack
    static let surface       = Palette.panel
    static let textPrimary   = Color(white: 0.92)
    static let textSecondary = Color(white: 0.55)
    static let accent        = Palette.lime
    static let routeLine     = Palette.lime
    static let destructive   = Palette.pink
    static let onAccent      = Palette.inkOnLime
    static let onDestructive = Palette.inkOnPink

    // MARK: - Spacing scale (pt)
    enum Spacing {
        static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16
        static let xl: CGFloat = 20, xxl: CGFloat = 24, xxxl: CGFloat = 32
    }

    // MARK: - Radius scale (pt)
    enum Radius {
        static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 20
    }

    // MARK: - Typography roles (cockpit Saira variants added in Task 2)
    enum Typography {
        /// Brand numerals (chrome): SF Pro Rounded. Pass a @ScaledMetric size for Dynamic Type.
        static func metricBrand(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static let unit = Font.system(.caption2, design: .rounded).weight(.bold)
        static func title(_ style: Font.TextStyle = .title2) -> Font {
            .system(style, design: .rounded).weight(.semibold)
        }
    }

    // MARK: - Deprecated — removed in the final cleanup task once all call sites migrate.
    static let bg = background
    static let cyan   = Palette.lime
    static let violet = Palette.lime
    static let pink   = destructive
    static let route  = Palette.lime
    static let text   = textPrimary
    static let muted  = textSecondary
    static let auroraGradient = LinearGradient(colors: [accent, accent], startPoint: .leading, endPoint: .trailing)
    static func heroNumber(_ size: CGFloat = 52) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static let unitLabel = Typography.unit
}
```

Note: the deprecated aliases now point at the NEW values (cyan/violet/route → lime, bg → background, auroraGradient → a flat lime "gradient"), so even before a screen is migrated it already shows the new identity. This makes the reskin land progressively and keeps every intermediate build coherent.

- [ ] **Step 2: Build + lint.**
```bash
cd Aura && xcodegen generate >/dev/null && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3; cd ..
./scripts/lint.sh
```
Expected: `** BUILD SUCCEEDED **`, lint 0 violations. (xcodegen only needed if project.yml changed; harmless here.)

- [ ] **Step 3: Commit.**
```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Theme/AuraTheme.swift
git commit -m "feat(theme): add design-system token roles, scales, and type ramp

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Bundle Saira Condensed + cockpit type roles

Download and register the font in both targets, then add the cockpit type roles. Consult @all-ios-skills:ios-accessibility (Dynamic Type via `@ScaledMetric` / `relativeTo:`).

**Files:** Create `Aura/Resources/Fonts/SairaCondensed-{Medium,SemiBold,Bold}.ttf`, `Aura/Resources/Fonts/SairaCondensed-OFL.txt`; Modify `Aura/Resources/Info.plist`, `Aura/Widgets/Info.plist`, `Aura/project.yml`, `Aura/Sources/Theme/AuraTheme.swift`.

- [ ] **Step 1: Download the font + license.**
```bash
mkdir -p Aura/Resources/Fonts
base=https://raw.githubusercontent.com/google/fonts/main/ofl/sairacondensed
for w in Medium SemiBold Bold; do curl -fsSL "$base/SairaCondensed-$w.ttf" -o "Aura/Resources/Fonts/SairaCondensed-$w.ttf"; done
curl -fsSL "$base/OFL.txt" -o Aura/Resources/Fonts/SairaCondensed-OFL.txt
ls -la Aura/Resources/Fonts
```

- [ ] **Step 2: Verify the PostScript names** (needed for `Font.custom`):
```bash
for f in Aura/Resources/Fonts/SairaCondensed-*.ttf; do echo "$f:"; mdls -name com_apple_ats_name_postscript "$f" 2>/dev/null || true; done
```
Expected names like `SairaCondensed-SemiBold`. If they differ, use the reported names in Step 5.

- [ ] **Step 3: Register `UIAppFonts` in both Info.plists.** Add to `Aura/Resources/Info.plist` and `Aura/Widgets/Info.plist` (inside the top-level `<dict>`):
```xml
<key>UIAppFonts</key>
<array>
  <string>SairaCondensed-Medium.ttf</string>
  <string>SairaCondensed-SemiBold.ttf</string>
  <string>SairaCondensed-Bold.ttf</string>
</array>
```

- [ ] **Step 4: Bundle the fonts in both targets** in `Aura/project.yml`. Add the Fonts folder to the `Aura` target sources (resources) and the `AuraWidgets` target sources so both copy the fonts:
  - Under the `Aura` target `sources:`, add `- path: Resources/Fonts` (it will be classified as a resource).
  - Under the `AuraWidgets` target `sources:`, add `- path: Resources/Fonts`.
  Then `cd Aura && xcodegen generate`.

- [ ] **Step 5: Add cockpit type roles** to `AuraTheme.Typography` (use the verified PostScript family). Saira Condensed is registered by family name "Saira Condensed":
```swift
        /// Cockpit numerals (Saira Condensed). Pass a @ScaledMetric size for Dynamic Type.
        static func metricCockpit(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
            .custom("Saira Condensed", size: size, relativeTo: style).weight(.bold)
        }
        static func speedHero(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
            .custom("Saira Condensed", size: size, relativeTo: style).weight(.bold)
        }
```

- [ ] **Step 6: Verify the font loads at runtime.** Build, install, launch on the sim, and confirm the family registers:
```bash
cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3; cd ..
```
Then on a booted iPhone 17 sim, after installing, confirm `UIFont.familyNames` contains "Saira Condensed" (a one-off check via a temporary debug print, or visually once a cockpit screen is migrated in Task 8). Lint: `./scripts/lint.sh`.

- [ ] **Step 7: Commit.**
```bash
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Resources/Fonts Aura/Resources/Info.plist Aura/Widgets/Info.plist Aura/project.yml Aura/Sources/Theme/AuraTheme.swift
git commit -m "feat(theme): bundle Saira Condensed (OFL) and add cockpit type roles

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Button components (`CTAButtonStyle`, `HUDControlButton`)

Consult @all-ios-skills:swiftui-patterns (ButtonStyle) and @all-ios-skills:ios-accessibility (Reduce Transparency).

**Files:** Create `Aura/Sources/Theme/CTAButtonStyle.swift`, `Aura/Sources/Theme/HUDControlButton.swift`.

- [ ] **Step 1: `CTAButtonStyle`** with the refined hierarchy (radius lg, weight 600/`.semibold`, ~50pt primary, reduce-motion-aware press):
```swift
import SwiftUI

struct CTAButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, tertiary, destructive }
    var variant: Variant = .primary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded).weight(.semibold))
            .frame(maxWidth: variant == .tertiary ? nil : .infinity)
            .frame(height: variant == .tertiary ? 40 : 50)
            .padding(.horizontal, variant == .tertiary ? AuraTheme.Spacing.md : AuraTheme.Spacing.lg)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return AuraTheme.onAccent
        case .destructive: return AuraTheme.onDestructive
        case .secondary, .tertiary: return AuraTheme.accent
        }
    }
    @ViewBuilder private var background: some View {
        switch variant {
        case .primary: AuraTheme.accent
        case .destructive: AuraTheme.destructive
        case .secondary: RoundedRectangle(cornerRadius: AuraTheme.Radius.lg, style: .continuous).strokeBorder(AuraTheme.accent, lineWidth: 1.5)
        case .tertiary: Color.clear
        }
    }
}

extension ButtonStyle where Self == CTAButtonStyle {
    static var ctaPrimary: CTAButtonStyle { .init(variant: .primary) }
    static var ctaSecondary: CTAButtonStyle { .init(variant: .secondary) }
    static var ctaTertiary: CTAButtonStyle { .init(variant: .tertiary) }
    static var ctaDestructive: CTAButtonStyle { .init(variant: .destructive) }
}
```

- [ ] **Step 2: `HUDControlButton`** — the floating circular control with the Reduce Transparency fallback:
```swift
import SwiftUI

struct HUDControlButton: ButtonStyle {
    var isActive = false
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(isActive ? AuraTheme.accent : AuraTheme.textPrimary)
            .frame(width: size, height: size)
            .background(backgroundView)
            .clipShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    @ViewBuilder private var backgroundView: some View {
        if reduceTransparency {
            AuraTheme.surface
        } else {
            Color.clear.background(.ultraThinMaterial)
        }
    }
}

extension ButtonStyle where Self == HUDControlButton {
    static var hudControl: HUDControlButton { .init() }
    static func hudControl(active: Bool) -> HUDControlButton { .init(isActive: active) }
}
```

- [ ] **Step 3: Add both files to `AuraWidgets` membership** if the widget will use them (the Live Activity may use `HUDControlButton`-style chrome — if not needed, skip). For now add `CTAButtonStyle.swift`/`HUDControlButton.swift` only to the app target; revisit in Task 9 if the widget needs them.

- [ ] **Step 4: Build + lint + commit.**
```bash
cd Aura && xcodebuild build -project Aura.xcodeproj -scheme Aura -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3; cd ..
./scripts/lint.sh
git checkout -- AuraCore/Package.resolved 2>/dev/null || true
git add Aura/Sources/Theme/CTAButtonStyle.swift Aura/Sources/Theme/HUDControlButton.swift Aura/project.yml
git commit -m "feat(theme): add CTAButtonStyle hierarchy and HUDControlButton with Reduce Transparency fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Metric components (`SpeedReadout`, `StatPair`)

**Files:** Create `Aura/Sources/Theme/SpeedReadout.swift`, `Aura/Sources/Theme/StatPair.swift` (add both to `AuraWidgets` membership in project.yml — the Live Activity uses them in Task 9).

- [ ] **Step 1: `StatPair`** (value over label, context-aware):
```swift
import SwiftUI

struct StatPair: View {
    enum Context { case cockpit, brand }
    let value: String
    let label: String
    var context: Context = .brand
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 21

    var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            Text(value)
                .font(context == .cockpit ? AuraTheme.Typography.metricCockpit(valueSize, relativeTo: .title2)
                                          : AuraTheme.Typography.metricBrand(valueSize))
                .foregroundStyle(AuraTheme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }
}
```

- [ ] **Step 2: `SpeedReadout`** (the big cockpit speed + lime unit):
```swift
import SwiftUI

struct SpeedReadout: View {
    let value: String
    let unit: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 62

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.sm) {
            Text(value)
                .font(AuraTheme.Typography.speedHero(size, relativeTo: .largeTitle))
                .foregroundStyle(AuraTheme.textPrimary)
            Text(unit)
                .font(AuraTheme.Typography.unit)
                .foregroundStyle(AuraTheme.accent)
        }
    }
}
```

- [ ] **Step 3: Build + lint + commit** (same pattern; stage the two files + project.yml).

---

## Task 5: Route color bridge

Add a Mapbox `StyleColor` derived from `routeLine` and replace the four hardcoded literals. The bridge can't import SwiftUI Color into Mapbox directly, so define a `UIColor`-based constant.

**Files:** Modify `Aura/Sources/Theme/AuraTheme.swift` (add bridge); Modify `RoutePreviewView.swift:68`, `StaticRouteMap.swift:25`, `RideMapView.swift:21`, `NavigateHUDView.swift:187`.

- [ ] **Step 1: Add the bridge** to AuraTheme (uses UIColor so Mapbox `StyleColor(_:)` accepts it; lime = #C8FA4B = RGB 200/250/75):
```swift
    // MARK: - Mapbox bridge
    static let routeUIColor = UIColor(red: 200/255, green: 250/255, blue: 75/255, alpha: 1)
```
(Add `import UIKit` if needed; `AuraTheme.swift` already imports SwiftUI which re-exports UIKit on iOS.)

- [ ] **Step 2: Replace each literal.** In each of the four files, replace `StyleColor(UIColor(red: 43 / 255, green: 224 / 255, blue: 138 / 255, alpha: 1))` with `StyleColor(AuraTheme.routeUIColor)`. Remove the now-stale `// TODO(Wave 2)` comment at `NavigateHUDView.swift:186`.

- [ ] **Step 3: Build + lint + sim check** (the route polyline renders lime on the preview and ride maps), then commit the 5 files.

---

## Task 6: Migrate chrome — Plan area

Apply the migration map to the planning surfaces. Behavior unchanged; colors→roles, fonts→type roles, literals→scales, gradient CTAs→`CTAButtonStyle`, value+label stacks→`StatPair(context: .brand)`, the floating close button→`HUDControlButton`, the goal ring stroke→lime at ~6pt.

**Files:** `Aura/Sources/Plan/PlanView.swift`, `RoutePreviewView.swift`, `DestinationSearchView.swift`, `LastRideCard.swift`, `WeeklyRing.swift`, `ElevationSparkline.swift`, `Aura/Sources/Shared/RouteThumbnail.swift`, `Aura/Sources/Ride/StaticRouteMap.swift`.

- [ ] **Step 1:** Migrate each file per the map. Specifics: PlanView "Free ride" → `.buttonStyle(.ctaPrimary)`; RoutePreviewView start button → `.ctaPrimary`, back/close circle → `HUDControlButton`, its route already bridged (Task 5); WeeklyRing ring stroke → `AuraTheme.accent`, lineWidth ~6; snap radii/spacing to `AuraTheme.Radius`/`.Spacing`.
- [ ] **Step 2:** `xcodebuild build` succeeds; `./scripts/lint.sh` clean.
- [ ] **Step 3:** Sim spot-check: launch, open Plan, push a route preview — confirm lime CTAs/ring, no aurora gradient, layout intact.
- [ ] **Step 4:** Commit the group.

---

## Task 7: Migrate chrome — Summary, History, Settings, Offline, Permission

**Files:** `Aura/Sources/Ride/RideSummaryView.swift`, `Aura/Sources/History/HistoryView.swift`, `Aura/Sources/Settings/SettingsView.swift`, `AttributionView.swift`, `Aura/Sources/Offline/OfflineMapsView.swift`, `Aura/Sources/Location/LocationPermissionView.swift`.

- [ ] **Step 1:** Migrate per the map. RideSummaryView: replace the inline `stat()` helper with `StatPair(context: .brand)`, "Done" → `.ctaPrimary`, route map already bridged; the finish marker stays `AuraTheme.destructive` (pink). HistoryView numerals → `metricBrand`; LocationPermissionView CTA → `.ctaPrimary`, "Not now" → `.ctaTertiary`.
- [ ] **Step 2-4:** Build, lint, sim spot-check (Summary stat grid, History list, Settings), commit.

---

## Task 8: Migrate cockpit screens

The instrument personality: Saira Condensed via `SpeedReadout`/`StatPair(context: .cockpit)`, lime accents, `HUDControlButton` + Reduce Transparency fallback, lime route. Consult @all-ios-skills:ios-accessibility.

**Files:** `Aura/Sources/Ride/RideHUDView.swift`, `NavigateHUDView.swift`, `SpeedRail.swift`, `TurnCardView.swift`, `RideMapView.swift` (route bridged in Task 5; confirm), `GPSSignalChip.swift`.

- [ ] **Step 1:** SpeedRail → use `SpeedReadout` (replaces `AuraTheme.heroNumber`/`unitLabel`); HUD stat row → `StatPair(context: .cockpit)`; the floating back/mute/info buttons → `.buttonStyle(HUDControlButton())` (active state lime); end-ride button → `.ctaDestructive`; turn-card maneuver distance → `metricCockpit` in lime; snap spacing/radii. Confirm the Reduce Transparency fallback path compiles and renders (toggle the setting in the sim).
- [ ] **Step 2-4:** Build, lint, sim spot-check both a free ride and a navigate session (confirm Saira numerals, lime, RT fallback when enabled), commit.

---

## Task 9: Migrate the Live Activity (widget)

**Files:** `Aura/Widgets/RideLiveActivity.swift`, `RideLockScreenView.swift`, `RideActivityComponents.swift` (and add any component files they use to `AuraWidgets` membership if not already).

- [ ] **Step 1:** Apply roles + cockpit type (Saira is bundled in the widget from Task 2). Replace the aurora gradient usage (`RideActivityComponents`) with solid `AuraTheme.accent`. Numerals → `metricCockpit`/`StatPair(.cockpit)`; route/active → lime; end/destructive → pink.
- [ ] **Step 2:** Build (the app build compiles the embedded widget); lint.
- [ ] **Step 3:** Sim check the Live Activity if feasible (start a ride; otherwise confirm via build + the widget preview). Commit.

---

## Task 10: Remove deprecated symbols + final audit + roadmap

**Files:** `Aura/Sources/Theme/AuraTheme.swift`, `docs/ROADMAP.md`.

- [ ] **Step 1: Confirm no references remain** to the deprecated symbols:
```bash
grep -rn "AuraTheme\.\(bg\|cyan\|violet\|route\b\|text\b\|muted\|auroraGradient\|heroNumber\|unitLabel\)\|AuraTheme.pink" Aura/Sources Aura/Widgets || echo "none remain"
```
Fix any stragglers. (`AuraTheme.surface` stays — it's a current role.)
- [ ] **Step 2: Delete the `// Deprecated` block** from `AuraTheme.swift`.
- [ ] **Step 3: Build + lint.**
- [ ] **Step 4: Final design pass** — run an impeccable `audit`/`polish` lens over screenshots of the migrated cockpit and chrome screens from the sim; fix any contrast/spacing nits surfaced (must stay AA; re-check any new color-on-color pair).
- [ ] **Step 5: Update `docs/ROADMAP.md`** — mark the Wave 1 design-system item shipped (2026-06-25): mono-lime identity, semantic roles + scales + type ramp, the four components, Saira Condensed bundled, Reduce Transparency fallback added; note the custom Mapbox map style remains a deferred fast-follow and the Wave 2 contrast/VoiceOver work is still pending. Run the prose through the @humanizer lens.
- [ ] **Step 6: Commit** the cleanup + roadmap.

---

## Done criteria

- `AuraTheme` exposes only roles, scales, type roles, and the Mapbox bridge; no deprecated symbols remain.
- Saira Condensed bundled and registered in both targets; cockpit numerals render in it.
- The four components exist and are adopted across the screens.
- The route line is lime everywhere via the bridge; no hardcoded route literals remain.
- `xcodebuild build -scheme Aura` and `swiftlint --strict` are green; package tests still pass (`cd AuraCore && swift test`).
- Both personalities verified on the simulator; Reduce Transparency fallback confirmed.
- `docs/ROADMAP.md` reflects the shipped design system.
- No runtime behavior changed; `AuraCore/Package.resolved` unmodified.
