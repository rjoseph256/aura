# Ride-summary elevation profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a quiet, distance-accurate elevation-profile section to the ride-summary screen, shown only when a ride has meaningful relief.

**Architecture:** A pure `ElevationProfileBuilder` in AuraCore resamples the track's elevation series evenly by cumulative distance (so slow/stopped stretches don't over-widen the profile) and applies the share card's relief gate. A pure `ElevationProfileVoice` in AuraKit builds the composed VoiceOver label. A new `ElevationProfileSection` SwiftUI view in the app target draws it by reusing the existing `ElevationSparkline` Canvas component, and `RideSummaryView` inserts it after the supporting-stats row. The share card and `ElevationSparkline` are untouched.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing. No new dependencies (Canvas, not Swift Charts).

## Global Constraints

- Swift 6 language mode across all targets; code must compile under it.
- SwiftLint runs `--strict`; no new violations.
- AuraCore imports only `Foundation` (no SwiftUI/UIKit/Mapbox). AuraKit imports only `Foundation`/`AuraCore`. UI stays in the `Aura` app target — the package must still build on the macOS CI host.
- All displayed values go through `RideStatsFormatter` (feet/meters, miles/km) — never hardcode a unit.
- All colors/spacing come from `AuraTheme` tokens; the accent is `AuraTheme.accent` (lime), fills are flat opacity (never a gradient).
- Copy is sentence case.
- Relief gate (mirror the share card exactly): at least 2 elevation-carrying points **and** peak-to-trough range ≥ 5 m.
- Package tests run from the `AuraCore` directory with `swift test`.

---

### Task 1: `ElevationProfile` + `ElevationProfileBuilder` (pure, AuraCore)

**Files:**
- Create: `AuraCore/Sources/AuraCore/Geo/ElevationProfile.swift`
- Test: `AuraCore/Tests/AuraCoreTests/ElevationProfileBuilderTests.swift`

**Interfaces:**
- Consumes: `TrackPoint` (`coordinate: Coordinate`, `elevation: Double?`), `Geo.distance(_:_:) -> Double`, `ElevationSampling.sampleIndices(total:count:) -> [Int]` — all existing in AuraCore.
- Produces:
  - `struct ElevationProfile: Equatable, Sendable { let samples: [Double]; let minMeters: Double; let maxMeters: Double }`
  - `enum ElevationProfileBuilder { static func make(track: [TrackPoint], sampleCount: Int = 96, minRangeMeters: Double = 5) -> ElevationProfile? }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraCore

struct ElevationProfileBuilderTests {
    private func p(_ lat: Double, _ lon: Double, _ elev: Double?) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: elev, timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test func hillyRideResamplesToCountWithMinMax() {
        let track = [p(40.00, -80.0, 100), p(40.01, -80.0, 150),
                     p(40.02, -80.0, 120), p(40.03, -80.0, 180)]
        let profile = ElevationProfileBuilder.make(track: track, sampleCount: 8)
        #expect(profile != nil)
        #expect(profile?.samples.count == 8)
        #expect(profile?.minMeters == 100)
        #expect(profile?.maxMeters == 180)
        #expect(profile?.samples.first == 100)   // d = 0 → first elevation
        #expect(profile?.samples.last == 180)     // d = total → last elevation
    }

    @Test func flatRideReturnsNil() {
        let track = [p(40.0, -80.0, 100), p(40.01, -80.0, 101), p(40.02, -80.0, 102)]
        #expect(ElevationProfileBuilder.make(track: track) == nil)   // range 2 m < 5 m
    }

    @Test func fewerThanTwoElevationPointsReturnsNil() {
        let track = [p(40.0, -80.0, 100), p(40.01, -80.0, nil)]
        #expect(ElevationProfileBuilder.make(track: track) == nil)
    }

    @Test func emptyTrackReturnsNil() {
        #expect(ElevationProfileBuilder.make(track: []) == nil)
    }

    @Test func singleSegmentInterpolatesLinearlyByFraction() {
        // Two points, one segment: sample k maps to t = k/(n-1) regardless of the
        // segment's real length, so a 0→100 climb over 5 samples is exact quartiles.
        let track = [p(40.0, -80.0, 0), p(40.01, -80.0, 100)]
        #expect(ElevationProfileBuilder.make(track: track, sampleCount: 5)?.samples == [0, 25, 50, 75, 100])
    }

    @Test func distanceWeightingIgnoresClusteredSlowStretch() {
        // Ten points bunched within ~1 m (a stop), then one far point 100 m up over ~2 km.
        var track = [p(40.0, -80.0, 0)]
        for i in 1...9 { track.append(p(40.0 + Double(i) * 0.000001, -80.0, 0)) }
        track.append(p(40.02, -80.0, 100))
        let profile = ElevationProfileBuilder.make(track: track, sampleCount: 11)!
        // The mid-distance sample sits deep in the climb (~50 m), not ~0 like an index plot.
        #expect(profile.samples[5] > 40 && profile.samples[5] < 60)
    }

    @Test func degenerateZeroDistanceFallsBackToIndexSpacing() {
        // All points at one coordinate: total distance 0, but real relief. Fall back to
        // even index spacing rather than dividing by zero.
        let track = [p(40.0, -80.0, 0), p(40.0, -80.0, 10), p(40.0, -80.0, 5)]
        let profile = ElevationProfileBuilder.make(track: track, sampleCount: 5)!
        #expect(profile.samples == [0, 10, 5])
        #expect(profile.minMeters == 0)
        #expect(profile.maxMeters == 10)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AuraCore && swift test --filter ElevationProfileBuilderTests`
