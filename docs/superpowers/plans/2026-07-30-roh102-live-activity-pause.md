# ROH-102 Pass 5 — Live Activity pause: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The in-progress-ride Live Activity reports active time, reads as paused on every presentation in both modes, and stops claiming to be paused once the app is dead.

**Architecture:** The clock becomes a two-case `RideActiveClock` carried in one optional `ContentState` field. A pure `RideActivityPayload` mirror and a pure `RideActivityPushPolicy` live in AuraCore so the dedupe, its equality and the heartbeat are host-tested — `ContentState` sits in an app-target file no test target on any platform can see. `RideLiveActivityController` becomes a mapper over that policy with serialized pushes.

**Tech Stack:** Swift 6, SwiftUI, ActivityKit, WidgetKit, Swift Testing (`@Suite`/`@Test`/`#expect`) throughout, SwiftLint.

**Spec:** [2026-07-30-roh102-live-activity-pause-design.md](../specs/2026-07-30-roh102-live-activity-pause-design.md), revision 3. D1–D10 below refer to it.

**Plan revision 2**, after two reviewers refuted revision 1. The changes that matter: task order now keeps the app target compiling at every commit (revision 1 broke it across three tasks and then asserted a build gate that could not pass); Task 1's paused test data was arithmetically impossible; `pause(at:)`/`resume(at:)` gain injectable instants without which two of the coordinator tests are tautologies; and the controller stamps its dedupe state at enqueue rather than after the push lands.

## Global Constraints

- The AuraCore package builds on the **macOS CI host**. Anything iOS-only is `#if os(iOS)`-guarded. AuraKit never imports ActivityKit (`RideSessionSeams.swift:12-13`) — that rule is why this plan has the shape it does.
- **No async default-argument closures anywhere** (SwiftLint `async_closure_default_argument`). A plain `now: Date = Date()` default is fine and already ships at `RideSessionCoordinator.swift:220`.
- Run `swiftlint` **from the repo root**.
- `swift test` prints **two** totals. Baseline before this plan: 223 XCTest / 780 Swift Testing, 0 failures.
- **Every** test target here uses Swift Testing — AuraCoreTests and AuraKitTests alike. No XCTest in new code. `RideSessionCoordinatorTests` is `@MainActor @Suite(.swiftDataSerialized) struct`; keep the trait, it is the SwiftData flake gate (ROH-65).
- Real call shapes, verified — do not invent variants:
  - `RideRecorder()` takes **no** arguments.
  - `makeCoordinator(kind:destinationName:screen:activity:)` — `screen:` and `activity:` both required, no `saving:`.
  - Saving is injected at start: `c.start(location: ScriptedLocationProvider([...]), saving: store, units: .metric, authorization: .authorized)`.
  - `RideStore.inMemory()` throws.
- **Every commit must leave the app target compiling.** `.github/workflows/ci.yml` runs an `App build (xcodebuild)` job, and `.claude/agent-gate.sh` does not build the app — so a broken tree passes the local gate and fails CI. The seam change (Task 6) and its only conformer therefore land together.
- Copy is fixed and exact: `PAUSED`, and `PAUSED · NOT UPDATING` when also stale. The separator is U+00B7 MIDDLE DOT.
- The widget target sees AuraCore and AuraKit (`Aura/project.yml:106-110`), but **there is no `@_exported import` anywhere in `AuraCore/Sources`** — every file naming an AuraCore type must `import AuraCore` itself.
- Delegate Xcode builds to the `apple-platform-build-tools:builder` subagent. Run the package suite directly.

## File Structure

**Create:** `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`, `RideActivityPayload.swift`, `RideActivityPushPolicy.swift`, and a test file for each under `AuraCore/Tests/AuraCoreTests/`.

**Modify:** `AuraCore/Sources/AuraKit/RideRecorder.swift`; `RideSession/RideSessionSeams.swift`; `RideSession/RideSessionCoordinator.swift`; `AuraCore/Tests/AuraKitTests/{RideRecorderPauseTests,RideSessionCoordinatorTests}.swift`; `Aura/Sources/LiveActivity/{RideActivityAttributes,RideLiveActivityController,RideLiveActivityController+RideActivityControlling}.swift`; `Aura/Widgets/{RideActivityComponents,RideLiveActivity,RideLockScreenView}.swift`.

---

### Task 1: `RideActiveClock`

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `RideActiveClock` (`Codable, Hashable, Sendable`), cases `.running(anchor: Date)` and `.paused(since: Date, activeSeconds: TimeInterval)`; `var isPaused: Bool`; `static func make(startedAt: Date, pausedSeconds: TimeInterval, pausedSince: Date?, now: Date) -> RideActiveClock`.

