# Shareable Ride-Summary Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a rider share a 1080×1350 PNG "instrument card" of a finished ride from the ride-summary screen via the native share sheet.

**Architecture:** A pure `ShareCardContent` value type (AuraKit) resolves a `Ride` + units into display-ready strings and the route/elevation series, unit-tested with no app target. A fixed-size SwiftUI `ShareCardView` (app) projects it; `RideCardRenderer` (app) renders it offscreen through `ImageRenderer` to a PNG temp file; `RideSummaryView` gains a Share button that hands that file to `ShareLink`. The card uses only Canvas-based renderers (`RouteThumbnail`, `ElevationSparkline`) so it draws correctly offscreen (the Mapbox map cannot).

**Tech Stack:** Swift 6, SwiftUI, `ImageRenderer` (iOS 16+), `ShareLink`/`SharePreview`, Swift Testing. Deployment target iOS 17.

## Global Constraints

- Swift 6 language mode on all targets; `ShareCardContent` must be `Sendable`.
- Three layers: AuraCore (pure), AuraKit (stores/formatting; depends only on AuraCore), Aura (app; SwiftUI/Mapbox). Card image rendering is app-target only.
- Every visual value comes from `AuraTheme`/`AuraPalette` tokens. No gradients. One lime accent, spent only on the route line + elevation trace.
- The card always uses the high-contrast secondary text value (`AuraPalette.textSecondaryWhiteHighContrast`, 0.80) for text over the scrim and the elevation caption; reused `StatPair` labels (0.62) sit on the near-black band where they already clear 7.48:1.
- No top-speed / average-speed on the card.
- Gates before any task is "done": `cd AuraCore && swift test` green; `swiftlint lint --strict` clean (line ≤140 warn / 200 err; `void_function_in_ternary` is an error); app builds via `xcodegen generate` + `xcodebuild` on iPhone 17 sim.
- Copy the Mapbox token into the worktree (`Aura/Resources/MapboxAccessToken`) and run `xcodegen generate` before any local build (both are gitignored).

---

### Task 1: `ShareCardContent` (pure, AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift`
- Test: `AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift`

**Interfaces:**
- Consumes: `Ride`, `TrackPoint`, `Coordinate`, `RideStats` (AuraCore); `DistanceUnits`, `RideStatsFormatter` (AuraKit).
- Produces: `public struct ShareCardContent: Equatable, Sendable` with `init(ride:units:locale:timeZone:)` and stored `distanceValue/distanceUnit/movingTime/climbedValue/climbedUnit/dateText: String`, `destinationName: String?`, `routeCoordinates: [Coordinate]`, `elevationSamples: [Double]`.

- [ ] **Step 1: Write the failing tests**

