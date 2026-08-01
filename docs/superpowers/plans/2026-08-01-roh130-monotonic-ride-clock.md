# Monotonic Ride Clock (ROH-130) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure every ride duration with a monotonic clock so a system clock step cannot move the rider's active time, paused chip, Lock Screen clock, or saved ride.

**Architecture:** A `RideInstant` value pairs one wall-clock `Date` with one `ContinuousClock` reading, and every recorder boundary takes that pair instead of a bare `Date`. Durations come from the monotonic half; persisted and displayed stamps come from the wall half and are never mutated in place. The Live Activity's two anchors are built from stamps plus a discretely-updated `wallOffset`, so they stay byte-identical between events and the push dedupe survives.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM package `AuraCore` (targets `AuraCore` and `AuraKit`), Xcode app target `Aura`, ActivityKit.

**Spec:** `docs/superpowers/specs/2026-08-01-roh130-monotonic-ride-clock-design.md`

## Global Constraints

- Package platforms are `.iOS(.v17), .macOS(.v14)` (`AuraCore/Package.swift:6`). `ContinuousClock` and `InstantProtocol.duration(to:)` are iOS 16 / macOS 13, so **no `@available` gate is needed and none may be added**.
- `AuraCore` must not import `AuraKit`. The `AuraCoreTests` target does **not** import `AuraKit`, so no AuraKit test helper can be used from it.
- `AuraKit` builds on the macOS CI host. Anything iOS-only stays behind `#if os(iOS)`.
- Active time has exactly one definition, `RideDuration.activeSeconds`, enforced by `scripts/check-single-active-definition.sh` (run by CI at `.github/workflows/ci.yml:197` and by `.claude/agent-gate.sh:86`).
- `RideActiveClock` is `Codable` inside `RideActivityAttributes.ContentState`. **Do not rename a case or an associated-value label** — an activity in flight across an app update is decoded by a new binary from bytes an old one wrote, and a rename strands it on its last rendered frame. Adding a *type* used only as a parameter is fine; changing the enum's own shape is not.
- SwiftLint runs `--strict`. Keep functions and files within the configured limits; if `RideRecorder.swift` trips a length rule, extract the clock arithmetic into `RideRecorder+Clock.swift` rather than raising the limit.
- Clock step threshold: **2 seconds**, one named constant, used in exactly one place.
- Run the package suite with `swift test --package-path AuraCore`. Note it prints **two** totals (one per test target) — read both.

## File Structure

**Created**

- `AuraCore/Sources/AuraCore/Ride/RideInstant.swift` — the paired reading, the process-wide monotonic origin, and the `RideClocking` seam. The only file allowed to construct a `RideInstant` from parts inside `Sources/`.
- `scripts/check-monotonic-instants.sh` — build gate: no fabricated pairs outside that file.
- `AuraCore/Tests/AuraCoreTests/RideInstantTests.swift`
- `AuraCore/Tests/AuraKitTests/Support/RideClockTestSupport.swift` — `RideInstant.coherent`/`.stepped`, `FakeRideClock`, and the `Date`-taking overloads that keep the existing suites compiling.
- `AuraCore/Tests/AuraKitTests/RideClockStepTests.swift` — the recorder-level step fixtures.
- `AuraCore/Tests/AuraKitTests/RideSessionClockStepTests.swift` — the coordinator-level step fixtures.

**Modified**

- `AuraCore/Sources/AuraCore/Ride/RideDuration.swift` — new `activeSeconds` signature, new `runningAnchor`.
- `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift` — `make` takes a `RideOpenStop?`; anchors stop depending on `now`.
- `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift` — `decide` takes `secondsSinceLastPush`.
- `AuraCore/Sources/AuraKit/RideRecorder.swift` — monotonic durations, `wallOffset`, derived `endedAt`.
- `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` — `RideClocking` seam, `RideInstant` throughout, clamp removal.
- `Aura/Sources/LiveActivity/RideLiveActivityController.swift` — monotonic push bookkeeping.
- `scripts/check-single-active-definition.sh` — second detector.
- `.github/workflows/ci.yml`, `.claude/agent-gate.sh` — wire the new guard.
- Test suites listed per task.

---

### Task 1: `RideInstant`, the clock seam, and its build guard

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideInstant.swift`
- Create: `AuraCore/Tests/AuraCoreTests/RideInstantTests.swift`
- Create: `scripts/check-monotonic-instants.sh`
- Modify: `.github/workflows/ci.yml:196` (add a step after the single-active-definition guard)
- Modify: `.claude/agent-gate.sh:86` (add a `run` line in the same `if has '\.swift$'` block)

**Interfaces:**
- Produces: `RideInstant.init(date:monotonicSeconds:)`, `RideInstant.now`, `RideInstant.date`, `RideInstant.monotonicSeconds`, `protocol RideClocking { func now() -> RideInstant }`, `struct SystemRideClock: RideClocking`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraCoreTests/RideInstantTests.swift`:

```swift
import Foundation
import Testing
@testable import AuraCore

@Suite struct RideInstantTests {
    @Test func nowAdvancesMonotonicallyAndCarriesAWallDate() {
        let a = RideInstant.now
        let b = RideInstant.now
        #expect(b.monotonicSeconds >= a.monotonicSeconds)
        // Sanity that the wall half is a real Date and not a stub: within a day of the test run.
        #expect(abs(a.date.timeIntervalSinceNow) < 86_400)
    }

    /// The origin is process-wide and taken at first use, so a production reading is a small
    /// number. The test shim in AuraKitTests uses `timeIntervalSinceReferenceDate` (~8e8), and
    /// mixing the two conventions inside one recorder is the failure this pins the shape against.
    @Test func nowIsMeasuredFromAProcessLifetimeOrigin() {
        #expect(RideInstant.now.monotonicSeconds < 86_400)
    }

    @Test func systemRideClockReturnsNow() {
        let before = RideInstant.now
        let read = SystemRideClock().now()
        #expect(read.monotonicSeconds >= before.monotonicSeconds)
    }

    @Test func partsAreCarriedVerbatim() {
        let d = Date(timeIntervalSinceReferenceDate: 1_000)
        let i = RideInstant(date: d, monotonicSeconds: 42)
        #expect(i.date == d)
        #expect(i.monotonicSeconds == 42)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideInstantTests`
Expected: FAIL to compile — "cannot find 'RideInstant' in scope".

- [ ] **Step 3: Write the implementation**

Create `AuraCore/Sources/AuraCore/Ride/RideInstant.swift`:

```swift
import Foundation

/// One instant, read on both clocks that matter.
///
/// `date` is civil time: it is what gets persisted, displayed, and handed to the OS timer, and iOS
/// moves it (NTP, NITZ, a manual change). `monotonicSeconds` is a reading that only ever moves
/// forward at a real-time rate. **Every duration in the ride path is a difference of
/// `monotonicSeconds`; nothing subtracts two `date`s** (ROH-130).
///
/// One value rather than two parameters so a caller cannot hand a boundary a mismatched pair.
public struct RideInstant: Equatable, Sendable {
    public let date: Date
    /// Seconds since an arbitrary origin taken once per process. **Only ever subtracted from
    /// another reading taken in the same process run** — the origin does not survive a relaunch,
    /// which is a constraint on ROH-144's eventual resume-across-relaunch work.
    public let monotonicSeconds: TimeInterval

    public init(date: Date, monotonicSeconds: TimeInterval) {
        self.date = date
        self.monotonicSeconds = monotonicSeconds
    }

    public static var now: RideInstant {
        RideInstant(date: Date(), monotonicSeconds: elapsedSinceOrigin())
    }

    /// `ContinuousClock` and not `SuspendingClock`: on Darwin this is `mach_continuous_time`, which
    /// keeps advancing while the machine sleeps. A phone in a jersey pocket with the screen locked
    /// is exactly where a suspending clock under-counts, and a ride clock that loses the sleeping
    /// minutes is a worse bug than the one this fixes. `ProcessInfo.systemUptime` is out for the
    /// same reason — it is documented as time *awake* since restart.
    ///
    /// A reboot needs no handling: it terminates the process, so the origin is re-taken.
    private static let origin = ContinuousClock.now

    /// `Duration` has no `TimeInterval` bridge, so the conversion is explicit. Both components
    /// carry the sign, so this is also correct for a negative duration.
    private static func elapsedSinceOrigin() -> TimeInterval {
        let c = origin.duration(to: ContinuousClock.now).components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}

/// The ride path's source of instants.
///
/// A seam rather than a bare `RideInstant.now` call because `RideSessionCoordinator` reads the
/// clock from inside `start`, `pause`, `resume` and `finish`, where a test cannot inject one. A
/// test that injects instants into some entry points and lets others read the real clock puts two
/// different monotonic origins into one recorder and computes durations of tens of millions of
/// seconds — while `>=`-shaped assertions keep passing.
///
/// Not `Sendable`-constrained: every consumer is `@MainActor`, and requiring `Sendable` would push
/// test fakes into `@unchecked`.
public protocol RideClocking {
    func now() -> RideInstant
}

public struct SystemRideClock: RideClocking {
    public init() {}
    public func now() -> RideInstant { .now }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path AuraCore --filter RideInstantTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write the build guard**

Create `scripts/check-monotonic-instants.sh`:

```bash
#!/usr/bin/env bash
# A `RideInstant` may only be fabricated from parts in one place.
#
# The whole point of the type is that its two halves were read at the same instant on two real
# clocks. Anything under Sources/ that builds one from a `Date` is inventing a monotonic reading
# from a wall clock, which silently reintroduces ROH-130 while the types still line up. Tests do
# exactly that on purpose, which is why this scans Sources/ only.
set -euo pipefail
cd "$(dirname "$0")/.."