**Precondition that the whole design rests on:** `pausedSeconds` must be measured *as of the same `now`* — that is, `RideRecorder.pausedSeconds(asOf: now)`, which **includes the stop currently open**. Given that, `(now − startedAt) − pausedSeconds` is constant through a stop, which is what makes the paused case dedupe. Get this wrong and D3's trap returns.

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
        // 10 min of wall clock, 4 of them stopped: active is 6 min, so the anchor sits 4 min in.
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 240,
                                         pausedSince: nil, now: start.addingTimeInterval(600))
        #expect(clock == .running(anchor: start.addingTimeInterval(240)))
    }

    @Test("A running anchor is identical across a span of ticks")
    func runningIsStableAcrossTicks() {
        // While no stop is open pausedSeconds does not move, so neither may the anchor — a
        // per-tick anchor would be a per-tick payload and the dedupe would never fire.
        let ticks = (0..<200).map { i in
            RideActiveClock.make(startedAt: start, pausedSeconds: 240, pausedSince: nil,
                                 now: start.addingTimeInterval(600 + Double(i) * 0.5))
        }
        #expect(Set(ticks).count == 1)
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
        // Stop opened at start+600 with nothing paused before it. 90 s later the recorder
        // reports pausedSeconds(asOf: now) == 90, so active is 690 - 90 = 600 — which is
        // exactly the active time at the instant the stop began.
        let stoppedAt = start.addingTimeInterval(600)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 90,
                                         pausedSince: stoppedAt,
                                         now: stoppedAt.addingTimeInterval(90))
        #expect(clock == .paused(since: stoppedAt, activeSeconds: 600))
        #expect(clock.isPaused)
    }

    @Test("A second stop freezes active time net of the first stop")
    func pausedAfterAnEarlierStop() {
        // 60 s banked from an earlier stop; this stop opens at start+900 and is 90 s old.
        let stoppedAt = start.addingTimeInterval(900)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 150,
                                         pausedSince: stoppedAt,
                                         now: stoppedAt.addingTimeInterval(90))
        #expect(clock == .paused(since: stoppedAt, activeSeconds: 840))
    }

    @Test("The paused value is identical across a span of ticks")
    func pausedIsStableAcrossTicks() {
        // The trap that killed spec revision 1: pausedSeconds(asOf:) grows every tick while a
        // stop is open, so anything carrying it raw changes every tick and defeats the dedupe.
        let stoppedAt = start.addingTimeInterval(600)
        let ticks = (0..<200).map { i -> RideActiveClock in
            let now = stoppedAt.addingTimeInterval(Double(i) * 0.5)
            return .make(startedAt: start, pausedSeconds: Double(i) * 0.5,
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

- [ ] **Step 2: Run and watch it fail**

Run: `cd AuraCore && swift test --filter RideActiveClockTests`
Expected: the whole test target fails to **compile** — `cannot find 'RideActiveClock' in scope`. This proves the type is absent, not that the assertions discriminate; Step 4 is what proves that.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`:

```swift
import Foundation

/// What the Live Activity's clock should display, as a value the widget renders without
/// arithmetic. Two cases, because a paused clock answers a different question than a running one
/// (spec D1).
///
/// **Neither case carries a value that moves while the ride is paused**, which is the whole point
/// of the shape: `RideRecorder.pausedSeconds(asOf:)` grows on every tick of a stop, so a clock
/// storing it raw would be a distinct value every tick and the controller's dedupe — which exists
/// precisely for a long stop — could never fire (spec D3).
///
/// **Wire-format note.** This type is `Codable` inside `RideActivityAttributes.ContentState`, so
/// an activity in flight across an app update is decoded by a *new* binary from bytes an *old* one
/// wrote. Adding a case is safe; **renaming a case or an associated-value label is not** — the new
/// binary would throw and strand the activity on its last rendered frame.
public enum RideActiveClock: Codable, Hashable, Sendable {
    /// Active time is `now - anchor`, rendered by the OS via `Text(anchor, style: .timer)` with
    /// no per-second pushes. `anchor` is `startedAt + pausedSeconds`, never in the future.
    case running(anchor: Date)
    /// `since` is the instant this stop began — the widget counts *up* from it, so the paused
    /// clock keeps moving and answers "how long have I been stopped". `activeSeconds` is the
    /// ride's active time frozen at that instant, carried for the ride's end, not rendered.
    case paused(since: Date, activeSeconds: TimeInterval)

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// Build the clock from the three numbers the recorder holds.
    ///
    /// **`pausedSeconds` must be measured as of `now`** — `RideRecorder.pausedSeconds(asOf: now)`,
    /// which includes the stop currently open. That coupling is what makes the paused case
    /// constant through a stop: both terms grow in lockstep, so their difference does not.
    /// A caller that measures the two at different instants reintroduces D3's trap.
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
        // it, and `Text(_, style: .timer)` with a future anchor counts DOWN. While the clamp is
        // active the anchor tracks `now` and the clock reads 0:00, which costs a push per
        // coalescing interval until wall-clock catches up — bounded by the size of the backward
        // step, and strictly better than a Lock Screen counting down. The in-app clock clamps for
        // the same reason (`RideSessionCoordinator.refreshElapsed`); the residual wall-clock
        // weakness is ROH-130.
        return .running(anchor: min(startedAt.addingTimeInterval(pausedSeconds), now))
    }
}
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd AuraCore && swift test --filter RideActiveClockTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift
git commit -m "feat(roh-102): RideActiveClock with a clamped anchor and a stable paused case"
```

---

### Task 2: `RideActivityPayload`

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideActivityPayload.swift`
- Test: `AuraCore/Tests/AuraCoreTests/RideActivityPayloadTests.swift`

**Interfaces:**
- Consumes: `RideActiveClock` (Task 1).
- Produces: `RideActivityPayload` (`Codable, Hashable, Sendable`) with `distanceMeters`, `speedMetersPerSecond`, `elevationGainMeters: Double`, `turnInstruction: String?`, `turnDistanceMeters: Double?`, `turnGlyphSystemName: String?`, `clock: RideActiveClock`; a memberwise `init` defaulting everything but `clock`; `func holdingTurn(from previous: RideActivityPayload?) -> RideActivityPayload`.

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
        // GuidanceViewModel.applyProgress updates lastUpdate before its isPaused guard, so a
        // stationary rider's distance-to-turn drifts with GPS jitter. Left alone it ticks beside
        // a frozen clock and defeats the dedupe on every navigate pause (spec D7).
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

- [ ] **Step 2: Run and watch it fail**

Run: `cd AuraCore && swift test --filter RideActivityPayloadTests`
Expected: compile failure — `cannot find 'RideActivityPayload' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideActivityPayload.swift`:

```swift
import Foundation

/// Every live value the in-progress-ride Live Activity displays, as a pure value.
///
/// This mirrors the app target's `RideActivityAttributes.ContentState`, which is declared inside
/// an `ActivityAttributes` conformer and is therefore invisible to every test target this repo
/// has (spec D2). `ContentState` is derived *solely* from a payload — its memberwise initializer
/// is private — so payload equality implies content equality, which is what lets the controller's
/// dedupe be host-tested here rather than shipped untested there.
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
    /// ticking number beside a frozen clock and a PAUSED pill — two readings of one surface
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

- [ ] **Step 4: Run and watch it pass**

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
- Produces: `RideActivityPushDecision` (`Hashable, Sendable`) with `.push` and `.skip`; `enum RideActivityPushPolicy` with `coalesceInterval: TimeInterval = 4`, `heartbeatInterval: TimeInterval = 60`, `staleInterval: TimeInterval = 90`, and `static func decide(last: RideActivityPayload?, next: RideActivityPayload, lastPushedAt: Date?, now: Date) -> RideActivityPushDecision`.

Note `.push` carries **no** stale date. Revision 1 put one there, computed from the decision-time `now`; a push that waits behind others would then carry a window that had already half elapsed, and under a backlog the content lands already stale — dimming a live ride. The controller computes `staleDate` from a fresh `Date()` immediately before it sends (spec D5).

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

    @Test("The first push always goes")
    func firstPush() {
        #expect(RideActivityPushPolicy.decide(
            last: nil, next: payload(), lastPushedAt: nil, now: t0) == .push)
    }

    @Test("An unchanged payload inside the coalescing window is skipped")
    func unchangedIsSkipped() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(), next: payload(),
            lastPushedAt: t0, now: t0.addingTimeInterval(2)) == .skip)
    }

    @Test("An unchanged payload past the coalescing window is still skipped")
    func unchangedStaysSkippedPastCoalesce() {
        // This is the dedupe: ~600 identical pushes across a 40-minute stop become heartbeats.
        #expect(RideActivityPushPolicy.decide(
            last: payload(), next: payload(),
            lastPushedAt: t0, now: t0.addingTimeInterval(30)) == .skip)
    }

    @Test("A changed payload is coalesced to the 4-second cadence")
    func changedIsCoalesced() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(distance: 1), next: payload(distance: 2),
            lastPushedAt: t0, now: t0.addingTimeInterval(2)) == .skip)
        #expect(RideActivityPushPolicy.decide(
            last: payload(distance: 1), next: payload(distance: 2),
            lastPushedAt: t0, now: t0.addingTimeInterval(4)) == .push)
    }

    @Test("A changed turn instruction bypasses the cadence")
    func turnChangeBypasses() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(turn: "Left onto Liberty"), next: payload(turn: "Right onto Penn"),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5)) == .push)
    }

    @Test("A pause bypasses the cadence, so the tap reaches the Lock Screen in the same turn")
    func pauseTransitionBypasses() {
        // Spec revision 1's fatal defect: it put this bypass nowhere, so a tap landing inside
        // the 4-second window changed nothing at all.
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: false), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5)) == .push)
    }

    @Test("A resume bypasses the cadence too")
    func resumeTransitionBypasses() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: false),
            lastPushedAt: t0, now: t0.addingTimeInterval(0.5)) == .push)
    }

    @Test("The heartbeat fires on an unchanged paused payload")
    func heartbeatWhilePaused() {
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(59)) == .skip)
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: true), next: payload(paused: true),
            lastPushedAt: t0, now: t0.addingTimeInterval(60)) == .push)
    }

    @Test("The heartbeat is not gated on paused: a running ride with no new fixes stays fresh")
    func heartbeatWhileRunning() {
        // A garage start, a tunnel or a bad urban canyon yields no acceptable fixes, so the
        // payload is byte-identical for minutes. Gating the heartbeat on paused would let that
        // healthy ride go stale and tell the rider the app had died.
        #expect(RideActivityPushPolicy.decide(
            last: payload(paused: false), next: payload(paused: false),
            lastPushedAt: t0, now: t0.addingTimeInterval(60)) == .push)
    }

    @Test("The heartbeat beats the stale window, so an alive ride never dims in either state")
    func heartbeatOutrunsStaleWindow() {
        #expect(RideActivityPushPolicy.heartbeatInterval < RideActivityPushPolicy.staleInterval)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd AuraCore && swift test --filter RideActivityPushPolicyTests`
Expected: compile failure — `cannot find 'RideActivityPushPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift`:

```swift
import Foundation

/// Whether to push the Live Activity.
///
/// There is deliberately no "skip but advance the clock" case. The controller's throttle state
/// moves only inside the `.push` branch, so a skipped push cannot advance the clock the heartbeat
/// measures against — the defect that would otherwise make the heartbeat dead code (spec D4).
public enum RideActivityPushDecision: Hashable, Sendable {
    case push
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
    /// How far ahead pushed content is marked stale — longer than the heartbeat, so an alive app
    /// never dims and a dead one confesses within the window.
    public static let staleInterval: TimeInterval = 90

    public static func decide(last: RideActivityPayload?,
                              next: RideActivityPayload,
                              lastPushedAt: Date?,
                              now: Date) -> RideActivityPushDecision {
        guard let last, let lastPushedAt else { return .push }

        let sinceLastPush = now.timeIntervalSince(lastPushedAt)
        // A new maneuver and a pause/resume are both state the rider is waiting to see, so
        // neither waits on the coalescing cadence.
        if next.turnInstruction != last.turnInstruction { return .push }
        if next.clock.isPaused != last.clock.isPaused { return .push }
        if sinceLastPush >= heartbeatInterval { return .push }
        if next != last && sinceLastPush >= coalesceInterval { return .push }
        return .skip
    }
}
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd AuraCore && swift test --filter RideActivityPushPolicyTests`
Expected: PASS, 10 tests.

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
- Produces: `RideRecorder.pausedSince: Date?`, non-nil exactly while a stop is open.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `RideRecorderPauseTests` struct, which already has the `at(_:)` helper:

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

- [ ] **Step 2: Run and watch it fail**

Run: `cd AuraCore && swift test --filter RideRecorderPauseTests`
Expected: compile failure — `value of type 'RideRecorder' has no member 'pausedSince'`.

- [ ] **Step 3: Write the implementation**

In `AuraCore/Sources/AuraKit/RideRecorder.swift`, beside `isPaused` (near line 24):

```swift
    /// The instant the stop in progress began, or nil while recording.
    ///
    /// Exposed for `RideActiveClock.paused(since:)`: the Live Activity counts *up* from this
    /// instant, which is what makes the paused Lock Screen answer "how long have I been stopped"
    /// with a number that keeps moving even when the app cannot push (spec D1).
    public var pausedSince: Date? { pauseStartedAt }
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd AuraCore && swift test --filter RideRecorderPauseTests`
Expected: PASS, including both new tests.

- [ ] **Step 5: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraKit/RideRecorder.swift AuraCore/Tests/AuraKitTests/RideRecorderPauseTests.swift
git commit -m "feat(roh-102): expose the recorder's stop instant as pausedSince"
```

---

### Task 5: `ContentState` gains the clock

**Files:**
- Modify: `Aura/Sources/LiveActivity/RideActivityAttributes.swift`

**Interfaces:**
- Consumes: `RideActivityPayload` (Task 2), `RideActiveClock` (Task 1).
- Produces: `ContentState.clock: RideActiveClock?`; `ContentState.init(payload:)`; `ContentState.init()`; `ContentState.isPaused`; `ContentState.activeClock(startedAt:)`.

This lands **before** the seam change so the app target keeps compiling at every commit. No test target on any platform can see this type (spec D2); its correctness rests on being a total projection with no logic, which is why the memberwise initializer becomes private.

- [ ] **Step 1: Add the import, the property, the projection and the rule**

Add `import AuraCore` at the top of `Aura/Sources/LiveActivity/RideActivityAttributes.swift` if absent. Extend `ContentState`'s doc comment with the rule, add `clock`, make the memberwise init `private`, and add the three members:

```swift
    /// **Every field added here from now on must be `Optional` or defaulted.** `ContentState` is
    /// `Codable` and re-serialized on every update, so an activity in flight across an app update
    /// is decoded by the *new* binary from bytes the *old* one wrote. Swift's synthesized
    /// `init(from:)` uses `decodeIfPresent` for `Optional` stored properties, so a missing key
    /// yields nil; a non-Optional field would throw and strand the activity on its last rendered
    /// content forever. The same applies to `RideActiveClock`'s cases and associated-value labels:
    /// adding is safe, renaming is not. No test target on any platform can see this type, so this
    /// rule is the whole guarantee (ROH-102 spec D2, invariant 6).
    public struct ContentState: Codable, Hashable, Sendable {
        // ... existing properties unchanged ...

        /// What the clock displays. `nil` for an activity started before ROH-102 shipped; every
        /// read site falls back to `attributes.startedAt`, which is the pre-ROH-102 behavior.
        public var clock: RideActiveClock?

        /// Becomes `private` in Task 7, so that `ContentState` can only be built from a payload.
        /// It cannot be private yet: `RideLiveActivityController` still holds a
        /// `lastState = ContentState()` stored property and an `update` body that constructs one
        /// field-by-field, and both disappear in Task 7. Making it private here would leave the
        /// app target non-compiling for two commits.
        ///
        /// The dedupe's whole correctness argument is "payload equality implies content
        /// equality"; a field set outside a payload breaks it silently, on a type nothing can
        /// test (invariant 5). Task 7 is where that becomes structural.
        init(distanceMeters: Double = 0,
                     speedMetersPerSecond: Double = 0,
                     elevationGainMeters: Double = 0,
                     turnInstruction: String? = nil,
                     turnDistanceMeters: Double? = nil,
                     turnGlyphSystemName: String? = nil,
                     clock: RideActiveClock? = nil) {
            self.distanceMeters = distanceMeters
            self.speedMetersPerSecond = speedMetersPerSecond
            self.elevationGainMeters = elevationGainMeters
            self.turnInstruction = turnInstruction
            self.turnDistanceMeters = turnDistanceMeters
            self.turnGlyphSystemName = turnGlyphSystemName
            self.clock = clock
        }

        /// The only initializer production code uses.
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

Fix the stale doc on `speedMetersPerSecond` in the same edit — it says "the ride's average" but the controller passes `currentSpeedMetersPerSecond`:

```swift
        /// Current smoothed speed in meters per second — not the ride average.
```

- [ ] **Step 2: Fix the one existing caller of the memberwise init**

`RideLiveActivityController.start` currently calls `RideActivityAttributes.ContentState()`. Making the init private breaks it. Change that one line to build from a payload:

```swift
        let state = RideActivityAttributes.ContentState(
            payload: RideActivityPayload(clock: .running(anchor: startedAt)))
```

Add `import AuraCore` to `RideLiveActivityController.swift` if absent.

- [ ] **Step 3: Build**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds clean. The widget still reads `attributes.startedAt`; nothing consumes `clock` yet.

- [ ] **Step 4: Lint and commit**

```bash
swiftlint --quiet
git add Aura/Sources/LiveActivity
git commit -m "feat(roh-102): ContentState carries the active clock, built only from a payload"
```

---

### Task 6: The seam carries the clock, and both transitions push

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionSeams.swift:15-19`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (`pushActivityUpdate`, `pause()`, `resume()`, and the no-yield comment at `:238-241`)
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController.swift` (signature only)
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController+RideActivityControlling.swift` (doc comment)
- Modify: `AuraCore/Tests/AuraKitTests/RideSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `RideActiveClock.make` (Task 1), `RideRecorder.pausedSince` (Task 4), `ContentState.init(payload:)` (Task 5).
- Produces: `RideActivityControlling.update(stats:currentSpeedMetersPerSecond:maneuver:activeClock:)`; `RideSessionCoordinator.pause(at:)` / `resume(at:)` / `pushActivityUpdate(now:)`; `SpyRideActivity.UpdateCall.activeClock`.

The seam and its only conformer change in **one commit** — the app target does not compile in between, and CI runs an app build.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `@MainActor @Suite(.swiftDataSerialized) struct RideSessionCoordinatorTests`:

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

    @Test func theResumedAnchorShiftsForwardByExactlyTheStopDuration() throws {
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        let started = try #require(c.startedAt)

        c.pushActivityUpdate(now: started.addingTimeInterval(600))
        guard case .running(let firstAnchor) =
                try #require(activity.updates.last).activeClock else {
            Issue.record("expected a running clock before the stop")
            return
        }

        // A 240-second stop, driven by injected instants: pause()/resume() calling Date()
        // internally would make the stop microseconds long and the assertion a tautology.
        c.pause(at: started.addingTimeInterval(600))
        c.resume(at: started.addingTimeInterval(840))
        c.pushActivityUpdate(now: started.addingTimeInterval(900))

        guard case .running(let resumedAnchor) =
                try #require(activity.updates.last).activeClock else {
            Issue.record("expected a running clock after the resume")
            return
        }
        #expect(resumedAnchor.timeIntervalSince(firstAnchor) == 240)
        c.cancel()
    }

    @Test func thePausedClockIsIdenticalAcrossTwentyTicks() throws {
        // The highest-value test in this pass. `RideActiveClock.make`'s stability holds only
        // because pushActivityUpdate passes pausedSeconds(asOf: now) with the SAME now it passes
        // as now. A pure-function suite that hand-writes both in lockstep proves the arithmetic
        // and nothing about the wiring, which is the only place the coupling can break.
        let activity = SpyRideActivity()
        let c = makeCoordinator(screen: SpyScreenWake(), activity: activity)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        let started = try #require(c.startedAt)
        let stoppedAt = started.addingTimeInterval(600)

        c.pause(at: stoppedAt)
        for i in 0..<20 {
            c.pushActivityUpdate(now: stoppedAt.addingTimeInterval(Double(i) * 0.5))
        }

        let clocks = activity.updates.suffix(20).map(\.activeClock)
        #expect(clocks.count == 20)
        #expect(Set(clocks).count == 1)
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
        // Two points far enough apart to clear RideBackOutGate's 25 m discard floor, or the
        // pause flushes nothing and there is no ordering to assert.
        c.start(location: ScriptedLocationProvider([point(40.40, 0), point(40.45, 60)]),
                saving: saving, units: .metric, authorization: .authorized)
        await c.streamTask?.value

        c.pause()

        #expect(try #require(activity.lastUpdateSequence) < #require(saving.lastSaveSequence))
        c.cancel()
    }
```

Extend the spy at `:238-259`. `order` is optional so the file's existing `SpyRideActivity()` sites keep compiling:

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

/// Shared monotonic counter, so a test can assert the relative order of two collaborators'
/// calls inside one synchronous turn.
@MainActor
final class CallOrder {
    private var next = 0
    func stamp() -> Int { defer { next += 1 }; return next }
}

/// Stamps its saves against a shared `CallOrder`, then delegates. Wraps rather than replaces
/// `RideStore`, so the checkpoint really writes and the discard-floor gate still applies.
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

If `startedAt` is `private(set)` rather than internal on the coordinator, widen it to `public private(set)` in Step 3 — the two anchor tests read it.

- [ ] **Step 2: Run and watch it fail**

Run: `cd AuraCore && swift test --filter RideSessionCoordinatorTests`
Expected: compile failure — the protocol has no `activeClock:` parameter and no `pause(at:)`.

- [ ] **Step 3: Change the seam and the coordinator**

In `RideSessionSeams.swift`, replace the `update` requirement:

```swift
    /// `activeClock` is what the widget's clock should display — active time while running, the
    /// stop's own instant while paused. Built by the coordinator so the app target does no
    /// arithmetic and the widget none at all.
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock)
```

In `RideSessionCoordinator.swift`, replace `pushActivityUpdate()`:

```swift
    /// Pushes current stats, the maneuver and the clock. Factored out so a test can call it
    /// directly instead of waiting on the 0.5 s ticker; `now` is injectable for the same reason.
    /// The controller decides whether the push actually goes out.
    ///
    /// `pausedSeconds(asOf: now)` and `now` must be the same instant — that coupling is what
    /// keeps the paused clock constant through a stop (`RideActiveClock.make`).
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

