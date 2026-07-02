# Live Ride-Summary Elevation Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an elevation-profile "effort story" band to the ride summary — a silhouette + total-climb callout for real climbs, a slim "Mostly flat" line otherwise — driven by one shared classifier the share card also uses.

**Architecture:** A pure `ElevationProfile.classify` (AuraKit) keys the profile/flat/unavailable decision on **cumulative climb** (`RideStats.elevationGainMeters`), the same number shown on the callout, so label and number can never disagree. A pure `ElevationProfileContent` view-model wraps it with display-ready climb text. The share card migrates to the same classifier. An app-target `ElevationProfileBand` (a `switch` over the classifier's `Kind`) reuses the existing pure-Canvas `ElevationSparkline`, and `RideSummaryView` inserts it after the distance hero and drops the "climbed" stat.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`), the existing `ElevationSparkline` Canvas view, xcodegen, xcodebuild (iPhone 17 sim), SwiftLint.

## Global Constraints

- 3-layer architecture: pure logic in AuraCore/AuraKit (no UIKit/SwiftUI/SwiftData/Mapbox in the pure layer); band view in the app target.
- One shared classifier `ElevationProfile.classify` (`minGainMeters = 10.0`) drives BOTH the summary and the share card — they must never disagree.
- The profile/flat gate and the climb callout are the SAME measure (cumulative gain) — label and number can never contradict on screen.
- Reuse the existing pure-Canvas `ElevationSparkline` (offscreen-safe); do NOT introduce Swift Charts or Mapbox for the profile.
- Static in v1; no interactivity.
- Per-state rendering is a `switch`, never a ternary (`void_function_in_ternary` is a SwiftLint error). Keep interpolated label lines ≤140 cols (warnings are build-gating).
- Run `xcodegen generate` before building locally (the `.xcodeproj` is gitignored; new files under `Aura/Sources/**` are picked up only after regen). Copy the Mapbox token into `Aura/Resources/MapboxAccessToken` if missing (gitignored).
- Gates before "done": `cd AuraCore && swift test` green; `swiftlint lint --strict` clean; app builds on the iPhone 17 sim.
- After any app build, revert Mapbox SPM pin churn: `git checkout -- AuraCore/Package.resolved` (never commit it).
- Local-only until the user says "push."

---

### Task 1: `ElevationProfile` classifier (pure)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Plotting/ElevationProfile.swift`
- Test: `AuraCore/Tests/AuraKitTests/ElevationProfileTests.swift`

**Interfaces:**
- Consumes: `AuraCore.TrackPoint` (has `var elevation: Double?`).
- Produces: `enum ElevationProfile` with `static let minGainMeters = 10.0`, nested `enum Kind: Equatable, Sendable { case profile([Double]); case flat; case unavailable }`, and `static func classify(track: [TrackPoint], gainMeters: Double) -> Kind`.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/ElevationProfileTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ElevationProfileTests {
    private func pt(_ e: Double?) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 0),
                   elevation: e, timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test func realClimbIsProfile() {
        let k = ElevationProfile.classify(track: [pt(10), pt(40)], gainMeters: 30)
        #expect(k == .profile([10, 40]))
    }

    @Test func belowFloorIsFlat() {
        let k = ElevationProfile.classify(track: [pt(10), pt(13)], gainMeters: 3)
        #expect(k == .flat)
    }

    @Test func gainFloorIsInclusive() {
        let k = ElevationProfile.classify(track: [pt(10), pt(20)], gainMeters: 10)
        #expect(k == .profile([10, 20]))
    }

    @Test func fewerThanTwoSamplesIsUnavailable() {
        // No elevation samples at all (pre-elevation ride), even with a stats gain.
        #expect(ElevationProfile.classify(track: [pt(nil), pt(nil)], gainMeters: 50) == .unavailable)
        // Exactly one non-nil sample.
        #expect(ElevationProfile.classify(track: [pt(10), pt(nil)], gainMeters: 50) == .unavailable)
        // Empty track.
        #expect(ElevationProfile.classify(track: [], gainMeters: 50) == .unavailable)
    }

    @Test func netDownhillIsFlatNotProfile() {
        // Big peak-to-trough range but tiny cumulative climb -> flat (regression guard:
        // no "plunging silhouette + 3 ft climbed" contradiction).
        let k = ElevationProfile.classify(track: [pt(500), pt(505), pt(460)], gainMeters: 5)
        #expect(k == .flat)
    }

    @Test func rollingRideIsProfile() {
        // Small range but real cumulative climb -> profile (no "Mostly flat · 180 ft").
        let k = ElevationProfile.classify(track: [pt(100), pt(103), pt(100), pt(103)], gainMeters: 30)
        #expect(k == .profile([100, 103, 100, 103]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter ElevationProfileTests`
Expected: FAIL — "cannot find 'ElevationProfile' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `AuraCore/Sources/AuraKit/Plotting/ElevationProfile.swift`:

```swift
import AuraCore

/// Classifies a ride's elevation into what the summary and share card should draw.
/// The profile/flat decision keys on **cumulative climb** (`gainMeters`) — the same
/// number both surfaces put on the callout — so the label and the number can never
/// contradict on screen. Gain-gating also excludes the flat-trace "solid bar" failure
/// mode: a near-flat series can't clear the climb floor, so `.profile` never receives
/// a flat trace. Pure + testable; shared so the two surfaces never diverge.
public enum ElevationProfile {
    /// Minimum cumulative climb (meters) to headline an elevation profile. Tunable;
    /// settled during the on-device pass.
    public static let minGainMeters = 10.0

    public enum Kind: Equatable, Sendable {
        case profile([Double])   // gain ≥ floor, ≥2 samples: draw the silhouette
        case flat                // ≥2 samples but gain < floor: "Mostly flat"
        case unavailable         // < 2 elevation samples: omit the section
    }

    /// `gainMeters` is the ride's cumulative ascent (`RideStats.elevationGainMeters`);
    /// `track` supplies the elevation samples the silhouette is drawn from.
    public static func classify(track: [TrackPoint], gainMeters: Double) -> Kind {
        let elevations = track.compactMap(\.elevation)
        guard elevations.count >= 2 else { return .unavailable }
        return gainMeters >= minGainMeters ? .profile(elevations) : .flat
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter ElevationProfileTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Plotting/ElevationProfile.swift AuraCore/Tests/AuraKitTests/ElevationProfileTests.swift
git commit -m "feat(core): ElevationProfile gain-gated classifier"
```

---

### Task 2: `ElevationProfileContent` view-model (pure)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Summary/ElevationProfileContent.swift`
- Test: `AuraCore/Tests/AuraKitTests/ElevationProfileContentTests.swift`

**Interfaces:**
- Consumes: `ElevationProfile.classify` (Task 1); `AuraCore.Ride` (has `var track: [TrackPoint]`, `var stats: RideStats?`); `RideStatsFormatter` (`elevationValue(_:) -> String` via `%.0f`, `elevationUnit`, `elevationUnitSpoken`); `RideStats.zero`, `RideStats.elevationGainMeters`; `DistanceUnits`.
- Produces: `struct ElevationProfileContent: Equatable, Sendable` with `let kind: ElevationProfile.Kind`, `let climbedValue: String`, `let climbedUnit: String`, `let climbedUnitSpoken: String`, `let isTrivialClimb: Bool`, and `init(ride: Ride, units: DistanceUnits)`.

- [ ] **Step 1: Write the failing test**

Create `AuraCore/Tests/AuraKitTests/ElevationProfileContentTests.swift`:

```swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct ElevationProfileContentTests {
    private func pt(_ e: Double?) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: 0, longitude: 0),
                   elevation: e, timestamp: Date(timeIntervalSince1970: 0))
    }
    private func stats(climb: Double) -> RideStats {
        RideStats(distanceMeters: 8046.72, movingTimeSeconds: 2520,
                  averageSpeedMetersPerSecond: 5, maxSpeedMetersPerSecond: 9,
                  elevationGainMeters: climb)
    }
    private func ride(track: [TrackPoint], climb: Double) -> Ride {
        Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
             track: track, stats: stats(climb: climb), destinationName: nil,
             routeId: nil, destinationPlaceId: nil)
    }

    @Test func imperialClimbStrings() {
        let c = ElevationProfileContent(ride: ride(track: [pt(10), pt(40)], climb: 73.152),
                                        units: .imperial)
        #expect(c.climbedValue == "240")           // 73.152 m -> 240 ft
        #expect(c.climbedUnit == "ft")
        #expect(c.climbedUnitSpoken == "feet")
        #expect(c.kind == .profile([10, 40]))
    }

    @Test func metricClimbStrings() {
        let c = ElevationProfileContent(ride: ride(track: [pt(10), pt(40)], climb: 73.152),
                                        units: .metric)
        #expect(c.climbedValue == "73")
        #expect(c.climbedUnit == "m")
        #expect(c.climbedUnitSpoken == "meters")
    }

    @Test func trivialClimbFlagsWhenFormattedZero() {
        // Flat ride, gain rounds to 0 -> isTrivialClimb true, kind .flat.
        let c = ElevationProfileContent(ride: ride(track: [pt(12), pt(12)], climb: 0),
                                        units: .imperial)
        #expect(c.kind == .flat)
        #expect(c.isTrivialClimb == true)
        #expect(c.climbedValue == "0")
    }

    @Test func flatButNonTrivialClimb() {
        // 6 m gain (< 10 m floor) -> flat, but formatted climb is non-zero.
        let c = ElevationProfileContent(ride: ride(track: [pt(10), pt(13)], climb: 6),
                                        units: .imperial)
        #expect(c.kind == .flat)
        #expect(c.isTrivialClimb == false)         // 6 m -> "20" ft
    }

    @Test func preElevationRideIsUnavailable() {
        let c = ElevationProfileContent(ride: ride(track: [pt(nil), pt(nil)], climb: 0),
                                        units: .imperial)
        #expect(c.kind == .unavailable)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter ElevationProfileContentTests`
Expected: FAIL — "cannot find 'ElevationProfileContent' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `AuraCore/Sources/AuraKit/Summary/ElevationProfileContent.swift`:

```swift
import AuraCore

/// Everything the ride summary's elevation band renders, resolved to display-ready
/// primitives in the pure layer. The SwiftUI band is a dumb `switch` over `kind`.
/// The climb callout number and the profile/flat decision are both cumulative gain,
/// so the label and the number can never disagree on screen.
public struct ElevationProfileContent: Equatable, Sendable {
    public let kind: ElevationProfile.Kind
    public let climbedValue: String
    public let climbedUnit: String
    public let climbedUnitSpoken: String
    /// True when the formatted climb reads zero — the flat line drops the climb clause.
    public let isTrivialClimb: Bool

    public init(ride: Ride, units: DistanceUnits) {
        let stats = ride.stats ?? .zero
        let fmt = RideStatsFormatter(units: units)
        kind = ElevationProfile.classify(track: ride.track,
                                         gainMeters: stats.elevationGainMeters)
        climbedValue = fmt.elevationValue(stats.elevationGainMeters)
        climbedUnit = fmt.elevationUnit
        climbedUnitSpoken = fmt.elevationUnitSpoken
        isTrivialClimb = climbedValue == "0"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter ElevationProfileContentTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Summary/ElevationProfileContent.swift AuraCore/Tests/AuraKitTests/ElevationProfileContentTests.swift
git commit -m "feat(core): ElevationProfileContent summary view-model"
```

---

### Task 3: Migrate `ShareCardContent` to the shared classifier

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift:10-11` (remove `minElevationRangeMeters`) and `:44-48` (the elevation gate)
- Modify (tests): `AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift` (rewrite the range-based test to gain semantics; add a parity test)

**Interfaces:**
- Consumes: `ElevationProfile.classify` (Task 1); `ElevationProfileContent` (Task 2, for the parity test).
- Produces: no signature change — `ShareCardContent.elevationSamples: [Double]` stays, now sourced from the shared classifier (behavior changes: gain-gated, not range-gated).

**Why the behavior change:** the current gate uses peak-to-trough *range* (≥5 m); the shared classifier uses cumulative *gain* (≥10 m). A single-bump 6 m-range ride that used to draw a sparkline on the card now shows the climb as a plain stat, and vice-versa. This is the intended consistency fix — the card and summary now agree.

- [ ] **Step 1: Update the failing tests first (TDD: red)**

In `AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift`, REPLACE the whole `flatOrTinyElevationYieldsEmptyButRealReliefKept` test with the gain-gated version, and ADD a parity test. The existing `elevationRequiresTwoSamples` test stays as-is (it still passes: its `stats()` gain is 73 m, so `[10,20]` → `.profile` → `[10,20]`; the single-sample and no-sample cases → `.unavailable` → empty).

```swift
    @Test func gainGateDrivesElevationSamples() {
        // Below the 10 m climb floor -> empty, regardless of track shape.
        let flatStats = stats(climb: 2)
        let flat = ride(track: [point(0, 0, elevation: 12), point(1, 1, elevation: 12)], stats: flatStats)
        #expect(ShareCardContent(ride: flat, units: .imperial).elevationSamples.isEmpty)
        let tiny = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 13)], stats: flatStats)
        #expect(ShareCardContent(ride: tiny, units: .imperial).elevationSamples.isEmpty)
        // Real climb (stats gain 73 m >= 10) -> samples kept.
        let real = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 40)], stats: stats())
        #expect(ShareCardContent(ride: real, units: .imperial).elevationSamples == [10, 40])
    }

    @Test func cardAndSummaryClassifyIdentically() {
        func cardHasProfile(_ r: Ride) -> Bool {
            !ShareCardContent(ride: r, units: .imperial).elevationSamples.isEmpty
        }
        func summaryHasProfile(_ r: Ride) -> Bool {
            if case .profile = ElevationProfileContent(ride: r, units: .imperial).kind { return true }
            return false
        }
        let real = ride(track: [point(0, 0, elevation: 10), point(1, 1, elevation: 40)], stats: stats())
        let flat = ride(track: [point(0, 0, elevation: 12), point(1, 1, elevation: 12)], stats: stats(climb: 2))
        #expect(cardHasProfile(real) == summaryHasProfile(real))   // both true
        #expect(cardHasProfile(flat) == summaryHasProfile(flat))   // both false
    }
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `cd AuraCore && swift test --filter ShareCardContentTests`
Expected: FAIL — `gainGateDrivesElevationSamples` fails (old range gate keeps `tiny`/`flat` logic differently) and/or `cardAndSummaryClassifyIdentically` fails to compile until the source is migrated. (Confirms the tests exercise the new behavior.)