Expected: FAIL — `cannot find 'ElevationProfileBuilder' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A ride's elevation trace resampled to evenly-distance-spaced points, so the profile is
/// proportionally honest: GPS is time-sampled, so plotting by index over-widens the
/// stretches where the rider was slow or stopped. Pure and deterministic — the view layer
/// just draws `samples`.
public struct ElevationProfile: Equatable, Sendable {
    public let samples: [Double]      // elevation in meters, evenly spaced by distance
    public let minMeters: Double
    public let maxMeters: Double

    public init(samples: [Double], minMeters: Double, maxMeters: Double) {
        self.samples = samples
        self.minMeters = minMeters
        self.maxMeters = maxMeters
    }
}

public enum ElevationProfileBuilder {
    /// Builds a distance-resampled elevation profile, or nil when the ride has no meaningful
    /// relief: fewer than 2 elevation-carrying points, or a peak-to-trough range below
    /// `minRangeMeters`. The gate mirrors the share card so the summary and card agree.
    public static func make(track: [TrackPoint],
                            sampleCount: Int = 96,
                            minRangeMeters: Double = 5) -> ElevationProfile? {
        let pts = track.filter { $0.elevation != nil }
        guard pts.count > 1, sampleCount > 1 else { return nil }
        let elevations = pts.map { $0.elevation! }
        let lo = elevations.min()!
        let hi = elevations.max()!
        guard hi - lo >= minRangeMeters else { return nil }

        var cumulative = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count {
            cumulative[i] = cumulative[i - 1] + Geo.distance(pts[i - 1].coordinate, pts[i].coordinate)
        }
        let total = cumulative.last!

        let samples: [Double]
        if total <= 0 {
            samples = ElevationSampling.sampleIndices(total: elevations.count, count: sampleCount)
                .map { elevations[$0] }
        } else {
            samples = (0..<sampleCount).map { k in
                let d = total * Double(k) / Double(sampleCount - 1)
                return interpolatedElevation(atDistance: d, cumulative: cumulative, elevations: elevations)
            }
        }
        return ElevationProfile(samples: samples, minMeters: lo, maxMeters: hi)
    }

    /// Linear interpolation of elevation at a cumulative distance `d` along the track.
    private static func interpolatedElevation(atDistance d: Double,
                                              cumulative: [Double],
                                              elevations: [Double]) -> Double {
        if d <= 0 { return elevations.first! }
        if d >= cumulative.last! { return elevations.last! }
        var i = 1
        while i < cumulative.count && cumulative[i] < d { i += 1 }
        let segStart = cumulative[i - 1]
        let segEnd = cumulative[i]
        let span = segEnd - segStart
        let t = span > 0 ? (d - segStart) / span : 0
        return elevations[i - 1] + t * (elevations[i] - elevations[i - 1])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter ElevationProfileBuilderTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraCore/Geo/ElevationProfile.swift AuraCore/Tests/AuraCoreTests/ElevationProfileBuilderTests.swift
git commit -m "feat(core): distance-accurate elevation profile builder"
```

---

### Task 2: `ElevationProfileVoice` (pure, AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Formatting/ElevationProfileVoice.swift`
- Test: `AuraCore/Tests/AuraKitTests/ElevationProfileVoiceTests.swift`

