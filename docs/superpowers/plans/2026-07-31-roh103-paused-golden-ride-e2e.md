# ROH-103 Paused Golden-Ride E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive the real cockpit pause control through a two-segment GPX fixture in the iOS Simulator, so the pause feature's view wiring, its end-while-paused path, and its persisted segmented save are covered end to end for the first time.

**Architecture:** The golden-ride harness (ROH-92/93) replays a bundled GPX through the real app behind DEBUG launch arguments. This pass teaches it to select a *second* fixture, extends its invisible accessibility probe with speed and segment count, and adds two XCUITest methods: a free-ride test that pauses at the fixture's own segment boundary and a short navigate test that covers the second, duplicated pause-toggle implementation.

**Tech Stack:** Swift 6, SwiftUI, XCUITest, Swift Testing (package layer), Mapbox Maps SDK, `xcodebuild` against an iPhone 17 simulator.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-31-roh103-paused-golden-ride-e2e-design.md` (revision 2). Parent: `docs/superpowers/specs/2026-07-26-segmented-rides-pause-design.md`.
- Fixture literals are **frozen and recorded, never recomputed at test time**. Refresh only via `GOLDEN_RECORD=1 swift test --filter recordPausedTruthLiterals` and paste.
- Package code lives in `AuraCore/` (targets `AuraCore` and `AuraKit`); app code in `Aura/Sources/`; UI tests in `Aura/UITests/`. The app target has no test bundle, so any logic that needs testing goes in `AuraKit`.
- The package builds on a macOS host in CI, so iOS-only CoreLocation APIs must stay `#if os(iOS)`-guarded. Nothing in this plan touches them.
- SwiftLint must pass from the repo root: `scripts/lint.sh`.
- Delegate every `xcodebuild` invocation to the `apple-platform-build-tools:builder` subagent; do not run it inline.
- Never construct a bare `LocationService()` in a test (ROH-88).
- Accessibility identifiers are declared once in `RideTestID` (`AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`) and referenced from both the view and the screen object, so a rename is a compile error in both places.

---

### Task 1: Fixture selection validated at parse

The launch argument currently names a fixture that nothing reads: `rideOverride` always loads `GoldenRideFixture`. An unknown name must turn the whole harness off rather than leave five of its six sites engaged while the ride records real GPS (spec D1).

**Files:**
- Create: `AuraCore/Sources/AuraKit/Testing/SimulatedRideFixture.swift`
- Create: `AuraCore/Tests/AuraKitTests/SimulatedRideFixtureTests.swift`
- Modify: `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift:20-32`
- Modify: `AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift` (append a factory)
- Modify: `Aura/Sources/Ride/SimulatedRideSupport.swift:13-26`
- Test: `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift`

**Interfaces:**
- Consumes: `GoldenRideFixture.simulatedProvider(multiplier:)`, `PausedGoldenRideFixture.track()`, `SimulatedLocationProvider(track:speedMultiplier:)`.
- Produces: `SimulatedRideFixture.isKnown(_ name: String) -> Bool` and `@MainActor SimulatedRideFixture.provider(named: String, multiplier: Double) throws -> SimulatedLocationProvider?`. `SimulatedRideConfig.parse` returns `nil` for an unknown fixture name. `PausedGoldenRideFixture.simulatedProvider(multiplier:)`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/SimulatedRideFixtureTests.swift`:

```swift
import Testing
@testable import AuraKit

struct SimulatedRideFixtureTests {
    @Test func knownNamesAreTheTwoBundledFixtures() {
        #expect(SimulatedRideFixture.isKnown("golden"))
        #expect(SimulatedRideFixture.isKnown("paused"))
    }

    @Test func unknownNameIsNotKnown() {
        // The typo case the validation exists for.
        #expect(!SimulatedRideFixture.isKnown("pasued"))
        #expect(!SimulatedRideFixture.isKnown(""))
    }