```swift
// AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ShareCardContentTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")
    /// 2026-07-01T12:00:00Z
    private let startedAt = Date(timeIntervalSince1970: 1_782_907_200)

    private func stats(distance: Double = 8046.72, moving: Double = 2520,
                       climb: Double = 73.152) -> RideStats {
        RideStats(distanceMeters: distance, movingTimeSeconds: moving,
                  averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 9,
                  elevationGainMeters: climb)
    }

    private func point(_ lat: Double, _ lon: Double, elevation: Double? = nil) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: elevation, timestamp: startedAt)
    }

    private func ride(track: [TrackPoint] = [], stats: RideStats? = nil,
                      destination: String? = nil) -> Ride {
        Ride(kind: .freeRide, startedAt: startedAt, endedAt: nil, track: track,
             stats: stats, destinationName: destination, routeId: nil, destinationPlaceId: nil)
    }

    @Test func imperialStrings() {
        let c = ShareCardContent(ride: ride(stats: stats()), units: .imperial,
                                 locale: posix, timeZone: utc)
        #expect(c.distanceValue == "5.0")       // 8046.72 m -> 5.0 mi
        #expect(c.distanceUnit == "mi")
        #expect(c.movingTime == "42 min")        // 2520 s
        #expect(c.climbedValue == "240")         // 73.152 m -> 240 ft
        #expect(c.climbedUnit == "ft")
    }

    @Test func metricStrings() {
        let c = ShareCardContent(ride: ride(stats: stats()), units: .metric,
                                 locale: posix, timeZone: utc)
        #expect(c.distanceValue == "8.0")        // 8046.72 m -> 8.0 km
        #expect(c.distanceUnit == "km")
        #expect(c.climbedValue == "73")          // meters, rounded
        #expect(c.climbedUnit == "m")
    }

    @Test func dateTextIsDeterministic() {
        let c = ShareCardContent(ride: ride(stats: stats()), units: .imperial,
                                 locale: posix, timeZone: utc)
        #expect(c.dateText == "Jul 1, 2026")
    }

    @Test func elevationRequiresTwoSamples() {
        let two = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 20)], stats: stats())
        #expect(ShareCardContent(ride: two, units: .imperial).elevationSamples == [10, 20])

        let one = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: nil)], stats: stats())
        #expect(ShareCardContent(ride: one, units: .imperial).elevationSamples.isEmpty)

        let none = ride(track: [point(0, 0), point(1, 1)], stats: stats())
        #expect(ShareCardContent(ride: none, units: .imperial).elevationSamples.isEmpty)
    }

    @Test func routeRequiresTwoPoints() {
        let multi = ride(track: [point(0, 0), point(1, 1)], stats: stats())
        #expect(ShareCardContent(ride: multi, units: .imperial).routeCoordinates.count == 2)

        let single = ride(track: [point(0, 0)], stats: stats())
        #expect(ShareCardContent(ride: single, units: .imperial).routeCoordinates.isEmpty)
    }

    @Test func destinationTrimmedAndNilled() {
        #expect(ShareCardContent(ride: ride(stats: stats(), destination: "  Millvale "),
                                 units: .imperial).destinationName == "Millvale")
        #expect(ShareCardContent(ride: ride(stats: stats(), destination: "   "),
                                 units: .imperial).destinationName == nil)
        #expect(ShareCardContent(ride: ride(stats: stats()), units: .imperial).destinationName == nil)
    }

    @Test func statsNilProducesZeroedStrings() {
        let c = ShareCardContent(ride: ride(stats: nil), units: .imperial,
                                 locale: posix, timeZone: utc)
        #expect(c.distanceValue == "0.0")
        #expect(c.movingTime == "0 min")
        #expect(c.climbedValue == "0")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AuraCore && swift test --filter ShareCardContentTests`
Expected: FAIL — `cannot find 'ShareCardContent' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift
import Foundation
import AuraCore

/// Everything the shareable ride card renders, resolved to display-ready primitives in the
/// pure layer so the branching (units, has-elevation, has-route, has-destination) is unit
/// tested without the app target. The SwiftUI card view is a dumb projection of this.
public struct ShareCardContent: Equatable, Sendable {
    public let distanceValue: String
    public let distanceUnit: String
    public let movingTime: String
    public let climbedValue: String
    public let climbedUnit: String
    public let dateText: String
    public let destinationName: String?
    public let routeCoordinates: [Coordinate]
    public let elevationSamples: [Double]

    public init(ride: Ride, units: DistanceUnits,
                locale: Locale = .current, timeZone: TimeZone = .current) {
        let fmt = RideStatsFormatter(units: units)
        let stats = ride.stats ?? .zero
        distanceValue = fmt.distanceValue(stats.distanceMeters)
        distanceUnit = fmt.distanceUnit
        movingTime = fmt.minutes(stats.movingTimeSeconds)
        climbedValue = fmt.elevationValue(stats.elevationGainMeters)
        climbedUnit = fmt.elevationUnit

        var dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        dateStyle.timeZone = timeZone
        dateText = ride.startedAt.formatted(dateStyle)

        let trimmed = ride.destinationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        destinationName = (trimmed?.isEmpty == false) ? trimmed : nil

        routeCoordinates = ride.track.count > 1 ? ride.track.map(\.coordinate) : []

        let elevations = ride.track.compactMap(\.elevation)
        elevationSamples = elevations.count > 1 ? elevations : []
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter ShareCardContentTests`
Expected: PASS (7 tests). If `dateText` differs, confirm the abbreviated en_US_POSIX form is `"Jul 1, 2026"`; adjust the expected string to the actual only if the OS locale data differs, otherwise fix the code.

- [ ] **Step 5: Lint + full test run + commit**

```bash
cd AuraCore && swift test && cd .. && swiftlint lint --strict
git add AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift \
        AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift
git commit -m "feat(core): ShareCardContent — pure share-card view model"
```

---

### Task 2: Card contrast guard (WCAG on `surface`)

**Files:**
- Modify: `AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift` (add to `AuraPaletteContrastTests`)

