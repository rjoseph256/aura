# Routing Correctness Fixes Plan

> **For agentic workers:** TDD per fix. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Four shelved correctness fixes from the ROADMAP "Smaller fixes" list, batched into one PR.

**Tech Stack:** Swift 6, SwiftUI, CoreLocation, Mapbox v3. AuraCore/AuraKit must build+test on the macOS CI host.

## Global Constraints

- Swift 6; AuraCore/AuraKit pure logic stays macOS-CI-testable (no Mapbox/UIKit in tested code).
- `cd AuraCore && swift test`, the app `xcodebuild`, and SwiftLint `--strict` all stay green.
- No behavior regression on short routes / existing callers.

---

### Fix 1 — Distance-proportional elevation sampling

**Problem:** `MapboxTerrainRGBElevationProvider` samples a fixed 16 points regardless of route length (`init(sampleCount: Int = 16)`), undersampling climb on long routes and weakening the "Flattest" ranking. Tiles are cached and bounded by route geography, so more samples within the same tiles is nearly free.

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Routing/ElevationProvider.swift` (add a distance-based index helper to `ElevationSampling`)
- Modify: `Aura/Sources/Routing/MapboxTerrainRGBElevationProvider.swift` (use it)
- Test: `AuraCore/Tests/AuraCoreTests/ElevationSamplingTests.swift` (extend)

**Approach:** Add a pure helper that turns route distance into a sample count, reusing the existing even-spacing index picker.

```swift
/// Distance-proportional sample count: ~one sample per `spacingMeters` of polyline
/// length, clamped to [minCount, maxCount]. minCount keeps short routes at least as
/// detailed as the old fixed-16 behavior; maxCount caps cost on very long routes.
public static func proportionalCount(coordinates: [Coordinate], spacingMeters: Double = 150,
                                     minCount: Int = 16, maxCount: Int = 96) -> Int {
    guard coordinates.count > 1, spacingMeters > 0 else { return min(max(coordinates.count, 0), minCount) }
    var distance = 0.0
    for i in 1..<coordinates.count { distance += Geo.distance(coordinates[i - 1], coordinates[i]) }
    let raw = Int((distance / spacingMeters).rounded()) + 1
    return min(max(raw, minCount), maxCount)
}
```

The provider computes the count, then reuses `sampleIndices(total:count:)`:

- `MapboxTerrainRGBElevationProvider` swaps its `sampleCount` stored property for `spacingMeters`/`minSamples`/`maxSamples` (defaulted `150`/`16`/`96`); `init` becomes `init(spacingMeters: Double = 150, minSamples: Int = 16, maxSamples: Int = 96, zoom: Int = 14, tileCache: ...)`. Only caller is `MapboxRoutingProvider`'s default arg — update it if needed (it uses `MapboxTerrainRGBElevationProvider()`, so the new defaults apply with no change).
- In `elevations(along:)`: `let count = ElevationSampling.proportionalCount(coordinates: coordinates, spacingMeters: spacingMeters, minCount: minSamples, maxCount: maxSamples)` then `ElevationSampling.sampleIndices(total: coordinates.count, count: count)`.

- [ ] **Step 1: Tests** — add to `ElevationSamplingTests`:
  - empty / single coord → `minCount`-bounded (count clamps, no crash).
  - a ~1 km synthetic polyline at spacing 150 → count ≈ 7 → clamps up to `minCount` 16.
  - a ~30 km polyline → count clamps to `maxCount` 96 (not unbounded).
  - count is monotonic in distance (longer route ⇒ ≥ count).
  Use real `Coordinate`s and `Geo.distance`. (Pin exact expected counts from the spacing math.)
- [ ] **Step 2: Run, expect FAIL** (`swift test --filter ElevationSamplingTests`).
- [ ] **Step 3: Implement** the helper + provider wiring.
- [ ] **Step 4: Run, expect PASS** + full `swift test`.
- [ ] **Step 5: Commit** `feat(core): distance-proportional elevation sampling (was fixed 16)`.

---

### Fix 2 — Shared-scale elevation sparklines

**Problem:** `Sparkline.points(values:in:inset:)` normalizes each series to its OWN min/max, so a flat route and a hilly route look equally hilly. The comparison should share one vertical scale across the visible options.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Plotting/Plotting.swift` (range-aware `Sparkline.points`)
- Modify: `Aura/Sources/Plan/ElevationSparkline.swift` (optional `range`)
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (compute shared range in `routeRows`, thread through `RouteOptionRow`)
- Test: `AuraCore/Tests/AuraKitTests/` Sparkline tests (find existing: `grep -rl Sparkline AuraCore/Tests`)