    @MainActor
    @Test func providerResolvesBothFixturesAndNilsAnUnknownOne() throws {
        #expect(try SimulatedRideFixture.provider(named: "golden", multiplier: 30) != nil)
        #expect(try SimulatedRideFixture.provider(named: "paused", multiplier: 30) != nil)
        #expect(try SimulatedRideFixture.provider(named: "pasued", multiplier: 30) == nil)
    }
}
```

Append to `AuraCore/Tests/AuraKitTests/SimulatedRideConfigTests.swift`:

```swift
    @Test func parseAcceptsThePausedFixture() {
        let config = SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide", "paused"])
        #expect(config?.fixture == "paused")
    }

    @Test func parseRejectsAnUnknownFixtureName() {
        // Spec D1: an unrecognised name must turn the whole harness off, not just the ride
        // stream — six sites key off `current != nil`.
        #expect(SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide", "pasued"]) == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd AuraCore && swift test --filter SimulatedRide`
Expected: FAIL — `cannot find 'SimulatedRideFixture' in scope`, and `parseRejectsAnUnknownFixtureName` fails because `parse` accepts any non-flag string.

- [ ] **Step 3: Write the registry**

Create `AuraCore/Sources/AuraKit/Testing/SimulatedRideFixture.swift`:

```swift
import Foundation

/// Name-to-fixture lookup for the golden-ride harness (ROH-92/93/103). A dictionary here
/// rather than a `switch` in the app target, for the reason `PauseNudgePolicy` already
/// documents: the app target has no test bundle, so a `switch` there is untestable by
/// construction. `SimulatedRideConfig.parse` validates against this, so an unrecognised
/// name turns the harness off everywhere instead of leaving the app half-harnessed on
/// real GPS.
public enum SimulatedRideFixture {
    /// Every fixture the harness can play, keyed by the launch argument's value.
    public static let names: Set<String> = ["golden", "paused"]

    public static func isKnown(_ name: String) -> Bool { names.contains(name) }

    /// The replay stream for `name`, or nil if the name is unknown. Throws only when a
    /// known fixture fails to load, which is a packaging regression.
    @MainActor
    public static func provider(named name: String,
                                multiplier: Double) throws -> SimulatedLocationProvider? {
        switch name {
        case "golden": return try GoldenRideFixture.simulatedProvider(multiplier: multiplier)
        case "paused": return try PausedGoldenRideFixture.simulatedProvider(multiplier: multiplier)
        default: return nil
        }
    }
}
```

Append to `AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift`, inside the enum:

```swift
    @MainActor
    public static func simulatedProvider(multiplier: Double) throws -> SimulatedLocationProvider {
        SimulatedLocationProvider(track: try track(), speedMultiplier: multiplier)
    }
```

- [ ] **Step 4: Validate the name in `parse`**

In `AuraCore/Sources/AuraKit/Testing/SimulatedRideConfig.swift`, replace the fixture guard (line 23-24):

```swift
        let fixture = arguments[index + 1]
        guard !fixture.hasPrefix("-") else { return nil }
```

with:

```swift
        let fixture = arguments[index + 1]
        // Spec D1: an unknown name must read as "no harness" at all six `current != nil`
        // sites, not just at the ride stream. Otherwise a typo gives you the in-memory
        // store, the probe, scripted guidance and no ambient location tier, over a ride
        // recording real GPS — which reads in CI as "distance never reached" 90 s later.
        guard !fixture.hasPrefix("-"), SimulatedRideFixture.isKnown(fixture) else { return nil }
```

- [ ] **Step 5: Run the package tests to verify they pass**

Run: `cd AuraCore && swift test --filter SimulatedRide`
Expected: PASS, all cases.

Note: `swift test` prints TWO totals (Swift Testing and XCTest). Read both.

- [ ] **Step 6: Resolve the app's override through the registry**

In `Aura/Sources/Ride/SimulatedRideSupport.swift`, replace the body of `rideOverride()` (lines 16-25):

```swift
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
```

with:

```swift
        guard let sim = SimulatedRideConfig.current else { return nil }
        do {
            // The name is validated in `SimulatedRideConfig.parse`, so `current` being
            // non-nil already means the lookup knows it; the nil branch below is
            // unreachable and asserts rather than riding on real GPS.
            guard let provider = try SimulatedRideFixture.provider(
                named: sim.fixture, multiplier: sim.speedMultiplier) else {
                assertionFailure("Simulated ride fixture not in the registry: \(sim.fixture)")
                return nil
            }
            return (provider, .authorized)
        } catch {
            // Defensive-only: the fixture is always bundled; a packaging regression
            // fails loudly in Debug instead of silently riding on GPS.
            assertionFailure("Simulated ride fixture failed to load: \(error)")
            return nil
        }
```

The argument label is `multiplier:`, matching the registry signature in Step 3.

- [ ] **Step 7: Build the app to verify the call site compiles**

Dispatch the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme, Debug, for an iPhone 17 simulator, `CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Lint and commit**

```bash
scripts/lint.sh
git add AuraCore/Sources/AuraKit/Testing/ AuraCore/Tests/AuraKitTests/ Aura/Sources/Ride/SimulatedRideSupport.swift
git commit -m "feat(roh-103): select the harness fixture by name, validated at parse"
```

---

### Task 2: Per-segment distance literal

The E2E finds the fixture's segment boundary by riding to a known distance (spec D4), which needs a frozen per-segment number. The recorder that emits this fixture's literals does not print one.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift:24-37`
- Modify: `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift:70-86` (the recorder) and add a test

**Interfaces:**
- Produces: `PausedGoldenRideFixture.expectedSegmentDistanceMeters: [Double]`, used by Task 6.

- [ ] **Step 1: Write the failing test**

Append to `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift`, inside the struct:

```swift
    /// Three literals describe the same track and must agree. Nothing checked that they did.
    @Test func segmentDistancesSumToTheRideDistance() throws {
        let perSegment = PausedGoldenRideFixture.expectedSegmentDistanceMeters
        #expect(perSegment.count == PausedGoldenRideFixture.expectedSegmentCount)
        #expect(close(perSegment.reduce(0, +), PausedGoldenRideFixture.expectedDistanceMeters))

        // And they are the frozen truth, not a recomputation: each matches the fixture.
        let segments = try PausedGoldenRideFixture.track().segments
        for (index, segment) in segments.enumerated() {
            #expect(close(RideStatsCalculator.stats(segments: [segment]).distanceMeters,
                          perSegment[index]))
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd AuraCore && swift test --filter segmentDistancesSumToTheRideDistance`
Expected: FAIL — `type 'PausedGoldenRideFixture' has no member 'expectedSegmentDistanceMeters'`.

- [ ] **Step 3: Extend the recorder**

In `AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift`, inside `recordPausedTruthLiterals`, add above the `print`:

```swift
        let perSegment = track.segments.map {
            RideStatsCalculator.stats(segments: [$0]).distanceMeters
        }
```

and add this line to the printed block, directly under `expectedSegmentPointCounts`:

```
            expectedSegmentDistanceMeters = \(perSegment)
```

- [ ] **Step 4: Record the literal**

Run: `cd AuraCore && GOLDEN_RECORD=1 swift test --filter recordPausedTruthLiterals`

Copy the printed `expectedSegmentDistanceMeters` array **verbatim**. Do not round it, and do not compute it by hand — the fixture file's own rule (`PausedGoldenRideFixture.swift:16-18`) forbids that.

- [ ] **Step 5: Paste it into the fixture**

In `AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift`, directly under `expectedSegmentPointCounts`:

```swift
    /// Per-segment distance, so a test can ride to a segment boundary deterministically
    /// instead of guessing at it (ROH-103 spec D4). Sums to `expectedDistanceMeters`;
    /// `segmentDistancesSumToTheRideDistance` holds the three literals to that.
    public static let expectedSegmentDistanceMeters: [Double] = [<paste>, <paste>]
```

- [ ] **Step 6: Run the package tests to verify they pass**

Run: `cd AuraCore && swift test --filter PausedGoldenRideFixture`
Expected: PASS. Both totals.

- [ ] **Step 7: Lint and commit**

```bash
scripts/lint.sh
git add AuraCore/Sources/AuraKit/Testing/PausedGoldenRideFixture.swift AuraCore/Tests/AuraKitTests/PausedGoldenRideFixtureTests.swift
git commit -m "feat(roh-103): freeze the paused fixture's per-segment distances"
```

---

### Task 3: Speed and segment count on the HUD probe

Spec D2. The probe is the only place a UI test can read raw, unformatted ride numbers. `s` and `n` parse as **optional** so a test bundle from this commit against an older app binary — an ordinary `test-without-building` state — does not fail all three golden tests with an unattributable nil.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift:23-50`
- Modify: `AuraCore/Tests/AuraKitTests/RideTestProbeTests.swift`
- Modify: `Aura/Sources/Ride/SimulatedRideSupport.swift:33-65`
- Modify: `Aura/Sources/Ride/RideHUDView.swift:94-96`
- Modify: `Aura/Sources/Ride/NavigateHUDView.swift:154-156`

**Interfaces:**
- Produces: `RideTestProbe.line(distanceMeters:elapsed:elevationGainMeters:speedDecimetersPerSecond:segmentCount:)`; `RideTestProbe.Values` gains `speedDecimetersPerSecond: Int?` and `segmentCount: Int?`; `View.simulatedRideProbe(distanceMeters:elapsed:elevationGainMeters:speedMetersPerSecond:segmentCount:)`.

- [ ] **Step 1: Write the failing tests**

Replace the body of `AuraCore/Tests/AuraKitTests/RideTestProbeTests.swift` with:

```swift
import Testing
@testable import AuraKit

struct RideTestProbeTests {
    @Test func lineFormatsTruncatedIntegers() {
        #expect(RideTestProbe.line(distanceMeters: 1234.9, elapsed: 45.6,
                                   elevationGainMeters: 12.2,
                                   speedMetersPerSecond: 6.54, segmentCount: 2)
                == "d=1234;e=45;g=12;s=65;n=2")
    }

    @Test func parseRoundTrips() {
        let parsed = RideTestProbe.parse("d=1234;e=45;g=12;s=65;n=2")
        #expect(parsed?.distanceMeters == 1234)
        #expect(parsed?.elapsed == 45)
        #expect(parsed?.elevationGainMeters == 12)
        #expect(parsed?.speedDecimetersPerSecond == 65)
        #expect(parsed?.segmentCount == 2)
    }

    /// A test bundle from this commit against an app binary from before it. `d/e/g` are
    /// required; the two new fields degrade to nil rather than failing the whole parse and
    /// taking the two shipped golden rides down with an unattributable error.
    @Test func parseAcceptsAnOldFormatLine() {
        let parsed = RideTestProbe.parse("d=1234;e=45;g=12")
        #expect(parsed?.distanceMeters == 1234)
        #expect(parsed?.speedDecimetersPerSecond == nil)
        #expect(parsed?.segmentCount == nil)
    }

    @Test func parseRejectsGarbage() {
        #expect(RideTestProbe.parse("hello") == nil)
    }

    @Test func parseRejectsAMissingRequiredField() {
        #expect(RideTestProbe.parse("d=1234;e=45") == nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd AuraCore && swift test --filter RideTestProbe`
Expected: FAIL — extra argument `speedMetersPerSecond` in call.

- [ ] **Step 3: Extend the probe**

In `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`, replace `RideTestProbe`'s `Values`, `line` and `parse`:

```swift
public enum RideTestProbe {
    public struct Values: Equatable, Sendable {
        public let distanceMeters: Int
        public let elapsed: Int
        public let elevationGainMeters: Int
        /// Decimetres per second, not metres: `pause(at:)` writes exactly 0, so the paused
        /// assertion is an equality, and this resolution also shows a partial-decay
        /// regression that metre truncation would round into looking correct.
        public let speedDecimetersPerSecond: Int?
        /// Live `coordinator.segments.count`. A cheap check that `resume()` ran — NOT proof
        /// of the saved shape: `resume(at:)` appends unconditionally, and the saved ride goes
        /// through `normalizedSegments`, which drops a trailing empty. The distance and
        /// moving-time bands are what prove the segmented save.
        public let segmentCount: Int?
    }

    public static func line(distanceMeters: Double, elapsed: Double,
                            elevationGainMeters: Double,
                            speedMetersPerSecond: Double, segmentCount: Int) -> String {
        "d=\(Int(distanceMeters));e=\(Int(elapsed));g=\(Int(elevationGainMeters))"
            + ";s=\(Int(speedMetersPerSecond * 10));n=\(segmentCount)"
    }

    /// `d`, `e` and `g` are required; `s` and `n` are optional so an app binary predating
    /// ROH-103 still parses. An unknown key is still a hard failure — it means the format
    /// changed in a way this parser does not understand.
    public static func parse(_ line: String) -> Values? {
        var d: Int?, e: Int?, g: Int?, s: Int?, n: Int?
        for part in line.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            switch pair[0] {
            case "d": d = value
            case "e": e = value
            case "g": g = value
            case "s": s = value
            case "n": n = value
            default: return nil
            }
        }
        guard let d, let e, let g else { return nil }
        return Values(distanceMeters: d, elapsed: e, elevationGainMeters: g,
                      speedDecimetersPerSecond: s, segmentCount: n)
    }
}
```

- [ ] **Step 4: Run the package tests to verify they pass**

Run: `cd AuraCore && swift test --filter RideTestProbe`
Expected: PASS, five cases.

- [ ] **Step 5: Thread the values through the view modifier**

In `Aura/Sources/Ride/SimulatedRideSupport.swift`, add the two stored properties to `SimulatedRideProbe`, pass them to `RideTestProbe.line`, and extend the `View` extension. The struct becomes:

```swift
private struct SimulatedRideProbe: ViewModifier {
    let distanceMeters: Double
    let elapsed: Double
    let elevationGainMeters: Double
    let speedMetersPerSecond: Double
    let segmentCount: Int

    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .bottomLeading) {
            if SimulatedRideConfig.current != nil {
                Text(RideTestProbe.line(distanceMeters: distanceMeters,
                                        elapsed: elapsed,
                                        elevationGainMeters: elevationGainMeters,
                                        speedMetersPerSecond: speedMetersPerSecond,
                                        segmentCount: segmentCount))
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
                            elevationGainMeters: Double,
                            speedMetersPerSecond: Double,
                            segmentCount: Int) -> some View {
        modifier(SimulatedRideProbe(distanceMeters: distanceMeters, elapsed: elapsed,
                                    elevationGainMeters: elevationGainMeters,
                                    speedMetersPerSecond: speedMetersPerSecond,
                                    segmentCount: segmentCount))
    }
}
```

- [ ] **Step 6: Update both HUD call sites**

`Aura/Sources/Ride/RideHUDView.swift:94` and `Aura/Sources/Ride/NavigateHUDView.swift:154` each call `.simulatedRideProbe(...)`. Add the two arguments to both, reading from the same coordinator the existing arguments read:

```swift
                          speedMetersPerSecond: coordinator.currentSpeedMetersPerSecond,
                          segmentCount: coordinator.segments.count)
```

The compiler finds any site you miss — that is why the signature changed rather than gaining defaults.

- [ ] **Step 7: Build to verify both HUDs compile**

Dispatch the builder subagent: build the `Aura` scheme, Debug, iPhone 17 simulator, `CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Lint and commit**

```bash
scripts/lint.sh
git add AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift AuraCore/Tests/AuraKitTests/RideTestProbeTests.swift Aura/Sources/Ride/
git commit -m "feat(roh-103): carry speed and segment count on the HUD probe"
```

---

### Task 4: Identifiers and screen accessors for the paused surfaces

Spec D3 and D5 assert two summary cells and three ride-screen elements that no screen object reaches today.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift:6-19`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:213-222`
- Modify: `Aura/UITests/Screens/Screens.swift:64-96`

**Interfaces:**
- Consumes: `RideTestID.hudPause`, `RideTestID.hudPausedBanner` (both already exist).
- Produces: `RideTestID.summaryMoving`, `RideTestID.summaryTopSpeed`; `RideScreen.pauseControl`, `.pausedBanner`, `.speedValue`, `.waitForElapsedToAdvance(from:timeout:)`; `SummaryScreen.movingStat`, `.topSpeedStat`; `HistoryScreen.firstRow`.

- [ ] **Step 1: Add the identifiers**

In `AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift`, inside `RideTestID`, under `summaryDistance`:

```swift
    /// The summary's moving-time and top-speed cells. ROH-103 asserts both: moving time
    /// discriminates a segmented save (≈4 min) from a flattened one (≈14 min), and top
    /// speed guards the phantom resume spike (parent spec D6).
    public static let summaryMoving = "summary.moving"
    public static let summaryTopSpeed = "summary.topSpeed"
```

- [ ] **Step 2: Apply them in the summary**

In `Aura/Sources/Ride/RideSummaryView.swift`, give `stat` an identifier parameter and pass one from each supporting cell. Replace lines 213-222:

```swift
    @ViewBuilder private var supportingCells: some View {
        stat(fmt.minutes(stats.movingTimeSeconds), "moving", id: RideTestID.summaryMoving)
        stat(fmt.speedValue(stats.maxSpeedMetersPerSecond, decimals: 1),
             metric ? "km/h top" : "mph top", id: RideTestID.summaryTopSpeed)
    }

    /// One value+label metric, left-aligned, combined into a single VoiceOver element.
    private func stat(_ value: String, _ label: String, id: String) -> some View {
        StatPair(value: value, label: label, context: .brand, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
    }
```

- [ ] **Step 3: Add the screen accessors**

In `Aura/UITests/Screens/Screens.swift`, extend `RideScreen` with:

```swift
    var pauseControl: XCUIElement { app.buttons[RideTestID.hudPause] }
    var pausedBanner: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.hudPausedBanner).firstMatch
    }
    /// The cockpit's hero speed readout. `InstrumentChassis` composes it into one element
    /// labelled "Speed" whose value is the spoken speed, e.g. "0 miles per hour" — so a
    /// paused reading is a `"0 "` prefix in either unit system.
    var speedValue: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Speed")).firstMatch
    }

    /// Polls until the probe's elapsed reading exceeds `seconds` (or fails at `timeout`).
    /// Real sleep between polls, same rationale as `waitForDistance`.
    func waitForElapsedToAdvance(beyond seconds: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let values = probeValues(), values.elapsed > seconds { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }
```

and extend `SummaryScreen` with:

```swift
    var movingStat: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.summaryMoving).firstMatch
    }
    var topSpeedStat: XCUIElement {
        app.descendants(matching: .any).matching(identifier: RideTestID.summaryTopSpeed).firstMatch
    }