Give `pause()` and `resume()` injectable instants, mirroring `RideRecorder.pause(at:)`, and add the push. Keep the public no-argument entry points so no HUD call site changes:

```swift
    public func pause() { pause(at: Date()) }

    func pause(at now: Date) {
        guard recorder.isRecording, !recorder.isPaused else { return }
        recorder.pause(at: now)
        haptics.play(.pause)
        pauseObserver?.rideDidSetPaused(true)
        refreshElapsed(now: now)
        // Before flushCheckpoint, which is a full-track encode and a mirrored write in this same
        // turn (see its doc comment) at the instant a jetsam kill is most likely. The rider's
        // Lock Screen learns about the stop first. Creating a Task does not suspend this
        // function, so the no-yield window above is unaffected.
        pushActivityUpdate(now: now)
        currentPauseSeconds = 0
        screen.setKeepAwake(false)
        flushCheckpoint(at: now)
        scheduleNudges(from: now)
    }

    public func resume() { resume(at: Date()) }

    func resume(at now: Date) {
        guard recorder.isPaused else { return }
        recorder.resume(at: now)
        haptics.play(.resume)
        nudges.cancelForgottenPauseNudges()
        currentPauseSeconds = 0
        pauseObserver?.rideDidSetPaused(false)
        refreshElapsed(now: now)
        pushActivityUpdate(now: now)
        screen.setKeepAwake(true)
    }
```

