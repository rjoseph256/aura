# Aura v1 — Plan 3: Routing + Navigate-mode HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add destination navigation: search a place, get up to three bike-aware route options (**Most paths / Fastest / Flattest**), preview them, and ride one in a turn-by-turn **navigate-mode HUD** — the dark cockpit with a turn card that grows as a maneuver approaches, plus voice guidance — recording the ride just like free-ride.

**Architecture:** Two pure, fully-tested logic units land in `AuraKit`: `RouteMetrics` (distance-weighted off-road share + elevation gain, which turn Mapbox routes into `AuraCore.CandidateRoute`s) and `TurnCardPresenter` (the adaptive turn-card display logic — the soul of "option C"). The app gets `MapboxRoutingProvider` (implements `AuraCore.RoutingProvider` via Mapbox Directions → `RouteMetrics` → `RouteRanker.label`), a destination search + route-preview UI, and a navigate-mode HUD driven by the Mapbox **Navigation** SDK's route-progress, feeding our custom turn card and the existing `RideRecorder`.

**Tech Stack:** Swift 5.10+, SwiftUI, Mapbox **Navigation** SDK v3 + **Search** SDK for iOS, `AuraCore` + `AuraKit`, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-22-aura-cycling-app-v1-design.md`
**Depends on:** Plan 1 (`AuraCore`) and Plan 2 (`AuraKit`, app shell, Mapbox Maps, free-ride HUD).

**This is Plan 3 of 4.** Scope: navigate-to-a-destination. Persistent history, saved places across launches, settings, and offline maps are Plan 4 (this plan keeps saved/recent places in memory).

### Notes for implementers
- **Mapbox API drift (important here):** the Navigation SDK v3 and Search SDK APIs are the most volatile surface in the whole project. The glue code below (Tasks 3–8) targets **v3** symbols and is **representative** — verify every Mapbox type/method against the installed SDK version's docs and adjust. The deterministic `RouteMetrics` and `TurnCardPresenter` logic (Tasks 1–2) is Mapbox-independent and is the correctness source of truth; lean on its tests.
- **`MapboxRoutingProvider` is build/run-verified, not unit-tested** (it wraps a network SDK). Its pure sub-computations are extracted into `RouteMetrics` and tested. Don't add brittle network mocking; verify route quality by running real Pittsburgh queries.
- **Design-skill checkpoint:** build the route-preview and navigate-HUD UI (Tasks 6–7) through `impeccable` / `emil-design-eng` per the project instruction.

---

## File Structure

```
biking-app/
  AuraCore/
    Sources/AuraKit/
      RouteMetrics.swift            # offRoadFraction + elevationGain (pure)
      TurnCardPresenter.swift       # adaptive turn-card state (pure)
    Tests/AuraKitTests/
      RouteMetricsTests.swift
      TurnCardPresenterTests.swift
  Aura/
    project.yml                     # MODIFY: + MapboxNavigation, MapboxSearch
    Sources/
      Routing/MapboxRoutingProvider.swift   # AuraCore.RoutingProvider via Mapbox Directions
      Plan/PlanView.swift                    # Home/Plan: search + "Free ride" + recents
      Plan/DestinationSearchView.swift       # Mapbox Search field + results
      Plan/RoutePreviewView.swift            # 3 labeled options + map + Start RIDE
      Ride/NavigateHUDView.swift             # turn-by-turn cockpit (turn card + rail + voice)
      Ride/TurnCardView.swift                # the growing turn card
      Ride/NavigationMapView.swift           # Mapbox NavigationMapView wrapper (route + puck)
      App/AppRouter.swift                    # nav state: plan → preview → ride → summary
    Sources/AuraApp.swift           # MODIFY: root is PlanView via AppRouter