```

and extend `HistoryScreen` with:

```swift
    var firstRow: XCUIElement { rideRows.firstMatch }
```

- [ ] **Step 4: Build for testing to verify both targets compile**

Dispatch the builder subagent: `build-for-testing`, `Aura` scheme, Debug, iPhone 17 simulator, `CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED (the UI-test target compiles against the new `RideTestID` members).

- [ ] **Step 5: Lint and commit**

```bash
scripts/lint.sh
git add AuraCore/Sources/AuraKit/Testing/RideTestSupport.swift Aura/Sources/Ride/RideSummaryView.swift Aura/UITests/Screens/Screens.swift
git commit -m "feat(roh-103): identifiers and screen accessors for the paused surfaces"
```

---

### Task 5: The harness stops scheduling pause nudges

Spec D7. `PauseNudgeScheduler`'s comment says the nudges are safe to leave wired because "the harness never pauses". Tasks 6 and 7 make it pause, so five `UNTimeIntervalNotificationTrigger` requests get added on every run and outlive a run that aborts between pause and resume.

**Files:**
- Modify: `Aura/Sources/Notifications/PauseNudgeScheduler.swift:29-35` (the comment) and `:49` (the guard)

- [ ] **Step 1: Correct the comment**

In `Aura/Sources/Notifications/PauseNudgeScheduler.swift`, replace the final sentence of `prepareAuthorization`'s doc comment — "The pause nudges themselves are left wired: the harness never pauses, and adding requests prompts nobody." — with:

```
/// `scheduleForgottenPauseNudges` is skipped for the same reason. Until ROH-103 the harness
/// never paused, so leaving the nudges wired was harmless; the E2E now pauses four times a
/// run, and a run that aborts mid-pause would leave its requests alive in that simulator to
/// fire ten to a hundred and twenty minutes later, over whatever is running then.
```

- [ ] **Step 2: Skip scheduling under the harness**

At the top of `scheduleForgottenPauseNudges(startingAt:)`, before `cancelForgottenPauseNudges()`:

```swift
        #if DEBUG
        if SimulatedRideConfig.current != nil { return }
        #endif
```

- [ ] **Step 3: Build**

Dispatch the builder subagent: build the `Aura` scheme, Debug, iPhone 17 simulator, `CODE_SIGNING_ALLOWED=NO`.
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Lint and commit**

```bash
scripts/lint.sh
git add Aura/Sources/Notifications/PauseNudgeScheduler.swift
git commit -m "fix(roh-103): stop scheduling pause nudges under the golden-ride harness"
```

---

### Task 6: The free-ride paused E2E

Spec D5. Two pauses: one inside the fixture's replay silence carrying only taps, one after playback where the clock assertions are free. Ends from the paused state, then reads the ride back from History.

**Files:**
- Modify: `Aura/UITests/RideE2EUITests.swift` (add one method and one band helper)