Update the no-yield comment at `:238-240` so its enumeration stays true — it currently names only `haptics.play` and `scheduleNudges`; `pushActivityUpdate` now sits in the same window and is likewise synchronous.

- [ ] **Step 4: Change the conformer in the same commit**

In `RideLiveActivityController.swift`, add the parameter to `update` and thread it into the state it already builds. The policy rewrite is Task 7; this step only keeps the app compiling:

```swift
    func update(stats: RideStats,
                currentSpeedMetersPerSecond: Double,
                maneuver: GuidanceUpdate?,
                activeClock: RideActiveClock) {
        guard let activity else { return }

        let instruction = maneuver?.instruction
        let now = Date()
        let turnChanged = instruction != lastInstruction
        let due = lastPush.map { now.timeIntervalSince($0) >= minInterval } ?? true
        guard turnChanged || due else { return }

        lastPush = now
        lastInstruction = instruction

        let payload = RideActivityPayload(
            distanceMeters: stats.distanceMeters,
            speedMetersPerSecond: currentSpeedMetersPerSecond,
            elevationGainMeters: stats.elevationGainMeters,
            turnInstruction: instruction,
            turnDistanceMeters: maneuver?.distanceToManeuverMeters,
            turnGlyphSystemName: ManeuverIcon.symbol(for: maneuver?.maneuver),
            clock: activeClock)
        let state = RideActivityAttributes.ContentState(payload: payload)
        lastState = state

        let content = ActivityContent(state: state,
                                      staleDate: now.addingTimeInterval(staleInterval))
        Task { await activity.update(content) }
    }
```

