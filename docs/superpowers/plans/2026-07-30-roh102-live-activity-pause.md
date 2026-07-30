# ROH-102 Pass 5 — Live Activity pause: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The in-progress-ride Live Activity reports active time, reads as paused on every presentation in both modes, and stops claiming to be paused once the app is dead.

**Architecture:** The clock becomes a two-case `RideActiveClock` value carried in one optional `ContentState` field. A pure `RideActivityPayload` mirror and a pure `RideActivityPushPolicy` move to AuraCore so the dedupe, its equality, and the heartbeat are host-tested — `ContentState` itself lives in an app-target file that no test target on any platform can see. `RideLiveActivityController` becomes a mapper over that policy with serialized pushes.

**Tech Stack:** Swift 6, SwiftUI, ActivityKit, WidgetKit, Swift Testing (`@Suite`/`@Test`/`#expect`) throughout, SwiftLint.

**Spec:** [2026-07-30-roh102-live-activity-pause-design.md](../specs/2026-07-30-roh102-live-activity-pause-design.md). Every decision reference below (D1–D10) is to that document.

## Global Constraints

- The AuraCore package builds on the **macOS CI host**. Anything iOS-only is `#if os(iOS)`-guarded. AuraKit never imports ActivityKit (`RideSessionSeams.swift:12-13`) — that rule is why this plan exists in its current shape.
- **No async default-argument closures anywhere.** They produce linkonce copies that disagree on frame size and abort the task allocator; SwiftLint has a guard rule. Pass closures explicitly.
- Run `swiftlint` **from the repo root**, not from a subdirectory.
- `swift test` prints **two** totals (XCTest and Swift Testing). Both must be clean; baseline before this plan is 223 XCTest / 780 Swift Testing, 0 failures.
- **Every** test target here uses Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`) — AuraCoreTests and AuraKitTests alike. There is no XCTest in the new code. `RideSessionCoordinatorTests` is `@MainActor @Suite(.swiftDataSerialized) struct`; keep that trait, it is the SwiftData flake gate (ROH-65).
- Real call shapes, verified against the files — do not invent variants:
  - `RideRecorder()` takes **no** arguments (`RideRecorderPauseTests.swift:23`).
  - `makeCoordinator(kind:destinationName:screen:activity:)` — `screen:` and `activity:` are both required, and there is no `saving:` parameter.
  - Saving is injected at start: `c.start(location: ScriptedLocationProvider([...]), saving: store, units: .metric, authorization: .authorized)`.
  - `RideStore.inMemory()` throws; `ThrowingRideSaving` is the failure double.
- Delegate any Xcode app/widget build to the `apple-platform-build-tools:builder` subagent. The package suite (`swift test` in `AuraCore/`) runs directly.
- Copy is fixed by the spec and must match exactly: `PAUSED`, and `PAUSED · NOT UPDATING` when also stale (D6). The separator is U+00B7 MIDDLE DOT, matching nothing else in the repo — type it, do not substitute `-`.
- The widget target sees both AuraCore and AuraKit (`Aura/project.yml:106-110`), so `RideActiveClock` and `PauseControlCopy` are both reachable from widget code.

## File Structure

**Create:**
- `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift` — the two-case clock and its pure constructor. One responsibility: what the clock displays.
- `AuraCore/Sources/AuraCore/Ride/RideActivityPayload.swift` — the pure mirror of everything pushed to the activity, plus the paused turn-hold helper.
- `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift` — push/skip/staleDate. One responsibility: when to push.
- `AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift`
- `AuraCore/Tests/AuraCoreTests/RideActivityPayloadTests.swift`
- `AuraCore/Tests/AuraCoreTests/RideActivityPushPolicyTests.swift`

**Modify:**
- `AuraCore/Sources/AuraKit/RideRecorder.swift` — expose `pausedSince`.
- `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift:15-19` — seam gains `activeClock:`.
- `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` — build the clock, push on both transitions before the checkpoint flush.
- `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift:238-259` — spy records the clock.
- `Aura/Sources/LiveActivity/RideActivityAttributes.swift` — `ContentState` gains `clock`, an `init(payload:)`, and the Optional-forever rule.
- `Aura/Sources/LiveActivity/RideLiveActivityController.swift` — payload dedupe, serialized pushes, heartbeat, guard order.
- `Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift` — conformer signature.
- `Aura/Widgets/RideActivityComponents.swift` — `RideTimerStatCell` takes a clock; `RideStatusPill` composes paused and stale; imminent suppression.
- `Aura/Widgets/RideLiveActivity.swift` — three clock sites, glyph swaps, labels.
- `Aura/Widgets/RideLockScreenView.swift` — two clock sites, header glyph, VoiceOver labels.

---

### Task 1: `RideActiveClock` and its clamped constructor

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `RideActiveClock` (`Codable, Hashable, Sendable`) with cases `.running(anchor: Date)` and `.paused(since: Date, activeSeconds: TimeInterval)`; `var isPaused: Bool`; `static func make(startedAt: Date, pausedSeconds: TimeInterval, pausedSince: Date?, now: Date) -> RideActiveClock`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("Ride active clock")
struct RideActiveClockTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A ride with no pauses anchors at its start")
    func runningWithNoPauses() {
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 0,
                                         pausedSince: nil, now: start.addingTimeInterval(600))
        #expect(clock == .running(anchor: start))
        #expect(clock.isPaused == false)
    }

    @Test("After a stop the anchor shifts forward by exactly the paused seconds")
    func runningAfterOnePause() {
        // 10 min ride, 4 of them stopped: active time is 6 min, so the anchor sits 4 min in.
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 240,
                                         pausedSince: nil, now: start.addingTimeInterval(600))
        #expect(clock == .running(anchor: start.addingTimeInterval(240)))
    }

    @Test("The anchor is never in the future, so the OS timer cannot count down")
    func anchorClampedToNow() {
        // A backward wall-clock step (NTP correction) makes startedAt + paused exceed now.
        let now = start.addingTimeInterval(100)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 500,
                                         pausedSince: nil, now: now)
        #expect(clock == .running(anchor: now))
    }

    @Test("A stop carries its own instant and the active time frozen at that instant")
    func pausedCarriesStopInstantAndFrozenActive() {
        let stoppedAt = start.addingTimeInterval(600)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 60,
                                         pausedSince: stoppedAt,
                                         now: stoppedAt.addingTimeInterval(90))
        #expect(clock == .paused(since: stoppedAt, activeSeconds: 540))
        #expect(clock.isPaused)
    }

    @Test("The paused value is identical across a span of ticks")
    func pausedIsStableAcrossTicks() {
        // The trap that killed revision 1: pausedSeconds(asOf:) grows every tick while a stop
        // is open, so anything carrying it changes every tick and defeats the dedupe entirely.
        let stoppedAt = start.addingTimeInterval(600)
        let ticks = (0..<200).map { i -> RideActiveClock in
            let now = stoppedAt.addingTimeInterval(Double(i) * 0.5)
            // pausedSeconds grows in lockstep with now, exactly as the recorder reports it.
            return .make(startedAt: start, pausedSeconds: 60 + Double(i) * 0.5,
                         pausedSince: stoppedAt, now: now)
        }
        #expect(Set(ticks).count == 1)
    }

    @Test("Frozen active seconds never go negative")
    func frozenActiveClampedAtZero() {
        let stoppedAt = start.addingTimeInterval(10)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 999,
                                         pausedSince: stoppedAt, now: stoppedAt)
        #expect(clock == .paused(since: stoppedAt, activeSeconds: 0))
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        let cases: [RideActiveClock] = [
            .running(anchor: start),
            .paused(since: start, activeSeconds: 540)
        ]
        for clock in cases {
            let data = try JSONEncoder().encode(clock)
            #expect(try JSONDecoder().decode(RideActiveClock.self, from: data) == clock)
        }
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd AuraCore && swift test --filter RideActiveClockTests`
Expected: FAIL — `cannot find 'RideActiveClock' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`:

```swift
import Foundation

/// What the Live Activity's clock should display, as a value the widget renders without
/// arithmetic. Two cases, because the paused clock answers a different question than the
/// running one (spec D1).
///
/// **Neither case carries a value that moves while the ride is paused.** That is the whole
/// point of the shape: `RideRecorder.pausedSeconds(asOf:)` grows on every tick of a stop, so a
/// clock that stored it would be a distinct value every tick, and the controller's dedupe —
/// which exists precisely for a long stop — could never fire (spec D3).
public enum RideActiveClock: Codable, Hashable, Sendable {
    /// Active time is `now - anchor`, rendered by the OS via `Text(anchor, style: .timer)` with
    /// no per-second pushes. `anchor` is `startedAt + pausedSeconds`, never in the future.
    case running(anchor: Date)
    /// `since` is the instant this stop began — the widget counts *up* from it, so the paused
    /// clock keeps moving and answers "how long have I been stopped". `activeSeconds` is the
    /// ride's active time frozen at that instant, carried for the ride's end and not rendered.
    case paused(since: Date, activeSeconds: TimeInterval)

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// Build the clock from the three numbers the recorder holds.
    ///
    /// `pausedSince` is non-nil exactly while a stop is open, so it — not a separate flag —
    /// selects the case.
    public static func make(startedAt: Date,
                            pausedSeconds: TimeInterval,
                            pausedSince: Date?,
                            now: Date) -> RideActiveClock {
        let activeSeconds = max(0, now.timeIntervalSince(startedAt) - pausedSeconds)
        if let pausedSince {
            return .paused(since: pausedSince, activeSeconds: activeSeconds)
        }
        // Clamped to `now`: a backward wall-clock step can push `startedAt + pausedSeconds` past
        // it, and `Text(_, style: .timer)` with a future anchor counts DOWN. The in-app clock
        // clamps for the same reason (`RideSessionCoordinator.refreshElapsed`); the residual
        // wall-clock weakness is ROH-130.
        return .running(anchor: min(startedAt.addingTimeInterval(pausedSeconds), now))
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd AuraCore && swift test --filter RideActiveClockTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift
git commit -m "feat(roh-102): RideActiveClock with a clamped anchor and a stable paused case"
```

---

### Task 2: `RideActivityPayload`, the pure mirror

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideActivityPayload.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideActivityPayloadTests.swift`

**Interfaces:**
- Consumes: `RideActiveClock` from Task 1.
- Produces: `RideActivityPayload` (`Codable, Hashable, Sendable`) with `distanceMeters: Double`, `speedMetersPerSecond: Double`, `elevationGainMeters: Double`, `turnInstruction: String?`, `turnDistanceMeters: Double?`, `turnGlyphSystemName: String?`, `clock: RideActiveClock`; a memberwise `init` with defaults for every field except `clock`; and `func holdingTurn(from previous: RideActivityPayload?) -> RideActivityPayload`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/RideActivityPayloadTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("Ride activity payload")
struct RideActivityPayloadTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func running(distance: Double) -> RideActivityPayload {
        RideActivityPayload(distanceMeters: distance, clock: .running(anchor: start))
    }

    @Test("Two payloads with the same values are equal, so the dedupe can key on them")
    func equalityIsByValue() {
        #expect(running(distance: 100) == running(distance: 100))
        #expect(running(distance: 100) != running(distance: 101))
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        let payload = RideActivityPayload(
            distanceMeters: 1234.5, speedMetersPerSecond: 6.1, elevationGainMeters: 42,
            turnInstruction: "Right onto Penn Ave", turnDistanceMeters: 120,
            turnGlyphSystemName: "arrow.turn.up.right",
            clock: .paused(since: start, activeSeconds: 600))
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(RideActivityPayload.self, from: data) == payload)
    }

    @Test("A paused payload holds the turn it had before the stop")
    func pausedHoldsPreviousTurn() {
        // GuidanceViewModel keeps updating lastUpdate while paused, so a stationary rider's
        // distance-to-turn drifts with GPS jitter. Left alone it ticks beside a frozen clock
        // and defeats the dedupe on every navigate pause (spec D7).
        let before = RideActivityPayload(turnInstruction: "Right onto Penn Ave",
                                         turnDistanceMeters: 120,
                                         turnGlyphSystemName: "arrow.turn.up.right",
                                         clock: .running(anchor: start))
        let drifted = RideActivityPayload(turnInstruction: "Right onto Penn Ave",
                                          turnDistanceMeters: 117,
                                          turnGlyphSystemName: "arrow.turn.up.right",
                                          clock: .paused(since: start, activeSeconds: 600))
        let held = drifted.holdingTurn(from: before)
        #expect(held.turnDistanceMeters == 120)
        #expect(held.turnInstruction == "Right onto Penn Ave")
        #expect(held.clock == drifted.clock)
    }

    @Test("Holding is stable, so successive paused ticks stay equal")
    func holdingIsStableAcrossTicks() {
        let before = RideActivityPayload(turnDistanceMeters: 120, clock: .running(anchor: start))
        var previous = before
        var held: [RideActivityPayload] = []
        for drift in [117.0, 114.0, 119.0] {
            let tick = RideActivityPayload(turnDistanceMeters: drift,
                                           clock: .paused(since: start, activeSeconds: 600))
                .holdingTurn(from: previous)
            held.append(tick)
            previous = tick
        }
        #expect(Set(held).count == 1)
    }

    @Test("A running payload keeps its own turn")
    func runningKeepsItsOwnTurn() {
        let before = RideActivityPayload(turnDistanceMeters: 120, clock: .running(anchor: start))
        let next = RideActivityPayload(turnDistanceMeters: 90, clock: .running(anchor: start))
        #expect(next.holdingTurn(from: before).turnDistanceMeters == 90)
    }

    @Test("A pause with no previous payload holds nothing")
    func pausedWithNoPreviousIsUnchanged() {
        let paused = RideActivityPayload(turnDistanceMeters: 90,
                                         clock: .paused(since: start, activeSeconds: 600))
        #expect(paused.holdingTurn(from: nil) == paused)
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd AuraCore && swift test --filter RideActivityPayloadTests`
Expected: FAIL — `cannot find 'RideActivityPayload' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideActivityPayload.swift`:

```swift
import Foundation

/// Every live value the in-progress-ride Live Activity displays, as a pure value.
///
/// This mirrors the app target's `RideActivityAttributes.ContentState`, which is declared inside
/// an `ActivityAttributes` conformer and therefore invisible to every test target this repo has
/// (spec D2). `ContentState` is derived solely from a payload, so payload equality implies
/// content equality — which is what lets the controller's dedupe be host-tested here rather than
/// shipped untested there.
public struct RideActivityPayload: Codable, Hashable, Sendable {
    public var distanceMeters: Double
    public var speedMetersPerSecond: Double
    public var elevationGainMeters: Double
    public var turnInstruction: String?
    public var turnDistanceMeters: Double?
    public var turnGlyphSystemName: String?
    public var clock: RideActiveClock

    public init(distanceMeters: Double = 0,
                speedMetersPerSecond: Double = 0,
                elevationGainMeters: Double = 0,
                turnInstruction: String? = nil,
                turnDistanceMeters: Double? = nil,
                turnGlyphSystemName: String? = nil,
                clock: RideActiveClock) {
        self.distanceMeters = distanceMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.elevationGainMeters = elevationGainMeters
        self.turnInstruction = turnInstruction
        self.turnDistanceMeters = turnDistanceMeters
        self.turnGlyphSystemName = turnGlyphSystemName
        self.clock = clock
    }

    /// While paused, carry the previous payload's maneuver rather than the live one.
    ///
    /// `GuidanceViewModel.applyProgress` updates `lastUpdate` before its `isPaused` guard, so a
    /// stationary rider's distance-to-maneuver still drifts with GPS jitter. Rendered, that is a
    /// ticking number beside a frozen clock and a PAUSED pill — two readings of the same surface
    /// disagreeing about whether the ride is moving. It would also make every paused navigate
    /// tick a distinct payload and defeat the dedupe.
    public func holdingTurn(from previous: RideActivityPayload?) -> RideActivityPayload {
        guard clock.isPaused, let previous else { return self }
        var held = self
        held.turnInstruction = previous.turnInstruction
        held.turnDistanceMeters = previous.turnDistanceMeters
        held.turnGlyphSystemName = previous.turnGlyphSystemName
        return held
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd AuraCore && swift test --filter RideActivityPayloadTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraCore/Ride/RideActivityPayload.swift AuraCore/Tests/AuraCoreTests/RideActivityPayloadTests.swift
git commit -m "feat(roh-102): pure RideActivityPayload mirror with a paused turn hold"
```

---

### Task 3: `RideActivityPushPolicy`

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideActivityPushPolicyTests.swift`

**Interfaces:**
- Consumes: `RideActivityPayload` (Task 2), `RideActiveClock` (Task 1).
- Produces: `RideActivityPushDecision` (`Hashable, Sendable`) with `.push(staleDate: Date)` and `.skip`; `enum RideActivityPushPolicy` with `static let coalesceInterval: TimeInterval = 4`, `static let heartbeatInterval: TimeInterval = 60`, `static let staleInterval: TimeInterval = 90`, and `static func decide(last: RideActivityPayload?, next: RideActivityPayload, lastPushedAt: Date?, now: Date) -> RideActivityPushDecision`.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/RideActivityPushPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import AuraCore

@Suite("Ride activity push policy")
struct RideActivityPushPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func payload(distance: Double = 0,
                         turn: String? = nil,
                         paused: Bool = false) -> RideActivityPayload {
        RideActivityPayload(
            distanceMeters: distance,
            turnInstruction: turn,
            clock: paused ? .paused(since: t0, activeSeconds: 600) : .running(anchor: t0))
    }

    private func isPush(_ decision: RideActivityPushDecision) -> Bool {
        if case .push = decision { return true }
        return false
    }

    @Test("The first push always goes")
    func firstPush() {
        let decision = RideActivityPushPolicy.decide(
            last: nil, next: payload(), lastPushedAt: nil, now: t0)
        #expect(decision == .push(staleDate: t0.addingTimeInterval(90)))
    }

    @Test("An unchanged payload inside the coalescing window is skipped")
    func unchangedIsSkipped() {
        let decision = RideActivityPushPolicy.decide(
            last: payload(), next: payload(),
            lastPushedAt: t0, now: t0.addingTimeInterval(2))
        #expect(decision == .skip)
    }

    @Test("An unchanged payload past the coalescing window is still skipped")
    func unchangedStaysSkippedPastCoalesce() {
        // This is the dedupe: 600 identical pushes across a 40-minute stop become the heartbeat.
        let decision = RideActivityPushPolicy.decide(
            last: payload(), next: payload(),
            lastPushedAt: t0, now: t0.addingTimeInterval(30))
        #expect(decision == .skip)
    }

    @Test("A changed payload is coalesced to the 4-second cadence")
    func changedIsCoalesced() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(distance: 1), next: payload(distance: 2),
            lastPushedAt: t0, now: t0.addingTimeInterval(2)) == .skip)
        #expect(isPush(RideActivityPushPolicy.decide(
            last: payload(distance: 1), next: payload(distance: 2),
            lastPushedAt: t0, now: t0.addingTimeInterval(4))))
    }

    @Test("A changed turn instruction bypasses the cadence")
    func turnChangeBypasses() {
        let decision = RideActivityPushPolicy.decide(
            last: payload(turn: "Left onto Liberty"), next: payload(turn: "Right onto Penn"),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5))
        #expect(isPush(decision))
    }

    @Test("A pause bypasses the cadence, so the tap reaches the Lock Screen in the same turn")
    func pauseTransitionBypasses() {
        // Revision 1's fatal defect: it put this bypass nowhere, so a tap landing inside the
        // 4-second window changed nothing at all.
        let decision = RideActivityPushPolicy.decide(
            last: payload(paused: false), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5))
        #expect(isPush(decision))
    }

    @Test("A resume bypasses the cadence too")
    func resumeTransitionBypasses() {
        let decision = RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: false),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5))
        #expect(isPush(decision))
    }

    @Test("The heartbeat fires on an unchanged paused payload")
    func heartbeatWhilePaused() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(59)) == .skip)
        #expect(isPush(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(60))))
    }

    @Test("The heartbeat is not gated on paused: a running ride with no new fixes stays fresh")
    func heartbeatWhileRunning() {
        // A garage start, a tunnel or a bad urban canyon yields no acceptable fixes, so the
        // payload is byte-identical for minutes. Gating the heartbeat on paused would let that
        // healthy ride go stale and tell the rider the app had died.
        let decision = RideActivityPushPolicy.decide(
            last: payload(paused: false), next: payload(paused: false),
            lastPushedAt: t0, now: t0.addingTimeInterval(60))
        #expect(isPush(decision))
    }

    @Test("The heartbeat beats the stale window, so an alive ride never dims in either state")
    func heartbeatOutrunsStaleWindow() {
        #expect(RideActivityPushPolicy.heartbeatInterval < RideActivityPushPolicy.staleInterval)
    }

    @Test("Every push carries a stale date 90 seconds out, in both states")
    func staleDateIsUniform() {
        let now = t0.addingTimeInterval(60)
        let expected = now.addingTimeInterval(90)
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: true),
            lastPushedAt: t0, now: now) == .push(staleDate: expected))
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: false), next: payload(paused: false),
            lastPushedAt: t0, now: now) == .push(staleDate: expected))
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd AuraCore && swift test --filter RideActivityPushPolicyTests`
Expected: FAIL — `cannot find 'RideActivityPushPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift`:

```swift
import Foundation

/// Whether to push the Live Activity, and how far ahead to mark the pushed content stale.
///
/// There is deliberately no "skip but advance the clock" case. The controller's throttle state
/// moves only inside the `.push` branch, so a skipped push cannot advance the clock the heartbeat
/// measures against — the defect that would otherwise make the heartbeat dead code (spec D4).
public enum RideActivityPushDecision: Hashable, Sendable {
    case push(staleDate: Date)
    case skip
}

/// When the in-progress-ride Live Activity should be pushed.
///
/// Pure and host-tested, because the controller that consumes it imports ActivityKit and cannot
/// be tested on any platform this repo runs tests on (spec D2).
public enum RideActivityPushPolicy {
    /// Smallest gap between pushes of changed stats. GPS samples and the half-second ticker
    /// arrive far faster than a glanceable surface needs.
    public static let coalesceInterval: TimeInterval = 4
    /// A push goes out at least this often even when nothing changed, so `staleDate` keeps
    /// advancing while the app is alive. Not gated on paused: a ride receiving no acceptable
    /// fixes is equally quiet and equally alive.
    public static let heartbeatInterval: TimeInterval = 60
    /// How far ahead pushed content is marked stale. Shorter than nothing and longer than the
    /// heartbeat, so an alive app never dims and a dead one confesses within the window.
    public static let staleInterval: TimeInterval = 90

    public static func decide(last: RideActivityPayload?,
                              next: RideActivityPayload,
                              lastPushedAt: Date?,
                              now: Date) -> RideActivityPushDecision {
        let push = RideActivityPushDecision.push(staleDate: now.addingTimeInterval(staleInterval))
        guard let last, let lastPushedAt else { return push }

        let sinceLastPush = now.timeIntervalSince(lastPushedAt)
        // A new maneuver and a pause/resume are both state the rider is waiting to see, so
        // neither waits on the coalescing cadence.
        if next.turnInstruction != last.turnInstruction { return push }
        if next.clock.isPaused != last.clock.isPaused { return push }
        if sinceLastPush >= heartbeatInterval { return push }
        if next != last && sinceLastPush >= coalesceInterval { return push }
        return .skip
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd AuraCore && swift test --filter RideActivityPushPolicyTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift AuraCore/Tests/AuraCoreTests/RideActivityPushPolicyTests.swift
git commit -m "feat(roh-102): pure push policy with an ungated heartbeat and transition bypass"
```

---

### Task 4: `RideRecorder.pausedSince`

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideRecorder.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideRecorderPauseTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `RideRecorder.pausedSince: Date?` — non-nil exactly while a stop is open.

- [ ] **Step 1: Write the failing test**

Append to `AuraCore/Tests/AuraKitTests/RideRecorderPauseTests.swift`, which already owns the pause state machine and has the `at(_:)` helper these use:

```swift
    @Test func pausedSinceIsNonNilExactlyWhileAStopIsOpen() {
        let r = RideRecorder()
        r.start(at: at(0))
        #expect(r.pausedSince == nil)

        r.pause(at: at(600))
        #expect(r.pausedSince == at(600))

        r.resume(at: at(840))
        #expect(r.pausedSince == nil)
    }

    @Test func pausedSinceKeepsTheFirstStopInstantWhenPauseIsCalledTwice() {
        // `pause(at:)` is idempotent and deliberately does not restamp; `pausedSince` must not
        // either, or the Lock Screen's counting-up stop timer would reset itself mid-stop.
        let r = RideRecorder()
        r.start(at: at(0))
        r.pause(at: at(600))
        r.pause(at: at(630))
        #expect(r.pausedSince == at(600))
    }
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd AuraCore && swift test --filter RideRecorderPauseTests`
Expected: FAIL — `value of type 'RideRecorder' has no member 'pausedSince'`.

- [ ] **Step 3: Write the implementation**

In `AuraCore/Sources/AuraKit/RideRecorder.swift`, find the private stored property `pauseStartedAt` and add a public read-only accessor beside `isPaused` (near line 24):