SCAN_ROOTS=(AuraCore/Sources Aura/Sources Aura/Widgets)
OWNER='AuraCore/Sources/AuraCore/Ride/RideInstant.swift'

# The tell is the label, not the type name: `.init(date:monotonicSeconds:)` and
# `RideInstant(date:monotonicSeconds:)` both carry it, and nothing else in the tree uses it.
detect() { sed -E 's|//.*$||' | grep -E 'monotonicSeconds:' || true; }

self_test() {
  local bad='x.swift:1:  let i = RideInstant(date: d, monotonicSeconds: d.timeIntervalSinceReferenceDate)'
  [ -n "$(printf '%s\n' "$bad" | detect)" ] || { echo "SELF-TEST FAIL: missed a fabricated pair"; exit 2; }
  local bad_init='x.swift:1:  let i: RideInstant = .init(date: d, monotonicSeconds: 0)'
  [ -n "$(printf '%s\n' "$bad_init" | detect)" ] || { echo "SELF-TEST FAIL: missed a .init form"; exit 2; }
  local ok='x.swift:1:  // monotonicSeconds: only RideInstant.swift may build one'
  [ -z "$(printf '%s\n' "$ok" | detect)" ] || { echo "SELF-TEST FAIL: flagged a comment"; exit 2; }
  local ok_read='x.swift:1:  let s = instant.monotonicSeconds - start'
  [ -z "$(printf '%s\n' "$ok_read" | detect)" ] || { echo "SELF-TEST FAIL: flagged a property read"; exit 2; }
}

self_test

for root in "${SCAN_ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    echo "FAIL: scan root '$root' does not exist — check-monotonic-instants.sh is stale"
    exit 1
  fi
done

if [ ! -f "$OWNER" ]; then
  echo "FAIL: '$OWNER' does not exist — check-monotonic-instants.sh is stale"
  exit 1
fi

offenders=$(grep -rn 'monotonicSeconds:' --include='*.swift' "${SCAN_ROOTS[@]}" \
  | grep -v "^${OWNER}:" | detect || true)

if [ -n "$offenders" ]; then
  echo "FAIL: a RideInstant may only be built from parts in ${OWNER}. Built at:"
  echo "$offenders"
  exit 1
fi

echo "PASS: no fabricated RideInstant outside ${OWNER} (self-test OK)."
```

- [ ] **Step 6: Wire the guard and verify it passes**

`chmod +x scripts/check-monotonic-instants.sh`.

In `.github/workflows/ci.yml`, directly after the `Single active-time definition guard` step:

```yaml
      - name: Monotonic instant guard
        run: bash scripts/check-monotonic-instants.sh
```

In `.claude/agent-gate.sh`, directly after the `single active-time definition` block:

```bash
if has '\.swift$'; then
  run "monotonic instant guard" . bash scripts/check-monotonic-instants.sh
fi
```

Run: `bash scripts/check-monotonic-instants.sh`
Expected: `PASS: no fabricated RideInstant outside ... (self-test OK).`

- [ ] **Step 7: Commit**

```bash
git add AuraCore/Sources/AuraCore/Ride/RideInstant.swift AuraCore/Tests/AuraCoreTests/RideInstantTests.swift scripts/check-monotonic-instants.sh .github/workflows/ci.yml .claude/agent-gate.sh
git commit -m "feat(roh-130): a paired wall/monotonic ride instant and its clock seam"
```

---

### Task 2: `RideDuration` takes elapsed seconds, and gains the running anchor

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideDuration.swift:62-82`
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift:43`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:224`
- Modify: `Aura/Sources/Ride/ShareCard/ShareCardView.swift` (one `activeSeconds` call — locate with `grep -n activeSeconds`)
- Test: `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift:77,79`
- Test: `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift:39,57,67`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `RideDuration.activeSeconds(elapsedSeconds: TimeInterval, pausedSeconds: TimeInterval) -> TimeInterval` and `RideDuration.runningAnchor(startedAt: Date, pausedSeconds: TimeInterval, now: Date) -> Date`.

This task is behavior-preserving: every caller keeps computing elapsed from the same wall pair it uses today. Only the shape moves.

- [ ] **Step 1: Write the failing tests**

Append to `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift`:

```swift
    @Test func activeIsElapsedLessPaused() {
        #expect(RideDuration.activeSeconds(elapsedSeconds: 100, pausedSeconds: 30) == 70)
    }

    @Test func activeFloorsAtZeroRatherThanGoingNegative() {
        #expect(RideDuration.activeSeconds(elapsedSeconds: 10, pausedSeconds: 30) == 0)
    }

    /// The Lock Screen's running anchor. `Text(_, style: .timer)` counts DOWN from a future
    /// anchor, so it is clamped to `now`.
    @Test func runningAnchorIsTheStartPlusPausedTime() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = Date(timeIntervalSinceReferenceDate: 1_600)
        #expect(RideDuration.runningAnchor(startedAt: start, pausedSeconds: 120, now: now)
                == Date(timeIntervalSinceReferenceDate: 1_120))
    }

    @Test func runningAnchorNeverSitsInTheFuture() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = Date(timeIntervalSinceReferenceDate: 1_050)
        #expect(RideDuration.runningAnchor(startedAt: start, pausedSeconds: 120, now: now) == now)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideDurationTests`
Expected: FAIL to compile — no `activeSeconds(elapsedSeconds:pausedSeconds:)`, no `runningAnchor`.

- [ ] **Step 3: Change the primitive**

In `RideDuration.swift`, replace the `activeSeconds` declaration (currently lines 79-82) and add the anchor. Keep the existing doc comment above `activeSeconds` and edit its last paragraph as shown:

```swift
    /// **The one definition of active time**: elapsed time less time spent paused.
    ///
    /// Every clock calls this and nothing re-derives it — the HUD's live number
    /// (`RideSessionCoordinator.refreshElapsed`), the value frozen at a pause
    /// (`RideRecorder.pause(at:)`), and the finished ride's (`init` above). Parent spec D5 makes
    /// their agreement a product requirement: the rider must see the same clock after the ride
    /// that they watched during it. `scripts/check-single-active-definition.sh` is what keeps that
    /// true.
    ///
    /// **`elapsedSeconds` must come from the same clock as `pausedSeconds`.** The live callers pass
    /// `RideRecorder.elapsedSeconds(asOf:)`, which is monotonic; `init` above passes a wall pair,
    /// which is monotonic too because `RideRecorder.end(at:)` derives `endedAt` from the monotonic
    /// elapsed (ROH-130 D3). Mixing them is the new way to get this wrong, and the guard script has
    /// a detector for it.
    public static func activeSeconds(elapsedSeconds: TimeInterval,
                                     pausedSeconds: TimeInterval) -> TimeInterval {
        max(0, elapsedSeconds - pausedSeconds)
    }

    /// Where the Live Activity's running timer counts up from.
    ///
    /// Lives here, and not in `RideActiveClock`, because the expression it needs is
    /// `addingTimeInterval(pausedSeconds)` and this file is the guard script's only exemption.
    ///
    /// Deliberately built from stamps rather than as `now - activeSeconds`: both inputs move only
    /// at a pause boundary, so the anchor is byte-identical between boundaries and the Live
    /// Activity's push dedupe survives (ROH-130 D5). The `min` keeps a future anchor off the Lock
    /// Screen — `Text(_, style: .timer)` counts DOWN from one. While the clamp binds, the anchor
    /// tracks `now` and costs a push per coalescing interval.
    public static func runningAnchor(startedAt: Date, pausedSeconds: TimeInterval,
                                     now: Date) -> Date {
        min(now, startedAt.addingTimeInterval(pausedSeconds))
    }
```