**Interfaces:**
- Consumes: everything produced by Tasks 1-4.

- [ ] **Step 1: Write the failing test**

Add to `Aura/UITests/RideE2EUITests.swift`, after `testNavigateGoldenRideEndsToSummaryAndHistory`:

```swift
    /// ROH-103: the paused golden ride. Pauses at the fixture's own segment boundary, inside
    /// the 600 s stop that replays as ~20 s of dead air, so the ride records as two segments
    /// and the chord across the stop is never drawn.
    ///
    /// What a green run does NOT prove: active time on any post-ride surface (it does not
    /// exist yet — ROH-112); `pausedSeconds` surviving persistence; the rendered map gap
    /// (ROH-143); drift gating during a stop, since this fixture's stop has no fixes in it;
    /// the nudge ladder; or haptics.
    @MainActor
    func testPausedGoldenRideSegmentsAndSummary() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "paused",
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

        // --- Pause A: inside the replay silence, taps only. ------------------------------
        // Segment 1 is exactly `expectedSegmentDistanceMeters[0]`, every fixture point is
        // accepted unconditionally, and the next increment is +507 m thirty seconds later —
        // so this floor is reachable only at the last point of segment 1.
        let boundary = Int(PausedGoldenRideFixture.expectedSegmentDistanceMeters[0])
        XCTAssertTrue(ride.waitForDistance(atLeast: boundary, timeout: 90),
                      "never reached the segment boundary — last probe: \(ride.probe.label)")

        // Positive control: `s == 0` while paused proves nothing if speed is always 0.
        let ridingSpeed = try XCTUnwrap(ride.probeValues()?.speedDecimetersPerSecond)
        XCTAssertGreaterThan(ridingSpeed, 0, "speed already zero before the pause")

        ride.pauseControl.tap()
        XCTAssertTrue(ride.pausedBanner.waitForExistence(timeout: 5),
                      "PAUSED chip never appeared — the control is not wired")

        // `record()` is a no-op while paused, so segment 1 is final. Equality catches a tap
        // that landed early (reads low) and one that landed late (reads ~1449 — the chord).
        XCTAssertEqual(try XCTUnwrap(ride.probeValues()).distanceMeters, boundary,
                       "distance at the pause is not segment 1")

        ride.pauseControl.tap()
        XCTAssertFalse(ride.pausedBanner.waitForExistence(timeout: 3),
                       "PAUSED chip survived the resume")

        // --- Segment 2 records out. -----------------------------------------------------
        let total = Int(PausedGoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: total - 30, timeout: 90),
                      "segment 2 never completed — last probe: \(ride.probe.label)")

        let afterRide = try XCTUnwrap(ride.probeValues())
        XCTAssertEqual(afterRide.segmentCount, 2, "resume did not open a second segment")
        // Holds the segmented literal (1883 m), excludes the flattened one (2391 m).
        XCTAssertTrue((total - 30...total + 200).contains(afterRide.distanceMeters),
                      "distance \(afterRide.distanceMeters) m is not the segmented total")
        // Segmented gain is 58 m, flattened 100 m, and the climb is +2 m per point inside
        // segment 1 — so this band also catches a tap one point early.
        XCTAssertTrue((55...70).contains(afterRide.elevationGainMeters),
                      "elevation gain \(afterRide.elevationGainMeters) m is not segmented")

        // --- Pause B: after playback, where the window costs nothing. --------------------
        ride.pauseControl.tap()
        XCTAssertTrue(ride.pausedBanner.waitForExistence(timeout: 5), "second pause did not take")

        let frozenAt = try XCTUnwrap(ride.probeValues()).elapsed
        XCTAssertEqual(try XCTUnwrap(ride.probeValues()).speedDecimetersPerSecond, 0,
                       "speed hero did not fall to zero on pause")
        // The rendered readout, not just the probe — this is what the rider sees.
        XCTAssertTrue(try XCTUnwrap(ride.speedValue.value as? String).hasPrefix("0 "),
                      "speed readout reads \(ride.speedValue.value ?? "nil") while paused")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(try XCTUnwrap(ride.probeValues()).elapsed, frozenAt,
                       "the active clock kept running while paused")

        ride.pauseControl.tap()
        XCTAssertTrue(ride.waitForElapsedToAdvance(beyond: frozenAt, timeout: 10),
                      "the clock did not restart on resume")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ride.probeValues()).elapsed, frozenAt,
                                    "the clock went backwards across the pause")

        // --- End from the paused state (parent spec D6's first table row). ---------------
        ride.pauseControl.tap()
        XCTAssertTrue(ride.pausedBanner.waitForExistence(timeout: 5), "third pause did not take")
        ride.backButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10),
                      "End did nothing while paused — the ride would have been discarded")
        ride.endAlert.buttons["End ride"].tap()

        // --- Summary. -------------------------------------------------------------------
        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")
        try Self.assertPausedHeroDistanceInBand(summary)
        try Self.assertMovingTimeIsSegmented(summary)
        // Resume position-deltas across a 507 m gap; a spike here is parent D6's phantom.
        let top = try XCTUnwrap(Self.leadingNumber(in: summary.topSpeedStat.label))
        XCTAssertTrue(top < 60, "top speed \(top) — phantom spike across the resume")

        // --- History: one row, not marked unfinished, and it reads back segmented. -------
        summary.doneButton.tap()
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Done did not return Home")
        home.goToHistory()
        let history = HistoryScreen(app: app)
        XCTAssertTrue(history.title.waitForExistence(timeout: 10))
        XCTAssertTrue(history.firstRow.waitForExistence(timeout: 10),
                      "finished ride missing from History")
        // The pause-boundary flush upserts on ride.id — a pause must not duplicate the ride.
        XCTAssertEqual(history.rideRows.count, 1)
        XCTAssertFalse(history.firstRow.label.contains(UnfinishedRideCopy.label),
                       "a paused ride is marked unfinished: \(history.firstRow.label)")

        // Tapping re-reads through `store.ride(id:)`, so these bands are the PERSISTED ride
        // decoded from segmentsData — the only step that proves the save kept its segments.
        history.firstRow.tap()
        XCTAssertTrue(summary.title.waitForExistence(timeout: 10),
                      "History detail never appeared")
        try Self.assertPausedHeroDistanceInBand(summary)
        try Self.assertMovingTimeIsSegmented(summary)
    }

    /// The paused fixture's own hero band: 1883 m is 1.2 mi / 1.9 km. It must EXCLUDE the
    /// flattened reading (1.5 mi / 2.4 km), not merely contain the segmented one.
    @MainActor
    private static func assertPausedHeroDistanceInBand(_ summary: SummaryScreen,
                                                       file: StaticString = #filePath,
                                                       line: UInt = #line) throws {
        XCTAssertTrue(summary.heroDistance.waitForExistence(timeout: 5), "hero distance missing",
                      file: file, line: line)
        let label = summary.heroDistance.label
        let value = try XCTUnwrap(leadingNumber(in: label),
                                  "no number in hero label: \(label)", file: file, line: line)
        if label.contains("kilometer") {
            XCTAssertTrue((1.7...2.1).contains(value), "km out of band: \(label)",
                          file: file, line: line)
        } else {
            XCTAssertTrue((1.05...1.35).contains(value), "miles out of band: \(label)",
                          file: file, line: line)
        }
    }

    /// Segmented moving time is 290 s → "4 min"; flattened is 890 s → "14 min". The band is
    /// wide enough to absorb a boundary point and nowhere near the flattened reading. This is
    /// the only assertion here that is fully independent of when the tap landed, because
    /// movingTimeSeconds comes from the fixture's own stamps rather than wall clock.
    @MainActor
    private static func assertMovingTimeIsSegmented(_ summary: SummaryScreen,
                                                    file: StaticString = #filePath,
                                                    line: UInt = #line) throws {
        XCTAssertTrue(summary.movingStat.waitForExistence(timeout: 5), "moving cell missing",
                      file: file, line: line)
        let label = summary.movingStat.label
        let value = try XCTUnwrap(leadingNumber(in: label),
                                  "no number in moving label: \(label)", file: file, line: line)
        XCTAssertTrue((3.0...6.0).contains(value),
                      "moving time \(label) — a flattened ride reads ~14 min",
                      file: file, line: line)
    }
```