In `RideLiveActivityController+RideActivityControlling.swift`, update the doc comment naming the old signature.

- [ ] **Step 5: Run the package suite and build the app**

Run: `cd AuraCore && swift test`
Expected: PASS on both totals, with the five new coordinator tests green.

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds clean — this is the commit where seam and conformer move together.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint --quiet
git add AuraCore/Sources/AuraKit AuraCore/Tests/AuraKitTests Aura/Sources/LiveActivity
git commit -m "feat(roh-102): carry the active clock across the seam and push on both transitions"
```

---

### Task 7: The controller becomes a mapper over the policy

**Files:**
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController.swift`

**Interfaces:**
- Consumes: `RideActivityPushPolicy.decide` (Task 3), `RideActivityPayload.holdingTurn` (Task 2), `ContentState.init(payload:)` (Task 5).
- Produces: nothing later tasks consume.

- [ ] **Step 0: Close the deferred invariant from Task 5**

Task 5 left `ContentState`'s memberwise initializer internal because `lastState` and the old
`update` body still constructed one field-by-field. Step 1 deletes both. Once they are gone, mark
that initializer `private` in `Aura/Sources/LiveActivity/RideActivityAttributes.swift` and update
its doc comment to drop the "becomes private in Task 7" note. Invariant 5 — `ContentState` derived
solely from a payload — is only structural once this lands, and a `grep -rn "ContentState(" Aura/`
should afterwards show every construction going through `ContentState(payload:)`.