```

---

## Prerequisites

- [ ] Plan 1 + Plan 2 complete and green (`cd AuraCore && swift test`; app builds).
- [ ] Same Mapbox account/tokens as Plan 2 (Navigation + Search SDKs download with the same `Downloads:Read` secret token in `~/.netrc`; runtime uses the same `pk.…`).
- [ ] Branch: `git checkout -b plan-3-routing-nav`.

---

## Task 1: `RouteMetrics` — off-road share + elevation gain (pure)

**Files:**
- Create: `AuraCore/Sources/AuraKit/RouteMetrics.swift`
- Test: `AuraCore/Tests/AuraKitTests/RouteMetricsTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/RouteMetricsTests.swift`:
```swift
import XCTest
@testable import AuraKit

final class RouteMetricsTests: XCTestCase {
    func test_offRoadFraction_isDistanceWeighted() {
        let segments: [(distanceMeters: Double, isOffRoad: Bool)] = [
            (300, true),   // path
            (100, false),  // road
            (100, true),   // path
        ]
        // 400 off-road of 500 total = 0.8
        XCTAssertEqual(RouteMetrics.offRoadFraction(segments: segments), 0.8, accuracy: 0.0001)
    }

    func test_offRoadFraction_emptyOrZeroDistance_isZero() {
        XCTAssertEqual(RouteMetrics.offRoadFraction(segments: []), 0, accuracy: 0.0001)
        XCTAssertEqual(RouteMetrics.offRoadFraction(segments: [(0, true)]), 0, accuracy: 0.0001)
    }

    func test_elevationGain_sumsPositiveDeltasAboveNoise() {
        // +5, -3 (ignored), +6, +0.4 (noise, ignored) = 11
        let profile = [250.0, 255, 252, 258, 258.4]
        XCTAssertEqual(RouteMetrics.elevationGain(elevations: profile), 11, accuracy: 0.0001)
    }