**Approach:**

```swift
// Plotting.swift — new range-aware overload; refactor the existing one to delegate.
public static func points(values: [Double], in size: CGSize, inset: CGFloat,
                          range: ClosedRange<Double>) -> [CGPoint] {
    guard values.count > 1, size.width > 0, size.height > 0 else { return [] }
    let minV = range.lowerBound, span = range.upperBound - range.lowerBound
    let availW = max(size.width - inset * 2, 1), availH = max(size.height - inset * 2, 1)
    let last = CGFloat(values.count - 1)
    return values.enumerated().map { i, v in
        let x = inset + availW * CGFloat(i) / last
        let t: CGFloat = span > 1e-12 ? CGFloat((v - minV) / span) : 0.5
        return CGPoint(x: x, y: inset + availH * (1 - t))
    }
}
// Existing signature delegates with the series' own range (unchanged behavior):
public static func points(values: [Double], in size: CGSize, inset: CGFloat) -> [CGPoint] {
    guard let lo = values.min(), let hi = values.max() else { return [] }
    return points(values: values, in: size, inset: inset, range: lo...hi)
}
```

- `ElevationSparkline` gains `var range: ClosedRange<Double>? = nil`; body uses `Sparkline.points(values:in:inset:range:)` when non-nil, else the self-scaling overload (so any other caller is unaffected).
- `RoutePreviewView.routeRows`: compute `sharedElevationRange` over all visible routes:
  ```swift
  let allElevs = routes.flatMap(\.elevationProfile)
  let sharedElevationRange: ClosedRange<Double>? =
      allElevs.isEmpty ? nil : (allElevs.min()!...allElevs.max()!)
  ```
  Pass it to each `RouteOptionRow(route:..., elevationRange: sharedElevationRange)`, which forwards it to `ElevationSparkline(range:)`.

- [ ] **Step 1: Tests** — range-aware `Sparkline.points`: a flat series under a wide range sits near the bottom (not center); two different series under the SAME range produce y-values whose ordering reflects the shared scale; a zero-span range renders flat at center; the no-range overload still self-scales (regression).
- [ ] **Step 2: FAIL** → **Step 3: Implement** → **Step 4: PASS** + app build.
- [ ] **Step 5: Commit** `feat(app): shared vertical scale across route elevation sparklines`.

---

### Fix 3 — Carry the Mapbox route index through the ranker

**Problem:** `MapboxRoutingProvider` correlates each labeled `Route` back to its `mbRoutes` index by matching `mb.distance == route.distanceMeters` (exact `Double`) plus the first geometry coordinate. Every route starts at the same origin, so the coordinate tie-breaker is nearly useless; two equal-distance alternatives can mis-map. `RouteRanker.label` already computes the winning candidate index — surface it.

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Routing/RouteRanker.swift`
- Modify: `Aura/Sources/Routing/MapboxRoutingProvider.swift:116-129`
- Test: `AuraCore/Tests/AuraCoreTests/RouteRankerTests.swift` (extend)

**Approach:** Add an index-carrying variant; keep `label` as a thin wrapper so the 4 existing `RouteRanker.label` test call sites stay green.

```swift
public struct LabeledRoute: Equatable, Sendable {
    public let route: Route
    public let sourceIndex: Int   // index into the input `candidates` array
    public init(route: Route, sourceIndex: Int) { self.route = route; self.sourceIndex = sourceIndex }
}