Then update `init`'s call (currently lines 62-64):

```swift
        activeSeconds = RideDuration.activeSeconds(
            elapsedSeconds: elapsed,
            pausedSeconds: max(0, pausedSeconds))
```

- [ ] **Step 4: Update the two in-tree callers, behavior-preserving**

`RideActiveClock.swift:43` becomes:

```swift
        let activeSeconds = RideDuration.activeSeconds(
            elapsedSeconds: now.timeIntervalSince(startedAt), pausedSeconds: pausedSeconds)
```

`RideSessionCoordinator.swift:224` becomes:

```swift
        elapsed = RideDuration.activeSeconds(
            elapsedSeconds: now.timeIntervalSince(startedAt),
            pausedSeconds: recorder.pausedSeconds(asOf: now))
```

Both are temporary and are replaced in Tasks 3 and 4. **Do not add the guard script's second detector yet** — it would reject exactly these two lines.

For `ShareCardView.swift`, run `grep -n 'activeSeconds' Aura/Sources/Ride/ShareCard/ShareCardView.swift`. If it calls the primitive, convert the same way; if it reads `ride.duration?.activeSeconds`, leave it alone.

- [ ] **Step 5: Update the two AuraCore test suites**

In `RideDurationTests.swift:77,79` and `ActiveTimeAgreementTests.swift:39,57,67`, replace each
`RideDuration.activeSeconds(startedAt: X, asOf: Y, pausedSeconds: Z)` with
`RideDuration.activeSeconds(elapsedSeconds: Y.timeIntervalSince(X), pausedSeconds: Z)`.
Do not change any expected value — this is a pure re-spelling and every assertion must still hold.

- [ ] **Step 6: Run the full package suite**

Run: `swift test --package-path AuraCore`
Expected: PASS, both target totals, no assertion changes.

Run: `bash scripts/check-single-active-definition.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add AuraCore Aura/Sources/Ride/ShareCard/ShareCardView.swift
git commit -m "refactor(roh-130): RideDuration takes elapsed seconds and owns the running anchor"
```

---

### Task 3: The recorder measures monotonically

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideRecorder.swift`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (call sites only; the seam lands in Task 5)
- Create: `AuraCore/Tests/AuraKitTests/Support/RideClockTestSupport.swift`
- Create: `AuraCore/Tests/AuraKitTests/RideClockStepTests.swift`

**Interfaces:**
- Consumes: `RideInstant` from Task 1; `RideDuration.activeSeconds(elapsedSeconds:pausedSeconds:)` from Task 2.
- Produces, all on `RideRecorder`:
  - `start(at: RideInstant)`, `pause(at: RideInstant)`, `resume(at: RideInstant)`
  - `end(at: RideInstant, destinationName: String?) -> Ride`, `checkpoint(at: RideInstant, destinationName: String?) -> Ride`
  - `pausedSeconds(asOf: RideInstant) -> TimeInterval`, `currentPauseSeconds(asOf: RideInstant) -> TimeInterval`, `elapsedSeconds(asOf: RideInstant) -> TimeInterval`
  - `align(at: RideInstant)`, `var anchorStartedAt: Date?`, `var anchorPausedSince: Date?`, `var activeSecondsAtPause: TimeInterval?`
- Also produces, for tests: `RideInstant.coherent(_:)`, `RideInstant.stepped(_:by:)`, and `Date`-taking overloads of every boundary above.

- [ ] **Step 1: Write the test support**

Create `AuraCore/Tests/AuraKitTests/Support/RideClockTestSupport.swift`:

```swift
import Foundation
import AuraCore
@testable import AuraKit

extension RideInstant {
    /// A pair with no clock step: the monotonic reading *is* the wall reading, so any two
    /// `coherent` instants differ by the same amount on both clocks.
    ///
    /// Every pre-ROH-130 test drove time with bare `Date`s and meant exactly this, so the `Date`
    /// overloads below route through it and those suites keep asserting what they asserted.
    ///
    /// **One convention per recorder.** `FakeRideClock` below produces the same shape, which is
    /// what lets a test call `coordinator.pause()` and `coordinator.refreshElapsed(now: someDate)`
    /// and get a coherent stop. Mixing this with `RideInstant.now` — whose origin is
    /// process-lifetime, roughly 8e8 seconds away — yields durations in the tens of millions.
    static func coherent(_ date: Date) -> RideInstant {
        RideInstant(date: date, monotonicSeconds: date.timeIntervalSinceReferenceDate)
    }

    /// A pair whose wall half has stepped `by` seconds relative to the monotonic timeline —
    /// what an NTP or NITZ correction does mid-ride. Negative steps the clock backwards.
    ///
    /// `date` is the *unstepped* wall reading, so a fixture reads as "the timeline is here, and
    /// the system clock now disagrees by this much".
    static func stepped(_ date: Date, by seconds: TimeInterval) -> RideInstant {
        RideInstant(date: date.addingTimeInterval(seconds),
                    monotonicSeconds: date.timeIntervalSinceReferenceDate)
    }
}

/// A `RideClocking` a test drives by hand. Shares `coherent`'s convention, so instants it hands
/// the coordinator internally and instants a test injects through a `Date` overload are on one
/// timeline.
final class FakeRideClock: RideClocking {
    /// The monotonic timeline's current position, expressed as a `Date`.
    var date: Date
    /// Wall-clock divergence from that timeline. Set this to simulate a system clock step.
    var step: TimeInterval = 0

    init(date: Date = Date()) { self.date = date }