```swift
    /// The instant the stop in progress began, or nil when recording.
    ///
    /// Exposed for `RideActiveClock.paused(since:)`: the Live Activity counts *up* from this
    /// instant, which is what makes the paused Lock Screen answer "how long have I been stopped"
    /// with a number that keeps moving even when the app cannot push (spec D1).
    public var pausedSince: Date? { pauseStartedAt }
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd AuraCore && swift test --filter RideRecorderPauseTests`
Expected: PASS, including both new tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraKit/RideRecorder.swift AuraCore/Tests/AuraKitTests/RideRecorderTests.swift
git commit -m "feat(roh-102): expose the recorder's stop instant as pausedSince"
```

---

### Task 5: The seam carries the clock, and both transitions push

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift:15-19`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (`pushActivityUpdate` ~`:308`, `pause()` ~`:233-253`, `resume()` ~`:267-277`)
- Modify: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift:238-259`

**Interfaces:**
- Consumes: `RideActiveClock.make` (Task 1), `RideRecorder.pausedSince` (Task 4).
- Produces: `RideActivityControlling.update(stats:currentSpeedMetersPerSecond:maneuver:activeClock:)`; `SpyRideActivity.UpdateCall` gains `activeClock: RideActiveClock`; `RideSessionCoordinator.pushActivityUpdate(now:)` takes an injectable `now`.

- [ ] **Step 1: Write the failing tests**

Append to `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`, inside the existing `@MainActor @Suite(.swiftDataSerialized) struct`, using its `makeCoordinator(kind:destinationName:screen:activity:)` and `point(_:_:)` helpers:

```swift
    @Test func pausePushesTheActivityInTheSameTurnWithAPausedClock() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        let before = activity.updates.count

        c.pause()

        // pause() must push in the same turn as the tap, not wait on the 0.5 s ticker.
        #expect(activity.updates.count == before + 1)
        #expect(try #require(activity.updates.last).activeClock.isPaused)
        c.cancel()
    }

    @Test func resumePushesTheActivityInTheSameTurnWithARunningClock() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pause()
        let before = activity.updates.count

        c.resume()

        #expect(activity.updates.count == before + 1)
        #expect(try #require(activity.updates.last).activeClock.isPaused == false)
        c.cancel()
    }

    @Test func theResumedAnchorIsNeverEarlierThanTheAnchorBeforeTheStop() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.pushActivityUpdate()
        guard case .running(let firstAnchor) =
                try #require(activity.updates.last).activeClock else {
            Issue.record("expected a running clock before the stop")
            return
        }

        c.pause()
        c.resume()
        c.pushActivityUpdate()

        guard case .running(let resumedAnchor) =
                try #require(activity.updates.last).activeClock else {
            Issue.record("expected a running clock after the resume")
            return
        }
        // The anchor shifts forward by the paused seconds, never back.
        #expect(resumedAnchor >= firstAnchor)
        c.cancel()
    }

    @Test func thePausePushPrecedesTheCheckpointFlush() async throws {
        // flushCheckpoint is a full-track encode plus a mirrored write in this same turn, at the
        // exact instant a jetsam kill is most likely. If the kill lands during it, the activity
        // must already know about the stop.
        let order = CallOrder()
        let activity = SpyRideActivity(order: order)
        let saving = OrderRecordingRideSaving(order: order, inner: try RideStore.inMemory())
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        // Two points far enough apart to clear RideBackOutGate's discard floor, or the pause
        // flushes nothing and there is no ordering to assert.
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.45, 60)]),
                saving: saving, units: .metric, authorization: .authorized)
        await c.streamTask?.value

        c.pause()

        #expect(try #require(activity.lastUpdateSequence) < #require(saving.lastSaveSequence))
        c.cancel()
    }
```

Add the two ordering doubles beside the existing spies at the bottom of the file:

```swift
/// Shared monotonic counter, so a test can assert the relative order of two collaborators'
/// calls inside one synchronous turn.
@MainActor
final class CallOrder {
    private var next = 0
    func stamp() -> Int { defer { next += 1 }; return next }
}

/// Stamps its saves against a shared `CallOrder`, then delegates. Wraps rather than replaces
/// `RideStore`, so the checkpoint still really writes and the discard-floor gate still applies.
@MainActor
final class OrderRecordingRideSaving: RideSaving {
    private let order: CallOrder
    private let inner: any RideSaving
    private(set) var lastSaveSequence: Int?

    init(order: CallOrder, inner: any RideSaving) {
        self.order = order
        self.inner = inner
    }

    func save(_ ride: Ride) throws {
        lastSaveSequence = order.stamp()
        try inner.save(ride)
    }

    func discard(id: UUID) throws { try inner.discard(id: id) }
}
```

Extend the spy at `:238-259`. `order` is optional so the file's many existing `SpyRideActivity()` call sites keep compiling unchanged:

```swift
@MainActor
final class SpyRideActivity: RideActivityControlling {
    struct StartCall {
        let kind: Ride.Kind
        let units: DistanceUnits
        let destinationName: String?
    }
    struct UpdateCall {
        let stats: RideStats
        let currentSpeedMetersPerSecond: Double
        let maneuver: GuidanceUpdate?
        let activeClock: RideActiveClock
    }
    private let order: CallOrder?
    private(set) var started: StartCall?
    private(set) var updates: [UpdateCall] = []
    private(set) var lastUpdateSequence: Int?
    private(set) var ended = false

    init(order: CallOrder? = nil) { self.order = order }

    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?) {
        started = StartCall(kind: kind, units: units, destinationName: destinationName)
    }
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock) {
        updates.append(UpdateCall(stats: stats,
                                  currentSpeedMetersPerSecond: currentSpeedMetersPerSecond,
                                  maneuver: maneuver,
                                  activeClock: activeClock))
        lastUpdateSequence = order?.stamp()
    }
    func end() { ended = true }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: FAIL — the protocol has no `activeClock:` parameter, so the spy does not conform.

- [ ] **Step 3: Write the implementation**

In `RideSessionSeams.swift`, replace the `update` requirement:

```swift
    /// `activeClock` is what the widget's clock should display — active time while running, and
    /// the stop's own instant while paused. Built by the coordinator so the app target does no
    /// arithmetic and the widget none at all.
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock)
```

In `RideSessionCoordinator.swift`, replace `pushActivityUpdate()`:

```swift
    /// Pushes current stats, the maneuver and the clock to the Live Activity. Factored out so a
    /// test can call it directly instead of waiting on the 0.5 s ticker; `now` is injectable for
    /// the same reason. The controller decides whether the push actually goes out.
    func pushActivityUpdate(now: Date = Date()) {
        guard let startedAt else { return }
        activity.update(stats: recorder.stats,
                        currentSpeedMetersPerSecond: recorder.currentSpeedMetersPerSecond,
                        maneuver: maneuver,
                        activeClock: .make(startedAt: startedAt,
                                           pausedSeconds: recorder.pausedSeconds(asOf: now),
                                           pausedSince: recorder.pausedSince,
                                           now: now))
    }
```

In `pause()`, insert the push immediately after `refreshElapsed(now: now)` and **before** `screen.setKeepAwake(false)` / `flushCheckpoint(at: now)`:

```swift
        refreshElapsed(now: now)
        // Before flushCheckpoint, which is a full-track encode and a mirrored write in this same
        // turn (see its doc comment) at the instant a jetsam kill is most likely. The rider's
        // Lock Screen learns about the stop first.
        pushActivityUpdate(now: now)
```

In `resume()`, add the same call after `refreshElapsed(now: now)`:

```swift
        refreshElapsed(now: now)
        pushActivityUpdate(now: now)
```

- [ ] **Step 4: Run the whole package suite**