- [ ] **Step 3: Migrate the source**

In `AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift`, DELETE the doc-comment + constant at the top of the struct:

```swift
    /// Minimum peak-to-trough elevation range (meters) for the card to draw an elevation
    /// profile; below this a ride is treated as flat and the climb shows as a plain stat.
    private static let minElevationRangeMeters = 5.0
```

and REPLACE the elevation block near the end of `init` (currently the `let elevations = ...` / `hasRelief` / `elevationSamples = ...` lines) with:

```swift
        // The card draws the silhouette only for a real climb, gated on cumulative gain
        // via the shared classifier so the card and the ride summary never disagree.
        if case .profile(let samples) = ElevationProfile.classify(
            track: ride.track, gainMeters: stats.elevationGainMeters) {
            elevationSamples = samples
        } else {
            elevationSamples = []
        }
```

- [ ] **Step 4: Run the full AuraKit suite to verify green**

Run: `cd AuraCore && swift test`
Expected: PASS — all `ShareCardContentTests` (including the two updated), plus Tasks 1–2 suites, plus the rest of AuraKitTests/AuraCoreTests.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Sharing/ShareCardContent.swift AuraCore/Tests/AuraKitTests/ShareCardContentTests.swift
git commit -m "refactor(core): share card uses shared gain-gated ElevationProfile classifier"
```

---

### Task 4: `ElevationProfileBand` view + `RideSummaryView` integration (app target)

**Files:**
- Create: `Aura/Sources/Ride/ElevationProfileBand.swift`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift` (insert the band after `heroDistance`; bump `supportingStats` reveal delay `0.15 → 0.20`; drop the climbed cell from `supportingCells`)