    func now() -> RideInstant { .stepped(date, by: step) }

    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

// `Date`-taking overloads so the ~133 existing call sites compile unchanged. Test-target only, so
// production cannot fabricate a monotonic reading from a wall clock; `check-monotonic-instants.sh`
// enforces that from the other side.
@MainActor
extension RideRecorder {
    func start(at date: Date) { start(at: .coherent(date)) }
    func pause(at date: Date) { pause(at: .coherent(date)) }
    func resume(at date: Date) { resume(at: .coherent(date)) }
    func pausedSeconds(asOf date: Date) -> TimeInterval { pausedSeconds(asOf: .coherent(date)) }
    func currentPauseSeconds(asOf date: Date) -> TimeInterval {
        currentPauseSeconds(asOf: .coherent(date))
    }
    func elapsedSeconds(asOf date: Date) -> TimeInterval { elapsedSeconds(asOf: .coherent(date)) }
    @discardableResult
    func end(at date: Date, destinationName: String? = nil) -> Ride {
        end(at: .coherent(date), destinationName: destinationName)
    }
    func checkpoint(at date: Date, destinationName: String? = nil) -> Ride {
        checkpoint(at: .coherent(date), destinationName: destinationName)
    }
}
```

- [ ] **Step 2: Write the failing step fixtures**

Create `AuraCore/Tests/AuraKitTests/RideClockStepTests.swift`:

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// A system clock step during a ride must not move any duration. Every fixture states the step it
/// applies and then asserts the step is actually present, so a shim that quietly made the two
/// clocks agree would fail these rather than pass them vacuously (ROH-103's lesson).
@MainActor
@Suite struct RideClockStepTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func startedRecorder() -> RideRecorder {
        let r = RideRecorder()
        r.start(at: .coherent(t0))
        return r
    }

    // MARK: negative controls

    @Test func steppedInstantsActuallyCarryAStep() {
        let plain = RideInstant.coherent(t0.addingTimeInterval(100))
        let stepped = RideInstant.stepped(t0.addingTimeInterval(100), by: -40)
        #expect(stepped.monotonicSeconds == plain.monotonicSeconds)
        #expect(stepped.date.timeIntervalSince(plain.date) == -40)
    }

    /// Pins that fixture `aBackwardStepLongerThanTheStopKeepsTheWholeStop` exercises the defect:
    /// the pre-ROH-130 wall-clock expression over the same readings gives a different answer.
    @Test func theOldWallClockExpressionWouldHaveLostTheStop() {
        let pauseAt = RideInstant.coherent(t0.addingTimeInterval(600))
        let readAt = RideInstant.stepped(t0.addingTimeInterval(610), by: -40)
        let old = max(0, readAt.date.timeIntervalSince(pauseAt.date))
        let new = readAt.monotonicSeconds - pauseAt.monotonicSeconds
        #expect(old == 0)
        #expect(new == 10)
    }

    // MARK: the live clocks

    @Test func aBackwardStepMidStopDoesNotMoveEitherNumber() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        let stepped = RideInstant.stepped(t0.addingTimeInterval(640), by: -40)
        #expect(r.currentPauseSeconds(asOf: stepped) == 40)
        #expect(r.elapsedSeconds(asOf: stepped) == 640)
        #expect(RideDuration.activeSeconds(elapsedSeconds: r.elapsedSeconds(asOf: stepped),
                                           pausedSeconds: r.pausedSeconds(asOf: stepped)) == 600)
    }

    /// The durably wrong case today: the `max(0,)` clamp stops crediting the stop entirely, so the
    /// ride banks a café stop as riding.
    @Test func aBackwardStepLongerThanTheStopKeepsTheWholeStop() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .stepped(t0.addingTimeInterval(610), by: -40))
        #expect(r.pausedSeconds(asOf: .stepped(t0.addingTimeInterval(700), by: -40)) == 10)
    }

    @Test func aForwardStepMidStopDoesNotMoveEitherNumber() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        let stepped = RideInstant.stepped(t0.addingTimeInterval(640), by: 40)
        #expect(r.currentPauseSeconds(asOf: stepped) == 40)
        #expect(r.elapsedSeconds(asOf: stepped) == 640)
    }

    @Test func aStepSpanningAPauseAndAResumeCreditsTheRealStop() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .stepped(t0.addingTimeInterval(900), by: -40))
        #expect(r.pausedSeconds(asOf: .stepped(t0.addingTimeInterval(1_200), by: -40)) == 300)
    }

    // MARK: what gets persisted

    /// The shape revision 1 of the spec missed entirely: a ride with no pause at all calls no
    /// pause-path code, so a fix that only corrected the pause path would leave this wrong.
    @Test func anUnpausedRideWithAStepPersistsTheMonotonicDuration() {
        let r = startedRecorder()
        let ride = r.end(at: .stepped(t0.addingTimeInterval(3_600), by: 40))
        let d = try! #require(ride.duration)
        #expect(d.elapsedSeconds == 3_600)
        #expect(d.activeSeconds == 3_600)
        #expect(ride.startedAt == t0, "the start stamp the rider saw is never rewritten")
        #expect(ride.endedAt == t0.addingTimeInterval(3_600))
    }

    @Test func aPausedRideWithAStepPersistsBothDurations() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .coherent(t0.addingTimeInterval(900)))
        let ride = r.end(at: .stepped(t0.addingTimeInterval(3_600), by: -40))
        let d = try! #require(ride.duration)
        #expect(d.elapsedSeconds == 3_600)
        #expect(d.activeSeconds == 3_300)
        #expect(ride.startedAt == t0)
    }

    /// A checkpoint row must stay disqualified from reporting a duration: its two stamps are one
    /// instant, and `RideDuration.init` keys on `checkpointedAt >= endedAt`.
    @Test func aCheckpointAfterAStepKeepsItsTwoStampsEqual() {
        let r = startedRecorder()
        r.pause(at: .stepped(t0.addingTimeInterval(600), by: -40))
        let row = r.checkpoint(at: .stepped(t0.addingTimeInterval(600), by: -40))
        #expect(row.startedAt == t0)
        #expect(row.checkpointedAt == row.endedAt)
        #expect(row.duration == nil)
    }

    // MARK: the wall offset

    @Test func alignAbsorbsAStepIntoTheAnchorStampsOnly() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(600), by: -40))
        #expect(r.startedAt == t0, "the stored stamp never moves")
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-40))
    }

    @Test func alignIsIdempotent() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(600), by: -40))
        r.align(at: .stepped(t0.addingTimeInterval(601), by: -40))
        r.align(at: .stepped(t0.addingTimeInterval(602), by: -40))
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-40))
    }

    @Test func alignIgnoresDivergenceUnderTheThreshold() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(600), by: 1.9))
        #expect(r.anchorStartedAt == t0)
    }

    @Test func alignShiftsTheOpenStopStampTogetherWithTheStart() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.align(at: .stepped(t0.addingTimeInterval(640), by: -40))
        #expect(r.anchorPausedSince == t0.addingTimeInterval(560))
    }

    @Test func activeSecondsAtPauseIsFrozenForTheLengthOfTheStop() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        let atPause = r.activeSecondsAtPause
        r.align(at: .coherent(t0.addingTimeInterval(1_200)))
        #expect(atPause == 600)
        #expect(r.activeSecondsAtPause == 600)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideClockStepTests`
Expected: FAIL to compile — no `elapsedSeconds(asOf:)`, `align(at:)`, `anchorStartedAt`, `anchorPausedSince`, `activeSecondsAtPause`, and the `RideInstant` overloads do not exist.

- [ ] **Step 4: Rewrite the recorder's clock**

In `RideRecorder.swift`:

Replace the stored-state block (currently lines 52-67) with:

```swift
    /// Paused time from stops that have already ended, measured monotonically. The stop in
    /// progress is added by `pausedSeconds(asOf:)`; nothing else may read this.
    private var closedPausedSeconds: TimeInterval = 0
    /// When the ride started and when the stop in progress began, **on the wall clock**.
    ///
    /// Stamped once each and never rewritten. They are what gets persisted and what History shows,
    /// and a rider reads a ride's start time as its identity — so a clock correction moves the
    /// *durations*, which are measured elsewhere, and leaves these alone (ROH-130 D2).
    ///
    /// On the caller's clock, never the track's. `TrackPoint.timestamp` is a third clock: a
    /// replayed fixture carries the stamps it was recorded with, and a real ride's last accepted
    /// fix can be minutes stale through a tunnel, which would retroactively reclassify those
    /// minutes as paused the instant the rider taps. This is a deliberate departure from spec D6.
    private var pauseStartedAt: Date?
    /// The monotonic partner of each stamp above. Written and cleared in the same statement as its
    /// partner, at the three boundaries that already write them. **Every duration this type
    /// reports is a difference of these**, so no duration can move when civil time does.
    private var startMonotonic: TimeInterval?
    private var pauseStartMonotonic: TimeInterval?
    /// Active time frozen at the instant of the pause.
    ///
    /// Not recomputed per tick. The Live Activity's paused payload carries it, and
    /// `RideActivityPushPolicy` skips a push only when the whole payload is unchanged — so a value
    /// that moved by a rounding error every tick would push every 4 s for the length of a café
    /// stop instead of once a minute (ROH-130 D5).
    public private(set) var activeSecondsAtPause: TimeInterval?
    /// What to add to the stored wall stamps to express them on the *current* system clock.
    ///
    /// Consumed only by `anchorStartedAt` and `anchorPausedSince`, which the Live Activity's two
    /// anchors are built from. The OS renders those anchors against its own wall clock inside the
    /// widget process, so without this a step would leave the Lock Screen off by the step for the
    /// rest of the ride while the cockpit stayed right. Nothing persisted depends on it.
    private var wallOffset: TimeInterval = 0

    /// Below this, a wall/monotonic disagreement is NTP slewing rather than a clock set, and
    /// correcting it would move the Live Activity anchor continuously — which would defeat the
    /// push dedupe the discreteness exists to protect.
    private static let clockStepThreshold: TimeInterval = 2
```

Replace the boundaries and readers:

```swift
    public func start(at instant: RideInstant) {
        segments = [RideSegment(points: [])]
        stats = .zero
        startedAt = instant.date
        startMonotonic = instant.monotonicSeconds
        rideID = UUID()
        state = .recording
        smoother.reset()
        currentSpeedMetersPerSecond = 0
        lastPoint = nil
        closedPausedSeconds = 0
        pauseStartedAt = nil
        pauseStartMonotonic = nil
        activeSecondsAtPause = nil
        wallOffset = 0
    }

    public func pause(at instant: RideInstant) {
        guard state == .recording else { return }
        align(at: instant)
        state = .paused
        // `SpeedSmoother` has no time decay and `currentSpeedMetersPerSecond` is written only in
        // `record()`, so without this a rider who pauses at 25 km/h leaves 25 on the cockpit's
        // largest numeral for the whole stop — and reads `.moving` to the crew (spec D6/D7).
        currentSpeedMetersPerSecond = 0
        // Frozen before the stop opens, so it is active time as of the tap and stays that value.
        activeSecondsAtPause = RideDuration.activeSeconds(
            elapsedSeconds: elapsedSeconds(asOf: instant),
            pausedSeconds: pausedSeconds(asOf: instant))
        pauseStartedAt = instant.date
        pauseStartMonotonic = instant.monotonicSeconds
    }

    public func resume(at instant: RideInstant) {
        guard state == .paused else { return }
        align(at: instant)
        closePause(at: instant)
        state = .recording
        segments.append(RideSegment(points: []))
        smoother.reset()
        lastPoint = nil
        currentSpeedMetersPerSecond = 0
        activeSecondsAtPause = nil
    }

    /// Wall-clock time since the ride started, measured monotonically. Includes time spent paused;
    /// `RideDuration.activeSeconds` is what subtracts that.
    public func elapsedSeconds(asOf instant: RideInstant) -> TimeInterval {
        guard let startMonotonic else { return 0 }
        return max(0, instant.monotonicSeconds - startMonotonic)
    }

    /// Total paused time as of `instant`, including the stop in progress. The live active clock is
    /// `elapsed - pausedSeconds`, so this has to grow *while* the rider is stopped.
    public func pausedSeconds(asOf instant: RideInstant) -> TimeInterval {
        closedPausedSeconds + currentPauseSeconds(asOf: instant)
    }

    /// The stop **in progress** only, or zero when recording — the number the cockpit's chip
    /// shows. `pausedSeconds(asOf:)` is the ride's running total across every stop.
    ///
    /// The `max(0,)` cannot fire on a monotonic input. It stays because it costs nothing and
    /// because a floor here is cheaper to keep than to re-justify.
    public func currentPauseSeconds(asOf instant: RideInstant) -> TimeInterval {
        guard let pauseStartMonotonic else { return 0 }
        return max(0, instant.monotonicSeconds - pauseStartMonotonic)
    }

    /// Note how far the system clock has drifted from this ride's monotonic timeline, and absorb a
    /// genuine step into `wallOffset`.
    ///
    /// An explicit call, never a side effect of a getter: making a read mutate would put the
    /// correctness of `checkpoint(at:)` at the mercy of argument evaluation order. Called once per
    /// ticker tick and at each pause boundary.
    ///
    /// Idempotent — after an update, `expected` recomputes against the new offset and `delta` is
    /// zero, so a step is corrected once rather than compounded per tick.
    public func align(at instant: RideInstant) {
        guard let startedAt else { return }
        let expected = startedAt.addingTimeInterval(wallOffset + elapsedSeconds(asOf: instant))
        let delta = instant.date.timeIntervalSince(expected)
        if abs(delta) > Self.clockStepThreshold { wallOffset += delta }
    }

    /// The ride's start expressed on the *current* system clock, for the Live Activity's running
    /// anchor. Not what gets persisted — see `startedAt`.
    public var anchorStartedAt: Date? { startedAt?.addingTimeInterval(wallOffset) }
    /// The open stop's start on the current system clock, for the Live Activity's paused clock.
    public var anchorPausedSince: Date? { pauseStartedAt?.addingTimeInterval(wallOffset) }

    private func closePause(at instant: RideInstant) {
        guard let pauseStartMonotonic else { return }
        closedPausedSeconds += max(0, instant.monotonicSeconds - pauseStartMonotonic)
        pauseStartedAt = nil
        self.pauseStartMonotonic = nil
    }
```

Rewrite `checkpoint` and `end` so the persisted end instant is derived (spec D3):

```swift
    public func checkpoint(at instant: RideInstant, destinationName: String? = nil) -> Ride {
        let start = startedAt ?? instant.date
        // Derived, not `instant.date`: `endedAt - startedAt` is the ride's elapsed time, and a
        // wall pair spanning a clock step is not (ROH-130 D3). `checkpointedAt` gets the same
        // value so a checkpoint row keeps its two stamps equal, which is what
        // `RideDuration.init`'s `checkpointedAt >= endedAt` disqualifier keys on.
        let ended = start.addingTimeInterval(elapsedSeconds(asOf: instant))
        return Ride(id: rideID, kind: kind, startedAt: start, endedAt: ended,
                    segments: normalizedSegments, stats: stats,
                    pausedSeconds: pausedSeconds(asOf: instant), checkpointedAt: ended,
                    destinationName: destinationName,
                    routeId: nil, destinationPlaceId: nil)
    }

    @discardableResult
    public func end(at instant: RideInstant, destinationName: String? = nil) -> Ride {
        // Bank a stop still in progress, or every ride ended while paused over-reports active time
        // by the length of the tail (spec D6).
        closePause(at: instant)
        let paused = closedPausedSeconds
        let start = startedAt ?? instant.date
        // See `checkpoint(at:)`. After a backward step this sits slightly ahead of the current
        // wall clock; nothing renders `endedAt`, and the alternative is a wrong duration.
        let ended = start.addingTimeInterval(elapsedSeconds(asOf: instant))
        state = .idle
        return Ride(id: rideID, kind: kind, startedAt: start, endedAt: ended,
                    segments: normalizedSegments, stats: stats, pausedSeconds: paused,
                    checkpointedAt: nil,
                    destinationName: destinationName, routeId: nil, destinationPlaceId: nil)
    }
```

Update `pausedSince`'s doc comment (line 26-31) to say it is the stored stamp and that
`anchorPausedSince` is what the Live Activity uses. Delete the ROH-130 paragraph from
`currentPauseSeconds`' old doc comment (lines 142-145) — it is fixed now.

- [ ] **Step 5: Keep the coordinator compiling**

In `RideSessionCoordinator.swift`, wrap each recorder call in an instant. This is scaffolding that Task 5 replaces:

- `start()`: `let now = Date()` stays; add `let instant = RideInstant.now` immediately after and pass `instant` to `recorder.start(at:)`. **`startedAt`, `activity.start(startedAt:)` and everything else keep using `now`.**
- `refreshElapsed`, `pushActivityUpdate`, `pause(at:)`, `resume(at:)`, `flushCheckpoint(at:)`: change the time parameter's type from `Date` to `RideInstant`, drop the `= Date()` defaults so nothing can silently read a real clock, and derive any `Date` a body still needs as `instant.date`.
- The three callers that supply an instant — the public `pause()`, the public `resume()`, and the ticker body — build one with `RideInstant.now` and pass it down. Task 5 replaces those three reads with the injected seam; until then they are the only places in the type that read a clock.
- `finish()`: `recorder.end(at: RideInstant.now, destinationName: destinationName)`.
- Test call sites are covered by the `Date` overloads added in Step 1.
- `flushCheckpoint` must record what it actually wrote:

```swift
        do {
            let row = recorder.checkpoint(at: instant, destinationName: destinationName)
            try saving.save(row)
            // `row.checkpointedAt`, not `instant.date`: the recorder derives the row's stamps, and
            // this property documents itself as the stamp that is on that row.
            pendingCheckpoint = PendingCheckpoint(rideID: row.id,
                                                  at: row.checkpointedAt ?? instant.date)
        } catch { }
```

- Add `recorder.align(at: now)` as the first line of `refreshElapsed`.
- Replace `refreshElapsed`'s body's elapsed computation with:

```swift
        elapsed = RideDuration.activeSeconds(
            elapsedSeconds: recorder.elapsedSeconds(asOf: now),
            pausedSeconds: recorder.pausedSeconds(asOf: now))
```

Add the coordinator `Date` overloads to `RideClockTestSupport.swift` so existing suites compile:

```swift
@MainActor
extension RideSessionCoordinator {
    func refreshElapsed(now date: Date) { refreshElapsed(now: .coherent(date)) }
    func pushActivityUpdate(now date: Date) { pushActivityUpdate(now: .coherent(date)) }
    func pause(at date: Date) { pause(at: .coherent(date)) }
    func resume(at date: Date) { resume(at: .coherent(date)) }
}
```

`pushActivityUpdate` keeps its current body for now; it takes `RideInstant` and passes `now.date` to `RideActiveClock.make` and `now` to `recorder.pausedSeconds(asOf:)`.

**Leave `currentPauseSeconds`' `max(...)` clamp in place in this task.** It is removed in Task 5, where the tests that pin it are retargeted.

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path AuraCore --filter RideClockStepTests`
Expected: PASS, 14 tests.

Run: `swift test --package-path AuraCore`
Expected: PASS, both totals. Any pre-existing suite that now fails is a real behavior change — read it before touching it. The one expected class of change: a test asserting `ride.endedAt == theDatePassedToEnd`. Under `.coherent` instants the derived end is bit-identical to that date, so it should still hold; if one fails, stop and report rather than editing the assertion.

Run: `bash scripts/check-single-active-definition.sh && bash scripts/check-monotonic-instants.sh`
Expected: both PASS.

- [ ] **Step 7: Commit**

```bash
git add AuraCore
git commit -m "fix(roh-130): the recorder measures every duration on a monotonic clock"
```

---

### Task 4: The Live Activity's clock stops depending on `now`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (`pushActivityUpdate`)
- Modify: `scripts/check-single-active-definition.sh` (second detector + self-tests)
- Test: `AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift`
- Test: `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift`

**Interfaces:**
- Consumes: `RideDuration.runningAnchor` (Task 2); `RideRecorder.anchorStartedAt`, `.anchorPausedSince`, `.activeSecondsAtPause` (Task 3).
- Produces: `struct RideOpenStop { let since: Date; let activeSecondsAtPause: TimeInterval }` and
  `RideActiveClock.make(startedAt: Date, pausedSeconds: TimeInterval, openStop: RideOpenStop?, now: Date) -> RideActiveClock`.
- **The `RideActiveClock` enum's own cases and labels are unchanged** — `RideOpenStop` is a parameter type only. See Global Constraints.

- [ ] **Step 1: Write the failing tests**

Append to `AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift`:

```swift
    /// The trap this decision exists for. The pre-fix derivation recomputed `activeSeconds` from a
    /// monotonic elapsed and a wall `now`, which do not cancel — so every tick produced a
    /// numerically distinct payload, `RideActivityPushPolicy` saw `next != last`, and a café stop
    /// pushed every 4 s instead of once a minute.
    ///
    /// Driven at **production magnitude** (a monotonic origin near zero) with tick intervals that
    /// are not exact binary fractions. The old form of this test used `Date`-magnitude readings
    /// and exact half-seconds, where the arithmetic cancels exactly and the test could not fail.
    @Test func thePausedClockIsIdenticalAcrossFortyTicksAtProductionMagnitude() {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let stop = RideOpenStop(since: started.addingTimeInterval(600), activeSecondsAtPause: 600)
        let clocks = (0..<40).map { i in
            RideActiveClock.make(startedAt: started, pausedSeconds: 600, openStop: stop,
                                 now: started.addingTimeInterval(600 + Double(i) * 0.4999997))
        }
        #expect(Set(clocks).count == 1)
    }