**Interfaces:**
- Consumes: `WCAGContrast`, `AuraPalette` (AuraCore). No production change — the 0.80 token already exists; this locks it for the card's over-`surface` usage.

- [ ] **Step 1: Add the failing/guard test**

Add this method inside `struct AuraPaletteContrastTests` (after `increasedContrastSecondaryIsStronger`):

```swift
    @Test func cardHighContrastSecondaryClearsOverScrim() {
        // The share card can't honor Increase Contrast (it's a fixed PNG), so it always uses
        // the high-contrast secondary value. Its true worst case is text over the HUD scrim
        // (surface @ mapScrimOpacity) composited over the near-black route field — lock that
        // exact pairing, not just solid panel (CI otherwise only asserts the standard 0.62).
        let s = WCAGContrast.white(AuraPalette.textSecondaryWhiteHighContrast)
        let scrim = WCAGContrast.composite(AuraPalette.panel, over: AuraPalette.nearBlack,
                                           alpha: AuraPalette.mapScrimOpacity)
        #expect(WCAGContrast.ratio(s, scrim) >= 4.5)
        #expect(WCAGContrast.ratio(s, AuraPalette.nearBlack) >= 4.5)
    }
```

- [ ] **Step 2: Run it**

Run: `cd AuraCore && swift test --filter AuraPaletteContrastTests`
Expected: PASS (0.80 white clears 4.5:1 on both panel and near-black). This is a guard test; it passes immediately and fails only if someone lowers the token.

- [ ] **Step 3: Commit**

```bash
git add AuraCore/Tests/AuraCoreTests/WCAGContrastTests.swift
git commit -m "test(core): lock card high-contrast secondary on surface"
```

---

### Task 3: `ShareCardView` (app target)

**Files:**
- Create: `Aura/Sources/Ride/ShareCard/ShareCardView.swift`

**Interfaces:**
- Consumes: `ShareCardContent` (AuraKit); `RouteThumbnail`, `ElevationSparkline`, `StatPair`, `AuraTheme`, `AuraPalette`.
- Produces: `struct ShareCardView: View { let content: ShareCardContent }`, intrinsically sized 360×450.

No unit test (SwiftUI layout); verified by compile + preview. The pure logic it renders is already covered by Task 1.

- [ ] **Step 1: Write the view**

