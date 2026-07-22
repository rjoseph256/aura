# Navigate-Mode Golden Ride (ROH-93 + ROH-95) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the ROH-92 golden-ride harness to gate NavigateHUDView's preview → Go → record → manual End → summary → History wiring, and make every UI-test launch use the ephemeral in-memory ride store (ROH-95).

**Architecture:** A shared DEBUG helper (`SimulatedRideSupport`) supplies both HUDs the simulated location seam; the route preview serves a fixture-built `Route` under simulation (no Directions network); the navigate HUD swaps its Mapbox guidance session for an empty scripted one; one new XCUITest method in the existing `RideE2EUITests` class rides the existing CI lane. Spec: `docs/superpowers/specs/2026-07-22-navigate-golden-ride-design.md`.

**Tech Stack:** Swift 6 / SwiftUI (app target has `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`), Swift Testing for package tests, XCUITest for the E2E, XcodeGen (`Aura/project.yml` uses source globs — new app files are picked up by regenerating, no project.yml edit), SwiftPM package `AuraCore` (products AuraCore + AuraKit).

## Global Constraints

- `swiftlint --strict` must stay clean (run `scripts/lint.sh`).
- Every app-side harness hook is `#if DEBUG`; release builds must contain **no reference** to `ScriptedGuidanceSession` or probe rendering.
- Package builds on the macOS host too (CI): no iOS-only API outside existing guards.
- Builds/tests are delegated to the `apple-platform-build-tools:builder` agent; the app scheme is `Aura`, sim is `iPhone 17`, package tests run `swift test` in `AuraCore/`.
- Do NOT modify: `golden-ride.gpx`, the existing frozen truth literals, `scripts/golden-ride.sh`, Layer 1 tests, the free-ride test's assertions (beyond the stated helper extraction).
- Commit after every task; messages follow the repo's `type(roh-93): subject` convention.

---

### Task 1: `GoldenRideFixture.startCoordinate` literals + `route()`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift`
- Test (create): `AuraCore/Tests/AuraKitTests/GoldenRideFixtureRouteTests.swift`

**Interfaces:**
- Consumes: existing `GoldenRideFixture.track()`, truth literals, `AuraCore.Route`.
- Produces: `GoldenRideFixture.startLatitude: Double`, `startLongitude: Double` (frozen literals), and `GoldenRideFixture.route() throws -> Route`. Tasks 5 and 7 use these exact names.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/GoldenRideFixtureRouteTests.swift`:

```swift
import Testing
import AuraCore
import AuraKit

/// ROH-93: the fixture doubles as the navigate golden ride's preview Route. The start
/// literals exist so the E2E's deep-link URL is compile-time-tied to the fixture; this
/// suite pins them (and the route metadata) to the parsed track so a re-record that
/// forgets them fails here, not silently in the UI test.
struct GoldenRideFixtureRouteTests {
    @Test func startCoordinateLiteralsMatchFixtureFirstPoint() throws {
        let first = try #require(try GoldenRideFixture.track().points.first)
        #expect(first.coordinate.latitude == GoldenRideFixture.startLatitude)
        #expect(first.coordinate.longitude == GoldenRideFixture.startLongitude)
    }