    /// Negative control for the test above. If this ever reports 1, that test is not testing
    /// anything and both need rewriting.
    @Test func thePreFixDerivationWouldHaveJitteredAtProductionMagnitude() {
        let startedWall = Date(timeIntervalSinceReferenceDate: 800_000_000).timeIntervalSinceReferenceDate
        let values = (0..<40).map { i -> TimeInterval in
            let monotonicElapsed = 600 + Double(i) * 0.4999997
            let wallNow = startedWall + monotonicElapsed + 1e-6 * Double(i % 7)
            return RideDuration.activeSeconds(elapsedSeconds: wallNow - startedWall,
                                              pausedSeconds: monotonicElapsed - 600 + 600)
        }
        #expect(Set(values).count > 1)
    }

    @Test func theRunningAnchorIsIdenticalAcrossFortyTicks() {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clocks = (0..<40).map { i in
            RideActiveClock.make(startedAt: started, pausedSeconds: 120, openStop: nil,
                                 now: started.addingTimeInterval(600 + Double(i) * 0.4999997))
        }
        #expect(Set(clocks).count == 1)
        #expect(clocks[0] == .running(anchor: started.addingTimeInterval(120)))
    }

    @Test func anOpenStopSelectsThePausedCaseAndCarriesItsFrozenValues() {
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let since = started.addingTimeInterval(600)
        let clock = RideActiveClock.make(startedAt: started, pausedSeconds: 600,
                                         openStop: RideOpenStop(since: since,
                                                                activeSecondsAtPause: 600),
                                         now: started.addingTimeInterval(900))
        #expect(clock == .paused(since: since, activeSeconds: 600))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideActiveClockTests`
Expected: FAIL to compile — no `RideOpenStop`, and `make` has a different signature.

- [ ] **Step 3: Reshape `make`**

In `RideActiveClock.swift`, keep the enum exactly as it is and add above it:

```swift
/// The stop currently in progress, as two values that were stamped together at the pause.
///
/// One optional instead of two: `since` and `activeSecondsAtPause` are non-nil under exactly the
/// same condition, and a half-supplied pair is a state `make` would have to decide about.
public struct RideOpenStop: Equatable, Sendable {
    /// When this stop began, on the current system clock — `RideRecorder.anchorPausedSince`.
    public let since: Date
    /// The ride's active time frozen at that instant — `RideRecorder.activeSecondsAtPause`.
    public let activeSecondsAtPause: TimeInterval

    public init(since: Date, activeSecondsAtPause: TimeInterval) {
        self.since = since
        self.activeSecondsAtPause = activeSecondsAtPause
    }
}
```

Replace `make` (lines 30-59) with:

```swift
    /// Build the clock from values that do not move between events.
    ///
    /// **Nothing here is derived from `now` except the future-anchor clamp.** The controller skips
    /// a push when the whole payload is unchanged, which is what keeps a forty-minute café stop to
    /// one heartbeat push a minute. Recomputing either case's value per tick from a monotonic
    /// elapsed and a wall `now` — which cannot be sampled at the same instant — makes every payload
    /// distinct and pushes every coalescing interval instead (ROH-130 D5).
    ///
    /// A real clock step moves `startedAt` and `openStop.since` together, through the recorder's
    /// `wallOffset`, which emits exactly one push and lets the Lock Screen correct itself.
    public static func make(startedAt: Date,
                            pausedSeconds: TimeInterval,
                            openStop: RideOpenStop?,
                            now: Date) -> RideActiveClock {
        if let openStop {
            return .paused(since: openStop.since, activeSeconds: openStop.activeSecondsAtPause)
        }
        return .running(anchor: RideDuration.runningAnchor(startedAt: startedAt,
                                                           pausedSeconds: pausedSeconds,
                                                           now: now))
    }
```

Update the type's header comment: the paused case's values are now frozen at the pause rather than kept constant by cancellation, and the residual-weakness sentence naming ROH-130 goes.

- [ ] **Step 4: Rewire the coordinator**

`pushActivityUpdate` becomes:

```swift
    func pushActivityUpdate(now: RideInstant) {
        // The recorder's anchor stamps, not the coordinator's `startedAt`: these carry the
        // wall-offset correction, and `startedAt` deliberately does not (ROH-130 D2/D5).
        guard let anchorStartedAt = recorder.anchorStartedAt else { return }
        let openStop = recorder.anchorPausedSince.flatMap { since in
            recorder.activeSecondsAtPause.map {
                RideOpenStop(since: since, activeSecondsAtPause: $0)
            }
        }
        activity.update(stats: recorder.stats,
                        currentSpeedMetersPerSecond: recorder.currentSpeedMetersPerSecond,
                        maneuver: maneuver,
                        activeClock: .make(startedAt: anchorStartedAt,
                                           pausedSeconds: recorder.pausedSeconds(asOf: now),
                                           openStop: openStop,
                                           now: now.date))
    }
```

- [ ] **Step 5: Add the guard script's second detector**

In `scripts/check-single-active-definition.sh`, extend `detect()` and its self-test:

```bash
detect() {
  sed -E 's|//.*$||' | grep -E \
    '(-[[:space:]]*[A-Za-z_.]*[Pp]ausedSeconds)|(addingTimeInterval\([A-Za-z_.]*[Pp]ausedSeconds)|(activeSeconds\(elapsedSeconds:[^)]*timeIntervalSince)' \
    || true
}
```

and inside `self_test`, before the existing `ok` case:

```bash
  local bad_wall='x.swift:1:  let a = RideDuration.activeSeconds(elapsedSeconds: now.timeIntervalSince(startedAt), pausedSeconds: p)'
  [ -n "$(printf '%s\n' "$bad_wall" | detect)" ] || { echo "SELF-TEST FAIL: missed a wall-derived elapsed"; exit 2; }
  local ok_mono='x.swift:1:  let a = RideDuration.activeSeconds(elapsedSeconds: r.elapsedSeconds(asOf: now), pausedSeconds: p)'
  [ -z "$(printf '%s\n' "$ok_mono" | detect)" ] || { echo "SELF-TEST FAIL: flagged a monotonic elapsed"; exit 2; }
```

Add to the header comment: the second detector exists because the new signature takes a bare
`TimeInterval`, so deriving elapsed from a wall pair for a *live* clock reintroduces ROH-130 while
still calling the one definition. `RideDuration.swift` is the only legal site and is already excluded.

Also mirror the same two-line update into the `offenders=` grep pattern so it matches `detect()`.

- [ ] **Step 6: Run everything**

Run: `swift test --package-path AuraCore`
Expected: PASS. `ActiveTimeAgreementTests` may need its Live-Activity-side expectation restated in terms of the anchor rather than a recomputed `activeSeconds` — if so, keep it asserting agreement with the HUD number, do not weaken it to a tautology.

Run: `bash scripts/check-single-active-definition.sh`
Expected: `PASS: ... (self-test OK).`

- [ ] **Step 7: Commit**

```bash
git add AuraCore scripts/check-single-active-definition.sh
git commit -m "fix(roh-130): build the Live Activity clock from stamps, not from now"
```

---

### Task 5: The coordinator's clock seam, and the clamp comes out

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Modify: `AuraCore/Tests/AuraKitTests/Support/RideClockTestSupport.swift`
- Modify: every test file that constructs a `RideSessionCoordinator` (see Step 3)
- Create: `AuraCore/Tests/AuraKitTests/RideSessionClockStepTests.swift`

**Interfaces:**
- Consumes: `RideClocking`, `SystemRideClock`, `FakeRideClock`.
- Produces: `RideSessionCoordinator.init(kind:destinationName:screen:activity:workout:guidance:haptics:nudges:clock:)` with `clock: any RideClocking = SystemRideClock()` as the **last** parameter.

- [ ] **Step 1: Write the failing tests**

Create `AuraCore/Tests/AuraKitTests/RideSessionClockStepTests.swift`:

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// The cockpit's two numbers through a system clock step, driven end to end through the
/// coordinator so the ticker path and the pause path are both covered.
@MainActor
@Suite struct RideSessionClockStepTests {
    private func startedCoordinator(clock: FakeRideClock)
        throws -> (RideSessionCoordinator, RideStore) {
        let store = try RideStore.inMemory()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       haptics: HapticSpy(), nudges: NudgeSpy(), clock: clock)
        c.start(location: SpyLocationStream(), saving: store, units: .metric,
                authorization: .authorized)
        return (c, store)
    }

    @Test func theHeadlineClockDoesNotJumpOnABackwardStep() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, _) = try startedCoordinator(clock: clock)
        clock.advance(600)
        c.refreshElapsed(now: clock.now())
        let before = c.elapsed
        clock.step = -40
        clock.advance(1)
        c.refreshElapsed(now: clock.now())
        #expect(c.elapsed == before + 1)
    }

    @Test func theStopChipDoesNotFallOnABackwardStep() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, _) = try startedCoordinator(clock: clock)
        clock.advance(600)
        c.pause()
        clock.advance(30)
        c.refreshElapsed(now: clock.now())
        #expect(c.currentPauseSeconds == 30)
        clock.step = -40
        clock.advance(1)
        c.refreshElapsed(now: clock.now())
        #expect(c.currentPauseSeconds == 31)
    }

    /// The clamp that used to hold this line is gone, so this asserts the underlying guarantee
    /// rather than the guard: the value is monotonic because its input is.
    @Test func theStopChipRisesMonotonicallyAcrossAStep() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, _) = try startedCoordinator(clock: clock)
        c.pause()
        var readings: [TimeInterval] = []
        for i in 0..<20 {
            if i == 10 { clock.step = -40 }
            clock.advance(0.5)
            c.refreshElapsed(now: clock.now())
            readings.append(c.currentPauseSeconds)
        }
        #expect(readings == readings.sorted())
        #expect(readings.last == 10)
    }

    @Test func aFreshRideOnAReusedCoordinatorZeroesTheStopClock() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, store) = try startedCoordinator(clock: clock)
        clock.advance(600)
        c.pause()
        clock.advance(600)
        c.refreshElapsed(now: clock.now())
        #expect(c.currentPauseSeconds > 0)
        c.finish()
        c.start(location: SpyLocationStream(), saving: store, units: .metric,
                authorization: .authorized)
        #expect(c.currentPauseSeconds == 0, "start() zeroes this synchronously, before any tick")
    }
}
```

Adjust the spy type names in `startedCoordinator` to the ones the neighbouring suites already use — check `RideSessionCoordinatorPauseTests.swift:18-25` and its location-stream spy before writing.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideSessionClockStepTests`
Expected: FAIL to compile — `RideSessionCoordinator` has no `clock:` parameter.