`leadingNumber(in:)` is `private static` on this class already; leave it as is.

- [ ] **Step 2: Run it to verify it fails for the right reason**

Dispatch the builder subagent: run `-only-testing:AuraUITests/RideE2EUITests/testPausedGoldenRideSegmentsAndSummary` on an iPhone 17 simulator.

Expected on a clean tree before Tasks 1-4 land: a compile failure. With them landed, it should PASS. If it fails, read the failure message before changing anything — the assertions are written to name their own cause (`distance at the pause is not segment 1`, `the active clock kept running while paused`).

- [ ] **Step 3: Run the two shipped golden rides to confirm no regression**

Dispatch the builder subagent: run `-only-testing:AuraUITests/RideE2EUITests` (the whole class).
Expected: three tests, all PASS.

- [ ] **Step 4: Lint and commit**

```bash
scripts/lint.sh
git add Aura/UITests/RideE2EUITests.swift
git commit -m "test(roh-103): drive the pause control through the paused golden fixture"
```

---

### Task 7: The navigate pause control, and the CI budget comment

Spec D6 and D8. `togglePause()` has a second implementation in `NavigateHUDView+Cockpit.swift:129`, feeding a different instrument panel, and ROH-101 handed its coverage here. This test needs no replay silence, so it rides the ordinary golden fixture.