**Interfaces:**
- Consumes: `ElevationProfileContent` (Task 2) and its `kind`/`climbedValue`/`climbedUnit`/`climbedUnitSpoken`/`isTrivialClimb`; the existing app-target `ElevationSparkline(elevations:stroke:fill:lineWidth:)`; `AuraTheme.accent`, `AuraTheme.secondaryText(_:)`, `AuraTheme.hairline(_:)`, `AuraTheme.Spacing.*`.
- Produces: `struct ElevationProfileBand: View` taking `let content: ElevationProfileContent`.

No unit test — this is SwiftUI view + integration. It is verified by a clean build, SwiftLint, and the on-device visual pass (Task 4 steps 3–5). Do NOT add an XCUITest (out of scope).

- [ ] **Step 1: Create the band view**

Create `Aura/Sources/Ride/ElevationProfileBand.swift`:

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The ride summary's elevation band — the "how hard was it" effort story. A dumb
/// projection of `ElevationProfileContent`: a silhouette + climb callout for a real
/// climb, a slim "Mostly flat" line otherwise, and nothing for pre-elevation rides.
/// The silhouette reuses the pure-Canvas `ElevationSparkline` (same language as the
/// share card, scaled up). Self-scaling per ride: the silhouette shows shape; the
/// callout number carries the true magnitude.
struct ElevationProfileBand: View {
    let content: ElevationProfileContent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        switch content.kind {
        case .profile(let samples):
            profile(samples)
        case .flat:
            flatLine
        case .unavailable:
            EmptyView()
        }
    }

    private func profile(_ samples: [Double]) -> some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            Label("\(content.climbedValue) \(content.climbedUnit) climbed",
                  systemImage: "arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.accent)

            ElevationSparkline(elevations: samples,
                               stroke: AuraTheme.accent,
                               fill: AuraTheme.accent.opacity(0.18),
                               lineWidth: 2)
                .frame(height: 110)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AuraTheme.hairline(contrast))
                        .frame(height: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profileLabel)
    }

    private var flatLine: some View {
        Label(flatText, systemImage: "minus")
            .font(.subheadline)
            .foregroundStyle(AuraTheme.secondaryText(contrast))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(flatLabel)
    }

    private var flatText: String {
        content.isTrivialClimb
            ? "Mostly flat"
            : "Mostly flat · \(content.climbedValue) \(content.climbedUnit) climbed"
    }
    private var profileLabel: String {
        "Elevation. Climbed \(content.climbedValue) \(content.climbedUnitSpoken)."
    }
    private var flatLabel: String {
        content.isTrivialClimb
            ? "Mostly flat."
            : "Mostly flat. Climbed \(content.climbedValue) \(content.climbedUnitSpoken)."
    }
}
```

- [ ] **Step 2: Integrate into `RideSummaryView`**

In `Aura/Sources/Ride/RideSummaryView.swift`:

(a) Insert the band between `heroDistance` (delay 0.10) and `supportingStats`, and change `supportingStats`'s delay from `0.15` to `0.20`. The block becomes:

```swift
                heroDistance
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.10), value: revealed)

                ElevationProfileBand(content: ElevationProfileContent(ride: ride, units: settings.units))
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.15), value: revealed)

                supportingStats
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.20), value: revealed)
```

(b) Drop the climbed cell from `supportingCells` — it now becomes two stats:

```swift
    @ViewBuilder private var supportingCells: some View {
        stat(fmt.minutes(stats.movingTimeSeconds), "moving")
        stat(fmt.speedValue(stats.maxSpeedMetersPerSecond, decimals: 1), metric ? "km/h top" : "mph top")
    }
