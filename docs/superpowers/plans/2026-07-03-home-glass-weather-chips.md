# Home Glass + Weather + Chips — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the approved Home redesign into the real `HomeView` — Liquid Glass on the control layer, WeatherKit conditions inlined in the greeting behind a testable seam, and Explore/Join/Saved action chips.

**Architecture:** Pure weather model + formatter in AuraCore; a `WeatherProviding` seam and `@MainActor @Observable WeatherStore` in AuraKit (WeatherKit-free, CI-testable); a WeatherKit provider in the app target injected at the composition root. Home view changes are gated Liquid Glass with the shipped styles as the pre-iOS-26 fallback.

**Tech Stack:** Swift 6, SwiftUI, WeatherKit (app target only), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-03-home-glass-weather-chips-design.md` · **Linear:** ROH-55

## Global Constraints

- **Deployment target iOS 17.0.** Every Liquid Glass API (`.glassEffect`, `.buttonStyle(.glass)`, `GlassEffectContainer`, `.buttonBorderShape(.circle)`) is behind `if #available(iOS 26, *)` with a working fallback.
- **AuraCore and AuraKit build on macOS CI.** No `import UIKit`, no `import WeatherKit`, no `MeasurementFormatter` (not Sendable) in either package target. If WeatherKit ever leaks into AuraKit, the macOS package build fails — that build IS the guard.
- **Swift 6 strict concurrency.** New shared types are `Sendable`; stores are `@MainActor @Observable`; the provider seam is `Sendable`.
- **Push-injected time.** Testable logic takes `now: Date` parameters (repo convention). Never call `Date()` or `Task.sleep` inside testable logic; call sites pass `Date()`.
- **Slop gate.** No uppercase "eyebrow" labels. Weather condition text is lowercase. Chip labels are sentence-case.
- **VoiceOver order preserved:** primary "Where to?" `accessibilitySortPriority(3)`, glance `2`, chips `1`, header utilities `-1`.
- **New tests use Swift Testing** (`import Testing`, `@Test`, `#expect`), matching the newer test files.
- **Distance:** `Coordinate.distance(_ a: Coordinate, _ b: Coordinate) -> Double` returns meters.
- **Commits:** one per task, `feat(...)`/`refactor(...)`, ending with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: Weather model — `AuraWeatherCondition` + `WeatherSnapshot` (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Weather/WeatherSnapshot.swift`
- Test: `AuraCore/Tests/AuraCoreTests/WeatherSnapshotTests.swift`

**Interfaces:**
- Produces: `enum AuraWeatherCondition: String, Sendable, CaseIterable { case clear, mostlyClear, cloudy, mostlyCloudy, fog, drizzle, rain, heavyRain, thunderstorm, snow, sleet, hail, windy, hot, cold, unknown }` and `struct WeatherSnapshot: Sendable { let temperature: Measurement<UnitTemperature>; let condition: AuraWeatherCondition; let asOf: Date; let coordinate: Coordinate }` with a memberwise `public init`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AuraCore

@Test func weatherConditionIncludesUnknownFallback() {
    #expect(AuraWeatherCondition.allCases.contains(.unknown))
    #expect(AuraWeatherCondition.allCases.count == 16)
}

@Test func weatherSnapshotStoresValues() {
    let snap = WeatherSnapshot(
        temperature: Measurement(value: 22, unit: .celsius),
        condition: .clear,
        asOf: Date(timeIntervalSince1970: 1_000),
        coordinate: Coordinate(latitude: 40.44, longitude: -79.99))
    #expect(snap.condition == .clear)
    #expect(snap.temperature.value == 22)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter WeatherSnapshotTests`
Expected: FAIL — `AuraWeatherCondition` / `WeatherSnapshot` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum AuraWeatherCondition: String, Sendable, CaseIterable {
    case clear, mostlyClear, cloudy, mostlyCloudy, fog, drizzle, rain, heavyRain
    case thunderstorm, snow, sleet, hail, windy, hot, cold, unknown
}

public struct WeatherSnapshot: Sendable {
    public let temperature: Measurement<UnitTemperature>
    public let condition: AuraWeatherCondition
    public let asOf: Date
    public let coordinate: Coordinate

    public init(temperature: Measurement<UnitTemperature>, condition: AuraWeatherCondition,
                asOf: Date, coordinate: Coordinate) {
        self.temperature = temperature
        self.condition = condition
        self.asOf = asOf
        self.coordinate = coordinate
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter WeatherSnapshotTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Weather/WeatherSnapshot.swift AuraCore/Tests/AuraCoreTests/WeatherSnapshotTests.swift
git commit -m "feat(weather): AuraWeatherCondition + WeatherSnapshot value types (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Pure formatter — `WeatherGreeting` (AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Weather/WeatherGreeting.swift`
- Test: `AuraCore/Tests/AuraCoreTests/WeatherGreetingTests.swift`

**Interfaces:**
- Consumes: `AuraWeatherCondition`, `WeatherSnapshot` (Task 1).
- Produces: `enum WeatherGreeting` with statics: `symbolName(for: AuraWeatherCondition) -> String`; `text(for: AuraWeatherCondition) -> String`; `temperatureText(_ measurement: Measurement<UnitTemperature>, locale: Locale) -> String`; `accessibilityText(greeting: String, snapshot: WeatherSnapshot?, locale: Locale) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import AuraCore

@Test func symbolMapIsTotalAndNonEmpty() {
    for c in AuraWeatherCondition.allCases {
        #expect(!WeatherGreeting.symbolName(for: c).isEmpty)
    }
}

@Test func conditionTextIsLowercaseAndUnknownIsBlank() {
    for c in AuraWeatherCondition.allCases {
        let t = WeatherGreeting.text(for: c)
        #expect(t == t.lowercased())
    }
    #expect(WeatherGreeting.text(for: .unknown).isEmpty)
    #expect(WeatherGreeting.text(for: .clear) == "clear")
}

@Test func temperatureUsesFahrenheitForUSLocaleAndCelsiusOtherwise() {
    let m = Measurement(value: 22, unit: UnitTemperature.celsius) // 71.6°F
    #expect(WeatherGreeting.temperatureText(m, locale: Locale(identifier: "en_US")) == "72°")
    #expect(WeatherGreeting.temperatureText(m, locale: Locale(identifier: "fr_FR")) == "22°")
}

@Test func accessibilityTextComposesAndFallsBackToGreetingOnly() {
    let snap = WeatherSnapshot(temperature: Measurement(value: 22, unit: .celsius),
                              condition: .clear, asOf: Date(),
                              coordinate: Coordinate(latitude: 0, longitude: 0))
    let text = WeatherGreeting.accessibilityText(greeting: "Good evening", snapshot: snap,
                                                 locale: Locale(identifier: "en_US"))
    #expect(text == "Good evening, 72 degrees, clear")
    #expect(WeatherGreeting.accessibilityText(greeting: "Good evening", snapshot: nil,
                                              locale: Locale(identifier: "en_US")) == "Good evening")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter WeatherGreetingTests`
Expected: FAIL — `WeatherGreeting` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public enum WeatherGreeting {
    public static func symbolName(for c: AuraWeatherCondition) -> String {
        switch c {
        case .clear: "sun.max"
        case .mostlyClear: "sun.max"
        case .cloudy: "cloud"
        case .mostlyCloudy: "cloud.sun"
        case .fog: "cloud.fog"
        case .drizzle: "cloud.drizzle"
        case .rain: "cloud.rain"
        case .heavyRain: "cloud.heavyrain"
        case .thunderstorm: "cloud.bolt.rain"
        case .snow: "snowflake"
        case .sleet: "cloud.sleet"
        case .hail: "cloud.hail"
        case .windy: "wind"
        case .hot: "thermometer.sun"
        case .cold: "thermometer.snowflake"
        case .unknown: "cloud"
        }
    }

    public static func text(for c: AuraWeatherCondition) -> String {
        switch c {
        case .clear: "clear"
        case .mostlyClear: "mostly clear"
        case .cloudy: "cloudy"
        case .mostlyCloudy: "mostly cloudy"
        case .fog: "fog"
        case .drizzle: "drizzle"
        case .rain: "rain"
        case .heavyRain: "heavy rain"
        case .thunderstorm: "thunderstorms"
        case .snow: "snow"
        case .sleet: "sleet"
        case .hail: "hail"
        case .windy: "windy"
        case .hot: "hot"
        case .cold: "cold"
        case .unknown: ""
        }
    }

    /// Locale-based °F/°C without MeasurementFormatter (which is not Sendable).
    public static func temperatureText(_ measurement: Measurement<UnitTemperature>,
                                       locale: Locale) -> String {
        let unit: UnitTemperature = locale.measurementSystem == .us ? .fahrenheit : .celsius
        let value = measurement.converted(to: unit).value
        return "\(Int(value.rounded()))°"
    }

    public static func accessibilityText(greeting: String, snapshot: WeatherSnapshot?,
                                         locale: Locale) -> String {
        guard let snapshot else { return greeting }
        let unit: UnitTemperature = locale.measurementSystem == .us ? .fahrenheit : .celsius
        let degrees = Int(snapshot.temperature.converted(to: unit).value.rounded())
        let word = text(for: snapshot.condition)
        let tail = word.isEmpty ? "" : ", \(word)"
        return "\(greeting), \(degrees) degrees\(tail)"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter WeatherGreetingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Weather/WeatherGreeting.swift AuraCore/Tests/AuraCoreTests/WeatherGreetingTests.swift
git commit -m "feat(weather): pure WeatherGreeting formatter (symbol/text/temp/a11y) (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Seam + state — `WeatherProviding` + `WeatherStore` (AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Weather/WeatherProviding.swift`
- Create: `AuraCore/Sources/AuraKit/Weather/WeatherStore.swift`
- Create (fake): `AuraCore/Tests/AuraKitTests/Fakes/StubWeatherProvider.swift`
- Test: `AuraCore/Tests/AuraKitTests/WeatherStoreTests.swift`

**Interfaces:**
- Consumes: `WeatherSnapshot`, `Coordinate`, `Coordinate.distance` (AuraCore).
- Produces:
  - `public protocol WeatherProviding: Sendable { func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot }`
  - `@MainActor @Observable public final class WeatherStore` with `public init(provider: WeatherProviding)`, `public private(set) var snapshot: WeatherSnapshot?`, `public func refresh(near coordinate: Coordinate, now: Date) async`, `public func displaySnapshot(now: Date) -> WeatherSnapshot?`.
- Cache rule: `refresh` skips the fetch when `snapshot != nil`, `now - snapshot.asOf < 900 s`, AND `Coordinate.distance(snapshot.coordinate, coordinate) < 2000 m`. On provider throw, `snapshot` is left unchanged. `displaySnapshot` returns nil when `now - snapshot.asOf >= 3600 s`.

- [ ] **Step 1: Write the fake + failing test**

`Fakes/StubWeatherProvider.swift`:
```swift
import Foundation
@testable import AuraKit
import AuraCore

final class StubWeatherProvider: WeatherProviding, @unchecked Sendable {
    var result: Result<WeatherSnapshot, Error>
    private(set) var callCount = 0
    init(_ result: Result<WeatherSnapshot, Error>) { self.result = result }
    func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot {
        callCount += 1
        return try result.get()
    }
}
struct StubError: Error {}
```

`WeatherStoreTests.swift`:
```swift
import Testing
import Foundation
@testable import AuraKit
import AuraCore

private func snap(_ tempC: Double, _ at: Date, _ coord: Coordinate) -> WeatherSnapshot {
    WeatherSnapshot(temperature: Measurement(value: tempC, unit: .celsius),
                    condition: .clear, asOf: at, coordinate: coord)
}
private let pgh = Coordinate(latitude: 40.44, longitude: -79.99)

@MainActor @Test func firstRefreshSetsSnapshot() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let store = WeatherStore(provider: StubWeatherProvider(.success(snap(20, t0, pgh))))
    await store.refresh(near: pgh, now: t0)
    #expect(store.snapshot?.temperature.value == 20)
}

@MainActor @Test func providerThrowLeavesSnapshotUnchanged() async {
    let stub = StubWeatherProvider(.failure(StubError()))
    let store = WeatherStore(provider: stub)
    await store.refresh(near: pgh, now: Date(timeIntervalSince1970: 0))
    #expect(store.snapshot == nil)
}

@MainActor @Test func cacheHitSkipsSecondFetch() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let stub = StubWeatherProvider(.success(snap(20, t0, pgh)))
    let store = WeatherStore(provider: stub)
    await store.refresh(near: pgh, now: t0)
    await store.refresh(near: pgh, now: t0.addingTimeInterval(600)) // 10 min, same spot
    #expect(stub.callCount == 1)
}

@MainActor @Test func cacheMissOnStalenessOrMovementRefetches() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let stub = StubWeatherProvider(.success(snap(20, t0, pgh)))
    let store = WeatherStore(provider: stub)
    await store.refresh(near: pgh, now: t0)
    await store.refresh(near: pgh, now: t0.addingTimeInterval(1000)) // > 15 min
    #expect(stub.callCount == 2)
    let far = Coordinate(latitude: 41.0, longitude: -79.99)              // ~62 km away
    await store.refresh(near: far, now: t0.addingTimeInterval(1100))
    #expect(stub.callCount == 3)
}

@MainActor @Test func displaySnapshotHidesPastStaleness() async {
    let t0 = Date(timeIntervalSince1970: 0)
    let store = WeatherStore(provider: StubWeatherProvider(.success(snap(20, t0, pgh))))
    await store.refresh(near: pgh, now: t0)
    #expect(store.displaySnapshot(now: t0.addingTimeInterval(1800)) != nil)   // 30 min
    #expect(store.displaySnapshot(now: t0.addingTimeInterval(3600)) == nil)   // 60 min
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter WeatherStoreTests`
Expected: FAIL — `WeatherProviding` / `WeatherStore` undefined.

- [ ] **Step 3: Write minimal implementation**

`WeatherProviding.swift`:
```swift
import AuraCore

public protocol WeatherProviding: Sendable {
    func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot
}
```

`WeatherStore.swift`:
```swift
import Foundation
import AuraCore

@MainActor @Observable public final class WeatherStore {
    public private(set) var snapshot: WeatherSnapshot?
    private let provider: WeatherProviding
    private let cacheAge: TimeInterval = 15 * 60
    private let cacheDistance: Double = 2_000
    private let staleAfter: TimeInterval = 60 * 60

    public init(provider: WeatherProviding) { self.provider = provider }

    public func refresh(near coordinate: Coordinate, now: Date) async {
        if let s = snapshot,
           now.timeIntervalSince(s.asOf) < cacheAge,
           Coordinate.distance(s.coordinate, coordinate) < cacheDistance {
            return
        }
        do { snapshot = try await provider.currentConditions(for: coordinate) }
        catch { /* leave snapshot unchanged; silent hide */ }
    }

    public func displaySnapshot(now: Date) -> WeatherSnapshot? {
        guard let s = snapshot, now.timeIntervalSince(s.asOf) < staleAfter else { return nil }
        return s
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter WeatherStoreTests`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Weather AuraCore/Tests/AuraKitTests/WeatherStoreTests.swift AuraCore/Tests/AuraKitTests/Fakes/StubWeatherProvider.swift
git commit -m "feat(weather): WeatherProviding seam + WeatherStore with cache/staleness (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `WeatherKitProvider` (app target)

**Files:**
- Create: `Aura/Sources/Weather/WeatherKitProvider.swift`

**Interfaces:**
- Consumes: `WeatherProviding`, `Coordinate`, `WeatherSnapshot`, `AuraWeatherCondition`.
- Produces: `final class WeatherKitProvider: WeatherProviding` (the only file importing WeatherKit). No unit test — WeatherKit is a live iOS service; correctness of the neutral mapping's *symbols* is covered by Task 2's totality test and manual device verification.

- [ ] **Step 1: Implement the provider**

```swift
import Foundation
import CoreLocation
import WeatherKit
import AuraCore
import AuraKit

final class WeatherKitProvider: WeatherProviding {
    private let service = WeatherService.shared

    func currentConditions(for coordinate: Coordinate) async throws -> WeatherSnapshot {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let current = try await service.weather(for: location, including: .current)
        return WeatherSnapshot(
            temperature: current.temperature,
            condition: Self.map(current.condition),
            asOf: Date(),
            coordinate: coordinate)
    }

    /// Total map from WeatherKit's ~40 conditions to Aura's neutral set; default .unknown.
    static func map(_ c: WeatherCondition) -> AuraWeatherCondition {
        switch c {
        case .clear, .hot: return c == .hot ? .hot : .clear
        case .mostlyClear: return .mostlyClear
        case .partlyCloudy, .mostlyCloudy: return .mostlyCloudy
        case .cloudy: return .cloudy
        case .foggy, .haze, .smoky: return .fog
        case .drizzle: return .drizzle
        case .rain, .sunShowers, .freezingRain, .freezingDrizzle: return .rain
        case .heavyRain: return .heavyRain
        case .thunderstorms, .strongStorms, .isolatedThunderstorms, .scatteredThunderstorms,
             .tropicalStorm, .hurricane: return .thunderstorm
        case .snow, .flurries, .heavySnow, .sunFlurries, .blowingSnow, .blizzard,
             .wintryMix: return .snow
        case .sleet: return .sleet
        case .hail: return .hail
        case .windy, .breezy, .blowingDust: return .windy
        case .frigid: return .cold
        @unknown default: return .unknown
        }
    }
}
```
(If a case name above does not exist in the installed WeatherKit SDK, drop it — `@unknown default` catches anything unmapped as `.unknown`. Verify names against the SDK during the build step.)

- [ ] **Step 2: Verify it compiles** (delegate to the builder agent)

Build the `Aura` scheme for the simulator. Expected: BUILD SUCCEEDED. Fix any WeatherKit case-name mismatches (remove offending cases; `@unknown default` covers them).

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Weather/WeatherKitProvider.swift
git commit -m "feat(weather): WeatherKitProvider mapping WeatherKit -> neutral snapshot (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Inject `WeatherStore` at the composition root

**Files:**
- Modify: the app entry / root view where `SettingsStore`, `SavedPlacesStore`, `LocationService` are constructed and `.environment(...)`-injected (locate via `grep -rn "SavedPlacesStore(" Aura/Sources`).

**Interfaces:**
- Produces: a `WeatherStore(provider: WeatherKitProvider())` available in the environment for `HomeView` via `@Environment(WeatherStore.self)`.

- [ ] **Step 1:** Locate the root (grep above). Construct `@State private var weatherStore = WeatherStore(provider: WeatherKitProvider())` (or the matching pattern the other stores use) and add `.environment(weatherStore)` alongside the existing `.environment(...)` calls.
- [ ] **Step 2:** Build the `Aura` scheme (builder). Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Commit**

```bash
git commit -am "feat(weather): inject WeatherStore into the app environment (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Inline weather in the greeting (`HomeView`)

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift` (the `greeting`/`header` area, ~lines 116–161)

**Interfaces:**
- Consumes: `WeatherStore` (env), `LocationService` (env, already present), `WeatherGreeting`.

- [ ] **Step 1:** Add `@Environment(WeatherStore.self) private var weather`. Replace the greeting `Text` with a layout-stable line:

```swift
private var greetingLine: some View {
    HStack(spacing: 4) {
        Text(greeting)
        if let snap = weather.displaySnapshot(now: Date()) {
            Text("·").foregroundStyle(AuraTheme.textSecondary.opacity(0.6))
            Image(systemName: WeatherGreeting.symbolName(for: snap.condition))
                .foregroundStyle(AuraTheme.accent)
                .accessibilityHidden(true)
            Text(WeatherGreeting.temperatureText(snap.temperature, locale: .current))
                .foregroundStyle(AuraTheme.textPrimary)
            let word = WeatherGreeting.text(for: snap.condition)
            if !word.isEmpty { Text(word) }
        }
    }
    .font(.footnote.weight(.medium))
    .foregroundStyle(AuraTheme.textSecondary)
    .lineLimit(1)
    .minimumScaleFactor(0.85)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(WeatherGreeting.accessibilityText(
        greeting: greeting, snapshot: weather.displaySnapshot(now: Date()), locale: .current))
    .accessibilitySortPriority(2)
}
```
Use `greetingLine` in the header `VStack` in place of the old greeting `Text` (keep the "Aura" wordmark line below unchanged).

- [ ] **Step 2:** Trigger fetches. In `body`'s existing `.task { await loadRides() }` add a weather refresh, and refresh on auth change:

```swift
.task { if let c = location.currentCoordinate { await weather.refresh(near: c, now: Date()) } }
.onChange(of: location.authorization) {
    Task { if let c = location.currentCoordinate { await weather.refresh(near: c, now: Date()) } }
}
```
(Use the actual `LocationService` coordinate accessor — find it, e.g. `location.currentCoordinate` / `location.lastCoordinate`; adapt the name.)

- [ ] **Step 3:** Build (builder). Expected: BUILD SUCCEEDED. Manually confirm (later, on device) the greeting shows weather and does not reflow.
- [ ] **Step 4: Commit**

```bash
git commit -am "feat(home): inline weather in the greeting, layout-stable + composed a11y (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Liquid Glass helper + `HomeChip` (`HomeGlass.swift`)

**Files:**
- Create: `Aura/Sources/Home/HomeGlass.swift`

**Interfaces:**
- Produces: `GlassGroup { … }` container; a `HomeChip(title:systemImage:action:)` view; a `glassCircleButton` helper for the HUD buttons. All gate `if #available(iOS 26, *)`; under Reduce Transparency OR Increase Contrast they use the solid fallback even on iOS 26.

- [ ] **Step 1:** Implement:

```swift
import SwiftUI

/// GlassEffectContainer on iOS 26; pass-through otherwise.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = AuraTheme.Spacing.sm
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing) { content() } }
        else { content() }
    }
}

/// A circular HUD control: glass on iOS 26 unless the user prefers solid surfaces.
struct GlassCircleButton<Label: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    private var preferSolid: Bool { reduceTransparency || contrast == .increased }
    var body: some View {
        if #available(iOS 26, *), !preferSolid {
            Button(action: action, label: label)
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        } else {
            Button(action: action, label: label).buttonStyle(.hudControl)
        }
    }
}

struct HomeChip: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let systemImage: String
    let action: () -> Void
    private var preferSolid: Bool { reduceTransparency || contrast == .increased }
    var body: some View {
        if #available(iOS 26, *), !preferSolid {
            Button(action: action) { Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold)) }
                .buttonStyle(.glass).tint(AuraTheme.accent)
        } else {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage).font(.footnote.weight(.semibold))
                    Text(title).font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AuraTheme.accent)
                .padding(.horizontal, AuraTheme.Spacing.md)
                .padding(.vertical, AuraTheme.Spacing.sm + 2)
                .background(AuraTheme.surface.opacity(0.9), in: .capsule)
                .overlay(Capsule().strokeBorder(AuraTheme.accent.opacity(0.45), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}
```

- [ ] **Step 2:** Build (builder). Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Home/HomeGlass.swift
git commit -m "feat(home): Home-scoped Liquid Glass helpers (gated, contrast-aware) (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Chip row in `HomeLaunchBand`

**Files:**
- Modify: `Aura/Sources/Home/HomeLaunchBand.swift`

**Interfaces:**
- Consumes: `HomeChip`, `GlassGroup` (Task 7).
- Produces: `HomeLaunchBand(onWhereTo:onExplore:onJoin:onSaved:hasSaved:)` — new `onSaved: () -> Void` and `hasSaved: Bool`.

- [ ] **Step 1:** Replace the secondary `HStack` of `.ctaSecondary` buttons with the chip row (keep the `.ctaPrimary` "Where to?" primary untouched):

```swift
GlassGroup(spacing: AuraTheme.Spacing.sm) {
    HStack(spacing: AuraTheme.Spacing.sm) {
        HomeChip(title: "Explore", systemImage: "safari", action: onExplore)
            .accessibilitySortPriority(1).accessibilityIdentifier("home.explore")
        HomeChip(title: "Join a ride", systemImage: "person.2.badge.plus", action: onJoin)
            .accessibilitySortPriority(1).accessibilityIdentifier("home.join")
        if hasSaved {
            HomeChip(title: "Saved", systemImage: "bookmark", action: onSaved)
                .accessibilitySortPriority(1).accessibilityIdentifier("home.saved")
                .transition(.opacity)
        }
    }
}
```
Add the `onSaved` and `hasSaved` stored properties to the struct.

- [ ] **Step 2:** Build (builder). Expected: BUILD SUCCEEDED (HomeView call site will error until Task 10 — build after Task 10, or temporarily pass placeholders; note this cross-task dependency and build at Task 10).
- [ ] **Step 3: Commit**

```bash
git commit -am "feat(home): Explore/Join/Saved chips replace secondary launch buttons (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Sheet detent selection + scroll anchor (`HomeSheet`)

**Files:**
- Modify: `Aura/Sources/Home/HomeSheet.swift`

**Interfaces:**
- Produces: `homeDashboardSheet(isPresented:selection:peekHeight:peek:body:)` — new `selection: Binding<PresentationDetent>`. The scroll body is wrapped in a `ScrollViewReader`; consumers give the Saved section `.id("saved")`; when `selection` becomes `.large` the body scrolls to `"saved"`.

- [ ] **Step 1:** Add the `selection` binding and thread it into `.presentationDetents(_, selection:)`. Wrap the inner `ScrollView` content in `ScrollViewReader { proxy in … }` and add:

```swift
.onChange(of: selection) { _, new in
    if new == .large { withAnimation { proxy.scrollTo("saved", anchor: .top) } }
}
```
Keep `.presentationBackgroundInteraction`, drag indicator, background, and detent set as-is.

- [ ] **Step 2:** Build (builder) after Task 10 wires the caller. Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Commit**

```bash
git commit -am "feat(home): sheet detent selection + scroll-to-saved anchor (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Wire `HomeView` (glass HUD + chips + Saved) and delete the reference view

**Files:**
- Modify: `Aura/Sources/Home/HomeView.swift`
- Delete: `Aura/Sources/Home/HomeRedesignView.swift`

- [ ] **Step 1:** In `headerControls`, replace each `Button { … }.buttonStyle(.hudControl)` with `GlassCircleButton(action: …) { Image(systemName: …) }` (carry the existing `.accessibilityLabel/Hint/Identifier` and the `.accessibilitySortPriority(-1)`), wrapped in a `GlassGroup`.
- [ ] **Step 2:** Add `@State private var selectedDetent: PresentationDetent = .height(peekHeight)`. Pass it into `.homeDashboardSheet(isPresented:selection:$selectedDetent, …)`. Give the `savedSection` `.id("saved")`.
- [ ] **Step 3:** Update the `HomeLaunchBand(...)` call to pass `hasSaved: !savedPlaces.places.isEmpty` and:

```swift
onSaved: {
    if searchExpanded { searchExpanded = false }
    selectedDetent = .large
}
```
- [ ] **Step 4:** Delete `HomeRedesignView.swift` (`git rm`).
- [ ] **Step 5:** Build the `Aura` scheme (builder). Expected: BUILD SUCCEEDED (this resolves the Task 8/9 call sites).
- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(home): adopt glass HUD + chips + Saved-expands-sheet; drop reference view (ROH-55)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 11: Full verification

- [ ] **Step 1:** Run the whole package test suite: `cd AuraCore && swift test`. Expected: all pass (including the new weather tests).
- [ ] **Step 2:** Build the `Aura` scheme for the simulator (builder). Expected: BUILD SUCCEEDED, no new warnings on the touched files.
- [ ] **Step 3:** No commit (verification only). Proceed to whole-branch review, then device handoff.

## Self-Review

**Spec coverage:** Weather model (T1), formatter incl. locale/lowercase/a11y (T2), seam+store+cache+staleness (T3), provider+mapping (T4), injection (T5), greeting layout-stable + a11y + fetch triggers (T6), glass helper + contrast fallback (T7), chips (T8), detent+anchor (T9), HUD glass + Saved wiring + delete reference (T10), verification (T11). All spec sections map to a task.

**Placeholder scan:** No TBD/TODO; every code step shows real code. Two explicit, bounded unknowns are called out with how to resolve them at build time: (a) the exact `LocationService` coordinate accessor name in T6, (b) WeatherKit case names in T4 (covered by `@unknown default`). These are named lookups, not vague instructions.

**Type consistency:** `AuraWeatherCondition`/`WeatherSnapshot` (T1) used verbatim in T2–T4; `WeatherProviding`/`WeatherStore` signatures (T3) match the store test and the T4 provider and T5 injection; `refresh(near:now:)` and `displaySnapshot(now:)` consistent across T3/T6; `HomeLaunchBand(onWhereTo:onExplore:onJoin:onSaved:hasSaved:)` consistent across T8/T10; `homeDashboardSheet(...selection:...)` consistent across T9/T10; `.id("saved")` consistent across T9/T10.