**Interfaces:**
- Consumes: `RideStatsFormatter` (`elevationValue(_:) -> String`, `elevationUnitSpoken: String`) from AuraKit.
- Produces: `enum ElevationProfileVoice { static func label(climbedMeters: Double, minMeters: Double, maxMeters: Double, formatter: RideStatsFormatter) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import AuraKit

struct ElevationProfileVoiceTests {
    @Test func imperialLabelReadsFeetAndComposesViaFormatter() {
        let f = RideStatsFormatter(units: .imperial)
        let s = ElevationProfileVoice.label(climbedMeters: 103.6, minMeters: 341, maxMeters: 414, formatter: f)
        #expect(s == "Elevation profile. Climbed \(f.elevationValue(103.6)) feet, "
              + "from \(f.elevationValue(341)) to \(f.elevationValue(414)) feet.")
    }

    @Test func metricLabelReadsMeters() {
        let f = RideStatsFormatter(units: .metric)
        let s = ElevationProfileVoice.label(climbedMeters: 100, minMeters: 340, maxMeters: 380, formatter: f)
        #expect(s == "Elevation profile. Climbed \(f.elevationValue(100)) meters, "
              + "from \(f.elevationValue(340)) to \(f.elevationValue(380)) meters.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd AuraCore && swift test --filter ElevationProfileVoiceTests`
Expected: FAIL — `cannot find 'ElevationProfileVoice' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import AuraCore

/// Builds the single composed VoiceOver label for the ride-summary elevation profile,
/// unit-aware so metric riders hear meters and imperial riders feet. Pure so it is
/// unit-tested rather than assembled in the view.
public enum ElevationProfileVoice {
    public static func label(climbedMeters: Double,
                             minMeters: Double,
                             maxMeters: Double,
                             formatter: RideStatsFormatter) -> String {
        let climbed = formatter.elevationValue(climbedMeters)
        let lo = formatter.elevationValue(minMeters)
        let hi = formatter.elevationValue(maxMeters)
        let unit = formatter.elevationUnitSpoken
        return "Elevation profile. Climbed \(climbed) \(unit), from \(lo) to \(hi) \(unit)."
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd AuraCore && swift test --filter ElevationProfileVoiceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Formatting/ElevationProfileVoice.swift AuraCore/Tests/AuraKitTests/ElevationProfileVoiceTests.swift
git commit -m "feat(kit): composed VoiceOver label for the elevation profile"
```

---

### Task 3: `ElevationProfileSection` view + `RideSummaryView` wiring (app target)

**Files:**
- Create: `Aura/Sources/Ride/ElevationProfileSection.swift`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift` (add a computed `elevationProfile` and insert the section after `supportingStats`, before the `if ride.stats != nil` Share group)

**Interfaces:**
- Consumes: `ElevationProfile` + `ElevationProfileBuilder.make(track:)` (Task 1); `ElevationProfileVoice.label(...)` (Task 2); existing `ElevationSparkline(elevations:stroke:fill:lineWidth:)`, `RideStatsFormatter`, `AuraTheme`.
- Produces: `struct ElevationProfileSection: View` (app-internal).

- [ ] **Step 1: Create the section view**

```swift
import SwiftUI
import AuraCore
import AuraKit

/// The ride-summary elevation profile: a quiet labelled section drawing a distance-accurate
/// trace (from `ElevationProfileBuilder`) with min/max context, composed into one VoiceOver
/// element. Reuses `ElevationSparkline` for the Canvas trace, so the share card is untouched.
struct ElevationProfileSection: View {
    let profile: ElevationProfile
    let climbedMeters: Double
    let distanceMeters: Double
    let fmt: RideStatsFormatter
    var contrast: ColorSchemeContrast = .standard

    private var fillOpacity: Double { contrast == .increased ? 0.24 : 0.15 }