```

- [ ] **Step 3: Regenerate the project and build (delegate to the builder agent)**

Delegate to the `apple-platform-build-tools:builder` agent so build logs stay out of context. Instruct it to, from the worktree root:

```bash
xcodegen generate
xcodebuild -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 17' build
git checkout -- AuraCore/Package.resolved   # revert Mapbox SPM pin churn
```

Expected: BUILD SUCCEEDED. (If "cannot find 'ElevationProfileBand' in scope", `xcodegen generate` was not run first.)

- [ ] **Step 4: Lint**

Run: `swiftlint lint --strict`
Expected: no violations (watch the `Label`/interpolation lines against the 140-col limit; the per-state `switch` avoids `void_function_in_ternary`).

- [ ] **Step 5: On-device visual pass (sim, via History)**

Boot the iPhone 17 sim, open the app, and via History (seeded rides live there) confirm:
- A real hilly ride: silhouette draws + `↑ X climbed` callout, and the callout magnitude matches the shape (no contradiction).
- A flat ride: the slim "Mostly flat …" line renders and NOT a solid bar (the I1 regression).
- A pre-elevation ride (no elevation samples): no band at all; the stat row shows `moving · top` only.
- Small-screen check: resize to an SE/mini-class sim (or inspect layout) and confirm the stats stay reachable with minimal scroll and the entrance stagger reads sequentially (hero → band → stats).

Capture screenshots for the review package. Prefer the accessibility tree / screenshots per the sim tooling notes.

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/Ride/ElevationProfileBand.swift Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(app): elevation-profile band on the ride summary; drop climbed stat"
```

---

## Notes for the executor

- Tasks 1–3 are pure and TDD-clean. Task 4 is app-target UI; its "test" is the build + lint + on-device visual pass.
- Do NOT commit `AuraCore/Package.resolved` churn from the app build.
- The visual craft (exact spacing/weights/hairline/callout position) may be refined during Task 4 step 5 — consult `impeccable` + `swiftui-layout-components` if adjusting, keeping the share card's silhouette language.
- `minGainMeters = 10.0` is tunable; if the on-device pass shows too many real rides reading "Mostly flat" (or vice-versa), adjust the single constant in `ElevationProfile.swift` and note it.