**Files:**
- Modify: `Aura/UITests/RideE2EUITests.swift` (add one method)
- Modify: `.github/workflows/ci.yml:56` (the budget comment)

- [ ] **Step 1: Write the failing test**

Add to `Aura/UITests/RideE2EUITests.swift`:

```swift
    /// ROH-103: the navigate cockpit's pause control. `togglePause()` is implemented twice —
    /// here and in RideHUDView — and `isPaused` feeds a different instrument panel on this
    /// path, which has already drawn over the pause row once on an iPhone SE. The ordinary
    /// golden fixture, because nothing here needs the paused fixture's replay silence.
    @MainActor
    func testNavigatePauseControlEndsWhilePaused() throws {
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

        let preview = PreviewScreen(app: app)
        XCTAssertTrue(preview.waitForStartEnabled(timeout: 15),
                      "Start RIDE never enabled — fixture route did not load/select")
        preview.startRide.tap()

        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15),
                      "HUD probe missing — simulated-ride hook did not engage in navigate")
        // Far enough in to be recording, and well short of the fixture's end.
        XCTAssertTrue(ride.waitForDistance(atLeast: 300, timeout: 60),
                      "navigate ride never recorded — last probe: \(ride.probe.label)")

        ride.pauseControl.tap()
        XCTAssertTrue(ride.pausedBanner.waitForExistence(timeout: 5),
                      "PAUSED chip never appeared — the navigate control is not wired")
        XCTAssertEqual(try XCTUnwrap(ride.probeValues()).speedDecimetersPerSecond, 0,
                       "speed hero did not fall to zero on the navigate path")
        XCTAssertTrue(try XCTUnwrap(ride.speedValue.value as? String).hasPrefix("0 "),
                      "navigate speed readout reads \(ride.speedValue.value ?? "nil") while paused")

        // End from the paused state, via the navigate control cluster.
        ride.endButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10),
                      "End did nothing while paused on the navigate path")
        ride.endAlert.buttons["End ride"].tap()

        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15),
                      "Summary never appeared after ending a paused navigate ride")
    }
```