- [ ] **Step 1: Replace the throttle state**

Delete `minInterval`, `staleInterval`, `lastState`, `lastPush` and `lastInstruction`:

```swift
    private var activity: Activity<RideActivityAttributes>?
    /// The last payload *enqueued*, and when it was decided. Stamped at enqueue, not after the
    /// push lands: `Activity.update` returns on hand-off with no delivery signal, so no
    /// assignment point could mean "what the widget has" — and deferring the stamp would let
    /// every tick inside the in-flight window decide against pre-push state and enqueue again
    /// (spec D5).
    private var lastPayload: RideActivityPayload?
    private var lastPushedAt: Date?
    /// Serializes pushes so they land in the order they were decided. Two racing tasks could
    /// otherwise leave the widget holding a running state after a pause was pushed.
    private var pushChain: Task<Void, Never>?
```

- [ ] **Step 2: Rewrite `update` and add `enqueue`**

```swift
    /// Pushes the latest ride stats, maneuver and clock. Whether the push goes out is
    /// `RideActivityPushPolicy`'s decision — pure and host-tested in AuraCore, because this type
    /// imports ActivityKit and no test target can reach it.
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

        guard RideActivityPushPolicy.decide(last: lastPayload, next: payload,
                                            lastPushedAt: lastPushedAt, now: now) == .push else {
            return
        }

        // Inside the .push branch only: a skip must advance nothing (invariant 3).
        lastPayload = payload
        lastPushedAt = now
        enqueue(payload, on: activity)
    }

    /// Chains onto the previous push so updates land in the order they were decided.
    private func enqueue(_ payload: RideActivityPayload,
                         on activity: Activity<RideActivityAttributes>) {
        let previous = pushChain
        pushChain = Task { @MainActor [weak self] in
            await previous?.value
            // Before the send, not after: placed after, this would prevent stale bookkeeping but
            // not the stale push itself, and `start()` ends the old activity and requests the
            // next one in a single turn.
            guard let self, self.activity === activity else { return }
            // Fresh, so a push that waited behind others does not carry a window that has
            // already half elapsed.
            let staleDate = Date().addingTimeInterval(RideActivityPushPolicy.staleInterval)
            await activity.update(
                ActivityContent(state: RideActivityAttributes.ContentState(payload: payload),
                                staleDate: staleDate))
        }
    }
```

- [ ] **Step 3: Update `start` and `end`**

`start` — move the authorization guard below the defensive `end()`, so disabling Live Activities mid-ride ends the running one rather than orphaning it:

```swift
    func start(mode: RideActivityMode,
               startedAt: Date,
               units: DistanceUnits,
               destinationName: String?) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = RideActivityAttributes(
            mode: mode, startedAt: startedAt, units: units, destinationName: destinationName)
        let payload = RideActivityPayload(clock: .running(anchor: startedAt))
        let content = ActivityContent(
            state: RideActivityAttributes.ContentState(payload: payload),
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

`end` — join the chain rather than racing it. Cancelling does not work here: neither `Task.value` nor `activity.update` is cancellation-aware, so queued pushes run regardless, and an unchained end can be delivered ahead of one of them:

```swift
    func end() {
        guard let activity else { return }
        self.activity = nil
        let final = lastPayload ?? RideActivityPayload(clock: .running(anchor: Date()))
        lastPayload = nil
        lastPushedAt = nil

        let previous = pushChain
        pushChain = nil
        Task { @MainActor in
            // Drain what is already queued, so the end is the last thing the activity sees.
            await previous?.value
            await activity.end(
                ActivityContent(state: RideActivityAttributes.ContentState(payload: final),
                                staleDate: nil),
                dismissalPolicy: .immediate)
        }
    }
```

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
- Modify: `Aura/Widgets/RideActivityComponents.swift`
- Modify: `Aura/Widgets/RideLiveActivity.swift` (`:49`, `:94`, `:100`, `:121`)
- Modify: `Aura/Widgets/RideLockScreenView.swift` (`:45`, `:87`)

**Interfaces:**
- Consumes: `ContentState.activeClock(startedAt:)` (Task 5).
- Produces: `RideTimerStatCell(clock:label:)`; `rideActivityClockAnchor(_:)`; `rideActivityClockLabel(_:running:)`.

- [ ] **Step 1: Add the imports**

`Aura/Widgets/RideActivityComponents.swift`, `RideLiveActivity.swift` and `RideLockScreenView.swift` all import only SwiftUI/WidgetKit/ActivityKit/AuraKit. There is no `@_exported import` in `AuraCore/Sources`, so each file that names `RideActiveClock` or `PauseControlCopy` needs its own:

```swift
import AuraCore
```

- [ ] **Step 2: Rewrite `RideTimerStatCell` and add the two helpers**

In `RideActivityComponents.swift`:

```swift
/// The date to hand `Text(_, style: .timer)`: the active-time anchor while running, the stop's
/// own instant while paused.
func rideActivityClockAnchor(_ clock: RideActiveClock) -> Date {
    switch clock {
    case .running(let anchor): anchor
    case .paused(let since, _): since
    }
}

