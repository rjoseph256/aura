# E2E Ride Harness Implementation Plan (ROH-92)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A two-layer golden-ride regression gate: a package-level playback test of the assembled ride pipeline, and an XCUITest that drives the real app through a simulated free ride to summary and History, wired into CI.

**Architecture:** One canonical GPX fixture (`golden-ride.gpx`, AuraKit resources) feeds both layers. A DEBUG-gated launch-arg config (`SimulatedRideConfig`) makes the app start rides on `SimulatedLocationProvider` instead of `LocationService`, with a deterministic in-memory store. CI's existing `app-build` job grows `build-for-testing` + `test-without-building` steps running only the golden ride. Spec: `docs/superpowers/specs/2026-07-22-e2e-ride-harness-design.md`.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (package), XCUITest (UI), XcodeGen, GitHub Actions macos-15.

## Global Constraints

- Swift 6 language mode everywhere; app target has `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`.
- The AuraCore package builds on the macOS host in CI — iOS-only CoreLocation APIs must stay `#if`-guarded. (Nothing in this plan touches CL directly.)
- Never construct a bare `LocationService()` in a test (ROH-88).
- New AuraKit test suites touching SwiftData adopt `@Suite(.swiftDataSerialized)`.
- `swiftlint lint --strict` must pass (0.64.1; line length 120).
- All app-side harness hooks compiled under `#if DEBUG`.
- Package tests: `cd AuraCore && swift test --no-parallel`.
- App project is generated: `cd Aura && xcodegen generate` after any `project.yml` change. The worktree has `Aura/Resources/MapboxAccessToken` already (do not commit it).
- Local sim target: iPhone 17 (iOS 26). Commit after each task with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `SimulatedRideConfig` (pure launch-arg parser, AuraKit)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift`
- Test: `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift`

**Interfaces:**
- Produces: `SimulatedRideConfig` — `public struct SimulatedRideConfig: Equatable, Sendable { public let fixture: String; public let speedMultiplier: Double }`, `public static func parse(arguments: [String]) -> SimulatedRideConfig?`, `public static func forcesInMemoryStore(arguments: [String]) -> Bool`, `@MainActor public static let current: SimulatedRideConfig?` and `@MainActor public static let currentForcesInMemoryStore: Bool` (both parsed once from `ProcessInfo.processInfo.arguments`). Consumed by Tasks 4, 5, 6.

- [ ] **Step 1: Write the failing tests**

```swift
// AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift
import Testing
@testable import AuraKit

struct SimulatedRideConfigTests {
    @Test func absentFlagParsesToNil() {
        #expect(SimulatedRideConfig.parse(arguments: ["AppPath", "-someOther", "x"]) == nil)
    }

    @Test func goldenFixtureParsesWithDefaultMultiplier() {
        let config = SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide", "golden"])
        #expect(config == SimulatedRideConfig(fixture: "golden", speedMultiplier: 30))
    }

    @Test func explicitMultiplierOverridesDefault() {
        let config = SimulatedRideConfig.parse(
            arguments: ["App", "-auraSimulatedRide", "golden", "-auraSimulatedRideMultiplier", "60"])
        #expect(config?.speedMultiplier == 60)
    }

    @Test func malformedMultiplierFallsBackToDefault() {
        let config = SimulatedRideConfig.parse(
            arguments: ["App", "-auraSimulatedRide", "golden", "-auraSimulatedRideMultiplier", "fast"])
        #expect(config?.speedMultiplier == 30)
    }

    @Test func nonPositiveMultiplierFallsBackToDefault() {
        let config = SimulatedRideConfig.parse(
            arguments: ["App", "-auraSimulatedRide", "golden", "-auraSimulatedRideMultiplier", "0"])
        #expect(config?.speedMultiplier == 30)
    }

    @Test func missingFixtureNameParsesToNil() {
        #expect(SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide"]) == nil)
    }