- [ ] **Step 2: Run it**

Dispatch the builder subagent: run `-only-testing:AuraUITests/RideE2EUITests/testNavigatePauseControlEndsWhilePaused`.
Expected: PASS. A failure at the PAUSED chip means the navigate pause row is occluded or unwired — that is the bug this test exists for, so investigate rather than loosening the assertion.

- [ ] **Step 3: Update the CI budget comment**

In `.github/workflows/ci.yml`, line 56 reads:

```
# 50: cold SPM + Mapbox build + boot + TWO golden-ride methods, each retried once
# worst-case (ROH-93 added the navigate method).
```

Replace with:

```
# 50: cold SPM + Mapbox build + boot + FOUR golden-ride methods, each retried once
# worst-case (ROH-93 added the navigate method; ROH-103 added the paused ride and the
# navigate pause control). The paused method is the longest at ~30 s of replay. Note the
# retry flag means a first-run flake still reports green — see the ROH-103 spec, D8.
```

- [ ] **Step 4: Run the whole class**

Dispatch the builder subagent: run `-only-testing:AuraUITests/RideE2EUITests`.
Expected: four tests, all PASS.

- [ ] **Step 5: Run the full package suite**

Run: `cd AuraCore && swift test`
Expected: PASS. Read BOTH printed totals.

- [ ] **Step 6: Lint and commit**

```bash
scripts/lint.sh
git add Aura/UITests/RideE2EUITests.swift .github/workflows/ci.yml
git commit -m "test(roh-103): cover the navigate pause control, refresh the CI budget note"
```

---

## Self-review notes

Spec coverage: D1 → Task 1. D2 → Task 3. D3 → Tasks 4 and 6. D4 → Tasks 2 and 6. D5 → Task 6. D6 → Task 7. D7 → Task 5. D8 → Task 7.

Type consistency: `SimulatedRideFixture.provider(named:multiplier:)` is called with the same labels in Task 1 Step 6. `RideTestProbe.line` takes `speedMetersPerSecond` (a `Double`) and stores `speedDecimetersPerSecond` (an `Int?`) — the conversion happens once, inside `line`. `simulatedRideProbe` gains `speedMetersPerSecond` and `segmentCount` at both call sites.

Known follow-ups deliberately not in this plan: ROH-112 (active time on post-ride surfaces, now blocking ROH-74), ROH-143 (the rendered map gap, on device).