/// The label under the clock. A paused clock is not reporting elapsed ride time and must not keep
/// claiming to — the expanded Dynamic Island has no status pill, so this label is that
/// presentation's only paused signal.
func rideActivityClockLabel(_ clock: RideActiveClock, running: String) -> String {
    clock.isPaused ? PauseControlCopy.stateChipLabel : running
}

/// The clock cell. Running, it is a self-ticking active-time clock the system renders on-device,
/// so elapsed stays live without the app pushing every second. Paused, it counts *up* from the
/// instant of the stop — still OS-rendered, so it keeps moving even when the app is suspended or
/// dead, and answers the one question a stopped rider has: how long have I been stopped.
///
/// Mint marks the live running value; paused drops to secondary, because a paused clock is not
/// reporting the ride.
struct RideTimerStatCell: View {
    let clock: RideActiveClock
    let label: String
    var size: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rideActivityClockAnchor(clock), style: .timer)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(clock.isPaused ? AuraTheme.textSecondary : AuraTheme.accent)
                .lineLimit(1)
            Text(rideActivityClockLabel(clock, running: label))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuraTheme.textSecondary)
        }
    }
}
```

- [ ] **Step 3: Move all five call sites**

`RideLockScreenView.swift:45` and `:87`, both currently `RideTimerStatCell(start: attributes.startedAt, label: "TIME")`:

```swift
                RideTimerStatCell(clock: state.activeClock(startedAt: attributes.startedAt),
                                  label: "TIME")
```

`RideLiveActivity.swift:121` — the same substitution using `context.state` and `context.attributes.startedAt`.

In `RideLiveActivity.dynamicIsland`, bind the clock alongside the existing `nav` / `imminent` / `accent`, and pass it into `expandedTrailing` and `expandedBottom` as a parameter:

```swift
        let clock = context.state.activeClock(startedAt: context.attributes.startedAt)
```

`RideLiveActivity.swift:49` (compact trailing, free ride) — note this slot has no label channel, so the paused read comes from the tint plus `pause.fill` in compact **leading** (Task 9):

```swift
                Text(rideActivityClockAnchor(clock), style: .timer)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(clock.isPaused ? AuraTheme.textSecondary : AuraTheme.accent)
                    .frame(maxWidth: 56)
```

`RideLiveActivity.swift:94` (expanded trailing, free ride) — same anchor substitution, and its `Text("ELAPSED")` at `:100`:

```swift
                Text(rideActivityClockLabel(clock, running: "ELAPSED"))
```

- [ ] **Step 4: Verify no call site was missed**

Run: `grep -rn "startedAt, style: .timer\|start: attributes.startedAt\|start: context.attributes.startedAt" Aura/Widgets/`
Expected: no matches. Five sites moved; the parent spec's count of three missed both Lock Screen ones.

- [ ] **Step 5: Build**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds clean.

- [ ] **Step 6: Lint and commit**

```bash
swiftlint --quiet
git add Aura/Widgets
git commit -m "feat(roh-102): all five widget clock sites render the active clock"
```

---

### Task 9: The paused treatment, on both modes and every presentation

**Files:**
- Modify: `Aura/Widgets/RideActivityComponents.swift` (`RideStatusPill`, `rideActivityIsImminent`, glyph helper)
- Modify: `Aura/Widgets/RideLiveActivity.swift` (`:26`, `:40`, `:56`, `:67`)
- Modify: `Aura/Widgets/RideLockScreenView.swift` (`:42`, `:57-58`, `:64`, `:68`, `:83`, `:99-100`, `:125`)

**Interfaces:**
- Consumes: `ContentState.isPaused` (Task 5).
- Produces: `RideStatusPill(isPaused:isStale:)`; `rideActivityIsImminent(_:isPaused:)`; `rideActivityGlyph(nav:paused:stale:turnGlyph:)`.

- [ ] **Step 1: Compose paused and stale in the pill**

Replace `RideStatusPill`. Note `isPaused` has **no default** — a default would let a missed call site compile silently:

```swift
/// The Lock Screen's state word. Paused and stale **compose** rather than one masking the other:
/// a jetsam kill during a pause is likely by construction, nothing ends the orphan until ROH-124
/// ships, and a killed ride wearing a confident PAUSED is how a rider reads "still paused, good",
/// rides home, and records none of it (spec D6).
struct RideStatusPill: View {
    let isPaused: Bool
    let isStale: Bool