    @Test func routeCarriesFixtureGeometryAndFrozenTruth() throws {
        let route = try GoldenRideFixture.route()
        #expect(route.geometry.count == GoldenRideFixture.expectedPointCount)
        #expect(route.origin == route.geometry.first)
        #expect(route.destination == route.geometry.last)
        #expect(route.profile == .mostPaths)
        #expect(route.waypoints.isEmpty)
        #expect(route.distanceMeters == GoldenRideFixture.expectedDistanceMeters)
        #expect(route.estimatedDurationSeconds == GoldenRideFixture.nominalDurationSeconds)
        #expect(route.elevationGainMeters == GoldenRideFixture.expectedElevationGainMeters)
        #expect(route.elevationProfile.count == GoldenRideFixture.expectedPointCount)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Delegate to the builder agent: `cd AuraCore && swift test --filter GoldenRideFixtureRouteTests`
Expected: compile FAILURE — `startLatitude`/`route()` not defined.

- [ ] **Step 3: Implement**

In `GoldenRideFixture.swift`, add inside the enum (below `nominalDurationSeconds`):

```swift
    /// First trackpoint, frozen like the other truth literals so the navigate E2E's
    /// deep-link URL is built from the fixture instead of a drift-prone hardcoded
    /// pair. Re-record procedure: update these with the other literals.
    public static let startLatitude = 40.48
    public static let startLongitude = -79.76

    /// The fixture as a preview-able Route (ROH-93): geometry from the track, metadata
    /// from the frozen truth literals — never recomputed at runtime, so a calculator
    /// regression cannot re-derive them into passing.
    public static func route() throws -> Route {
        let points = try track().points
        guard let first = points.first, let last = points.last else {
            throw FixtureError.missingResource
        }
        return Route(origin: first.coordinate,
                     destination: last.coordinate,
                     waypoints: [],
                     geometry: points.map(\.coordinate),
                     profile: .mostPaths,
                     distanceMeters: expectedDistanceMeters,
                     estimatedDurationSeconds: nominalDurationSeconds,
                     elevationGainMeters: expectedElevationGainMeters,
                     elevationProfile: points.compactMap(\.elevation))
    }
```

(`Route` is in AuraCore, already imported by this file. The GPX's first point is
`lat="40.480000" lon="-79.760000"` — the literals `40.48` / `-79.76` are the identical
doubles.)

- [ ] **Step 4: Run tests to verify they pass**

Builder: `cd AuraCore && swift test --filter GoldenRideFixtureRouteTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift AuraCore/Tests/AuraKitTests/GoldenRideFixtureRouteTests.swift
git commit -m "feat(roh-93): fixture start literals + preview Route from the golden ride"
```

---

### Task 2: New `RideTestID`s + End / Start-RIDE identifiers

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` (enum `RideTestID`)
- Modify: `Aura/Sources/Ride/ControlCluster.swift` (End button, ~line 91)
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (`startButton`, ~line 239)

**Interfaces:**
- Produces: `RideTestID.hudEnd == "ride.hud.end"`, `RideTestID.previewStart == "preview.start"`. Task 6's screen objects reference these exact names.

- [ ] **Step 1: Add the constants**

In `RideTestSupport.swift`, extend the enum:

```swift
public enum RideTestID {
    public static let hudProbe = "ride.hud.probe"
    public static let hudBack = "ride.hud.back"
    public static let hudEnd = "ride.hud.end"
    public static let previewStart = "preview.start"
    public static let summaryDistance = "summary.distance"
    public static let historyRow = "history.row"
}
```

- [ ] **Step 2: Tag the End button**

In `ControlCluster.swift`, the End button currently reads:

```swift
            Button(action: onEndRide) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.hudControl(role: .destructive, metrics: .ride))
            .disabled(isEndDisabled)
            .accessibilityLabel("End ride")
```

Add the identifier after the label:

```swift
            .accessibilityLabel("End ride")
            .accessibilityIdentifier(RideTestID.hudEnd)
```

If `ControlCluster.swift` does not already `import AuraKit`, add it.

- [ ] **Step 3: Tag Start RIDE**

In `RoutePreviewView.swift` (`startButton`), the CTA currently reads:

```swift
            Button("Start RIDE") {
                if let selected {
                    router.push(.navigate(route: selected, destination: destination))
                }
            }
            .buttonStyle(.ctaPrimary)
            .disabled(selected == nil)
```

Add after `.disabled(...)`:

```swift
            .accessibilityIdentifier(RideTestID.previewStart)
```

- [ ] **Step 4: Build gate**

Builder: xcodegen + build the `Aura` scheme for the iPhone 17 simulator (Debug).
Expected: build succeeds. Also run `scripts/lint.sh` → clean.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift Aura/Sources/Ride/ControlCluster.swift Aura/Sources/Plan/RoutePreviewView.swift
git commit -m "feat(roh-93): shared a11y ids for the End control and Start RIDE CTA"
```

---

### Task 3: `SimulatedRideSupport` (shared override + probe modifier) + RideHUDView refactor

**Files:**
- Create: `Aura/Sources/Ride/SimulatedRideSupport.swift`
- Modify: `Aura/Sources/Ride/RideHUDView.swift` (probe overlay ~lines 90–101; `.task` DEBUG block ~lines 174–190)

**Interfaces:**
- Consumes: `SimulatedRideConfig.current`, `GoldenRideFixture.simulatedProvider(multiplier:)`, `RideTestProbe.line`, `RideTestID.hudProbe` (all AuraKit).
- Produces: `SimulatedRideSupport.rideOverride() -> (location: any LocationStreaming, authorization: LocationAuthorization)?` (DEBUG-only) and `View.simulatedRideProbe(distanceMeters:elapsed:elevationGainMeters:)`. Task 4 uses both, with these exact signatures.

- [ ] **Step 1: Create the shared support file**

`Aura/Sources/Ride/SimulatedRideSupport.swift`:

```swift
import SwiftUI
import AuraCore
import AuraKit

/// Golden-ride harness support shared by both HUDs (ROH-92/ROH-93). Inert in Release:
/// the ride override is compiled out entirely and the probe modifier passes content
/// through unchanged.
enum SimulatedRideSupport {
    #if DEBUG
    /// (fixture location stream, .authorized) when the harness is active, else nil.
    /// Both HUDs pass these straight into `coordinator.start`, so the two ride paths
    /// provably feed the coordinator identical simulated input.
    @MainActor
    static func rideOverride() -> (location: any LocationStreaming,
                                   authorization: LocationAuthorization)? {
        guard let sim = SimulatedRideConfig.current else { return nil }
        do {
            return (try GoldenRideFixture.simulatedProvider(multiplier: sim.speedMultiplier),
                    .authorized)
        } catch {
            // Defensive-only: the fixture is always bundled; a packaging regression
            // fails loudly in Debug instead of silently riding on GPS.
            assertionFailure("Simulated ride fixture failed to load: \(error)")
            return nil
        }
    }
    #endif
}

/// Invisible machine-readable stats line for the golden-ride tests. Renders only in
/// DEBUG simulated rides and never intercepts touches — the navigate End button lives
/// in the same bottom region the overlay anchors to.
private struct SimulatedRideProbe: ViewModifier {
    let distanceMeters: Double
    let elapsed: Double
    let elevationGainMeters: Double

    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .bottomLeading) {
            if SimulatedRideConfig.current != nil {
                Text(RideTestProbe.line(distanceMeters: distanceMeters,
                                        elapsed: elapsed,
                                        elevationGainMeters: elevationGainMeters))
                    .font(.system(size: 8))
                    .opacity(0.02)   // invisible to riders, present in the a11y tree
                    .accessibilityIdentifier(RideTestID.hudProbe)
                    .allowsHitTesting(false)
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Attach the golden-ride probe. Safe to leave in the modifier chain
    /// unconditionally; it is a no-op outside DEBUG simulated rides.
    func simulatedRideProbe(distanceMeters: Double, elapsed: Double,
                            elevationGainMeters: Double) -> some View {
        modifier(SimulatedRideProbe(distanceMeters: distanceMeters, elapsed: elapsed,
                                    elevationGainMeters: elevationGainMeters))
    }
}
```

- [ ] **Step 2: Refactor RideHUDView onto it**

Replace the probe overlay block (currently `#if DEBUG` + `.overlay(alignment: .bottomLeading) { … RideTestID.hudProbe … }` + `#endif`, ~lines 90–101) with a single modifier call in the same chain position:

```swift
        .simulatedRideProbe(distanceMeters: coordinator.stats.distanceMeters,
                            elapsed: coordinator.elapsed,
                            elevationGainMeters: coordinator.stats.elevationGainMeters)
```

Replace the `.task` DEBUG block (currently `if let sim = SimulatedRideConfig.current { do { rideLocation = …; rideAuthorization = .authorized; liveProvider = EmptyGemProvider() } catch { assertionFailure(…) } }`) with:

```swift
            #if DEBUG
            // Golden-ride harness (ROH-92): simulated rides swap the location seam for
            // the bundled fixture, bypass the permission gate, and drop the live
            // Overpass gem source (unmocked network → nondeterministic cards).
            if let override = SimulatedRideSupport.rideOverride() {
                rideLocation = override.location
                rideAuthorization = override.authorization
                liveProvider = EmptyGemProvider()
            }
            #endif
```

The surrounding `var liveProvider / var rideLocation / var rideAuthorization` lines and everything else stay as they are. Net behavior is identical (on a fixture-load throw, the helper asserts and returns nil, leaving all three variables untouched — same as today's throw-before-assign ordering).

- [ ] **Step 3: Build gate**

Builder: build `Aura` (Debug, iPhone 17 sim) + `scripts/lint.sh`.
Expected: build succeeds, lint clean.

- [ ] **Step 4: Commit**

```bash
git add Aura/Sources/Ride/SimulatedRideSupport.swift Aura/Sources/Ride/RideHUDView.swift
git commit -m "refactor(roh-93): shared SimulatedRideSupport override + probe modifier"
```

---

### Task 4: NavigateHUDView — scripted guidance, simulated start, probe

**Files:**
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift` (guidance `@State` ~line 48, `init` ~lines 70–78, `.task` ~lines 179–197, body chain for the probe)

**Interfaces:**
- Consumes: `SimulatedRideSupport.rideOverride()`, `.simulatedRideProbe(...)` (Task 3), `ScriptedGuidanceSession(script:)` (AuraCore, public).

- [ ] **Step 1: Session selection in init**

Change the property declaration (removing its default value):

```swift
    /// Owns the guidance event stream and the turn-card state. Backed by Mapbox here;
    /// a `ScriptedGuidanceSession` drives the same model in tests — and, under the
    /// DEBUG golden-ride harness, an empty scripted session replaces the engine
    /// entirely (no network, no telemetry, no arrival racing the manual End; the
    /// turn card renders its unavailable state, which nothing asserts).
    @State private var guidance: GuidanceViewModel
```

In `init`, after the existing `_coordinator = State(initialValue: …)` assignment, add:

```swift
        #if DEBUG
        if SimulatedRideConfig.current != nil {
            _guidance = State(initialValue:
                GuidanceViewModel(session: ScriptedGuidanceSession(script: [])))
        } else {
            _guidance = State(initialValue:
                GuidanceViewModel(session: MapboxGuidanceSession()))
        }
        #else
        _guidance = State(initialValue:
            GuidanceViewModel(session: MapboxGuidanceSession()))
        #endif
```

(The whole selection is inside `#if DEBUG`/`#else`, so Release contains no
`ScriptedGuidanceSession` reference and its init is byte-identical to today.)

- [ ] **Step 2: Simulated start override in `.task`**

The start block currently reads:

```swift
            let outcome = coordinator.start(
                location: location, saving: rideStore, units: settings.units,
                authorization: location.authorization, saveToHealth: settings.saveToHealth,
                groupSink: groupSession?.locationSink)
```

Replace with:

```swift
            var rideLocation: any LocationStreaming = location
            var rideAuthorization = location.authorization
            #if DEBUG
            // Golden-ride harness (ROH-93): same seam swap as the free-ride HUD, via
            // the shared helper, so both paths feed identical simulated input.
            if let override = SimulatedRideSupport.rideOverride() {
                rideLocation = override.location
                rideAuthorization = override.authorization
            }
            #endif
            let outcome = coordinator.start(
                location: rideLocation, saving: rideStore, units: settings.units,
                authorization: rideAuthorization, saveToHealth: settings.saveToHealth,
                groupSink: groupSession?.locationSink)
```

Everything around it (voice front matter, `guard outcome == .started`, `guidance.start(route:)`) stays unchanged — with the empty scripted session, `guidance.start` consumes a stream that finishes immediately; `turn` becomes `.unavailable`, `lastUpdate` stays nil.

- [ ] **Step 3: Attach the probe**

In `body`, after the GPS-chip overlay (`.overlay(alignment: .topLeading) { GPSSignalChip… }`), add:

```swift
        .simulatedRideProbe(distanceMeters: coordinator.stats.distanceMeters,
                            elapsed: coordinator.elapsed,
                            elevationGainMeters: coordinator.stats.elevationGainMeters)
```

- [ ] **Step 4: Build gate**

Builder: build `Aura` (Debug, iPhone 17 sim) + `scripts/lint.sh`. Expected: success, clean.

- [ ] **Step 5: Commit**

```bash
git add Aura/Sources/Ride/NavigateHUDView.swift
git commit -m "feat(roh-93): navigate HUD joins the golden-ride harness (scripted guidance, simulated start, probe)"
```

---

### Task 5: RoutePreviewView — fixture route under simulation

**Files:**
- Modify: `Aura/Sources/Plan/RoutePreviewView.swift` (`loadRoutes()`, ~lines 260–275)

**Interfaces:**
- Consumes: `GoldenRideFixture.route()` (Task 1), `SimulatedRideConfig.current`.

- [ ] **Step 1: Add the DEBUG branch**

`loadRoutes()` currently begins:

```swift
    private func loadRoutes() async {
        phase = .loading
        let origin = await location.current()
```

Insert between `phase = .loading` and the `location.current()` line:

```swift
        #if DEBUG
        // Golden-ride harness (ROH-93): a simulated ride previews the bundled fixture
        // as its one route — no Directions network, no location.current() stall.
        // Setting `selected` drives the production onChange → fitCamera path; the
        // .loading→.loaded machine and auto-select-from-a-real-fetch stay ungated by
        // design (spec §2).
        if SimulatedRideConfig.current != nil {
            do {
                let route = try GoldenRideFixture.route()
                routes = [route]
                selected = route
                phase = .loaded
                return
            } catch {
                // Defensive-only: the fixture is always bundled. Fail loudly in Debug,
                // then fall through to the real fetch rather than wedging the preview.
                assertionFailure("Golden-ride fixture route failed to load: \(error)")
            }
        }
        #endif
```

(`RoutePreviewView.swift` already imports AuraKit.)

- [ ] **Step 2: Build gate**

Builder: build `Aura` (Debug, iPhone 17 sim) + `scripts/lint.sh`. Expected: success, clean.

- [ ] **Step 3: Commit**

```bash
git add Aura/Sources/Plan/RoutePreviewView.swift
git commit -m "feat(roh-93): route preview serves the fixture route under simulation"
```

---

### Task 6: Screen objects + ROH-95 ephemeral-store flags

**Files:**
- Modify: `Aura/UITests/Screens/Screens.swift`
- Modify: `Aura/UITests/SavedPlacesUITests.swift` (launch args, ~lines 8–13)
- Modify: `Aura/UITests/HomeUITests.swift` (`testAX5_…` launch args, ~lines 28–33)

**Interfaces:**
- Consumes: `RideTestID.hudEnd`, `RideTestID.previewStart` (Task 2).
- Produces: `PreviewScreen` with `startRide: XCUIElement` and `waitForStartEnabled(timeout:) -> Bool`; `RideScreen.endButton: XCUIElement`. Task 7 uses these exact names.

- [ ] **Step 1: Add `PreviewScreen` and `RideScreen.endButton`**

In `Screens.swift`, add to `RideScreen`:

```swift
    var endButton: XCUIElement { app.buttons[RideTestID.hudEnd] }
```

Add a new screen object (next to the other structs):

```swift
@MainActor
struct PreviewScreen {
    let app: XCUIApplication
    var startRide: XCUIElement { app.buttons[RideTestID.previewStart] }

    /// Polls until the CTA is enabled. The button exists (disabled) in every preview
    /// phase, and the fixture route auto-selects one runloop after the view's .task —
    /// so a bare waitForExistence would tap a disabled button. Real sleep between
    /// polls, same rationale as RideScreen.waitForDistance.
    func waitForStartEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if startRide.exists && startRide.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
```

- [ ] **Step 2: ROH-95 — flag in both launch helpers**

Replace the two helpers at the bottom of `Screens.swift`:

```swift
extension XCUIApplication {
    @MainActor static func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [ephemeralStoreFlag]
        app.launch()
        return app
    }

    /// Launch seeded past first-run via the built-in NSArgumentDomain, so Home shows the
    /// populated layout (not the first-run composition) without any app-side test-seed code.
    @MainActor static func launched(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if onboarded { app.launchArguments += ["-auraDidCompleteOnboarding", "YES"] }
        app.launchArguments += [ephemeralStoreFlag]
        app.launch()
        return app
    }

    /// ROH-95: every UI-test launch uses the ephemeral in-memory ride store. The
    /// unsigned (CODE_SIGNING_ALLOWED=NO) test build has no iCloud entitlements, and
    /// any launch that opens the CloudKit-mirrored SwiftData store SIGTRAPs later on
    /// CoreData's background CloudKit setup. No suite asserts cross-launch persistence.
    static let ephemeralStoreFlag = "-auraInMemoryRideStore"
}
```

- [ ] **Step 3: ROH-95 — the two direct-launch suites**

`SavedPlacesUITests.swift` — the launch-args block becomes:

```swift
        app.launchArguments += [
            "-auraDidCompleteOnboarding", "YES",
            XCUIApplication.ephemeralStoreFlag,
            "-openURL", "aura://preview?lat=40.4406&lng=-79.9959&name=Save%20Target"]
```

`HomeUITests.swift` (`testAX5_…`) — the launch-args block becomes:

```swift
        app.launchArguments += [
            "-auraDidCompleteOnboarding", "YES",
            XCUIApplication.ephemeralStoreFlag,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ]
```

- [ ] **Step 4: Build gate**

Builder: `xcodebuild build-for-testing -project Aura.xcodeproj -scheme Aura -configuration Debug -destination "platform=iOS Simulator,name=iPhone 17" CODE_SIGNING_ALLOWED=NO` (after xcodegen). Expected: builds, including the UITests bundle.

- [ ] **Step 5: Commit**

```bash
git add Aura/UITests/Screens/Screens.swift Aura/UITests/SavedPlacesUITests.swift Aura/UITests/HomeUITests.swift
git commit -m "test(roh-95): ephemeral ride store for every UI-test launch + navigate screen objects"
```

---

### Task 7: The navigate golden-ride test (+ shared band helper)

**Files:**
- Modify: `Aura/UITests/RideE2EUITests.swift`

**Interfaces:**
- Consumes: `PreviewScreen`, `RideScreen.endButton` (Task 6), `GoldenRideFixture.startLatitude/.startLongitude` (Task 1), existing `RideScreen`, `SummaryScreen`, `HomeScreen`, `HistoryScreen`, `dismissLocationAlertIfPresent()`, `leadingNumber(in:)`.

- [ ] **Step 1: Extract the shared hero-band helper**

In `RideE2EUITests`, replace the free-ride test's inline band block (from `XCTAssertTrue(summary.heroDistance.exists)` through the miles `XCTAssertTrue`) with a call:

```swift
        try Self.assertHeroDistanceInBand(summary)
```

and add the helper (next to `leadingNumber(in:)`):

```swift
    /// Hero-distance sanity band shared by both golden rides. NOTE: a fixture
    /// re-record must update GoldenRideFixture's literals AND these bands together.
    @MainActor
    private static func assertHeroDistanceInBand(_ summary: SummaryScreen,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) throws {
        XCTAssertTrue(summary.heroDistance.exists, "hero distance missing",
                      file: file, line: line)
        let label = summary.heroDistance.label   // e.g. "Distance, 1.8 miles"
        let value = try XCTUnwrap(leadingNumber(in: label),
                                  "no number in hero label: \(label)", file: file, line: line)
        if label.contains("kilometer") {
            XCTAssertTrue((2.3...3.4).contains(value), "km out of band: \(label)",
                          file: file, line: line)
        } else {
            XCTAssertTrue((1.4...2.2).contains(value), "miles out of band: \(label)",
                          file: file, line: line)
        }
    }
```

- [ ] **Step 2: Run the free-ride test to prove the refactor is behavior-neutral**

Builder: `scripts/golden-ride.sh` runs the whole class; or
`xcodebuild test-without-building … -only-testing:AuraUITests/RideE2EUITests/testGoldenRideRecordsToSummaryAndHistory`.
Expected: PASS.

- [ ] **Step 3: Add the navigate test**

```swift
    /// ROH-93: the navigate-mode golden ride. Enters via the -openURL preview deep link
    /// (search is out of scope — spec Non-goals), rides the same fixture through
    /// NavigateHUDView, ends via the manual End control (no Mapbox arrival), and
    /// asserts the same summary + History wiring whose navigate seam regressed in
    /// ROH-85.
    @MainActor
    func testNavigateGoldenRideEndsToSummaryAndHistory() throws {
        let app = XCUIApplication()
        let previewLink = "aura://preview?lat=\(GoldenRideFixture.startLatitude)" +
            "&lng=\(GoldenRideFixture.startLongitude)&name=Golden%20Loop"
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "golden",
                                "-auraSimulatedRideMultiplier", "30",
                                "-auraInMemoryRideStore",
                                "-openURL", previewLink]
        app.launch()
        dismissLocationAlertIfPresent()

        // Preview: the fixture route auto-selects; the CTA enables one runloop later.
        let preview = PreviewScreen(app: app)
        XCTAssertTrue(preview.waitForStartEnabled(timeout: 15),
                      "Start RIDE never enabled — fixture route did not load/select")
        preview.startRide.tap()

        // Navigate HUD: the simulated hook engaged and records through this path.
        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15),
                      "HUD probe missing — simulated-ride hook did not engage in navigate")
        let floor = Int(0.85 * GoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: floor, timeout: 90),
                      "distance never reached \(floor) m — last probe: \(ride.probe.label)")
        // One-line stats sanity: a diverged navigate provider would record flat gain.
        // Free ride owns the fuller recorder assertions (ticker, precision bands).
        let gain = try XCTUnwrap(ride.probeValues()).elevationGainMeters
        XCTAssertGreaterThanOrEqual(gain, 40, "elevation gain flat: \(gain) m")

        // Manual End via the control cluster (no arrival in this harness).
        ride.endButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10), "End alert never appeared")
        ride.endAlert.buttons["End ride"].tap()

        // Summary (the ROH-85 seam) → Done → Home → History (fresh store → 1 row).
        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")
        try Self.assertHeroDistanceInBand(summary)
        summary.doneButton.tap()
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Done did not return Home")
        home.goToHistory()
        let history = HistoryScreen(app: app)
        XCTAssertTrue(history.title.waitForExistence(timeout: 10))
        XCTAssertTrue(history.rideRows.firstMatch.waitForExistence(timeout: 10),
                      "finished ride missing from History")
        XCTAssertEqual(history.rideRows.count, 1)
    }
```

- [ ] **Step 4: Run the new test — expect PASS end-to-end**

Builder: `xcodebuild test-without-building … -only-testing:AuraUITests/RideE2EUITests/testNavigateGoldenRideEndsToSummaryAndHistory` (same destination/flags as `scripts/golden-ride.sh`).
Expected: PASS. If it fails, debug before proceeding — this step is the point of the feature.

- [ ] **Step 5: Commit**

```bash
git add Aura/UITests/RideE2EUITests.swift
git commit -m "test(roh-93): navigate-mode golden ride gates the NavigateHUDView summary seam"
```

---

### Task 8: CI timeout + ROADMAP line

**Files:**
- Modify: `.github/workflows/ci.yml` (line 40)
- Modify: `docs/ROADMAP.md` (testing section)

- [ ] **Step 1: Bump the job timeout**

`.github/workflows/ci.yml` line 40: `timeout-minutes: 40` → `timeout-minutes: 50`, with a trailing comment on the same line or the line above:

```yaml
    # 50: cold SPM + Mapbox build + boot + TWO golden-ride methods, each retried once
    # worst-case (ROH-93 added the navigate method).
    timeout-minutes: 50
```

- [ ] **Step 2: ROADMAP**

In `docs/ROADMAP.md`'s testing section, find the golden-ride paragraph (added by ROH-92) and add one sentence after the free-ride description:

```markdown
ROH-93 added the navigate-mode golden ride: the same fixture enters via the
`aura://preview` deep link, rides `NavigateHUDView` with an empty scripted
guidance session, and ends via the manual End control — so both HUDs'
finish → summary seams are now gated (the seam class that regressed in ROH-85).
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml docs/ROADMAP.md
git commit -m "ci(roh-93): 50-min app-build budget for the second golden ride; ROADMAP line"
```

---

### Task 9: Full local verification + regression drills

**Files:** none persisted (drills are reverted). Everything runs via the builder agent.

- [ ] **Step 1: Package tests**

Builder: `cd AuraCore && swift test`. Expected: all suites PASS.

- [ ] **Step 2: Both E2E methods, the real lane**

Builder: `scripts/golden-ride.sh` (runs build-for-testing + the whole `RideE2EUITests` class on iPhone 17). Expected: 2 tests PASS.

- [ ] **Step 3: Legacy suites under the unsigned build (ROH-95 verification)**

Builder: `xcodebuild test-without-building … -only-testing:AuraUITests` (whole bundle) or the seven classes explicitly. Expected: previously-failing local suites now green; record any residual failures verbatim (they go on the ROH-95 issue, not silently ignored).

- [ ] **Step 4: Regression drill (a) — the gate catches the seam**

Temporarily comment out the body of NavigateHUDView's `finishedRide` onChange (the `WidgetRefresh.reload` + `router.showRideSummary` lines). Builder: run ONLY `testNavigateGoldenRideEndsToSummaryAndHistory` → expect FAIL at "Summary never appeared"; run ONLY `testGoldenRideRecordsToSummaryAndHistory` → expect PASS. Save both result snippets for the PR. Revert the edit (`git checkout -- Aura/Sources/Ride/NavigateHUDView.swift`).

- [ ] **Step 5: Regression drill (b) — the documented boundary**

Temporarily replace `router.showRideSummary(ride, saveFailed: …)` in NavigateHUDView with `router.push(.rideSummary(RideSummaryPayload(ride: ride, saveFailed: coordinator.saveFailed)))` (push-instead-of-collapse; check the actual payload type/ctor in `AppRoute.swift` and mirror `showRideSummary`'s construction). Builder: run the navigate test → expected: PASS despite the stale stack (this documents the honest coverage boundary from the spec). Save the snippet. Revert.

- [ ] **Step 6: Lint + final clean build**

Builder: `scripts/lint.sh` → clean; `git status` → only intended files.

- [ ] **Step 7: Commit (only if drift was found and fixed)**

No commit expected from this task.