```swift
// Aura/Sources/Ride/ShareCard/ShareCardView.swift
import SwiftUI
import AuraCore
import AuraKit

/// The shareable 4:5 ride card, rendered offscreen by `RideCardRenderer` into a PNG.
/// A static projection of `ShareCardContent`: no animation, and the renderer pins
/// `dynamicTypeSize` so the pixel output is invariant. Uses only Canvas-based renderers
/// (`RouteThumbnail`, `ElevationSparkline`) so it draws correctly through `ImageRenderer`;
/// the Mapbox map cannot render offscreen.
struct ShareCardView: View {
    let content: ShareCardContent

    /// The card is a fixed PNG viewed at feed-thumbnail scale and can't honor Increase
    /// Contrast, so text over the scrim uses the high-contrast secondary value always.
    private let scrimText = Color(white: AuraPalette.textSecondaryWhiteHighContrast)
    private var hasRoute: Bool { !content.routeCoordinates.isEmpty }
    private var hasElevation: Bool { !content.elevationSamples.isEmpty }

    var body: some View {
        Group {
            if hasRoute {
                VStack(alignment: .leading, spacing: 0) {
                    routeField
                    readoutBand
                }
            } else {
                noRouteBody
            }
        }
        .frame(width: 360, height: 450)
        .background(AuraTheme.background)
    }

    // MARK: Route field (dominant, full-bleed)

    private var routeField: some View {
        ZStack(alignment: .bottomLeading) {
            RouteThumbnail(coordinates: content.routeCoordinates,
                           lineColor: AuraTheme.routeLine, lineWidth: 3)
                .padding(AuraTheme.Spacing.lg)
            overlayBlock
                .padding(AuraTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
    }

    private var overlayBlock: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            Text(contextLine)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(scrimText)
            HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xs) {
                Text(content.distanceValue)
                    .font(AuraTheme.Typography.speedHero(56))
                    .foregroundStyle(AuraTheme.textPrimary)
                Text(content.distanceUnit)
                    .font(AuraTheme.Typography.metricCockpit(22, face: .semibold, relativeTo: .title2))
                    .foregroundStyle(scrimText)
            }
        }
        .padding(.horizontal, AuraTheme.Spacing.md)
        .padding(.vertical, AuraTheme.Spacing.sm)
        .background(AuraTheme.surface.opacity(AuraPalette.mapScrimOpacity),
                    in: RoundedRectangle(cornerRadius: AuraTheme.Radius.md, style: .continuous))
    }

    // MARK: Readout band

    private var readoutBand: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.lg) {
            if hasElevation { elevationBlock }
            metricsRow
            Spacer(minLength: 0)
            wordmark
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, AuraTheme.Spacing.xl)
        .padding(.vertical, AuraTheme.Spacing.lg)
    }

    private var elevationBlock: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.xs) {
            HStack(spacing: AuraTheme.Spacing.xs) {
                Image(systemName: "arrow.up.forward")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AuraTheme.accent)
                Text("\(content.climbedValue) \(content.climbedUnit) climbed")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(scrimText)
            }
            ElevationSparkline(elevations: content.elevationSamples,
                               stroke: AuraTheme.accent,
                               fill: AuraTheme.accent.opacity(0.18),
                               lineWidth: 2)
                .frame(height: 48)
        }
    }

    private var metricsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: AuraTheme.Spacing.xxl) {
            StatPair(value: content.movingTime, label: "moving", context: .cockpit)
            if !hasElevation {
                StatPair(value: "\(content.climbedValue) \(content.climbedUnit)",
                         label: "climbed", context: .cockpit)
            }
        }
    }

    private var wordmark: some View {
        Text("AURA")
            .font(AuraTheme.Typography.metricCockpit(18, face: .semibold, relativeTo: .callout))
            .tracking(4)
            .foregroundStyle(AuraTheme.textPrimary)
    }

    // MARK: No-route variant (deliberate centered composition)

    private var noRouteBody: some View {
        VStack(spacing: AuraTheme.Spacing.lg) {
            Spacer()
            Text(contextLine)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(scrimText)
                .multilineTextAlignment(.center)
            VStack(spacing: AuraTheme.Spacing.xs) {
                Text(content.distanceValue)
                    .font(AuraTheme.Typography.speedHero(72))
                    .foregroundStyle(AuraTheme.textPrimary)
                Text(content.distanceUnit)
                    .font(AuraTheme.Typography.metricCockpit(20, face: .semibold, relativeTo: .title3))
                    .foregroundStyle(scrimText)
            }
            HStack(spacing: AuraTheme.Spacing.xxl) {
                StatPair(value: content.movingTime, label: "moving",
                         context: .cockpit, alignment: .center)
                StatPair(value: "\(content.climbedValue) \(content.climbedUnit)",
                         label: "climbed", context: .cockpit, alignment: .center)
            }
            Spacer()
            wordmark
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AuraTheme.Spacing.xxl)
    }

    // MARK: Context line

    private var contextLine: String {
        if let dest = content.destinationName {
            return "\(content.dateText)  ·  to \(dest)".uppercased()
        }
        return content.dateText.uppercased()
    }
}

#Preview("Route + elevation") {
    ShareCardView(content: ShareCardContent(
        ride: Ride(kind: .navigate, startedAt: Date(timeIntervalSince1970: 1_782_907_200),
                   endedAt: nil,
                   track: (0..<40).map { i in
                       TrackPoint(coordinate: Coordinate(latitude: 40.44 + Double(i) * 0.001,
                                                         longitude: -79.99 + Double(i) * 0.0012),
                                  elevation: 240 + 30 * sin(Double(i) / 4), timestamp: Date())
                   },
                   stats: RideStats(distanceMeters: 8046, movingTimeSeconds: 2520,
                                    averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 9,
                                    elevationGainMeters: 73),
                   destinationName: "Millvale", routeId: nil, destinationPlaceId: nil),
        units: .imperial))
}

#Preview("No route") {
    ShareCardView(content: ShareCardContent(
        ride: Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 1_782_907_200),
                   endedAt: nil, track: [], stats: RideStats(distanceMeters: 5000,
                   movingTimeSeconds: 1200, averageSpeedMetersPerSecond: 4,
                   maxSpeedMetersPerSecond: 7, elevationGainMeters: 20),
                   destinationName: nil, routeId: nil, destinationPlaceId: nil),
        units: .imperial))
}

#Preview("Route, no elevation") {
    // Exercises the routed layout's climbed-fallback branch (metricsRow shows a second
    // StatPair) when the track has coordinates but no elevation samples.
    ShareCardView(content: ShareCardContent(
        ride: Ride(kind: .navigate, startedAt: Date(timeIntervalSince1970: 1_782_907_200),
                   endedAt: nil,
                   track: (0..<30).map { i in
                       TrackPoint(coordinate: Coordinate(latitude: 40.44 + Double(i) * 0.001,
                                                         longitude: -79.99 + Double(i) * 0.0012),
                                  elevation: nil, timestamp: Date())
                   },
                   stats: RideStats(distanceMeters: 6400, movingTimeSeconds: 1800,
                                    averageSpeedMetersPerSecond: 4, maxSpeedMetersPerSecond: 8,
                                    elevationGainMeters: 55),
                   destinationName: "Downtown", routeId: nil, destinationPlaceId: nil),
        units: .imperial))
}
```