    func test_elevationGain_shortProfile_isZero() {
        XCTAssertEqual(RouteMetrics.elevationGain(elevations: [250]), 0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter RouteMetricsTests`
Expected: FAIL — `RouteMetrics` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraKit/RouteMetrics.swift`:
```swift
import Foundation

/// Pure helpers that turn raw route geometry/annotations into the metrics
/// `AuraCore.CandidateRoute` needs (so `RouteRanker` can label routes).
public enum RouteMetrics {
    /// Distance-weighted share (0...1) of a route that runs on off-road paths/trails.
    public static func offRoadFraction(segments: [(distanceMeters: Double, isOffRoad: Bool)]) -> Double {
        let total = segments.reduce(0) { $0 + $1.distanceMeters }
        guard total > 0 else { return 0 }
        let offRoad = segments.reduce(0) { $0 + ($1.isOffRoad ? $1.distanceMeters : 0) }
        return offRoad / total
    }

    /// Total climb (m): sum of positive elevation deltas above a noise threshold.
    public static func elevationGain(elevations: [Double], noiseThreshold: Double = 1.0) -> Double {
        guard elevations.count >= 2 else { return 0 }
        var gain = 0.0
        for i in 1..<elevations.count {
            let delta = elevations[i] - elevations[i - 1]
            if delta >= noiseThreshold { gain += delta }
        }
        return gain
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter RouteMetricsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/RouteMetrics.swift AuraCore/Tests/AuraKitTests/RouteMetricsTests.swift
git commit -m "feat(kit): RouteMetrics (off-road share + elevation gain)"
```

---

## Task 2: `TurnCardPresenter` — the adaptive turn-card logic (pure)

**Files:**
- Create: `AuraCore/Sources/AuraKit/TurnCardPresenter.swift`
- Test: `AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift`

- [ ] **Step 1: Write the failing test**

`AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift`:
```swift
import XCTest
@testable import AuraKit

final class TurnCardPresenterTests: XCTestCase {
    func test_distanceFormatting_feetThenMiles() {
        // 120 m ≈ 394 ft → rounded to nearest 10 ft = "390 ft"
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 120, instruction: "x").distanceText, "390 ft")
        // 400 m ≈ 1312 ft → switches to miles ≈ "0.2 mi"
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 400, instruction: "x").distanceText, "0.2 mi")
    }

    func test_isExpanded_whenWithinThreshold() {
        XCTAssertTrue(TurnCardPresenter.state(distanceToManeuverMeters: 100, instruction: "x", expandWithinMeters: 150).isExpanded)
        XCTAssertFalse(TurnCardPresenter.state(distanceToManeuverMeters: 200, instruction: "x", expandWithinMeters: 150).isExpanded)
    }

    func test_passesInstructionThrough() {
        XCTAssertEqual(TurnCardPresenter.state(distanceToManeuverMeters: 50, instruction: "Right onto Penn Ave").primaryText,
                       "Right onto Penn Ave")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd AuraCore && swift test --filter TurnCardPresenterTests`
Expected: FAIL — `TurnCardPresenter` undefined.

- [ ] **Step 3: Write minimal implementation**

`AuraCore/Sources/AuraKit/TurnCardPresenter.swift`:
```swift
import Foundation
import AuraCore

public struct TurnCardState: Equatable, Sendable {
    public var primaryText: String     // maneuver instruction, e.g. "Right onto Penn Ave"
    public var distanceText: String    // distance to the maneuver, e.g. "390 ft" or "0.2 mi"
    public var isExpanded: Bool         // true when the maneuver is near → the card grows
}

/// Adaptive turn-card display logic (the "option C" behavior). Pure + Mapbox-independent.
public enum TurnCardPresenter {
    public static func state(distanceToManeuverMeters: Double,
                             instruction: String,
                             expandWithinMeters: Double = 150) -> TurnCardState {
        let feet = UnitConverter.feet(fromMeters: distanceToManeuverMeters)
        let distanceText: String
        if feet >= 1000 {
            distanceText = String(format: "%.1f mi", UnitConverter.miles(fromMeters: distanceToManeuverMeters))
        } else {
            let rounded = Int((feet / 10).rounded()) * 10
            distanceText = "\(rounded) ft"
        }
        return TurnCardState(primaryText: instruction,
                             distanceText: distanceText,
                             isExpanded: distanceToManeuverMeters <= expandWithinMeters)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd AuraCore && swift test --filter TurnCardPresenterTests`
Expected: PASS (3 tests). (Check: 120 m → 393.7 ft → /10=39.37 → round 39 → ×10 = 390 ft. 400 m → 0.2486 mi → "0.2 mi".)

- [ ] **Step 5: Full suite green**

Run: `cd AuraCore && swift test`
Expected: PASS — all AuraCore + AuraKit tests.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/TurnCardPresenter.swift AuraCore/Tests/AuraKitTests/TurnCardPresenterTests.swift
git commit -m "feat(kit): TurnCardPresenter adaptive turn-card logic"
```

---

## Task 3: Add Mapbox Navigation + Search SDKs

**Files:**
- Modify: `Aura/project.yml`

- [ ] **Step 1: Add packages + products**

In `Aura/project.yml` under `packages:` add:
```yaml
  MapboxNavigation:
    url: https://github.com/mapbox/mapbox-navigation-ios.git
    majorVersion: 3.0.0
  MapboxSearch:
    url: https://github.com/mapbox/search-ios.git
    majorVersion: 2.0.0
```
Under the `Aura` target `dependencies:` add (verify exact product names against the installed SDKs):
```yaml
      - package: MapboxNavigation
        product: MapboxNavigationCore
      - package: MapboxNavigation
        product: MapboxNavigationUIKit
      - package: MapboxSearch
        product: MapboxSearch
      - package: MapboxSearch
        product: MapboxSearchUI
```

- [ ] **Step 2: Regenerate + build**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED (SDKs resolve via SPM; may take a while on first fetch). If a product name is wrong, correct it against the SDK's `Package.swift` and regenerate.

- [ ] **Step 3: Commit**

```bash
git add Aura/project.yml
git commit -m "build(app): add Mapbox Navigation + Search SDKs"
```

---

## Task 4: `MapboxRoutingProvider` — Directions → CandidateRoute → RouteRanker

**Files:**
- Create: `Aura/Sources/Routing/MapboxRoutingProvider.swift`

- [ ] **Step 1: Implement the provider** (representative v3 API — verify symbols)

`Aura/Sources/Routing/MapboxRoutingProvider.swift`:
```swift
import Foundation
import AuraCore
import AuraKit
import MapboxNavigationCore   // verify: Directions/RouteOptions live here in v3
import MapboxDirections

/// Implements AuraCore.RoutingProvider using Mapbox Directions (cycling profile),
/// then ranks/labels the alternatives via RouteRanker. Build/run-verified.
public struct MapboxRoutingProvider: RoutingProvider {
    public init() {}

    public func routes(for request: RouteRequest) async throws -> [Route] {
        let waypoints = ([request.origin] + request.waypoints + [request.destination])
            .map { Waypoint(coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }

        let options = RouteOptions(waypoints: waypoints, profileIdentifier: .cycling)
        options.includesAlternativeRoutes = true
        options.attributeOptions = [.distance]            // + elevation/road-class where available
        options.routeShapeResolution = .full

        let mapboxRoutes = try await fetchRoutes(options)   // adapt to installed Directions async API

        let candidates: [CandidateRoute] = mapboxRoutes.map { r in
            let elevations = Self.elevationProfile(of: r)    // from r.legs.steps coordinates + terrain source
            let segments = Self.offRoadSegments(of: r)       // (distance, isOffRoad) from step road classes
            return CandidateRoute(
                geometry: (r.shape?.coordinates ?? []).map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
                distanceMeters: r.distance,
                estimatedDurationSeconds: r.expectedTravelTime,
                elevationGainMeters: RouteMetrics.elevationGain(elevations: elevations),
                offRoadFraction: RouteMetrics.offRoadFraction(segments: segments))
        }
        return RouteRanker.label(origin: request.origin, destination: request.destination, candidates: candidates)
    }

    // MARK: - Adapters (verify against installed SDK)
    private func fetchRoutes(_ options: RouteOptions) async throws -> [/*Mapbox Route*/ Any] {
        // TODO(impl): call the installed Directions/MapboxRoutingProvider async API and return its routes.
        // Kept abstract because the exact v3 entry point varies by minor version — wire to the real one.
        fatalError("wire to installed Mapbox Directions async API")
    }
    private static func elevationProfile(of route: Any) -> [Double] { [] }       // map from route annotations
    private static func offRoadSegments(of route: Any) -> [(distanceMeters: Double, isOffRoad: Bool)] { [] } // from step.transportType / road class
}
```
> This file intentionally isolates the version-specific Mapbox calls in `fetchRoutes`/`elevationProfile`/`offRoadSegments`. Implement those three against the installed SDK; the surrounding pure mapping (`RouteMetrics`, `RouteRanker`) is already tested. A route's "off-road" classification comes from each step's transport type / road class (cycleway, path, track → off-road).

- [ ] **Step 2: Build**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED once the three adapters are wired to real SDK calls. (Until then it compiles but traps at runtime — acceptable to commit only after Step 1's adapters are implemented.)

- [ ] **Step 3: Verify with a real query** (manual)

Temporarily call `MapboxRoutingProvider().routes(for:)` with two Pittsburgh coordinates (e.g., Lawrenceville → a South Side brewery) from a debug button; log the returned `[Route]`. Confirm you get up to 3 routes labeled `.mostPaths` / `.fastest` / `.flattest` with plausible distances/elevations.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Routing/MapboxRoutingProvider.swift
git commit -m "feat(app): MapboxRoutingProvider (Directions → RouteRanker)"
```

---

## Task 5: Destination search + Plan/Home screen

**Files:**
- Create: `Aura/Sources/Plan/DestinationSearchView.swift`
- Create: `Aura/Sources/Plan/PlanView.swift`
- Create: `Aura/Sources/App/AppRouter.swift`
- Modify: `Aura/Sources/AuraApp.swift`

- [ ] **Step 1: App router (navigation state)**

`Aura/Sources/App/AppRouter.swift`:
```swift
import SwiftUI
import Observation
import AuraCore

@Observable
@MainActor
final class AppRouter {
    enum Screen: Equatable {
        case plan
        case preview(destination: Place)
        case ride(route: Route?)   // nil route => free ride
    }
    var screen: Screen = .plan
}
```

- [ ] **Step 2: Search view** (Mapbox Search — representative; verify symbols)

`Aura/Sources/Plan/DestinationSearchView.swift`:
```swift
import SwiftUI
import AuraCore
import MapboxSearch

struct DestinationSearchView: View {
    @State private var query = ""
    @State private var results: [Place] = []
    let onPick: (Place) -> Void
    // Wire a SearchEngine; map each suggestion → AuraCore.Place(category: .address/.brewery/...).

    var body: some View {
        VStack {
            TextField("Where to?", text: $query)
                .textFieldStyle(.roundedBorder).padding()
                .onChange(of: query) { _, q in /* engine.query(q); update results */ }
            List(results) { place in
                Button(place.name) { onPick(place) }
            }
        }
        .background(AuraTheme.bg)
    }
}
```

- [ ] **Step 3: Plan/Home screen** (search entry + Free ride + recents-in-memory)

`Aura/Sources/Plan/PlanView.swift`:
```swift
import SwiftUI
import AuraCore

struct PlanView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 16) {
            Text("Aura").font(.largeTitle.bold()).foregroundStyle(AuraTheme.text)
            DestinationSearchView { place in router.screen = .preview(destination: place) }
            Button("Free ride") { router.screen = .ride(route: nil) }
                .font(.headline).foregroundStyle(.black)
                .padding(.vertical, 14).frame(maxWidth: .infinity)
                .background(AuraTheme.auroraGradient, in: Capsule())
                .padding(.horizontal, 24)
        }
        .background(AuraTheme.bg.ignoresSafeArea())
    }
}
```

- [ ] **Step 4: Root the app in the router**

In `AuraApp.swift`, hold an `AppRouter` and switch on `router.screen` (plan / preview / ride). Inject via `.environment(router)`. Free-ride routes to the Plan-2 `RideHUDView`; navigate routes to `NavigateHUDView` (Task 7).

- [ ] **Step 5: Build + run**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED; Plan screen shows; typing yields search results; "Free ride" still works (Plan 2 path).

- [ ] **Step 6: Commit**

```bash
git add Aura/Sources/Plan Aura/Sources/App/AppRouter.swift Aura/Sources/AuraApp.swift
git commit -m "feat(app): Plan screen + destination search + app router"
```

---

## Task 6: Route preview (three labeled options)

**Files:**
- Create: `Aura/Sources/Plan/RoutePreviewView.swift`

> **Design-skill checkpoint** for this UI.

- [ ] **Step 1: Preview view**

`Aura/Sources/Plan/RoutePreviewView.swift`:
```swift
import SwiftUI
import AuraCore

struct RoutePreviewView: View {
    let destination: Place
    @Environment(AppRouter.self) private var router
    @State private var routes: [Route] = []
    @State private var selected: Route?
    let provider: RoutingProvider          // MapboxRoutingProvider in the app
    let origin: () -> Coordinate           // current location

    private func label(_ p: Route.Profile) -> String {
        switch p { case .mostPaths: "Most paths"; case .fastest: "Fastest"; case .flattest: "Flattest" }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Map preview of `selected` goes here (RideMapView-style, static).
            ForEach(routes) { route in
                Button { selected = route } label: { optionRow(route) }
            }
            Button("Start RIDE") {
                if let selected { router.screen = .ride(route: selected) }
            }
            .disabled(selected == nil)
            .font(.headline).foregroundStyle(.black)
            .padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(AuraTheme.auroraGradient, in: Capsule()).padding(.horizontal, 24)
        }
        .background(AuraTheme.bg.ignoresSafeArea())
        .task {
            let req = RouteRequest(origin: origin(), destination: destination.coordinate)
            routes = (try? await provider.routes(for: req)) ?? []
            selected = routes.first
        }
    }

    private func optionRow(_ route: Route) -> some View {
        HStack {
            Text(label(route.profile)).font(.headline)
                .foregroundStyle(selected == route ? .black : AuraTheme.text)
            Spacer()
            Text("\(UnitConverter.miles(fromMeters: route.distanceMeters), specifier: "%.1f") mi · \(Int(route.estimatedDurationSeconds/60)) min · \(Int(UnitConverter.feet(fromMeters: route.elevationGainMeters))) ft↑")
                .font(.caption).foregroundStyle(selected == route ? .black.opacity(0.7) : AuraTheme.muted)
        }
        .padding(14)
        .background(selected == route ? AnyShapeStyle(AuraTheme.route) : AnyShapeStyle(AuraTheme.surface),
                    in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }
}
```

- [ ] **Step 2: Route `.preview` in `AuraApp`/router to this view**, passing `MapboxRoutingProvider()` and a current-location closure.

- [ ] **Step 3: Build + run**

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED; picking a destination shows up to 3 labeled options with distance/time/climb; selecting one enables "Start RIDE".

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Plan/RoutePreviewView.swift Aura/Sources/AuraApp.swift
git commit -m "feat(app): route preview with Most paths/Fastest/Flattest options"
```

---

## Task 7: Navigate-mode HUD (turn-by-turn + growing turn card + voice)

**Files:**
- Create: `Aura/Sources/Ride/NavigationMapView.swift`
- Create: `Aura/Sources/Ride/TurnCardView.swift`
- Create: `Aura/Sources/Ride/NavigateHUDView.swift`

> **Design-skill checkpoint.** This is the product's signature screen.

- [ ] **Step 1: Turn card view (driven by `TurnCardState`)**

`Aura/Sources/Ride/TurnCardView.swift`:
```swift
import SwiftUI
import AuraKit

struct TurnCardView: View {
    let state: TurnCardState
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: state.isExpanded ? 34 : 24, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.distanceText)
                    .font(.system(size: state.isExpanded ? 30 : 20, weight: .heavy, design: .rounded))
                Text(state.primaryText).font(.subheadline.weight(.semibold)).opacity(0.85)
            }
            Spacer()
        }
        .foregroundStyle(.black)
        .padding(state.isExpanded ? 18 : 12)
        .background(AuraTheme.route, in: RoundedRectangle(cornerRadius: 16))
        .animation(.spring(duration: 0.3), value: state.isExpanded)
        .padding(.horizontal, 12)
    }
}
```

- [ ] **Step 2: Mapbox `NavigationMapView` wrapper** (UIViewRepresentable — representative; verify v3 symbols)

`Aura/Sources/Ride/NavigationMapView.swift`:
```swift
import SwiftUI
import MapboxNavigationCore
import MapboxNavigationUIKit