- [ ] **Step 3: Add the seam**

In `RideSessionCoordinator.swift`:

Add a stored property beside the other injected collaborators:

```swift
    /// Where every instant in this type comes from. `start`, `pause`, `resume` and `finish` read
    /// the clock themselves, so without a seam a test could inject instants into `refreshElapsed`
    /// and get a recorder holding two different monotonic origins — which computes stops of tens
    /// of millions of seconds while `>=` assertions keep passing (ROH-130 D7).
    @ObservationIgnored private let clock: any RideClocking
```

Add `clock: any RideClocking = SystemRideClock()` as the **last** initializer parameter and assign it.

Replace the four internal clock reads:

```swift
    public func pause() { pause(at: clock.now()) }
    public func resume() { resume(at: clock.now()) }
```

In `start()`, replace `let now = Date()` with:

```swift
        let instant = clock.now()
        let now = instant.date
```

and pass `instant` to `recorder.start(at:)`; everything else in `start()` keeps using `now`.

In `finish()`, replace `recorder.end(at: Date(), ...)` with `recorder.end(at: clock.now(), ...)`.

In the ticker, read one instant and use it for both calls:

```swift
            while !Task.isCancelled {
                guard let self, self.recorder.isRecording else { return }
                // One instant for both: `pausedSeconds(asOf:)` and the clock must be measured at
                // the same moment (`RideActiveClock.make`).
                let now = self.clock.now()
                self.refreshElapsed(now: now)
                self.pushActivityUpdate(now: now)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
```