- [ ] **Step 2: Regenerate project + build + eyeball previews**

Run (delegate to the builder agent): `cd Aura && xcodegen generate` then build the `Aura` scheme on the iPhone 17 simulator.
Expected: BUILD SUCCEEDED. Fix any compile error before proceeding. Eyeball all three `#Preview`s (route+elevation, no route, route-no-elevation) for the mono-lime bar and that each branch composes intentionally.

- [ ] **Step 3: Lint + commit**

```bash
swiftlint lint --strict
git add Aura/Sources/Ride/ShareCard/ShareCardView.swift
git commit -m "feat(app): ShareCardView — instrument-field share card"
```

---

### Task 4: `RideCardRenderer` + `RideShareImage` (app target)

**Files:**
- Create: `Aura/Sources/Ride/ShareCard/RideCardRenderer.swift`

**Interfaces:**
- Consumes: `ShareCardContent` (AuraKit), `ShareCardView` (Task 3).
- Produces: `struct RideShareImage { let fileURL: URL; let preview: Image }` and
  `@MainActor enum RideCardRenderer { static func make(_ content: ShareCardContent) -> RideShareImage? }`.

- [ ] **Step 1: Write the renderer**

```swift
// Aura/Sources/Ride/ShareCard/RideCardRenderer.swift
import SwiftUI
import AuraKit

/// The shareable image + a preview thumbnail. Sharing a written PNG file URL (not a bare
/// SwiftUI `Image`) is the robust payload for Photos / Messages / Instagram.
struct RideShareImage {
    let fileURL: URL
    let preview: Image
}

/// Renders `ShareCardView` offscreen to a 1080×1350 PNG. `@MainActor` because `ImageRenderer`
/// is main-actor-only; called from `RideSummaryView`'s `.task` (already on the MainActor).
@MainActor
enum RideCardRenderer {
    static func make(_ content: ShareCardContent) -> RideShareImage? {
        let card = ShareCardView(content: content)
            .environment(\.dynamicTypeSize, .large)   // pixel output invariant to Dynamic Type
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3                              // 360×450 pt → 1080×1350 px
        guard let uiImage = renderer.uiImage,
              let data = uiImage.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "Aura ride.png")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return RideShareImage(fileURL: url, preview: Image(uiImage: uiImage))
    }
}
```

- [ ] **Step 2: Regenerate project + build**

Run (builder agent): `cd Aura && xcodegen generate` **first** — this new file lives under the `Sources` glob and must be added to the (gitignored) pbxproj, or it won't compile and Task 5 will fail to find `RideCardRenderer`. Then build the `Aura` scheme on the iPhone 17 simulator.
Expected: BUILD SUCCEEDED. (No Swift 6 concurrency warnings: `RideCardRenderer` is `@MainActor`, `UIImage` is `Sendable`, and `make` is only called on the MainActor.)

- [ ] **Step 3: Lint + commit**

```bash
swiftlint lint --strict
git add Aura/Sources/Ride/ShareCard/RideCardRenderer.swift
git commit -m "feat(app): RideCardRenderer — offscreen PNG for the share card"
```

---

### Task 5: Wire Share into `RideSummaryView`

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

**Interfaces:**
- Consumes: `ShareCardContent` (AuraKit), `RideCardRenderer`/`RideShareImage` (Task 4). `settings` (`SettingsStore`) and `ride` are already in scope.

- [ ] **Step 1: Add the share state**

In `RideSummaryView`, after `@State private var revealed = false` (around line 19), add:

```swift
    @State private var shareImage: RideShareImage?
```

- [ ] **Step 2: Insert the Share control above Done**

Replace the existing Done button block (currently around lines 61–63):