/// Wraps Mapbox's NavigationMapView (route line + puck + dark style). Verify v3 symbols.
struct NavigationMapView: UIViewRepresentable {
    // Pass the active navigation/route session in; render the route line and follow the puck.
    func makeUIView(context: Context) -> UIView { /* return configured NavigationMapView */ UIView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
```

- [ ] **Step 3: Navigate HUD — start nav, map progress → turn card, record the ride**

`Aura/Sources/Ride/NavigateHUDView.swift`:
```swift
import SwiftUI
import AuraCore
import AuraKit
import MapboxNavigationCore

struct NavigateHUDView: View {
    let route: Route
    @Environment(AppRouter.self) private var router
    @State private var recorder = RideRecorder(kind: .navigate)
    @State private var turn: TurnCardState = .init(primaryText: "", distanceText: "", isExpanded: false)
    @State private var finishedRide: Ride?

    var body: some View {
        ZStack(alignment: .top) {
            NavigationMapView().ignoresSafeArea()
            TurnCardView(state: turn).padding(.top, 8)
            VStack {
                Spacer()
                HStack {
                    SpeedRail(stats: recorder.stats, elapsed: 0)   // wire elapsed like Plan 2
                    Spacer()
                }.padding(16)
                Button("End ride") { finishedRide = recorder.end(at: Date()) }
                    .font(.headline).foregroundStyle(.black)
                    .padding(.vertical, 14).frame(maxWidth: .infinity)
                    .background(AuraTheme.pink, in: Capsule()).padding(24)
            }
        }
        .background(AuraTheme.bg)
        .sheet(item: $finishedRide) { RideSummaryView(ride: $0) }
        .task {
            recorder.start(at: Date())
            // 1) Start Mapbox navigation for `route` (convert AuraCore.Route → Mapbox route / request by coords).
            // 2) Subscribe to routeProgress updates:
            //      turn = TurnCardPresenter.state(distanceToManeuverMeters: progress.distanceToNextManeuver,
            //                                     instruction: progress.upcomingInstructionText)
            // 3) Subscribe to location updates → recorder.record(TrackPoint(from: location))
            // 4) Voice: enable the SDK's voice controller (or speak progress.instruction).
        }
    }
}
```
> The three numbered integration points are the only Mapbox-version-specific work; the turn-card *behavior* is already tested via `TurnCardPresenter`. On arrival, the SDK's arrival event should also set `finishedRide`.

- [ ] **Step 4: Build + run** (use the simulator's **City Bicycle Ride** location to drive progress)

Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED; starting a navigate ride shows the dark map with the route line, a turn card that **grows within ~150 m** of a maneuver, voice cues, and a live speed rail; ending shows the summary.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/NavigationMapView.swift Aura/Sources/Ride/TurnCardView.swift Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(app): navigate-mode HUD (turn-by-turn + adaptive turn card + voice)"
```

---

## Task 8: End-to-end wiring

- [ ] **Step 1:** Confirm the full flow in `AppRouter`: `plan → preview(destination) → ride(route) → summary → back to plan`. Free ride: `plan → ride(nil) → summary → plan`. Ensure "Done" on the summary returns to `.plan`.

- [ ] **Step 2: Build + run the whole journey** with the simulator's bike-ride location: search a Pittsburgh destination → pick "Most paths" → ride with turn-by-turn → end → summary → home.
Run: `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED + the full journey works.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(app): wire plan→preview→navigate→summary end-to-end" || echo "nothing to commit"
```

---

## Task 9: Full green + wrap-up

- [ ] **Step 1:** `cd AuraCore && swift test` → all green (adds RouteMetrics + TurnCardPresenter tests).
- [ ] **Step 2:** `cd Aura && xcodegen generate && xcodebuild -project Aura.xcodeproj -scheme Aura -destination 'platform=iOS Simulator,name=iPhone 15' build` → BUILD SUCCEEDED.
- [ ] **Step 3:** `git add -A && git commit -m "chore(app): Plan 3 complete — navigate-mode HUD" || echo "nothing to commit"`

---

## Done criteria for Plan 3

- `swift test` green including `RouteMetrics` + `TurnCardPresenter`.
- Search a destination → up to 3 labeled bike-aware routes (Most paths / Fastest / Flattest) → preview → turn-by-turn navigate-mode HUD with the adaptive growing turn card + voice → ride recorded → summary.
- `MapboxRoutingProvider` conforms to `AuraCore.RoutingProvider`, so the routing engine stays swappable (future Valhalla/BRouter).
- **Next:** Plan 4 adds persistence (SwiftData) for ride history + saved places, the History UI, Settings (units, voice, map style, **offline map downloads**), and OSM/BikePGH attribution.