public static func labeled(origin: Coordinate, destination: Coordinate,
                           candidates: [CandidateRoute]) -> [LabeledRoute] {
    // identical winner logic, but emit LabeledRoute(route:, sourceIndex: idx)
}

public static func label(origin: Coordinate, destination: Coordinate,
                         candidates: [CandidateRoute]) -> [Route] {
    labeled(origin: origin, destination: destination, candidates: candidates).map(\.route)
}
```

Provider (step 8): `candidates[i]` is built in `mbRoutes` order (line 101), so `sourceIndex` == mbRoutes index. Replace the value-matching loop:

```swift
let labeledRoutes = AuraCore.RouteRanker.labeled(origin: ..., destination: ..., candidates: candidates)
var indexByRouteId: [UUID: Int] = [:]
for lr in labeledRoutes { indexByRouteId[lr.route.id] = lr.sourceIndex }
let labeled = labeledRoutes.map(\.route)   // returned + used downstream as before
```

(Add a one-line invariant comment at line 101 that `candidates[i]` ↔ `mbRoutes[i]`, which `sourceIndex` relies on.)

- [ ] **Step 1: Tests** — `labeled(...)` returns the correct `sourceIndex` for each profile winner; e.g. with 3 candidates where candidate 2 is flattest and candidate 0 fastest, the flattest `LabeledRoute.sourceIndex == 2`. A two-equal-distance case (the old bug): two candidates with identical `distanceMeters` map to distinct source indices. `label(...)` still returns the same `[Route]` as before (regression).
- [ ] **Step 2: FAIL** → **Step 3: Implement** → **Step 4: PASS** + full suite + app build.
- [ ] **Step 5: Commit** `fix(core): carry source index through RouteRanker; drop Double-equality route correlation`.

---

### Fix 4 — Stable key for the search suggestions list

**Problem:** `DestinationSearchView` keys its results `ForEach` on the array offset (`id: \.offset`), churning row identity as suggestions stream in.

**Files:**
- Modify: `Aura/Sources/Plan/DestinationSearchView.swift:78`

**Approach:** `PlaceAutocomplete.Suggestion` exposes `name`, `description`, `coordinate` (no stable id). Key on a composite content string:

```swift
private extension PlaceAutocomplete.Suggestion {
    var rowKey: String {
        let lat = coordinate?.latitude ?? 0, lon = coordinate?.longitude ?? 0
        return "\(name)|\(description ?? "")|\(lat),\(lon)"
    }
}
// ...
ForEach(suggestions, id: \.rowKey) { suggestion in
    SuggestionRow(suggestion: suggestion) { resolveSuggestion(suggestion) }
    if suggestion.rowKey != suggestions.last?.rowKey {
        Divider().background(AuraTheme.border).padding(.leading, 60)
    }
}
```

(Drop `Array(...enumerated())`; iterate `suggestions` directly. The divider's "is this the last row" check moves from `name` to `rowKey` for consistency.)

App-target only; no unit test (SwiftUI). Verified by the app `xcodebuild` + reading.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: App build** (delegate to build agent).
- [ ] **Step 3: Commit** `fix(app): stable content key for destination search suggestions`.

---

## Self-Review

- **Coverage:** all four ROADMAP "Smaller fixes" entries (16-point sampling, sparkline self-normalization, Mapbox Double-equality correlation, search offset key).
- **macOS CI:** Fixes 1 & 3 are pure AuraCore (tested); Fix 2's `Sparkline.points` is AuraKit (tested); the app-target view changes are build-verified.
- **No-regression:** existing `Sparkline.points`/`RouteRanker.label` signatures preserved as delegating wrappers, so existing tests/callers stay green; short routes keep ≥16 elevation samples.
- **Type consistency:** `ClosedRange<Double>` for the shared scale; `LabeledRoute.sourceIndex: Int` indexes the `candidates` array, which the provider keeps in `mbRoutes` order.
- **Open confirmations:** exact expected sample counts in Fix 1 tests (compute from spacing math); existing Sparkline test file location (Fix 2); `RouteOptionRow` lives in `RoutePreviewView.swift` and takes a single `route` today (thread the range param through it).