```swift
                Button("Done") { dismiss() }
                    .buttonStyle(.ctaPrimary)
                    .padding(.top, AuraTheme.Spacing.xs)
```

with:

```swift
                if ride.stats != nil {
                    Group {
                        if let shareImage {
                            ShareLink(item: shareImage.fileURL,
                                      preview: SharePreview("Aura ride", image: shareImage.preview)) {
                                Text("Share")
                            }
                        } else {
                            Button("Share") {}.disabled(true)
                        }
                    }
                    .buttonStyle(.ctaSecondary)
                    .padding(.top, AuraTheme.Spacing.md)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(.ctaPrimary)
                    .padding(.top, AuraTheme.Spacing.xs)
```

- [ ] **Step 3: Pre-render the card on appear**

Add a `.task` to the `ScrollView`, directly after the existing `.onAppear { ... }` modifier (around line 70–73):

```swift
        .task {
            guard ride.stats != nil, shareImage == nil else { return }
            await Task.yield()   // let the entrance animation start before the synchronous render
            let content = ShareCardContent(ride: ride, units: settings.units)
            shareImage = RideCardRenderer.make(content)
        }
```

- [ ] **Step 4: Build + regenerate if needed**

Run (builder agent): `cd Aura && xcodegen generate` (only if new files aren't yet in the project), then build the `Aura` scheme on the iPhone 17 simulator.
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Simulator verification**

Launch the app on the iPhone 17 sim (builder agent / sim). Open Simulator.app's GUI window (AXe returns empty trees otherwise). Navigate to a finished-ride summary (or trigger a free ride and end it). Verify with AXe accessibility tree:
- A "Share" button exists above "Done" and is enabled shortly after the summary appears.
- Tapping it presents the system share sheet.
Eyeball the rendered card (share sheet preview or Save to Files) for the mono-lime bar.
Expected: Share button present + labeled; share sheet presents; card looks on-brand.

- [ ] **Step 6: Full gates + commit**

```bash
cd AuraCore && swift test && cd .. && swiftlint lint --strict
git add Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(app): Share button on ride summary → system share sheet"
```

---

### Task 6: Retire the unbuilt-v1-promise line in ROADMAP

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Update the roadmap**

Find the "Deferred and unscheduled" note that reads (around line 608): *"Unbuilt v1 promise. One feature from the original design spec never shipped… the shareable ride-summary card (spec section 4)."* Replace it with a shipped note pointing at this work, e.g.:

```markdown
Unbuilt v1 promises: none remaining. The shareable ride-summary card (spec section 4)
shipped 2026-07-01 — see docs/superpowers/specs/2026-07-01-share-card-design.md.
```

Keep the separate "elevation profile on the ride summary" deferral intact (this feature put the elevation sparkline on the *card* only, not the live summary).

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roadmap): share card shipped — last v1 promise closed"
```

---

## Self-Review

**Spec coverage:**
- Instrument-field composition, HUD overlay, readout band, wordmark, no-route variant → Task 3.
- Pure content model + all branching, deterministic date, no top-speed → Task 1.
- PNG file-URL Transferable, explicit frame, pinned dynamicTypeSize, scale=3 → Task 4.
- Disabled-Button→ShareLink swap, gated on stats, pre-render → Task 5.
- Card high-contrast secondary on surface (WCAG) → Task 2.
- ROADMAP close-out → Task 6.
- Reuse of `RouteThumbnail`/`ElevationSparkline`/`RideStatsFormatter`/`StatPair`/tokens → Tasks 1, 3.

**Placeholder scan:** none — every code/test step shows complete content and exact commands.

**Type consistency:** `ShareCardContent` fields/init used identically in Tasks 1, 3, 4, 5. `RideShareImage { fileURL; preview }` and `RideCardRenderer.make(_:)` defined in Task 4 and consumed verbatim in Task 5. `StatPair(value:label:context:alignment:)`, `RouteThumbnail(coordinates:lineColor:lineWidth:)`, `ElevationSparkline(elevations:stroke:fill:lineWidth:)`, and `AuraTheme.Typography.speedHero/metricCockpit` match the real signatures.

**Note on StatPair labels:** reused `StatPair` renders its label in `AuraTheme.textSecondary` (0.62). On the near-black readout band that is 7.48:1 (well past 4.5:1), so it's not a contrast risk; the high-contrast 0.80 value is used specifically for text over the scrim and the elevation caption, per the spec.