    @Test func inMemoryStoreFlag() {
        #expect(SimulatedRideConfig.forcesInMemoryStore(arguments: ["App", "-auraInMemoryRideStore"]))
        #expect(!SimulatedRideConfig.forcesInMemoryStore(arguments: ["App"]))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd AuraCore && swift test --no-parallel --filter SimulatedRideConfigTests`
Expected: compile FAILURE — `SimulatedRideConfig` not found.

- [ ] **Step 3: Implement**

```swift
// AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift
import Foundation

/// Launch-argument contract for the golden-ride harness (ROH-92). Pure parser so it is
/// unit-testable; the app's DEBUG-only call sites read the `current` statics. Unknown or
/// malformed values degrade to "absent" (real location) rather than crashing.
public struct SimulatedRideConfig: Equatable, Sendable {
    /// Fixture selector, e.g. "golden" → GoldenRideFixture.
    public let fixture: String
    /// Wall-clock playback compression; ride timestamps (and thus stats) are unaffected.
    public let speedMultiplier: Double

    public static let defaultMultiplier: Double = 30

    public init(fixture: String, speedMultiplier: Double) {
        self.fixture = fixture
        self.speedMultiplier = speedMultiplier
    }

    /// "-auraSimulatedRide <fixture> [-auraSimulatedRideMultiplier <n>]" → config, else nil.
    public static func parse(arguments: [String]) -> SimulatedRideConfig? {
        guard let index = arguments.firstIndex(of: "-auraSimulatedRide"),
              arguments.indices.contains(index + 1) else { return nil }
        let fixture = arguments[index + 1]
        guard !fixture.hasPrefix("-") else { return nil }
        var multiplier = defaultMultiplier
        if let mIndex = arguments.firstIndex(of: "-auraSimulatedRideMultiplier"),
           arguments.indices.contains(mIndex + 1),
           let value = Double(arguments[mIndex + 1]), value > 0 {
            multiplier = value
        }
        return SimulatedRideConfig(fixture: fixture, speedMultiplier: multiplier)
    }

    /// "-auraInMemoryRideStore" → deterministic in-memory RideStore for UI tests.
    public static func forcesInMemoryStore(arguments: [String]) -> Bool {
        arguments.contains("-auraInMemoryRideStore")
    }

    /// Process-wide values, parsed once. MainActor confines the lazy statics under Swift 6.
    @MainActor public static let current = parse(arguments: ProcessInfo.processInfo.arguments)
    @MainActor public static let currentForcesInMemoryStore =
        forcesInMemoryStore(arguments: ProcessInfo.processInfo.arguments)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd AuraCore && swift test --no-parallel --filter SimulatedRideConfigTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift
git commit -m "feat(roh-92): SimulatedRideConfig launch-arg parser"
```

---

### Task 2: Golden fixture + `GoldenRideFixture` loader with frozen truth

**Files:**
- Create: `AuraCore/Sources/AuraKit/Resources/golden-ride.gpx` (generated below)
- Create: `AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift`
- Modify: `AuraCore/Package.swift:24` (add resource)
- Test: `AuraCore/Tests/AuraKitTests/GoldenRideFixtureTests.swift`

**Interfaces:**
- Consumes: `GPXParser.parse(_ xml: String) throws -> GPXTrack` (AuraCore), `SimulatedLocationProvider(track:speedMultiplier:)` (AuraKit).
- Produces: `public enum GoldenRideFixture` with `static func track() throws -> GPXTrack`, `@MainActor static func simulatedProvider(multiplier: Double) throws -> SimulatedLocationProvider`, and frozen literals `expectedPointCount: Int`, `expectedDistanceMeters: Double`, `expectedElevationGainMeters: Double`, `expectedMovingTimeSeconds: Double`, `nominalDurationSeconds: Double`. Consumed by Tasks 3, 4, 5.

- [ ] **Step 1: Generate the fixture**

Run from repo root (deterministic; commit the output):

```bash
python3 - <<'EOF'
from datetime import datetime, timedelta
lat, lon = 40.4800, -79.7600            # Plum Boro area — far from curated Pittsburgh gems
dlat, dlon = 0.000292, 0.000384         # ~32.5 m per 5 s step (≈6.5 m/s, ~23 km/h)
start = datetime(2026, 7, 22, 12, 0, 0)
pts = []
for i in range(90):
    if i < 45: la, lo = lat + dlat * i, lon                       # north leg
    else:      la, lo = lat + dlat * 44, lon + dlon * (i - 44)    # east leg
    if i < 30:   ele = 240 + 2 * i          # climb: 29 deltas of +2 m (all ≥ 1 m threshold)
    elif i < 60: ele = 298                  # flat
    else:        ele = 298 - 2 * (i - 59)   # descent (no gain contribution)
    t = (start + timedelta(seconds=5 * i)).strftime('%Y-%m-%dT%H:%M:%SZ')
    pts.append(f'  <trkpt lat="{la:.6f}" lon="{lo:.6f}"><ele>{ele}</ele><time>{t}</time></trkpt>')
xml = '<?xml version="1.0"?>\n<gpx version="1.1"><trk><trkseg>\n' + '\n'.join(pts) + '\n</trkseg></trk></gpx>\n'
open('AuraCore/Sources/AuraKit/Resources/golden-ride.gpx', 'w').write(xml)
print("wrote", len(pts), "points")
EOF
```

Expected output: `wrote 90 points`.

- [ ] **Step 2: Declare the resource**

In `AuraCore/Package.swift`, change the AuraKit target line to:

```swift
        .target(name: "AuraKit", dependencies: ["AuraCore"],
                resources: [.process("Resources/gems.json"),
                            .process("Resources/golden-ride.gpx")]),
```

- [ ] **Step 3: Write the failing loader test + the record helper**

```swift
// AuraCore/Tests/AuraKitTests/GoldenRideFixtureTests.swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct GoldenRideFixtureTests {
    @Test func fixtureLoadsWithExpectedShape() throws {
        let track = try GoldenRideFixture.track()
        #expect(track.points.count == GoldenRideFixture.expectedPointCount)
        #expect(track.points.first?.elevation == 240)
        // Every point parsed (lat/lon/time all present in the authored file).
        #expect(track.points.last?.timestamp.timeIntervalSince(track.points[0].timestamp)
                == GoldenRideFixture.nominalDurationSeconds)
    }

    /// Re-record helper (the documented refresh procedure, mirroring the snapshot-test
    /// policy): run with GOLDEN_RECORD=1 and paste the printed literals into
    /// GoldenRideFixture. Skipped otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLDEN_RECORD"] != nil))
    func recordTruthLiterals() throws {
        let track = try GoldenRideFixture.track()
        let stats = RideStatsCalculator.stats(from: track.points)
        print("""
        GOLDEN_RECORD →
            expectedPointCount = \(track.points.count)
            expectedDistanceMeters = \(stats.distanceMeters)
            expectedElevationGainMeters = \(stats.elevationGainMeters)
            expectedMovingTimeSeconds = \(stats.movingTimeSeconds)
        """)
    }
}
```

- [ ] **Step 4: Implement the loader with provisional literals**

```swift
// AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift
import Foundation
import AuraCore

/// The canonical golden-ride fixture (ROH-92): one bundled GPX consumed by the package
/// playback test AND the app's simulated-ride mode, so the two can't drift. The frozen
/// literals below are the ground truth both layers assert against; refresh them
/// deliberately via `GOLDEN_RECORD=1 swift test --filter recordTruthLiterals` and paste —
/// never recompute them at test time (that would let a calculator regression pass).
public enum GoldenRideFixture {
    /// 90 points, 5 s apart: a north leg then an east leg near Plum Boro (gem-free area),
    /// climbing +2 m/sample for 30 samples (all above the 1 m noise threshold), then flat,
    /// then descending. ~2.9 km at a steady ~6.5 m/s.
    public static let expectedPointCount = 90
    public static let expectedDistanceMeters = 2_890.0      // provisional — Step 5 pastes exact
    public static let expectedElevationGainMeters = 58.0    // provisional — Step 5 pastes exact
    public static let expectedMovingTimeSeconds = 445.0     // provisional — Step 5 pastes exact
    public static let nominalDurationSeconds = 445.0

    public static func track() throws -> GPXTrack {
        guard let url = Bundle.module.url(forResource: "golden-ride", withExtension: "gpx") else {
            throw FixtureError.missingResource
        }
        return try GPXParser.parse(String(contentsOf: url, encoding: .utf8))
    }

    @MainActor
    public static func simulatedProvider(multiplier: Double) throws -> SimulatedLocationProvider {
        SimulatedLocationProvider(track: try track(), speedMultiplier: multiplier)
    }

    public enum FixtureError: Error { case missingResource }
}
```

- [ ] **Step 5: Record the exact literals**

Run: `cd AuraCore && GOLDEN_RECORD=1 swift test --no-parallel --filter GoldenRideFixtureTests`
Copy the printed `expectedDistanceMeters` / `expectedElevationGainMeters` /
`expectedMovingTimeSeconds` values into `GoldenRideFixture.swift`, replacing the three
provisional literals (keep them as plain `Double` literals; drop the `// provisional` comments).
Sanity: distance must be ~2 800–3 000, gain exactly 58.0, moving time exactly 445.0 —
investigate before pasting if not.

- [ ] **Step 6: Run to verify pass**

Run: `cd AuraCore && swift test --no-parallel --filter GoldenRideFixtureTests`
Expected: PASS (`fixtureLoadsWithExpectedShape`; the record helper shows as skipped).

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraKit/Resources/golden-ride.gpx AuraCore/Sources/AuraKit/Testing/GoldenRideFixture.swift AuraCore/Package.swift AuraCore/Tests/AuraKitTests/GoldenRideFixtureTests.swift
git commit -m "feat(roh-92): golden-ride fixture + frozen truth literals"
```

---

### Task 3: Layer 1 — golden-ride playback suite

**Files:**
- Test: `AuraCore/Tests/AuraKitTests/GoldenRidePlaybackTests.swift`

**Interfaces:**
- Consumes: `GoldenRideFixture` (Task 2); `SimulatedLocationProvider`; `RideSessionCoordinator` (`init(kind:destinationName:screen:activity:)`, `start(location:saving:units:authorization:)`, internal `streamTask`, `finish()`, `finishedRide`, `saveFailed`); `RideStore.inMemory()`, `store.allRides()`, `store.summaries()`; existing internal fakes `SpyScreenWake`, `SpyRideActivity` from `RideSessionCoordinatorTests.swift` (same test target, internal access — do NOT redeclare them).
- Produces: the Layer-1 regression gate; nothing downstream consumes code from it.

- [ ] **Step 1: Write the failing test**

```swift
// AuraCore/Tests/AuraKitTests/GoldenRidePlaybackTests.swift
import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Layer 1 of the ROH-92 golden-ride harness: the real GPX → GPXLocationPlayer →
/// SimulatedLocationProvider chain drives the real coordinator into an in-memory store.
/// The numeric duty for the stats math itself stays with RideStatsCalculatorTests /
/// RideStatsSnapshotTests; the frozen literals here catch assembled-chain breaks and
/// fixture drift (e.g. a fixture that silently loses <ele> and records flat).
@MainActor
@Suite(.swiftDataSerialized)
struct GoldenRidePlaybackTests {
    /// Tolerance for cross-architecture Double drift (snapshot-test precedent), far below
    /// any real regression (flat = -58 m of gain, dropped points = tens of meters).
    private func close(_ a: Double, _ b: Double, within tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func goldenRidePlaysThroughCoordinatorAndPersists() async throws {
        let provider = try GoldenRideFixture.simulatedProvider(multiplier: 10_000)
        let store = try RideStore.inMemory()
        let coordinator = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: SpyScreenWake(), activity: SpyRideActivity())
        let outcome = coordinator.start(location: provider, saving: store,
                                        units: .metric, authorization: .authorized)
        #expect(outcome == .started)

        await coordinator.streamTask?.value   // deterministic drain — never sleep
        coordinator.finish()

        let ride = try #require(coordinator.finishedRide)
        #expect(coordinator.saveFailed == false)
        let stats = try #require(ride.stats)
        #expect(ride.track.count == GoldenRideFixture.expectedPointCount)
        #expect(close(stats.distanceMeters, GoldenRideFixture.expectedDistanceMeters))
        #expect(close(stats.elevationGainMeters, GoldenRideFixture.expectedElevationGainMeters))
        #expect(stats.elevationGainMeters > 0)   // hard floor: silent-flat must fail
        #expect(close(stats.movingTimeSeconds, GoldenRideFixture.expectedMovingTimeSeconds))

        // Persisted round-trip: denormalized columns + thumbnail via summaries().
        let summaries = try store.summaries()
        let summary = try #require(summaries.first { $0.id == ride.id })
        #expect(close(summary.distanceMeters, stats.distanceMeters))
        #expect(close(summary.elevationGainMeters, stats.elevationGainMeters))
        #expect(!summary.thumbnailCoordinates.isEmpty)
    }
}
```

Note for the implementer: if `RideSummary`'s field names differ (check
`AuraCore/Sources/AuraCore/Models/RideSummary.swift`), adapt the last three
assertions to the actual names — the asserted *facts* (distance column, gain
column, non-empty thumbnail) are the contract.

- [ ] **Step 2: Run to verify it fails only for the right reason**

Run: `cd AuraCore && swift test --no-parallel --filter GoldenRidePlaybackTests`
Expected: PASS immediately (this layer tests existing package plumbing; the test is new,
the code is not). To prove the test has teeth before trusting it, temporarily change
`multiplier: 10_000` to feed an empty track — `SimulatedLocationProvider(track: GPXTrack(points: []), speedMultiplier: 1)`
— run, observe FAIL on `expectedPointCount`, then restore. (The real regression drill is
Task 8.)

- [ ] **Step 3: Full package suite**

Run: `cd AuraCore && swift test --no-parallel`
Expected: all green (previously 226 + new tests).

- [ ] **Step 4: Commit**

```bash
git add AuraCore/Tests/AuraKitTests/GoldenRidePlaybackTests.swift
git commit -m "test(roh-92): Layer 1 golden-ride playback gate"
```

---

### Task 4: App-side DEBUG wiring (simulated start, store, ambient skip, gems, probe)

**Files:**
- Create: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift` (`RideTestID` + `RideTestProbe`)
- Test: `AuraCore/Tests/AuraKitTests/RideTestProbeTests.swift`
- Modify: `Aura/Sources/AuraApp.swift` (`makeRideStore` + `syncLocationActivity`)
- Modify: `Aura/Sources/Ride/RideHUDView.swift` (start `.task`, probe overlay, back-button identifier, gems live provider)
- Modify: `Aura/Sources/Ride/RideSummaryView.swift` (hero identifier)
- Modify: `Aura/Sources/History/HistoryView.swift` (row identifier)

**Interfaces:**
- Consumes: `SimulatedRideConfig.current`, `.currentForcesInMemoryStore` (Task 1); `GoldenRideFixture.simulatedProvider(multiplier:)` (Task 2).
- Produces: `RideTestID` (`hudProbe = "ride.hud.probe"`, `hudBack = "ride.hud.back"`, `summaryDistance = "summary.distance"`, `historyRow = "history.row"`) and `RideTestProbe.line(distanceMeters:elapsed:elevationGainMeters:) -> String` in format `d=<Int>;e=<Int>;g=<Int>`. Task 5's screen objects consume these via the AuraKit import.

- [ ] **Step 1: Write the failing probe test**

```swift
// AuraCore/Tests/AuraKitTests/RideTestProbeTests.swift
import Testing
@testable import AuraKit

struct RideTestProbeTests {
    @Test func lineFormatsTruncatedIntegers() {
        #expect(RideTestProbe.line(distanceMeters: 1234.9, elapsed: 45.6, elevationGainMeters: 12.2)
                == "d=1234;e=45;g=12")
    }

    @Test func parseRoundTrips() {
        let parsed = RideTestProbe.parse("d=1234;e=45;g=12")
        #expect(parsed?.distanceMeters == 1234)
        #expect(parsed?.elapsed == 45)
        #expect(parsed?.elevationGainMeters == 12)
    }

    @Test func parseRejectsGarbage() {
        #expect(RideTestProbe.parse("hello") == nil)
    }
}
```

- [ ] **Step 2: Implement `RideTestSupport.swift`**

```swift
// AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift
import Foundation

/// Accessibility identifiers shared between the app views and the XCUITest screen objects
/// (the AuraUITests target links AuraKit), so a rename is a compile-time break in both
/// places instead of a silent CI failure.
public enum RideTestID {
    public static let hudProbe = "ride.hud.probe"
    public static let hudBack = "ride.hud.back"
    public static let summaryDistance = "summary.distance"
    public static let historyRow = "history.row"
}

/// Machine-readable HUD probe line rendered (DEBUG + simulated rides only) so the golden
/// ride asserts raw meters/seconds instead of parsing localized display strings.
public enum RideTestProbe {
    public struct Values: Equatable, Sendable {
        public let distanceMeters: Int
        public let elapsed: Int
        public let elevationGainMeters: Int
    }

    public static func line(distanceMeters: Double, elapsed: Double,
                            elevationGainMeters: Double) -> String {
        "d=\(Int(distanceMeters));e=\(Int(elapsed));g=\(Int(elevationGainMeters))"
    }

    public static func parse(_ line: String) -> Values? {
        var d: Int?, e: Int?, g: Int?
        for part in line.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            switch pair[0] {
            case "d": d = value
            case "e": e = value
            case "g": g = value
            default: return nil
            }
        }
        guard let d, let e, let g else { return nil }
        return Values(distanceMeters: d, elapsed: e, elevationGainMeters: g)
    }
}
```

- [ ] **Step 3: Verify probe tests pass**

Run: `cd AuraCore && swift test --no-parallel --filter RideTestProbeTests`
Expected: PASS (3 tests).

- [ ] **Step 4: Wire the app target**

`Aura/Sources/AuraApp.swift` — `makeRideStore()` becomes:

```swift
    /// Builds the app's persistent SwiftData-backed RideStore. Falls back to an
    /// in-memory store if the on-disk container can't be created, so the app still runs.
    @MainActor static func makeRideStore() -> RideStore {
        #if DEBUG
        // Golden-ride harness (ROH-92): a fresh in-memory store per launch keeps the
        // History assertion deterministic across local runs and CI sims.
        if SimulatedRideConfig.currentForcesInMemoryStore, let store = try? RideStore.inMemory() {
            return store
        }
        #endif
        do {
            return try RideStore.persistent()
        } catch {
            assertionFailure("Failed to build persistent ModelContainer: \(error)")
            return (try? RideStore.inMemory()) ?? {
                // Last-resort: an in-memory store should never fail; if it does, crash loudly.
                fatalError("Could not create any RideStore: \(error)")
            }()
        }
    }
```

`Aura/Sources/AuraApp.swift` — top of `syncLocationActivity()` (RootView):

```swift
    private func syncLocationActivity() {
        #if DEBUG
        // Golden-ride harness: never engage the ambient CoreLocation tier while a ride is
        // simulated, so no permission prompt can interrupt the UI test mid-navigation.
        if SimulatedRideConfig.current != nil { return }
        #endif
        let isHomeForeground = router.path.isEmpty && scenePhase != .background
        ...existing body unchanged...
    }
```

`Aura/Sources/Ride/RideHUDView.swift` — in the auto-start `.task` (currently lines 158-175), replace the `GemDiscoveryStore` construction and `coordinator.start` call:

```swift
        .task {
            var liveProvider: any GemProviding = LiveGemProvider()
            var rideLocation: any LocationStreaming = location
            var rideAuthorization = location.authorization
            #if DEBUG
            // Golden-ride harness (ROH-92): simulated rides swap the location seam for the
            // bundled fixture, bypass the permission gate (no CoreLocation involved), and
            // drop the live Overpass gem source (unmocked network → nondeterministic cards).
            if let sim = SimulatedRideConfig.current {
                do {
                    rideLocation = try GoldenRideFixture.simulatedProvider(multiplier: sim.speedMultiplier)
                    rideAuthorization = .authorized
                    liveProvider = EmptyGemProvider()
                } catch {
                    assertionFailure("Simulated ride fixture failed to load: \(error)")
                }
            }
            #endif
            let store = gems ?? GemDiscoveryStore(
                provider: CompositeGemProvider(
                    local: [PersonalGemProvider(reading: savedPlaces), CuratedGemProvider()],
                    live: liveProvider),
                seen: SeenGemStore(container: rideStore.container),
                haptics: GemHapticPlayer())
            store.detourActive = { [coordinator] in coordinator.isDetouring }
            guidance.units = settings.units
            gems = store
            let outcome = coordinator.start(
                location: rideLocation, saving: rideStore, units: settings.units,
                authorization: rideAuthorization, saveToHealth: settings.saveToHealth,
                discoverySink: store)
            if outcome == .permissionDenied { showPermission = true }
        }
```

Add `EmptyGemProvider` at the bottom of `RideHUDView.swift` (app target, DEBUG only):

```swift
#if DEBUG
/// Harness stand-in for LiveGemProvider: contributes nothing, touches no network.
private struct EmptyGemProvider: GemProviding {
    func gems(near coordinate: Coordinate) async -> [Gem] { [] }
}
#endif
```

(If `GemProviding`'s requirement differs — check `AuraCore/Sources/AuraKit/Gems/` — match
its exact signature; the contract is "always returns []".)

Probe overlay — add after the existing `.overlay(alignment: .topTrailing)` GPS-chip overlay:

```swift
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if SimulatedRideConfig.current != nil {
                Text(RideTestProbe.line(distanceMeters: coordinator.stats.distanceMeters,
                                        elapsed: coordinator.elapsed,
                                        elevationGainMeters: coordinator.stats.elevationGainMeters))
                    .font(.system(size: 8))
                    .opacity(0.02)   // invisible to riders, present in the a11y tree
                    .accessibilityIdentifier(RideTestID.hudProbe)
            }
        }
        #endif
```

Back-button identifier — in `var backButton`, after `.accessibilityLabel(...)`:

```swift
        .accessibilityIdentifier(RideTestID.hudBack)
```

`Aura/Sources/Ride/RideSummaryView.swift` — on `heroDistance`, after the existing
`.accessibilityLabel(...)` line:

```swift
        .accessibilityIdentifier(RideTestID.summaryDistance)
```

`Aura/Sources/History/HistoryView.swift` — on the `RideRow(...)` call inside the list
`ForEach`, directly after `RideRow(summary: summary, units: settings.units)`:

```swift
                    .accessibilityIdentifier(RideTestID.historyRow)
```

Add `import AuraKit` where missing (AuraApp.swift already imports it; verify the others do).

- [ ] **Step 5: Build the app**

Run: `cd Aura && xcodegen generate && xcodebuild build -project Aura.xcodeproj -scheme Aura -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet`
Expected: BUILD SUCCEEDED. Also run `swiftlint lint --strict` from repo root: 0 violations.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift AuraCore/Tests/AuraKitTests/RideTestProbeTests.swift Aura/Sources/AuraApp.swift Aura/Sources/Ride/RideHUDView.swift Aura/Sources/Ride/RideSummaryView.swift Aura/Sources/History/HistoryView.swift
git commit -m "feat(roh-92): DEBUG simulated-ride wiring + test probe + identifiers"
```

---

### Task 5: Layer 2 — `RideE2EUITests` + screen objects + project plumbing

**Files:**
- Create: `Aura/UITests/RideE2EUITests.swift`
- Modify: `Aura/UITests/Screens/Screens.swift` (add `RideScreen`, `SummaryScreen`, extend `HistoryScreen`)
- Modify: `Aura/project.yml` (AuraUITests gains AuraKit; remove dead sample GPX)
- Delete: `Aura/Resources/sample-ride-pittsburgh.gpx`

**Interfaces:**
- Consumes: `RideTestID`, `RideTestProbe`, `GoldenRideFixture` literals (via `import AuraKit`); existing `HomeScreen`, `XCUIApplication.launched(onboarded:)` pattern.
- Produces: the CI-runnable golden ride: `AuraUITests/RideE2EUITests/testGoldenRideRecordsToSummaryAndHistory`.

- [ ] **Step 1: project.yml plumbing**

In `Aura/project.yml`:
1. Under `targets.Aura.sources`, delete the two `sample-ride-pittsburgh.gpx` entries: the
   `- sample-ride-pittsburgh.gpx` line in `excludes` and the whole
   `- path: Resources/sample-ride-pittsburgh.gpx` / `buildPhase: resources` block (with its comment).
2. Under `targets.AuraUITests.dependencies`, add:

```yaml
      - package: AuraCore
        product: AuraKit
```

3. Delete the file: `git rm Aura/Resources/sample-ride-pittsburgh.gpx`.

- [ ] **Step 2: Screen objects**

In `Aura/UITests/Screens/Screens.swift`: add `import AuraKit` at the top of the file
(next to `import XCTest`), then append:

```swift
@MainActor
struct RideScreen {
    let app: XCUIApplication
    var probe: XCUIElement { app.staticTexts[RideTestID.hudProbe] }
    var backButton: XCUIElement { app.buttons[RideTestID.hudBack] }
    var endAlert: XCUIElement { app.alerts["End ride?"] }

    func probeValues() -> RideTestProbe.Values? { RideTestProbe.parse(probe.label) }

    /// Polls the probe until recorded distance reaches `meters` (or fails at `timeout`).
    func waitForDistance(atLeast meters: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let values = probeValues(), values.distanceMeters >= meters { return true }
            _ = probe.waitForExistence(timeout: 1)   // ~1 s poll cadence
        }
        return false
    }
}

@MainActor
struct SummaryScreen {
    let app: XCUIApplication
    var title: XCUIElement { app.staticTexts["Nice ride"] }
    // Element type of a combined SwiftUI a11y element varies by runtime — query any type.
    var heroDistance: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.summaryDistance).firstMatch
    }
    var doneButton: XCUIElement { app.buttons["Done"] }
}
```

Extend `HistoryScreen` (same file) with:

```swift
    var rideRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: RideTestID.historyRow)
    }