    var body: some View {
        VStack(alignment: .leading, spacing: AuraTheme.Spacing.sm) {
            Text("Elevation")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AuraTheme.secondaryText(contrast))

            ElevationSparkline(elevations: profile.samples,
                               stroke: AuraTheme.accent,
                               fill: AuraTheme.accent.opacity(fillOpacity),
                               lineWidth: 2.5)
                .frame(height: 100)
                .overlay(alignment: .topLeading) {
                    Text("\(fmt.elevationValue(profile.maxMeters)) \(fmt.elevationUnit)")
                        .font(.caption2)
                        .foregroundStyle(AuraTheme.secondaryText(contrast))
                }
                .overlay(alignment: .bottomLeading) {
                    Text("\(fmt.elevationValue(profile.minMeters)) \(fmt.elevationUnit)")
                        .font(.caption2)
                        .foregroundStyle(AuraTheme.secondaryText(contrast))
                }

            HStack {
                Text("start")
                Spacer()
                Text("\(fmt.distanceValue(distanceMeters)) \(fmt.distanceUnit)")
            }
            .font(.caption2)
            .foregroundStyle(AuraTheme.secondaryText(contrast))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ElevationProfileVoice.label(climbedMeters: climbedMeters,
                                                        minMeters: profile.minMeters,
                                                        maxMeters: profile.maxMeters,
                                                        formatter: fmt))
    }
}
```

- [ ] **Step 2: Add the computed profile to `RideSummaryView`**

Add alongside the other computed properties (near `hasRoute`):

```swift
    private var elevationProfile: ElevationProfile? {
        ElevationProfileBuilder.make(track: ride.track)
    }
```

- [ ] **Step 3: Insert the section into the body**

In `RideSummaryView.body`, immediately after the `supportingStats` block (which ends with its `.animation(...)` modifier) and before the `if ride.stats != nil {` Share group, add:

```swift
                if let elevationProfile {
                    ElevationProfileSection(profile: elevationProfile,
                                            climbedMeters: stats.elevationGainMeters,
                                            distanceMeters: stats.distanceMeters,
                                            fmt: fmt,
                                            contrast: contrast)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 8)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.20), value: revealed)
                }
```

- [ ] **Step 4: Build the app + widgets and lint**

Delegate to the apple-platform-build-tools builder agent: build the `Aura` app target (which also builds `AuraWidgets`) for an iPhone 17 / iOS 26 simulator, and run `swiftlint --strict`. Also run the full package suite: `cd AuraCore && swift test`.
Expected: app builds clean; SwiftLint reports no violations; all package tests pass (including the 9 new ones from Tasks 1–2).

- [ ] **Step 5: Simulator verification**

Run the app on the iPhone 17 / iOS 26 simulator and confirm via the accessibility tree and a screenshot:
- A hilly recorded ride shows the Elevation section with a distance-accurate trace and min/max labels.
- A flat ride (or one with no GPS elevation) omits the section entirely — no empty chart.
- Imperial vs metric units switch the labels (ft/mi ↔ m/km).
- The section reads as one VoiceOver utterance: "Elevation profile. Climbed …, from … to ….".
- Reduce Motion: the section appears without animating.

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/Ride/ElevationProfileSection.swift Aura/Sources/Ride/RideSummaryView.swift
git commit -m "feat(app): elevation profile on the ride summary"
```

---

## Self-Review

**Spec coverage:**
- Placement below stats, shown only on relief → Task 3 Step 3 insertion + Task 1 gate. ✓
- Reuse share-card gate (≥2 points, ≥5 m) → Task 1 (`minRangeMeters: 5`, `pts.count > 1`). ✓
- Distance-accurate X-axis via a pure AuraCore resampler → Task 1. ✓
- Canvas reuse of `ElevationSparkline`, share card untouched → Task 3 Step 1 (composes it; no edit to `ElevationSparkline.swift` or the share card). ✓
- Units via `RideStatsFormatter` → Tasks 2 & 3. ✓
- Composed, unit-aware VoiceOver, pure/tested → Task 2 + applied in Task 3. ✓
- Increase-Contrast fill/label path → Task 3 `fillOpacity` + `AuraTheme.secondaryText(contrast)`. ✓
- No motion → Task 3 uses only the existing staggered reveal, no chart animation. ✓
- Degenerate/edge cases (zero distance, sparse elevation, below-sea-level) → Task 1 (`total <= 0` fallback, `filter` on elevation, min/max from data). ✓
- Tests in AuraCore/AuraKit + sim verification → Tasks 1, 2, 3 Steps 4–5. ✓

**Placeholder scan:** none — every code step carries complete code; every run step has a command and expected result.

**Type consistency:** `ElevationProfile{samples,minMeters,maxMeters}`, `ElevationProfileBuilder.make(track:sampleCount:minRangeMeters:)`, and `ElevationProfileVoice.label(climbedMeters:minMeters:maxMeters:formatter:)` are used identically in the tasks that consume them. `ColorSchemeContrast`, `RideStatsFormatter`, `AuraTheme.accent`/`secondaryText(contrast)`/`Spacing.sm`, and `ElevationSparkline(elevations:stroke:fill:lineWidth:)` match the real signatures read from the codebase.