    var body: some View {
        switch (isPaused, isStale) {
        case (true, true):
            pill("\(PauseControlCopy.stateChipLabel) · NOT UPDATING")
        case (true, false):
            pill(PauseControlCopy.stateChipLabel)
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

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(AuraTheme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}
```

Both call sites take `isPaused` **first**, matching the memberwise order — `RideStatusPill(isStale:isPaused:)` will not compile:

- `RideLockScreenView.swift:83` → `RideStatusPill(isPaused: state.isPaused, isStale: context.isStale)`
- `RideLockScreenView.swift:125` → same, inside `header(title:glyph:imminent:)`; thread `isPaused` in as a parameter.

- [ ] **Step 2: Suppress the imminent cue while paused**

```swift
/// Paused suppresses it: pausing within 150 m of a turn — at the junction, at the light, at the
/// shop just before it — would otherwise leave the app's single most urgent cue, a solid mint
/// fill, burning on a ride that is recording nothing.
func rideActivityIsImminent(_ turnDistanceMeters: Double?, isPaused: Bool) -> Bool {
    guard !isPaused, let d = turnDistanceMeters else { return false }
    return d <= rideActivityImminentMeters
}
```

Both call sites — `RideLiveActivity.swift:26` and `RideLockScreenView.swift:64` — pass `isPaused:`.

- [ ] **Step 3: Swap the identity glyph in both modes, and degrade it when stale**

```swift
/// `pause.fill` outranks both the maneuver arrow and the bicycle: what the rider needs from a
/// glance at a paused activity is that it is paused.
///
/// The stale variant exists because `RideStatusPill` is Lock-Screen-only. Without it, a rider in
/// another app after a jetsam kill sees `pause.fill` beside a still-counting timer indefinitely —
/// D6's failure on the presentation reached without unlocking. Minimal is a single glyph, so a
/// glyph is the only channel it has.
func rideActivityGlyph(nav: Bool, paused: Bool, stale: Bool, turnGlyph: String?) -> String {
    if paused { return stale ? "pause.trianglebadge.exclamationmark" : "pause.fill" }
    return nav ? (turnGlyph ?? "arrow.turn.up.right") : "bicycle"
}
```

Apply at every glyph site, both modes:

- `RideLiveActivity.swift:40` (compact **leading** — earlier revisions mislabelled this compact trailing) and `:56` (minimal):

```swift
            Image(systemName: rideActivityGlyph(nav: nav, paused: context.state.isPaused,
                                                stale: context.isStale,
                                                turnGlyph: context.state.turnGlyphSystemName))
                .foregroundStyle(accent)
```

- `RideLiveActivity.swift:67` (expanded leading) — same helper into `AuraGlyph(systemName:)`.
- `RideLockScreenView.swift:42` — the free-ride `header(glyph:)` call.
- **`RideLockScreenView.swift:68`** — the navigate layout builds its own `AuraGlyph` and is **not** routed through `header`, so a treatment applied only at `:42` leaves the paused navigate rider looking at a turn arrow. This is the single easiest site to miss:

```swift
                AuraGlyph(systemName: rideActivityGlyph(nav: true, paused: state.isPaused,
                                                        stale: context.isStale,
                                                        turnGlyph: state.turnGlyphSystemName),
                          imminent: imminent, size: 38)
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

- [ ] **Step 5: Verify no call site was missed**

Run: `grep -rn "RideStatusPill(\|rideActivityIsImminent(\|AuraGlyph(systemName:" Aura/Widgets/`
Expected: every `RideStatusPill(` passes `isPaused:` first; every `rideActivityIsImminent(` passes `isPaused:`; every free-ride/navigate identity `AuraGlyph` goes through `rideActivityGlyph`. The compiler enforces the first two; the third is by inspection.

- [ ] **Step 6: Build**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme for an iOS simulator.
Expected: builds clean.

- [ ] **Step 7: Lint and commit**

```bash
swiftlint --quiet
git add Aura/Widgets
git commit -m "feat(roh-102): paused treatment across both modes and every presentation"
```

---

### Task 10: Full suite, then the device pass

- [ ] **Step 1: Run the whole package suite**

Run: `cd AuraCore && swift test`
Expected: PASS on **both** totals, at or above the 223 XCTest / 780 Swift Testing baseline.

- [ ] **Step 2: Lint the whole repo**

Run: `swiftlint` from the repo root. Expected: no violations.

- [ ] **Step 3: Build app and widget**

Delegate to the `apple-platform-build-tools:builder` subagent: build the `Aura` scheme and confirm `AuraWidgets` builds.

- [ ] **Step 4: Device pass (spec D10)**

On a real phone. Record each outcome in the PR body:

1. Ride, pause, resume — the clock reports active time after the resume, not wall-clock and not a value that jumped.
2. The paused Lock Screen and both Dynamic Island presentations read as paused at arm's length, in free ride **and** navigate, including a pause within 150 m of a turn (the imminent-cue suppression). **Look hardest at compact trailing**, which changes quantity with no label to say so.
3. `PAUSED · NOT UPDATING` at 375 pt: it shares a row with a 30 pt cockpit numeral and a `lineLimit(1)` instruction behind `Spacer(minLength: 0)`. The instruction has no `minimumScaleFactor` and may truncate — this repo has a documented SE-fit lesson from ROH-57.
4. Leading-zero shape of the paused counting-up timer against the cockpit chip.
5. VoiceOver on the paused Lock Screen announces paused, not "in progress".
6. **The runtime measurement:** a forty-minute backgrounded pause with a log line per emitted push, to settle whether the ticker survives. This is spec D8's open question and it informs Slice B.
7. An activity started on the previous build with the new build installed over it. **Expected: a permanently wall-clock activity**, not a recovered one — the process is gone and orphan recovery is ROH-124. Reading a recovery here as the pass condition would invert the result.

- [ ] **Step 5: Commit any device-pass fixes separately**

```bash
git commit -m "fix(roh-102): device pass findings"
```

---

## Self-Review

**Spec coverage.** D1 → Tasks 1, 8. D2 → Tasks 2, 5. D3 → Tasks 1, 4, and the coordinator-wiring stability test in Task 6. D4 → Tasks 3, 7. D5 → Task 7. D6 → Task 9. D7 → Tasks 8, 9. D8 → Task 3's uniform stale window and Task 10 step 4.6. D9 is a recorded cost with no code. D10 → every task's test steps plus Task 10.

**Invariant coverage.** 1 → `pausedIsStableAcrossTicks`, `runningIsStableAcrossTicks`, and `thePausedClockIsIdenticalAcrossTwentyTicks` (the wiring). 2 → `anchorClampedToNow`. 3 → structural in the decision type; the assignment site is in an untestable file. 4 → structural. 5 → structural, via the private memberwise init. 6 → doc comment only, honestly named. 7 → `thePausePushPrecedesTheCheckpointFlush`.

**Type consistency.** `RideActiveClock.make(startedAt:pausedSeconds:pausedSince:now:)` — Task 1, called in Task 6. `RideActivityPayload.holdingTurn(from:)` — Task 2, called in Task 7. `RideActivityPushPolicy.decide(last:next:lastPushedAt:now:)` and `staleInterval` — Task 3, called in Tasks 5, 6, 7. `ContentState.init(payload:)`, `.isPaused`, `.activeClock(startedAt:)` — Task 5, called in Tasks 6, 7, 8, 9. `rideActivityClockAnchor`, `rideActivityClockLabel` — Task 8. `rideActivityGlyph(nav:paused:stale:turnGlyph:)`, `rideActivityIsImminent(_:isPaused:)`, `RideStatusPill(isPaused:isStale:)` — Task 9.

**Build integrity.** Every commit leaves the app target compiling: Task 5 changes `ContentState` and its one caller together; Task 6 changes the seam and its only conformer together.

**Known gap, deliberate.** `ContentState`'s own `Codable` decode has no automated test and cannot have one (spec D2). Task 5 reduces it to a total projection behind a private initializer; Task 10 step 4.7 covers it on device.