```

- [ ] **Step 3: The golden ride test**

```swift
// Aura/UITests/RideE2EUITests.swift
import XCTest
import AuraKit

/// ROH-92 Layer 2: the golden ride through the real app. Launches with the simulated
/// location fixture, records to ≥80% of the fixture's distance, ends the ride, and asserts
/// the summary and History wiring. Numbers are sanity bands only — Layer 1
/// (GoldenRidePlaybackTests) owns precision.
final class RideE2EUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGoldenRideRecordsToSummaryAndHistory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "golden",
                                "-auraSimulatedRideMultiplier", "30",
                                "-auraInMemoryRideStore"]
        app.launch()
        dismissLocationAlertIfPresent()

        let home = HomeScreen(app: app)
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Home never appeared")
        home.exploreButton.tap()

        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15),
                      "HUD probe missing — simulated-ride hook did not engage")

        // Playback ≈ nominal/multiplier ≈ 15 s; allow generous slack for CI.
        let floor = Int(0.8 * GoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: floor, timeout: 90),
                      "distance never reached \(floor) m — last probe: \(ride.probe.label)")

        // Elapsed ticker advances (catches a frozen tickerTask).
        let elapsedBefore = try XCTUnwrap(ride.probeValues()).elapsed
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 3))
        let deadline = Date().addingTimeInterval(10)
        var advanced = false
        while Date() < deadline {
            if let now = ride.probeValues()?.elapsed, now > elapsedBefore { advanced = true; break }
            _ = ride.probe.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(advanced, "elapsed ticker frozen at \(elapsedBefore)s")

        // Climb recorded (silent-flat guard at the wiring layer).
        let gain = try XCTUnwrap(ride.probeValues()).elevationGainMeters
        XCTAssertGreaterThanOrEqual(gain, 40, "elevation gain flat: \(gain) m")

        // End the ride via the back control → confirmation alert.
        ride.backButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10), "End alert never appeared")
        ride.endAlert.buttons["End ride"].tap()

        // Summary (path collapse) with a sane hero distance.
        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")
        XCTAssertTrue(summary.heroDistance.exists)
        let label = summary.heroDistance.label   // e.g. "Distance, 1.8 miles" or "…2.9 kilometers"
        let value = try XCTUnwrap(Self.leadingNumber(in: label),
                                  "no number in hero label: \(label)")
        if label.contains("kilometer") {
            XCTAssertTrue((2.4...3.4).contains(value), "km out of band: \(label)")
        } else {
            XCTAssertTrue((1.4...2.2).contains(value), "miles out of band: \(label)")
        }

        // Done → Home, then the ride is in History (fresh in-memory store → exactly 1 row).
        summary.doneButton.tap()
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Done did not return Home")
        home.goToHistory()
        let history = HistoryScreen(app: app)
        XCTAssertTrue(history.title.waitForExistence(timeout: 10))
        XCTAssertTrue(history.rideRows.firstMatch.waitForExistence(timeout: 10),
                      "finished ride missing from History")
        XCTAssertEqual(history.rideRows.count, 1)
    }

    /// First decimal number found after the first comma-space (locale label like
    /// "Distance, 1.8 miles"); tolerant of grouping-free decimals.
    private static func leadingNumber(in label: String) -> Double? {
        let scanner = Scanner(string: label)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)
        return scanner.scanDouble()
    }

    /// Defensive only: the ambient tier is skipped in simulated mode, but Mapbox's own
    /// location engine may still prompt on some runtimes.
    @MainActor
    private func dismissLocationAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }
}
```

- [ ] **Step 4: Run locally**

```bash
cd Aura && xcodegen generate
xcodebuild build-for-testing -project Aura.xcodeproj -scheme Aura -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild test-without-building -project Aura.xcodeproj -scheme Aura -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:AuraUITests/RideE2EUITests CODE_SIGNING_ALLOWED=NO
```

Expected: `Test Suite 'RideE2EUITests' passed` (~60–90 s including launch). If the probe
never appears, debug the DEBUG hook (Task 4) before touching timeouts. Also run the seven
existing suites once (`-only-testing:AuraUITests`) to confirm no regression, and
`swiftlint lint --strict`.

- [ ] **Step 5: Commit**

```bash
git add Aura/UITests Aura/project.yml
git rm --cached Aura/Resources/sample-ride-pittsburgh.gpx 2>/dev/null; rm -f Aura/Resources/sample-ride-pittsburgh.gpx
git commit -m "test(roh-92): Layer 2 golden-ride XCUITest + screen objects"
```

---

### Task 6: CI lane + local runner script

**Files:**
- Modify: `.github/workflows/ci.yml` (app-build job)
- Create: `scripts/golden-ride.sh`

**Interfaces:**
- Consumes: the Task 5 test (`AuraUITests/RideE2EUITests`).
- Produces: CI gate + `scripts/golden-ride.sh` for local one-command runs.

- [ ] **Step 1: Rework the `app-build` job**

Replace the `app-build` job's `Build app` step (and extend the job) so it reads:

```yaml
  app-build:
    name: App build + golden ride (xcodebuild)
    runs-on: macos-15
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Write Mapbox credentials
        env:
          MAPBOX_DOWNLOADS_TOKEN: ${{ secrets.MAPBOX_DOWNLOADS_TOKEN }}
          MAPBOX_PUBLIC_TOKEN: ${{ secrets.MAPBOX_PUBLIC_TOKEN }}
        run: |
          umask 077
          printf 'machine api.mapbox.com\n  login mapbox\n  password %s\n' "$MAPBOX_DOWNLOADS_TOKEN" > "$HOME/.netrc"
          printf '%s' "$MAPBOX_PUBLIC_TOKEN" > Aura/Resources/MapboxAccessToken
      - name: Generate project
        working-directory: Aura
        run: xcodegen generate
      - name: Select and boot simulator
        id: sim
        run: |
          UDID=$(xcrun simctl list -j devices available | jq -r '
            .devices | to_entries
            | map(select(.key | contains("iOS")))
            | sort_by(.key) | last | .value
            | map(select(.isAvailable and (.name | startswith("iPhone"))))
            | last | .udid')
          test -n "$UDID" && test "$UDID" != "null"
          xcrun simctl boot "$UDID" || true
          xcrun simctl bootstatus "$UDID" -b
          xcrun simctl privacy "$UDID" grant location com.rohunjoseph.aura || true
          echo "udid=$UDID" >> "$GITHUB_OUTPUT"
      - name: Build for testing (also builds the embedded AuraWidgets extension)
        working-directory: Aura
        run: |
          xcodebuild build-for-testing \
            -project Aura.xcodeproj \
            -scheme Aura \
            -configuration Debug \
            -destination "id=${{ steps.sim.outputs.udid }}" \
            -derivedDataPath DerivedData \
            CODE_SIGNING_ALLOWED=NO
      # Golden-ride E2E (ROH-92). Skipped for fork PRs: no Mapbox secrets there, so the
      # build above already failed anyway — the guard just makes intent explicit.
      - name: Golden ride E2E
        if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository
        working-directory: Aura
        run: |
          xcodebuild test-without-building \
            -project Aura.xcodeproj \
            -scheme Aura \
            -configuration Debug \
            -destination "id=${{ steps.sim.outputs.udid }}" \
            -derivedDataPath DerivedData \
            -only-testing:AuraUITests/RideE2EUITests \
            -retry-tests-on-failure -test-iterations 2 \
            CODE_SIGNING_ALLOWED=NO
      - name: Shutdown simulators
        if: always()
        run: xcrun simctl shutdown all || true
```

(Comment block at the top of ci.yml stays; do not touch the other jobs.)

- [ ] **Step 2: Local runner script**

```bash
#!/usr/bin/env bash
# scripts/golden-ride.sh — build + run the ROH-92 golden-ride E2E locally.
# Usage: scripts/golden-ride.sh [simulator-name]   (default: iPhone 17)
set -euo pipefail
cd "$(dirname "$0")/.."
SIM_NAME="${1:-iPhone 17}"

if [ ! -s Aura/Resources/MapboxAccessToken ]; then
  echo "error: Aura/Resources/MapboxAccessToken missing — see .mapbox-setup.md" >&2
  exit 1
fi

(cd Aura && xcodegen generate)

UDID=$(xcrun simctl list -j devices available | jq -r --arg name "$SIM_NAME" '
  .devices | to_entries | map(select(.key | contains("iOS"))) | sort_by(.key)
  | map(.value | map(select(.isAvailable and .name == $name))) | flatten
  | last | .udid')
if [ -z "$UDID" ] || [ "$UDID" = "null" ]; then
  echo "error: no available simulator named '$SIM_NAME'" >&2
  exit 1
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl privacy "$UDID" grant location com.rohunjoseph.aura || true

cd Aura
xcodebuild build-for-testing -project Aura.xcodeproj -scheme Aura -configuration Debug \
  -destination "id=$UDID" -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -quiet
xcodebuild test-without-building -project Aura.xcodeproj -scheme Aura -configuration Debug \
  -destination "id=$UDID" -derivedDataPath DerivedData \
  -only-testing:AuraUITests/RideE2EUITests CODE_SIGNING_ALLOWED=NO
```

`chmod +x scripts/golden-ride.sh`.

- [ ] **Step 3: Verify locally**

Run: `scripts/golden-ride.sh`
Expected: golden ride passes end-to-end via the script.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml scripts/golden-ride.sh
git commit -m "ci(roh-92): golden-ride E2E lane in app-build + local runner script"
```

---

### Task 7: Regression drill (prove the gate has teeth, then revert)

**Files:** temporary edits only — nothing new committed except the drill note in the PR body later.

- [ ] **Step 1: Drill Layer 1** — in `AuraCore/Sources/AuraKit/RideSession/RideRecorder.swift`, find `func record(` and make it drop every other point (e.g. guard on `track.count % 2 == 0` before appending). Run `cd AuraCore && swift test --no-parallel --filter GoldenRidePlaybackTests`. Expected: FAIL on point count + distance. Save the failure output. `git checkout -- AuraCore/Sources/AuraKit/RideSession/RideRecorder.swift`.

- [ ] **Step 2: Drill Layer 2** — in `Aura/Sources/Ride/RideHUDView.swift`, comment out the `router.showRideSummary(ride, saveFailed: coordinator.saveFailed)` line in the `finishedRide` onChange. Run `scripts/golden-ride.sh`. Expected: FAIL — "Summary never appeared". Save the failure output. Revert the edit.

- [ ] **Step 3: Confirm both layers green again** — `cd AuraCore && swift test --no-parallel` and `scripts/golden-ride.sh`. Expected: all green. Record both drill outputs for the PR body.

---

### Task 8: ROADMAP testing section

**Files:**
- Modify: `docs/ROADMAP.md` (testing section, ~lines 653–682)

- [ ] **Step 1: Update the testing section.** After the sentence ending "…run sim-first. A CI job for them is deferred; they run locally and on demand until the suite earns its own CI iteration." — replace the remainder of that sentence's paragraph (the part claiming the record-to-summary flow is a one-off smoke test) with:

```markdown
The free-ride record-to-summary loop is now gated end to end (ROH-92): a package-level
golden-ride playback test (`GoldenRidePlaybackTests`) drives the real GPX →
`SimulatedLocationProvider` → coordinator → store chain against frozen fixture truth, and
`AuraUITests/RideE2EUITests` rides the same fixture through the real app — Home → HUD →
End → summary → History — in CI (the `app-build` job now runs build-for-testing plus that
one UI test; `scripts/golden-ride.sh` is the local one-liner). The lane's flake policy:
one automatic retry; if it fails twice on unrelated PRs it gets demoted to non-required
and a fix issue filed. Honest boundaries: the harness bypasses live CoreLocation ingestion
(`LocationService.points()` — ROH-83/ROH-88 territory, still covered by unit seams +
device verification), the navigate/group summary seams (ROH-93), and the route-planning
elevation path (ROH-94). The Mapbox-backed providers remain built-but-untested in CI.
```

Adjust surrounding prose so the paragraph still reads cleanly (keep the Terrain-RGB
cautionary-tale sentence — it stays true for UI work generally).

- [ ] **Step 2: Commit**

```bash
git add docs/ROADMAP.md
git commit -m "docs(roh-92): ROADMAP testing section reflects the golden-ride gate"
```

---

### Task 9: Integration (main-session work, not a subagent task)

Push branch, open PR (body includes the drill outputs from Task 7), watch CI green,
merge per project default (`gh pr merge --merge`), fast-forward local main, move ROH-92
In Review → Done. If the CI sim cannot run the app (Mapbox/GPU), apply the spec's
fallback: keep the `Golden ride E2E` step `continue-on-error: true` with a comment, file
the fix issue, and record the reality in ROADMAP + the PR body.