Remove the clamp in `refreshElapsed` — the last line becomes:

```swift
        currentPauseSeconds = recorder.currentPauseSeconds(asOf: now)
```

and rewrite the property's doc comment (lines 33-36):

```swift
    /// Duration of the stop in progress, zero while recording.
    ///
    /// No longer clamped non-decreasing. It was, against a backward wall-clock step; the input is
    /// now a difference of monotonic readings, so within one stop it cannot fall, and a clamp that
    /// cannot fire is a guard nobody can test (ROH-130 D6).
    public private(set) var currentPauseSeconds: TimeInterval = 0
```

**Keep `start()`'s `currentPauseSeconds = 0`** (line 176) and update its comment: it is the only synchronous zeroing on the reused-coordinator path, and `RideSessionCoordinatorNudgeTests.startingAFreshRideZeroesTheStopClock` asserts on it before any tick runs. `resume()`'s reset at line 284 is redundant once the clamp is gone (the next `refreshElapsed` assigns zero) — delete it and its "belt-and-braces" comment in `pause()` at lines 253-259, whose only stated justification was the clamp.

Also delete the ROH-130 sentence from `RideSessionCoordinator.swift:35` and from `RideRecorder.swift`/`RideDuration.swift`/`RideActiveClock.swift` wherever it says the weakness is still open. `RideDuration.swift:46`'s paragraph should now say the negative-elapsed producer was ROH-130, that it is fixed for locally-recorded rides, and that the clamp stays because the value can also arrive from a CloudKit-mirrored row.