Run: `cd AuraCore && swift test`
Expected: PASS on both totals. Every existing `SpyRideActivity` assertion still compiles because the spy's stored `UpdateCall` only gained a field.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraKit AuraCore/Tests/AuraKitTests
git commit -m "feat(roh-102): carry the active clock across the seam and push on both transitions"
```

---

### Task 6: `ContentState` gains the clock

**Files:**
- Modify: `Aura/Sources/LiveActivity/RideActivityAttributes.swift`

**Interfaces:**
- Consumes: `RideActivityPayload` (Task 2), `RideActiveClock` (Task 1).
- Produces: `ContentState.clock: RideActiveClock?`; `ContentState.init(payload: RideActivityPayload)`; `ContentState.isPaused: Bool`; `func activeClock(startedAt: Date) -> RideActiveClock`.

There is no test target that can see this type (spec D2). Its correctness rests on being a total 1:1 projection with no logic, which is why the initializer below takes a payload and nothing else.

- [ ] **Step 1: Add the property, the projection and the rule**

In `Aura/Sources/LiveActivity/RideActivityAttributes.swift`, extend the doc comment on `ContentState` and add the field plus the two members. Keep every existing stored property and the existing memberwise `init` — the latter is still used by `ContentState()` at controller start.

```swift
    /// **Every field added here from now on must be `Optional` or defaulted.** `ContentState` is
    /// `Codable` and re-serialized on every update, so an activity in flight across an app update
    /// is decoded by the *new* binary from bytes the *old* one wrote. Swift's synthesized
    /// `init(from:)` uses `decodeIfPresent` for `Optional` stored properties, so a missing key
    /// yields nil; a non-Optional field would throw and the activity would be stuck on its last
    /// rendered content forever. There is no test target on any platform that can see this type,
    /// so this rule is the whole guarantee (ROH-102 spec D2).
    public struct ContentState: Codable, Hashable, Sendable {
        // ... existing properties unchanged ...

        /// What the clock displays. `nil` for an activity started before ROH-102 shipped; every
        /// read site falls back to `attributes.startedAt`, which is the pre-ROH-102 behavior.
        public var clock: RideActiveClock?

        // ... existing init unchanged, with `clock` added as a defaulted parameter ...

        /// The only initializer new code should use: `ContentState` is derived solely from a
        /// payload, so payload equality implies content equality — which is what lets the
        /// controller's dedupe be tested in AuraCore rather than shipped untested here.
        public init(payload: RideActivityPayload) {
            self.init(distanceMeters: payload.distanceMeters,
                      speedMetersPerSecond: payload.speedMetersPerSecond,
                      elevationGainMeters: payload.elevationGainMeters,
                      turnInstruction: payload.turnInstruction,
                      turnDistanceMeters: payload.turnDistanceMeters,
                      turnGlyphSystemName: payload.turnGlyphSystemName,
                      clock: payload.clock)
        }

        public var isPaused: Bool { clock?.isPaused ?? false }

        /// The clock to render, falling back to a wall-clock anchor for an activity that
        /// predates ROH-102.
        public func activeClock(startedAt: Date) -> RideActiveClock {
            clock ?? .running(anchor: startedAt)
        }
    }
```

Add `import AuraCore` at the top of the file if it is not already there, and fix the stale doc on `speedMetersPerSecond` at `:26` — it says "the ride's average" but the controller passes `currentSpeedMetersPerSecond` (`RideLiveActivityController.swift:71,85`):

```swift
        /// Current smoothed speed in meters per second — not the ride average.
```

- [ ] **Step 2: Build the app target**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds. The widget still reads `attributes.startedAt`; nothing consumes `clock` yet.

- [ ] **Step 3: Lint and commit**

```bash
swiftlint --quiet
git add Aura/Sources/LiveActivity/RideActivityAttributes.swift
git commit -m "feat(roh-102): ContentState carries the active clock as one optional field"
```

---

### Task 7: The controller becomes a mapper over the policy

**Files:**
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController.swift`
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift`

**Interfaces:**
- Consumes: `RideActivityPushPolicy.decide` (Task 3), `RideActivityPayload.holdingTurn` (Task 2), `ContentState.init(payload:)` (Task 6), the seam signature (Task 5).
- Produces: nothing further tasks consume.

- [ ] **Step 1: Replace the throttle state and `update`**

In `RideLiveActivityController.swift`, delete `minInterval`, `staleInterval`, `lastState`, `lastPush` and `lastInstruction`, and replace them with payload-keyed state plus a push chain:

```swift
    private var activity: Activity<RideActivityAttributes>?
    /// What the widget has, not what we intended to send — assigned only after an update
    /// returns. The dedupe gates on it, so a push that never landed must not be recorded as
    /// landed (spec D5).
    private var lastPayload: RideActivityPayload?
    private var lastPushedAt: Date?
    /// Serializes pushes. Two racing `Task`s could otherwise land out of order and leave the
    /// widget holding a running state while `lastPayload` says paused — after which the dedupe
    /// suppresses everything until the heartbeat a minute later.
    private var pushChain: Task<Void, Never>?
```

Replace `update` with:

```swift
    /// Pushes the latest ride stats, maneuver and clock. Whether the push actually goes out is
    /// `RideActivityPushPolicy`'s decision — pure, and host-tested in AuraCore, because this
    /// type imports ActivityKit and no test target can reach it.
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock) {
        guard let activity else { return }

        let now = Date()
        let payload = RideActivityPayload(
            distanceMeters: stats.distanceMeters,
            speedMetersPerSecond: currentSpeedMetersPerSecond,
            elevationGainMeters: stats.elevationGainMeters,
            turnInstruction: maneuver?.instruction,
            turnDistanceMeters: maneuver?.distanceToManeuverMeters,
            // Resolve the directional glyph app-side so the widget stays logic-free.
            turnGlyphSystemName: ManeuverIcon.symbol(for: maneuver?.maneuver),
            clock: activeClock
        ).holdingTurn(from: lastPayload)

        guard case .push(let staleDate) = RideActivityPushPolicy.decide(
            last: lastPayload, next: payload, lastPushedAt: lastPushedAt, now: now) else { return }

        enqueue(ActivityContent(state: ContentState(payload: payload), staleDate: staleDate),
                payload: payload, at: now, on: activity)
    }

    /// Chains onto the previous push so updates land in the order they were decided, and records
    /// the payload as delivered only once it has.
    private func enqueue(_ content: ActivityContent<RideActivityAttributes.ContentState>,
                         payload: RideActivityPayload,
                         at now: Date,
                         on activity: Activity<RideActivityAttributes>) {
        let previous = pushChain
        pushChain = Task { @MainActor [weak self] in
            await previous?.value
            await activity.update(content)
            guard let self, self.activity === activity else { return }
            self.lastPayload = payload
            self.lastPushedAt = now
        }
    }
```

- [ ] **Step 2: Update `start` and `end`**

In `start`, move the authorization guard below the defensive `end()` — today a rider who disables Live Activities mid-ride leaves the running one never ended and never updated again — and seed the payload:

```swift
    func start(mode: RideActivityMode,
               startedAt: Date,
               units: DistanceUnits,
               destinationName: String?) {
        // Clear any activity a previous ride left running BEFORE honoring the setting, so
        // turning Live Activities off mid-ride ends the running one rather than orphaning it.
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = RideActivityAttributes(
            mode: mode, startedAt: startedAt, units: units, destinationName: destinationName)
        let payload = RideActivityPayload(clock: .running(anchor: startedAt))
        let state = RideActivityAttributes.ContentState(payload: payload)
        let content = ActivityContent(
            state: state,
            staleDate: startedAt.addingTimeInterval(RideActivityPushPolicy.staleInterval))
        do {
            activity = try Activity.request(attributes: attributes, content: content)
            lastPayload = payload
            lastPushedAt = startedAt
        } catch {
            activity = nil
            lastPayload = nil
            lastPushedAt = nil
        }
    }
```

In `end`, cancel the chain and clear the payload state so a failed `Activity.request` cannot leave a previous ride's frame behind:

```swift
    func end() {
        guard let activity else { return }
        self.activity = nil
        let final = lastPayload
        lastPayload = nil
        lastPushedAt = nil
        pushChain?.cancel()
        pushChain = nil

        let state = final.map { RideActivityAttributes.ContentState(payload: $0) }
            ?? RideActivityAttributes.ContentState()
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
```

- [ ] **Step 3: Update the conformer's doc comment**

In `RideLiveActivityController+RideActivityControlling.swift`, the comment claims `update(stats:currentSpeedMetersPerSecond:maneuver:)` "already matches" — update the signature it names to include `activeClock:`.

- [ ] **Step 4: Build**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds clean.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add Aura/Sources/LiveActivity
git commit -m "feat(roh-102): payload-keyed dedupe, serialized pushes, ungated heartbeat"
```

---

### Task 8: The five clock call sites render the clock

**Files:**
- Modify: `Aura/Widgets/RideActivityComponents.swift:46-64`
- Modify: `Aura/Widgets/RideLiveActivity.swift:49,94,121`
- Modify: `Aura/Widgets/RideLockScreenView.swift:45,87`

**Interfaces:**
- Consumes: `ContentState.activeClock(startedAt:)` (Task 6).
- Produces: `RideTimerStatCell(clock:label:)`; `rideActivityClockLabel(_:)`.

- [ ] **Step 1: Rewrite `RideTimerStatCell` to switch on the clock**

Replace `RideTimerStatCell` in `RideActivityComponents.swift`:

```swift
/// The clock cell. Running, it is a self-ticking active-time clock the system renders on-device,
/// so elapsed stays live without the app pushing every second. Paused, it counts *up* from the
/// instant of the stop — still OS-rendered, so it keeps moving even when the app is suspended or
/// dead, and answers the one question a stopped rider has: how long have I been stopped.
///
/// Mint marks the live running value. Paused drops to secondary, because a paused clock is not
/// reporting the ride.
struct RideTimerStatCell: View {
    let clock: RideActiveClock
    let label: String
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(anchor, style: .timer)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(clock.isPaused ? AuraTheme.textSecondary : AuraTheme.accent)
                .lineLimit(1)
            Text(rideActivityClockLabel(clock, running: label))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }

    private var anchor: Date {
        switch clock {
        case .running(let anchor): anchor
        case .paused(let since, _): since
        }
    }
}

/// The label under the clock. A paused clock is not reporting elapsed ride time, so it must not
/// keep claiming to — the expanded Dynamic Island has no status pill, making this label that
/// presentation's only paused signal.
func rideActivityClockLabel(_ clock: RideActiveClock, running: String) -> String {
    clock.isPaused ? PauseControlCopy.stateChipLabel : running
}
```

- [ ] **Step 2: Move all five call sites onto the clock**

`RideLockScreenView.swift:45` and `:87` — both currently `RideTimerStatCell(start: attributes.startedAt, label: "TIME")`:

```swift
                RideTimerStatCell(clock: state.activeClock(startedAt: attributes.startedAt),
                                  label: "TIME")
```

`RideLiveActivity.swift:121` — same substitution, using `context.state` and `context.attributes.startedAt`.

`RideLiveActivity.swift:49` (compact trailing, free ride) — replace the bare `Text(context.attributes.startedAt, style: .timer)`:

```swift
                Text(rideActivityClockAnchor(context), style: .timer)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(clock.isPaused ? AuraTheme.textSecondary : AuraTheme.accent)
                    .frame(maxWidth: 56)
```

`RideLiveActivity.swift:94` (expanded trailing, free ride) — same anchor substitution, and its `Text("ELAPSED")` at `:100` becomes:

```swift
                Text(rideActivityClockLabel(clock, running: "ELAPSED"))
```

Add the shared helper to `RideActivityComponents.swift`:

```swift
/// The date to hand `Text(_, style: .timer)`: the active-time anchor while running, the stop's
/// instant while paused.
func rideActivityClockAnchor(_ clock: RideActiveClock) -> Date {
    switch clock {
    case .running(let anchor): anchor
    case .paused(let since, _): since
    }
}
```

and use it inside `RideTimerStatCell` in place of the private `anchor` computed property, so there is one definition. In `RideLiveActivity.dynamicIsland`, bind `let clock = context.state.activeClock(startedAt: context.attributes.startedAt)` alongside the existing `nav` / `imminent` / `accent` bindings, and thread it into `expandedTrailing` and `expandedBottom` as a parameter.

- [ ] **Step 3: Build**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds clean; `grep -rn "attributes.startedAt" Aura/Widgets/` returns only the fallback inside `activeClock(startedAt:)` call sites.

- [ ] **Step 4: Verify no call site was missed**

Run: `grep -rn "startedAt, style: .timer\|start: attributes.startedAt\|start: context.attributes.startedAt" Aura/Widgets/`
Expected: no matches. Five sites moved; the parent spec's count of three missed both Lock Screen ones.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add Aura/Widgets
git commit -m "feat(roh-102): all five widget clock sites render the active clock"
```

---

### Task 9: The paused treatment, on both modes and every presentation

**Files:**
- Modify: `Aura/Widgets/RideActivityComponents.swift` (`RideStatusPill`, `rideActivityIsImminent`)
- Modify: `Aura/Widgets/RideLiveActivity.swift:40,56,67`
- Modify: `Aura/Widgets/RideLockScreenView.swift:42,57-58,64,99-100`

**Interfaces:**
- Consumes: `ContentState.isPaused` (Task 6).
- Produces: `RideStatusPill(isPaused:isStale:)`; `rideActivityIsImminent(_:isPaused:)`.

- [ ] **Step 1: Compose paused and stale in the pill**

Replace `RideStatusPill` in `RideActivityComponents.swift`:

```swift
/// The Lock Screen's state word. Paused and stale **compose** rather than one masking the other:
/// a jetsam kill during a pause is likely by construction, nothing ends the orphan until ROH-124
/// ships, and a killed ride wearing a confident PAUSED is how a rider reads "still paused, good",
/// rides home, and records none of it (spec D6).
struct RideStatusPill: View {
    var isPaused: Bool = false
    let isStale: Bool

    var body: some View {
        switch (isPaused, isStale) {
        case (true, true):
            pill("\(PauseControlCopy.stateChipLabel) · NOT UPDATING", tint: AuraTheme.textSecondary)
        case (true, false):
            pill(PauseControlCopy.stateChipLabel, tint: AuraTheme.textSecondary)
        case (false, true):
            Label("Updating", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
                .labelStyle(.titleAndIcon)
        case (false, false):
            HStack(spacing: 5) {
                Circle().fill(AuraTheme.accent).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AuraTheme.accent)
            }
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}
```

Both existing call sites (`RideLockScreenView.swift:83`, `:125`) gain `isPaused: state.isPaused`.

- [ ] **Step 2: Suppress the imminent cue while paused**

In `RideActivityComponents.swift`:

```swift
/// Paused suppresses it: pausing within 150 m of a turn — at the junction, at the light, at the
/// shop just before it — would otherwise leave the app's single most urgent cue, a solid mint
/// fill, burning on a ride that is recording nothing.
func rideActivityIsImminent(_ turnDistanceMeters: Double?, isPaused: Bool) -> Bool {
    guard !isPaused, let d = turnDistanceMeters else { return false }
    return d <= rideActivityImminentMeters
}
```

Update both call sites — `RideLiveActivity.swift:26` and `RideLockScreenView.swift:64` — to pass `isPaused: context.state.isPaused` / `state.isPaused`.

- [ ] **Step 3: Swap the identity glyph in both modes**

The glyph is the only channel the minimal Dynamic Island presentation has, and navigate must swap too or a paused navigate ride is indistinguishable from a running one on every Dynamic Island phone.

`RideLiveActivity.swift:40` (compact **leading** — the prose in earlier revisions called this compact trailing) and `:56` (minimal), both currently `nav ? (context.state.turnGlyphSystemName ?? "arrow.turn.up.right") : "bicycle"`:

```swift
            Image(systemName: rideActivityGlyph(nav: nav, paused: context.state.isPaused,
                                                turnGlyph: context.state.turnGlyphSystemName))
                .foregroundStyle(accent)
```

`RideLiveActivity.swift:67` (expanded leading) and `RideLockScreenView.swift:42` (Lock Screen header, which passes `glyph: "bicycle"`) take the same helper. Add it to `RideActivityComponents.swift`:

```swift
/// `pause.fill` outranks both the maneuver arrow and the bicycle: what the rider needs from a
/// glance at a paused activity is that it is paused.
func rideActivityGlyph(nav: Bool, paused: Bool, turnGlyph: String?) -> String {
    if paused { return "pause.fill" }
    return nav ? (turnGlyph ?? "arrow.turn.up.right") : "bicycle"
}
```

- [ ] **Step 4: Tell VoiceOver**

`RideLockScreenView.swift:57-58` and `:99-100` hardcode labels that override their combined children, so a VoiceOver rider on a paused Lock Screen is currently told the ride is in progress:

```swift
        .accessibilityLabel(state.isPaused ? "Explore paused" : "Explore in progress")
```

```swift
        .accessibilityLabel(state.isPaused
                            ? "Navigating, paused. Next: \(instructionText), \(turnDistanceText)"
                            : "Navigating. Next: \(instructionText), \(turnDistanceText)")
```

- [ ] **Step 5: Build and verify the widget previews**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds clean.

Run: `grep -rn "RideStatusPill(isStale" Aura/Widgets/`
Expected: no matches — both call sites pass `isPaused`.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint --quiet
git add Aura/Widgets
git commit -m "feat(roh-102): paused treatment across both modes and every presentation"
```

---

### Task 10: Full suite, then the device pass

**Files:** none modified unless a failure surfaces.

- [ ] **Step 1: Run the whole package suite**

Run: `cd AuraCore && swift test`
Expected: PASS on **both** totals, at or above the 223 XCTest / 780 Swift Testing baseline.

- [ ] **Step 2: Lint the whole repo**

Run: `swiftlint` from the repo root.
Expected: no violations.

- [ ] **Step 3: Build app and widget**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme and confirm the `AuraWidgets` extension target builds.

- [ ] **Step 4: Device pass (spec D10)**

On a real phone, not the simulator. Record the outcome of each in the PR body:

1. Ride, pause, resume — the clock reports active time after the resume, not wall-clock and not a value that jumped.
2. The paused Lock Screen and both Dynamic Island presentations read as paused at arm's length, in free ride **and** navigate, including a pause taken within 150 m of a turn (the imminent-cue suppression).
3. Leading-zero shape of the paused counting-up timer against the cockpit chip.
4. VoiceOver on the paused Lock Screen announces paused, not "in progress".
5. **The runtime measurement:** a forty-minute backgrounded pause with a log line per emitted push, to settle whether the ticker survives. This is the open question from spec D8 and it informs Slice B.
6. An activity started on the previous build with the new build installed over it. **Expected: a permanently wall-clock activity**, not a recovered one — the process is gone and orphan recovery is ROH-124. Reading a recovery here as the pass condition would invert the result.

- [ ] **Step 5: Commit any device-pass fixes separately**

```bash
git commit -m "fix(roh-102): device pass findings"
```

---

## Self-Review

**Spec coverage.** D1 → Tasks 1, 8. D2 → Tasks 2, 6. D3 → Tasks 1, 4. D4 → Tasks 3, 7. D5 → Task 7. D6 → Task 9. D7 → Tasks 8, 9. D8 → Task 3 (uniform stale window) and Task 10 step 4.5 (the measurement). D9 is a recorded cost with no code. D10 → every task's test steps plus Task 10.

**Type consistency.** `RideActiveClock.make(startedAt:pausedSeconds:pausedSince:now:)` is defined in Task 1 and called in Task 5. `RideActivityPayload.holdingTurn(from:)` is defined in Task 2 and called in Task 7. `RideActivityPushPolicy.decide(last:next:lastPushedAt:now:)` and `staleInterval` are defined in Task 3 and called in Task 7. `ContentState.init(payload:)`, `.isPaused` and `.activeClock(startedAt:)` are defined in Task 6 and called in Tasks 7, 8, 9. `rideActivityClockAnchor`, `rideActivityClockLabel` and `rideActivityGlyph` are defined in Tasks 8 and 9 and used in both.

**Known gap, deliberate.** `ContentState`'s own `Codable` decode has no automated test and cannot have one (spec D2). Task 6 minimizes the surface to a total projection; Task 10 step 4.6 covers it on device.