- [ ] **Step 4: Inject the fake into every coordinator test construction**

Run `grep -rn 'RideSessionCoordinator(' AuraCore/Tests` and add `clock: FakeRideClock()` to each construction. Known sites: `RideSessionCoordinatorTests.swift:23,163,177,190,204`, `RideSessionCoordinatorPauseTests.swift:22`, `RideSessionCoordinatorNudgeTests.swift:28`, `RideSessionCheckpointFlushTests.swift:38`, `RideSessionCoordinatorDetourTests.swift:20,31,42,56`, `RideSessionCoordinatorDiscoveryTests.swift:18`, `GroupRide/CoordinatorGroupSinkTests.swift:26`, `GoldenRidePlaybackTests.swift:23`.

**Exception to check, not to assume:** `GoldenRidePlaybackTests` replays a fixture and may depend on wall-clock time advancing on its own. Read it. If any assertion there depends on real elapsed time, leave that one construction on the default `SystemRideClock()` and say so in a comment; if not, use the fake like the rest.

A `FakeRideClock()` constructed with no argument starts at `Date()` and never advances, which matches how those suites already treat time.

- [ ] **Step 5: Run everything**

Run: `swift test --package-path AuraCore`
Expected: PASS, both totals.

`RideSessionCoordinatorNudgeTests` around lines 186-220 and `RideRecorderPauseTests.swift:360` currently assert clamp behavior on a backward `Date`. With the clamp gone and the input monotonic they may fail. That is a real behavior change: retarget each to the monotonic guarantee (use `FakeRideClock.step` to apply a real clock step and assert the value does not fall) rather than deleting the test or restoring the clamp.

Run: `bash scripts/check-single-active-definition.sh && bash scripts/check-monotonic-instants.sh && swiftlint lint --strict`
Expected: all PASS. Run SwiftLint from the repo root.

- [ ] **Step 6: Commit**

```bash
git add AuraCore
git commit -m "fix(roh-130): inject the ride clock and drop the stop-chip clamp"
```

---

### Task 6: The push policy stops measuring itself on the wall clock

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift:29-43`
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController.swift:36,79,87,100,112-119,149`
- Test: `AuraCore/Tests/AuraCoreTests/` — the existing push-policy suite (find it with `grep -rln RideActivityPushPolicy AuraCore/Tests`)

**Interfaces:**
- Consumes: `RideInstant` (Task 1).
- Produces: `RideActivityPushPolicy.decide(last:next:secondsSinceLastPush:) -> RideActivityPushDecision`.

- [ ] **Step 1: Write the failing test**

Append to the existing push-policy suite:

```swift
    /// A backward system clock step used to drive `now - lastPushedAt` negative, which failed
    /// every time-gated branch at once — so the clock correction, the distance, the speed and the
    /// elevation all froze on the Lock Screen for the size of the step plus the coalescing
    /// interval, with no stale dimming because `staleDate` had moved out by the same amount.
    /// Measured monotonically, a step cannot reach this decision at all (ROH-130 D6).
    @Test func aCoalescedChangePushesOnElapsedMonotonicTimeAlone() {
        let last = RideActivityPayload(distanceMeters: 100, clock: .running(anchor: .init()))
        var next = last
        next.distanceMeters = 200
        #expect(RideActivityPushPolicy.decide(last: last, next: next,
                                              secondsSinceLastPush: 4.0) == .push)
        #expect(RideActivityPushPolicy.decide(last: last, next: next,
                                              secondsSinceLastPush: 3.9) == .skip)
    }

    @Test func theFirstPushNeedsNoElapsedTime() {
        let next = RideActivityPayload(clock: .running(anchor: .init()))
        #expect(RideActivityPushPolicy.decide(last: nil, next: next,
                                              secondsSinceLastPush: nil) == .push)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter PushPolicy`
Expected: FAIL to compile — `decide` takes `lastPushedAt:` and `now:`.

- [ ] **Step 3: Change the policy**

```swift
    /// `secondsSinceLastPush` is nil before the first push of an activity.
    ///
    /// A `TimeInterval` rather than two `Date`s: the caller measures it on the monotonic clock, so
    /// a system clock step cannot make it negative and stall every gate below.
    public static func decide(last: RideActivityPayload?,
                              next: RideActivityPayload,
                              secondsSinceLastPush: TimeInterval?) -> RideActivityPushDecision {
        guard let last, let secondsSinceLastPush else { return .push }
        // A new maneuver and a pause/resume are both state the rider is waiting to see, so
        // neither waits on the coalescing cadence.
        if next.turnInstruction != last.turnInstruction { return .push }
        if next.clock.isPaused != last.clock.isPaused { return .push }
        if secondsSinceLastPush >= heartbeatInterval { return .push }
        if next != last && secondsSinceLastPush >= coalesceInterval { return .push }
        return .skip
    }
```

- [ ] **Step 4: Change the controller**

In `RideLiveActivityController.swift`, replace `private var lastPushedAt: Date?` (line 36) with:

```swift
    /// Monotonic, so a system clock step cannot stall every push gate at once (ROH-130 D6).
    private var lastPushedMonotonicSeconds: TimeInterval?
```

- Line 79 (`lastPushedAt = startedAt` inside `start`): `lastPushedMonotonicSeconds = RideInstant.now.monotonicSeconds`
- Line 87 and line 149 (`lastPushedAt = nil`): `lastPushedMonotonicSeconds = nil`
- In `update`, replace lines 100 and 112-119:

```swift
        let instant = RideInstant.now
        // ... payload construction unchanged ...
        let sinceLastPush = lastPushedMonotonicSeconds.map { instant.monotonicSeconds - $0 }
        guard RideActivityPushPolicy.decide(last: lastPayload, next: payload,
                                            secondsSinceLastPush: sinceLastPush) == .push else {
            return
        }

        // Inside the .push branch only: a skip must advance nothing (invariant 3).
        lastPayload = payload
        lastPushedMonotonicSeconds = instant.monotonicSeconds
        enqueue(payload, on: activity)
```

`enqueue`'s `staleDate` keeps using `Date()` — it is an absolute deadline the OS evaluates on its own wall clock, not an interval this app measures.

- [ ] **Step 5: Run everything**

Run: `swift test --package-path AuraCore`
Expected: PASS, both totals.

Build the app target (the controller does not compile on the package host):

Delegate to the `apple-platform-build-tools:builder` subagent: build scheme `Aura` for an iOS simulator and report failures only.

- [ ] **Step 6: Commit**

```bash
git add AuraCore Aura/Sources/LiveActivity/RideLiveActivityController.swift
git commit -m "fix(roh-130): measure the Live Activity push cadence monotonically"
```

---

### Task 7: Close the loop — issue, docs, and the full gate

**Files:**
- Modify: `docs/ROADMAP.md` (if it tracks open clock work — check with `grep -n 'ROH-130' docs/ROADMAP.md`)
- Verify only: everything else

- [ ] **Step 1: Sweep for stale ROH-130 references**

Run: `grep -rn 'ROH-130' --include='*.swift' --include='*.md' --include='*.sh' . | grep -v docs/superpowers`
Every remaining mention must describe the *fix* or a documented residual, not an open weakness. Fix any that still say the bug is open.

- [ ] **Step 2: Check the Health path tolerates a derived `endedAt`**

Read `AuraCore/Sources/AuraCore/Health/WorkoutData.swift:32` and `RideWorkoutGate.swift:11`. Confirm neither rejects an `endedAt` marginally ahead of `Date()`, and that `WorkoutData` still produces `startDate <= endDate`. If either would reject it, stop and report rather than adding a clamp — it changes the spec's D3 residual.

- [ ] **Step 3: Run the whole gate**

```bash
swift test --package-path AuraCore
```

```bash
bash scripts/check-single-active-definition.sh && bash scripts/check-monotonic-instants.sh && bash scripts/check-explore-rename.sh && bash scripts/check-terrain-style.sh && swiftlint lint --strict
```

Then delegate an app build and the XCUITest golden-ride suite to `apple-platform-build-tools:builder`.

Expected: all green. Read both `swift test` totals.

- [ ] **Step 4: Commit anything the sweep changed**

```bash
git add -A
git commit -m "docs(roh-130): retire the open-weakness notes the fix closes"
```
