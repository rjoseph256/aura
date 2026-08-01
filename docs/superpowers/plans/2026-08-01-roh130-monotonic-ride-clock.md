# Monotonic Ride Clock (ROH-130) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure every ride duration with a monotonic clock so a system clock step cannot move the rider's active time, paused chip, Lock Screen clock, or saved ride.

**Architecture:** A `RideInstant` value pairs one wall-clock `Date` with one `ContinuousClock` reading, and every recorder boundary takes that pair instead of a bare `Date`. Durations come from the monotonic half; persisted and displayed stamps come from the wall half and are never mutated in place. The Live Activity's two anchors are built from stamps plus a discretely-updated `wallOffset`, each stamp remembering the offset in force when it was taken, so the anchors stay byte-identical between events and the push dedupe survives.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM package `AuraCore` (targets `AuraCore` and `AuraKit`), Xcode app target `Aura`, ActivityKit.

**Spec:** `docs/superpowers/specs/2026-08-01-roh130-monotonic-ride-clock-design.md` (revision 3)

This is plan revision 2, after a three-reviewer gate. Revision 1 shipped the spec's own D5 defect (`wallOffset` applied to a stamp taken after the step), left the tree red at three of its seven task boundaries, wrote two tests that could not fail, and relied on a grep detector that a wrapped line walks straight past. Corrections are marked inline.

## Global Constraints

- Package platforms are `.iOS(.v17), .macOS(.v14)` (`AuraCore/Package.swift:6`). `ContinuousClock` and `InstantProtocol.duration(to:)` are iOS 16 / macOS 13, so **no `@available` gate is needed and none may be added**.
- `AuraCore` must not import `AuraKit`. The `AuraCoreTests` target does **not** import `AuraKit`, so no AuraKit test helper can be used from it, and no test in it can reach `RideRecorder`.
- `AuraKit` builds on the macOS CI host. Anything iOS-only stays behind `#if os(iOS)`.
- Active time has exactly one definition, `RideDuration.activeSeconds`, enforced by `scripts/check-single-active-definition.sh` (CI at `.github/workflows/ci.yml:197`, and `.claude/agent-gate.sh:86`).
- `RideActiveClock` is `Codable` inside `RideActivityAttributes.ContentState`. **Do not rename a case or an associated-value label** — an activity in flight across an app update is decoded by a new binary from bytes an old one wrote, and a rename strands it on its last rendered frame. `RideActiveClockTests.codableRoundTrip` pins this. Adding a *parameter* type is fine; changing the enum's own shape is not.
- SwiftLint runs `--strict` from the repo root, `force_try` is enabled and `AuraCore/Tests` is in scope: **no `try!` in tests.** Make the test `throws` and use `try #require`.
- Any suite that builds a `RideStore` carries the `.swiftDataSerialized` trait (ROH-65). Copy the form from `RideSessionCoordinatorTests.swift:7`.
- Clock step threshold: **2 seconds**, one named constant, used in exactly one place.
- Run the package suite with `swift test --package-path AuraCore`. It prints **two** totals, one per test target — read both.
- **Every task ends with a green tree**: compiles, `swift test --package-path AuraCore` passes both totals, and all four `scripts/check-*.sh` pass.

## File Structure

**Created**

- `AuraCore/Sources/AuraCore/Ride/RideInstant.swift` — the paired reading, the process-wide monotonic origin, and the `RideClocking` seam. The only file under `Sources/` allowed to build a `RideInstant` from parts.
- `scripts/check-monotonic-instants.sh` — build gate: no fabricated pairs outside that file.
- `AuraCore/Tests/AuraCoreTests/RideInstantTests.swift`
- `AuraCore/Tests/AuraKitTests/Support/RideClockTestSupport.swift` — `RideInstant.coherent`/`.stepped`, `FakeRideClock`, and the `Date`-taking overloads that keep the existing suites compiling.
- `AuraCore/Tests/AuraKitTests/RideClockStepTests.swift` — recorder-level step and anchor fixtures.
- `AuraCore/Tests/AuraKitTests/RideSessionClockStepTests.swift` — coordinator-level step and Live Activity stability fixtures.

**Modified**

- `AuraCore/Sources/AuraCore/Ride/RideDuration.swift` — `RideElapsed`, new `activeSeconds` signature, new `runningAnchor`.
- `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift` — `make` takes a `RideOpenStop?`; anchors stop depending on `now`.
- `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift` — `decide` takes `secondsSinceLastPush`.
- `AuraCore/Sources/AuraKit/RideRecorder.swift` — monotonic durations, `wallOffset` with per-stamp provenance, derived `endedAt` on `end` only.
- `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` — `RideClocking` seam, `RideInstant` throughout, clamp removal.
- `Aura/Sources/LiveActivity/RideLiveActivityController.swift` — monotonic push bookkeeping.
- `scripts/check-single-active-definition.sh` — `betweenStamps` detector.
- `.github/workflows/ci.yml`, `.claude/agent-gate.sh` — wire the new guard.
- Test suites listed per task.

---

### Task 1: `RideInstant`, the clock seam, and its build guard

**Files:**
- Create: `AuraCore/Sources/AuraCore/Ride/RideInstant.swift`
- Create: `AuraCore/Tests/AuraCoreTests/RideInstantTests.swift`
- Create: `scripts/check-monotonic-instants.sh`
- Modify: `.github/workflows/ci.yml` (a step after the single-active-definition guard)
- Modify: `.claude/agent-gate.sh` (a `run` line after the same guard)

**Interfaces:**
- Consumes: nothing.
- Produces: `RideInstant.init(date:monotonicSeconds:)`, `RideInstant.now`, `.date`, `.monotonicSeconds`; `protocol RideClocking { func now() -> RideInstant }`; `struct SystemRideClock: RideClocking`.

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
        // Sanity that the wall half is a real Date and not a stub.
        #expect(abs(a.date.timeIntervalSinceNow) < 86_400)
    }

    /// The origin is process-wide and taken at first use, so a production reading is a small
    /// number. The AuraKitTests shim uses `timeIntervalSinceReferenceDate` (~8e8), and mixing the
    /// two conventions inside one recorder is the failure the `RideClocking` seam exists to
    /// prevent — durations in the tens of millions of seconds, under assertions that still pass.
    @Test func nowIsMeasuredFromAProcessLifetimeOrigin() {
        #expect(RideInstant.now.monotonicSeconds < 86_400)
    }

    @Test func systemRideClockReturnsNow() {
        let before = RideInstant.now
        #expect(SystemRideClock().now().monotonicSeconds >= before.monotonicSeconds)
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

    /// The two clocks are read a few instructions apart and cannot be sampled together. A thread
    /// descheduled between them fabricates a small disagreement; `RideRecorder.align(at:)` is the
    /// only consumer of that agreement, it needs a 2 s disagreement to act, and it self-corrects
    /// on the next reading.
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
/// different monotonic origins into one recorder and computes stops of tens of millions of seconds
/// — while the `>=`-shaped assertions in the suite keep passing (ROH-130 D7).
///
/// Not `Sendable`-constrained: every consumer is `@MainActor`, so global-actor isolation already
/// covers the stored existential, and requiring it would push the test fake into `@unchecked`.
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
# A `RideInstant` may only be built from parts in one place.
#
# The whole point of the type is that its two halves were read at the same instant on two real
# clocks. Anything under Sources/ that builds one from a `Date` is inventing a monotonic reading
# from a wall clock, which silently reintroduces ROH-130 while the types still line up. Tests do
# exactly that on purpose, which is why this scans Sources/ only.
set -euo pipefail
cd "$(dirname "$0")/.."

SCAN_ROOTS=(AuraCore/Sources Aura/Sources Aura/Widgets)
OWNER='AuraCore/Sources/AuraCore/Ride/RideInstant.swift'

# The tell is the argument label, not the type name: `RideInstant(date:monotonicSeconds:)` and
# `.init(date:monotonicSeconds:)` both carry it. A property read (`instant.monotonicSeconds`) does
# not, and neither does a local named for it.
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

- [ ] **Step 6: Wire the guard and verify**

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

### Task 2: `RideElapsed` and the running anchor

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideDuration.swift:62-82`
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift:43`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift:224`
- Modify: `scripts/check-single-active-definition.sh`
- Test: `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift:77,79`
- Test: `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift:39,57,67`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `RideElapsed.measured(_:)`, `RideElapsed.betweenStamps(startedAt:endedAt:)`, `RideElapsed.seconds`; `RideDuration.activeSeconds(elapsed: RideElapsed, pausedSeconds: TimeInterval) -> TimeInterval`; `RideDuration.runningAnchor(startedAt: Date, pausedSeconds: TimeInterval, now: Date) -> Date`.

Behavior-preserving: every caller keeps computing elapsed from the same values it uses today. Only the shape moves.

*(Revision 2 of this plan: the wrapper replaces revision 1's bare `elapsedSeconds: TimeInterval`, and the guard's new detector is a single token rather than a regex over a call that wraps across lines. The gate executed revision 1's detector and it matched only its own self-test string.)*

- [ ] **Step 1: Write the failing tests**

Append to `AuraCore/Tests/AuraCoreTests/RideDurationTests.swift`:

```swift
    @Test func activeIsElapsedLessPaused() {
        #expect(RideDuration.activeSeconds(elapsed: .measured(100), pausedSeconds: 30) == 70)
    }

    @Test func activeFloorsAtZeroRatherThanGoingNegative() {
        #expect(RideDuration.activeSeconds(elapsed: .measured(10), pausedSeconds: 30) == 0)
    }

    @Test func elapsedBetweenStampsFloorsAtZero() {
        let a = Date(timeIntervalSinceReferenceDate: 1_000)
        let b = Date(timeIntervalSinceReferenceDate: 900)
        #expect(RideElapsed.betweenStamps(startedAt: a, endedAt: b).seconds == 0)
        #expect(RideElapsed.betweenStamps(startedAt: b, endedAt: a).seconds == 100)
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
Expected: FAIL to compile — no `RideElapsed`, no `runningAnchor`.

- [ ] **Step 3: Change the primitive**

In `RideDuration.swift`, add above `RideDuration`:

```swift
/// Elapsed ride time, carrying where it came from.
///
/// The one definition of active time subtracts paused seconds from elapsed seconds, and those two
/// numbers have to be on the same clock or the subtraction is meaningless. A bare `TimeInterval`
/// cannot say which clock it is on, so this exists to make the wrong one require typing
/// `betweenStamps` at a live call site — which `scripts/check-single-active-definition.sh` then
/// rejects outside this file (ROH-130 D4).
public struct RideElapsed: Equatable, Sendable {
    public let seconds: TimeInterval

    /// A monotonic measurement — `RideRecorder.elapsedSeconds(asOf:)`. What every live clock uses.
    public static func measured(_ seconds: TimeInterval) -> RideElapsed {
        RideElapsed(seconds: max(0, seconds))
    }

    /// The interval between a finished ride's two stamps. **Legal for a saved ride and nothing
    /// else.** It is correct there because `RideRecorder.end(at:)` derives `endedAt` from the
    /// monotonic elapsed, so the pair spans no clock step; used for a running ride it would be a
    /// wall subtraction and ROH-130 all over again.
    public static func betweenStamps(startedAt: Date, endedAt: Date) -> RideElapsed {
        RideElapsed(seconds: max(0, endedAt.timeIntervalSince(startedAt)))
    }

    private init(seconds: TimeInterval) { self.seconds = seconds }
}
```

Replace `activeSeconds` (lines 79-82) and add the anchor, keeping the existing doc comment and editing its last paragraph:

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
    /// `RideElapsed` is what records which clock the elapsed half came from; see its doc comment.
    public static func activeSeconds(elapsed: RideElapsed,
                                     pausedSeconds: TimeInterval) -> TimeInterval {
        max(0, elapsed.seconds - pausedSeconds)
    }

    /// Where the Live Activity's running timer counts up from.
    ///
    /// Lives here, and not in `RideActiveClock`, because the expression it needs is
    /// `addingTimeInterval(pausedSeconds)` and this file is the guard script's only exemption.
    ///
    /// Deliberately built from stamps rather than as `now - activeSeconds`: both inputs move only
    /// at a pause boundary, so the anchor is byte-identical between boundaries and the Live
    /// Activity's push dedupe survives (ROH-130 D5). The `min` keeps a future anchor — which
    /// `Text(_, style: .timer)` counts DOWN from — off the Lock Screen. While that clamp binds the
    /// anchor tracks `now` and costs a push per coalescing interval.
    public static func runningAnchor(startedAt: Date, pausedSeconds: TimeInterval,
                                     now: Date) -> Date {
        min(now, startedAt.addingTimeInterval(pausedSeconds))
    }
```

Then rewrite `init`'s body (lines 51-64):

```swift
        let elapsed = RideElapsed.betweenStamps(startedAt: startedAt, endedAt: endedAt)
        elapsedSeconds = elapsed.seconds

        activeSeconds = RideDuration.activeSeconds(elapsed: elapsed,
                                                   pausedSeconds: max(0, pausedSeconds))
```

The `max(0,)` that was on line 51 now lives inside `betweenStamps`; update the comment above it to say so, and keep its explanation of why this is clamped and not asserted.

- [ ] **Step 4: Update the two in-tree callers, behavior-preserving**

`RideActiveClock.swift:43`:

```swift
        let activeSeconds = RideDuration.activeSeconds(
            elapsed: .betweenStamps(startedAt: startedAt, endedAt: now),
            pausedSeconds: pausedSeconds)
```

`RideSessionCoordinator.swift:224`:

```swift
        elapsed = RideDuration.activeSeconds(
            elapsed: .betweenStamps(startedAt: startedAt, endedAt: now),
            pausedSeconds: recorder.pausedSeconds(asOf: now))
```

Both are temporary and are replaced in Tasks 3 and 4. **Do not add the `betweenStamps` detector yet** — it would reject exactly these two lines, which is the detector working correctly.

- [ ] **Step 5: Update the two AuraCore test suites**

In `RideDurationTests.swift:77,79` and `ActiveTimeAgreementTests.swift:39,57,67`, replace each
`RideDuration.activeSeconds(startedAt: X, asOf: Y, pausedSeconds: Z)` with
`RideDuration.activeSeconds(elapsed: .betweenStamps(startedAt: X, endedAt: Y), pausedSeconds: Z)`.
Change no expected value — this is a pure re-spelling and every assertion must still hold.

- [ ] **Step 6: Run the gate**

Run: `swift test --package-path AuraCore`
Expected: PASS, both totals, no assertion changes.

Run: `bash scripts/check-single-active-definition.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add AuraCore
git commit -m "refactor(roh-130): RideElapsed records which clock elapsed came from"
```

---

### Task 3: The recorder measures monotonically, and the coordinator gets its clock seam

**Files:**
- Modify: `AuraCore/Sources/AuraKit/RideRecorder.swift`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift`
- Create: `AuraCore/Tests/AuraKitTests/Support/RideClockTestSupport.swift`
- Create: `AuraCore/Tests/AuraKitTests/RideClockStepTests.swift`
- Modify: every test file constructing a `RideSessionCoordinator` (Step 6)

**This is one task and not two on purpose.** *(Revision 2. Revision 1 split the recorder from the seam and left the package suite red in between: the coordinator's internal `RideInstant.now` reads have a process-lifetime origin while injected test `Date`s land ~8e8 seconds away, so `RideSessionCoordinatorNudgeTests.swift:201` computes a 780-million-second stop.)* The recorder's new API and the seam that feeds it coherent instants are one compile unit; there is no ordering of them that leaves a green tree in between.

**Interfaces:**
- Consumes: `RideInstant`, `RideClocking`, `SystemRideClock` (Task 1); `RideElapsed`, `RideDuration.activeSeconds(elapsed:pausedSeconds:)` (Task 2).
- Produces on `RideRecorder`: `start(at:)`, `pause(at:)`, `resume(at:)`, `end(at:destinationName:)`, `checkpoint(at:destinationName:)`, `pausedSeconds(asOf:)`, `currentPauseSeconds(asOf:)`, `elapsedSeconds(asOf:)`, `align(at:)` — all taking/returning `RideInstant` where they took `Date` — plus `var anchorStartedAt: Date?`, `var anchorPausedSince: Date?`, `var activeSecondsAtPause: TimeInterval?`.
- Produces on `RideSessionCoordinator`: `init(..., clock: any RideClocking = SystemRideClock())` with `clock` last; `refreshElapsed(now: RideInstant)`, `pushActivityUpdate(now: RideInstant)`, `pause(at: RideInstant)`, `resume(at: RideInstant)`.
- Produces for tests: `RideInstant.coherent(_:)`, `RideInstant.stepped(_:by:)`, `FakeRideClock`, and `Date`-taking overloads of every boundary above.

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
    /// **One convention per recorder.** `FakeRideClock` produces the same shape, which is what
    /// lets a test call `coordinator.pause()` and `coordinator.refreshElapsed(now: someDate)` and
    /// get a coherent stop. Mixing this with `RideInstant.now` — process-lifetime origin, roughly
    /// 8e8 seconds away — yields durations in the tens of millions, which is why the coordinator
    /// takes a `RideClocking` rather than reading the clock itself.
    static func coherent(_ date: Date) -> RideInstant {
        RideInstant(date: date, monotonicSeconds: date.timeIntervalSinceReferenceDate)
    }

    /// A pair whose wall half has stepped `by` seconds relative to the monotonic timeline — what
    /// an NTP or NITZ correction does mid-ride. Negative steps the clock backwards.
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
///
/// **Time does not pass on its own.** A suite that needs the real 0.5 s ticker to advance
/// `elapsed` must keep `SystemRideClock()`; see `RideSessionCoordinatorPauseTests`.
final class FakeRideClock: RideClocking {
    /// The monotonic timeline's current position, expressed as a `Date`.
    var date: Date
    /// Wall-clock divergence from that timeline. Set this to simulate a system clock step.
    var step: TimeInterval = 0

    init(date: Date = Date()) { self.date = date }

    func now() -> RideInstant { .stepped(date, by: step) }

    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

// `Date`-taking overloads so the existing call sites compile unchanged. Test-target only, so
// production cannot fabricate a monotonic reading from a wall clock; `check-monotonic-instants.sh`
// enforces that from the other side.
@MainActor
extension RideRecorder {
    func start(at date: Date) { start(at: .coherent(date)) }
    func pause(at date: Date) { pause(at: .coherent(date)) }
    func resume(at date: Date) { resume(at: .coherent(date)) }
    func align(at date: Date) { align(at: .coherent(date)) }
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

@MainActor
extension RideSessionCoordinator {
    func refreshElapsed(now date: Date) { refreshElapsed(now: .coherent(date)) }
    func pushActivityUpdate(now date: Date) { pushActivityUpdate(now: .coherent(date)) }
    func pause(at date: Date) { pause(at: .coherent(date)) }
    func resume(at date: Date) { resume(at: .coherent(date)) }
}
```

- [ ] **Step 2: Write the failing recorder fixtures**

Create `AuraCore/Tests/AuraKitTests/RideClockStepTests.swift`:

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// A system clock step during a ride must not move any duration, and must move both Live Activity
/// anchors by exactly the step — once.
///
/// **On negative controls.** A `.stepped` instant puts its whole divergence in the wall half, and
/// no duration reads the wall half, so the duration fixtures below would stay green against
/// `.coherent` instants too. That is structural, not sloppiness: what those fixtures catch is a
/// production regression back to wall subtraction. Policing the fixture generator is
/// `steppedInstantsActuallyCarryAStep`'s job, and pinning that the defect is real is
/// `theOldWallClockExpressionWouldHaveLostTheStop`'s. The anchor fixtures are wall-sensitive by
/// construction and need no control.
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

    @Test func theOldWallClockExpressionWouldHaveLostTheStop() {
        let pauseAt = RideInstant.coherent(t0.addingTimeInterval(600))
        let readAt = RideInstant.stepped(t0.addingTimeInterval(610), by: -40)
        #expect(max(0, readAt.date.timeIntervalSince(pauseAt.date)) == 0)
        #expect(readAt.monotonicSeconds - pauseAt.monotonicSeconds == 10)
    }

    // MARK: durations

    @Test func aBackwardStepMidStopDoesNotMoveEitherNumber() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        let stepped = RideInstant.stepped(t0.addingTimeInterval(640), by: -40)
        #expect(r.currentPauseSeconds(asOf: stepped) == 40)
        #expect(r.elapsedSeconds(asOf: stepped) == 640)
        #expect(RideDuration.activeSeconds(elapsed: .measured(r.elapsedSeconds(asOf: stepped)),
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

    /// The shape spec revision 1 missed: a ride with no pause at all calls no pause-path code, so
    /// a fix that only corrected the pause path would leave this wrong.
    @Test func anUnpausedRideWithAStepPersistsTheMonotonicDuration() throws {
        let r = startedRecorder()
        let ride = r.end(at: .stepped(t0.addingTimeInterval(3_600), by: 40))
        let d = try #require(ride.duration)
        #expect(d.elapsedSeconds == 3_600)
        #expect(d.activeSeconds == 3_600)
        #expect(ride.startedAt == t0, "the start stamp the rider saw is never rewritten")
        #expect(ride.endedAt == t0.addingTimeInterval(3_600))
    }

    @Test func aPausedRideWithAStepPersistsBothDurations() throws {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .coherent(t0.addingTimeInterval(900)))
        let ride = r.end(at: .stepped(t0.addingTimeInterval(3_600), by: -40))
        let d = try #require(ride.duration)
        #expect(d.elapsedSeconds == 3_600)
        #expect(d.activeSeconds == 3_300)
        #expect(ride.startedAt == t0)
    }

    /// `checkpoint(at:)` keeps both of its stamps raw — a checkpoint row reports no duration at
    /// all, so there is nothing there to correct, and `checkpointedAt` is rendered copy
    /// ("Recording stops at 2:14 PM"). Spec D3.
    @Test func aCheckpointKeepsBothStampsOnTheWallClock() {
        let r = startedRecorder()
        let at = RideInstant.stepped(t0.addingTimeInterval(600), by: -40)
        r.pause(at: at)
        let row = r.checkpoint(at: at)
        #expect(row.startedAt == t0)
        #expect(row.endedAt == at.date)
        #expect(row.checkpointedAt == at.date)
        #expect(row.duration == nil)
    }

    // MARK: the anchors

    @Test func alignAbsorbsAStepIntoTheAnchorStampsOnly() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(600), by: -40))
        #expect(r.startedAt == t0, "the stored stamp never moves")
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-40))
    }

    @Test func alignIsIdempotent() {
        let r = startedRecorder()
        for i in 0..<3 {
            r.align(at: .stepped(t0.addingTimeInterval(600 + Double(i)), by: -40))
        }
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-40))
    }

    @Test func alignIgnoresDivergenceUnderTheThreshold() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(600), by: 1.9))
        #expect(r.anchorStartedAt == t0)
    }

    @Test func aStopOpenedBeforeAStepMovesWithIt() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.align(at: .stepped(t0.addingTimeInterval(640), by: -40))
        #expect(r.anchorPausedSince == t0.addingTimeInterval(560))
    }

    /// The defect the plan gate found in spec revision 2: `wallOffset` corrects a stamp taken on
    /// the *old* clock, and a stop opened after the step is already on the new one. Correcting it
    /// anyway opens the Lock Screen's stop timer at 0:40 — or, on a forward step, 40 s in the
    /// future, counting down.
    @Test func aStopOpenedAfterAStepIsNotCorrectedAgain() {
        for step in [-40.0, 40.0] {
            let r = startedRecorder()
            r.align(at: .stepped(t0.addingTimeInterval(300), by: step))
            let tap = RideInstant.stepped(t0.addingTimeInterval(600), by: step)
            r.pause(at: tap)
            #expect(r.anchorPausedSince == tap.date,
                    "the stop timer opens at zero, step \(step)")
        }
    }

    @Test func aSecondStepMovesAStopOpenedAfterTheFirst() {
        let r = startedRecorder()
        r.align(at: .stepped(t0.addingTimeInterval(300), by: -40))
        let tap = RideInstant.stepped(t0.addingTimeInterval(600), by: -40)
        r.pause(at: tap)
        r.align(at: .stepped(t0.addingTimeInterval(700), by: -70))
        #expect(r.anchorStartedAt == t0.addingTimeInterval(-70))
        #expect(r.anchorPausedSince == tap.date.addingTimeInterval(-30))
    }

    // MARK: active time frozen at the pause
    // These three carry the arithmetic that used to live in RideActiveClockTests'
    // `pausedCarriesStopInstantAndFrozenActive`, `pausedAfterAnEarlierStop` and
    // `frozenActiveClampedAtZero`. It moved here with the code (spec D5).

    @Test func activeSecondsAtPauseIsActiveTimeAtTheTap() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        #expect(r.activeSecondsAtPause == 600)
    }

    @Test func aSecondStopFreezesActiveTimeNetOfTheFirst() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.resume(at: .coherent(t0.addingTimeInterval(660)))
        r.pause(at: .coherent(t0.addingTimeInterval(900)))
        #expect(r.activeSecondsAtPause == 840)
    }

    @Test func activeSecondsAtPauseDoesNotMoveDuringTheStopAndClearsOnResume() {
        let r = startedRecorder()
        r.pause(at: .coherent(t0.addingTimeInterval(600)))
        r.align(at: .coherent(t0.addingTimeInterval(1_200)))
        #expect(r.activeSecondsAtPause == 600)
        r.resume(at: .coherent(t0.addingTimeInterval(1_200)))
        #expect(r.activeSecondsAtPause == nil)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideClockStepTests`
Expected: FAIL to compile — no `elapsedSeconds(asOf:)`, `align(at:)`, `anchorStartedAt`, `anchorPausedSince`, `activeSecondsAtPause`.

- [ ] **Step 4: Rewrite the recorder's clock**

In `RideRecorder.swift`, replace the stored-state block (lines 52-67) with:

```swift
    /// Paused time from stops that have already ended, measured monotonically. The stop in
    /// progress is added by `pausedSeconds(asOf:)`; nothing else may read this.
    private var closedPausedSeconds: TimeInterval = 0
    /// When the stop in progress began, on the wall clock.
    ///
    /// Stamped once per stop and never rewritten, like `startedAt`. These two are what gets
    /// persisted and what History shows, and a rider reads a ride's start time as its identity —
    /// so a clock correction moves the *durations*, which are measured elsewhere, and leaves these
    /// alone (ROH-130 D2).
    ///
    /// On the caller's clock, never the track's. `TrackPoint.timestamp` is a third clock: a
    /// replayed fixture carries the stamps it was recorded with, and a real ride's last accepted
    /// fix can be minutes stale through a tunnel, which would retroactively reclassify those
    /// minutes as paused the instant the rider taps. A deliberate departure from spec D6.
    private var pauseStartedAt: Date?
    /// The monotonic partner of each stamp above. Written and cleared in the same statement as its
    /// partner. **Every duration this type reports is a difference of these**, so no duration can
    /// move when civil time does.
    private var startMonotonic: TimeInterval?
    private var pauseStartMonotonic: TimeInterval?
    /// The value `wallOffset` had when `pauseStartedAt` was stamped.
    ///
    /// **This is what stops a step being applied twice.** `wallOffset` converts a stamp taken on
    /// the *old* clock onto the current one. `startedAt` always qualifies, because `start()` zeroes
    /// the offset. A stop opened *after* a step does not: its stamp is already on the corrected
    /// clock. Correcting it anyway opened the Lock Screen's stop timer at 0:40, or — on a forward
    /// step — 40 s in the future counting down, which is worse than the bug being fixed.
    private var pauseStartWallOffset: TimeInterval?
    /// Active time frozen at the instant of the pause.
    ///
    /// Not recomputed per tick. The Live Activity's paused payload carries it, and
    /// `RideActivityPushPolicy` skips a push only when the whole payload is unchanged — so a value
    /// that moved by a rounding error every tick would push every 4 s for the length of a café
    /// stop instead of once a minute (ROH-130 D5).
    public private(set) var activeSecondsAtPause: TimeInterval?
    /// What to add to a wall stamp taken when the offset was zero to express it on the *current*
    /// system clock.
    ///
    /// Consumed only by `anchorStartedAt` and `anchorPausedSince`, which the Live Activity's two
    /// anchors are built from. The OS renders those anchors against its own wall clock inside the
    /// widget process, so without this a step would leave the Lock Screen off by the step for the
    /// rest of the ride while the cockpit stayed right. Nothing persisted depends on it.
    private var wallOffset: TimeInterval = 0

    /// Below this, a wall/monotonic disagreement is NTP slewing rather than a clock set, and
    /// correcting it would move the Live Activity anchor continuously — defeating the push dedupe
    /// the discreteness exists to protect.
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
        pauseStartWallOffset = nil
        activeSecondsAtPause = nil
        wallOffset = 0
    }

    public func pause(at instant: RideInstant) {
        guard state == .recording else { return }
        // Before the stamp, so a stop opened right after a step records the *corrected* offset as
        // its own and is not corrected a second time.
        align(at: instant)
        state = .paused
        // `SpeedSmoother` has no time decay and `currentSpeedMetersPerSecond` is written only in
        // `record()`, so without this a rider who pauses at 25 km/h leaves 25 on the cockpit's
        // largest numeral for the whole stop — and reads `.moving` to the crew (spec D6/D7).
        currentSpeedMetersPerSecond = 0
        activeSecondsAtPause = RideDuration.activeSeconds(
            elapsed: .measured(elapsedSeconds(asOf: instant)),
            pausedSeconds: pausedSeconds(asOf: instant))
        pauseStartedAt = instant.date
        pauseStartMonotonic = instant.monotonicSeconds
        pauseStartWallOffset = wallOffset
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
    /// The `max(0,)` cannot fire on a monotonic input. It stays because it costs nothing; the
    /// coordinator's non-decreasing clamp, which *could* wedge a displayed number, does not.
    public func currentPauseSeconds(asOf instant: RideInstant) -> TimeInterval {
        guard let pauseStartMonotonic else { return 0 }
        return max(0, instant.monotonicSeconds - pauseStartMonotonic)
    }

    /// Note how far the system clock has drifted from this ride's monotonic timeline, and absorb a
    /// genuine step into `wallOffset`.
    ///
    /// An explicit call, never a side effect of a getter: making a read mutate would put the
    /// correctness of `checkpoint(at:)` at the mercy of argument evaluation order. Called once per
    /// ticker tick from `RideSessionCoordinator.refreshElapsed`, and at each pause boundary.
    ///
    /// Idempotent — after an update, `expected` recomputes against the new offset and `delta` is
    /// zero, so a step is corrected once rather than compounded per tick. That is also what stops
    /// slew from flapping the anchor: a correction resets the divergence, so the next one has to
    /// re-accumulate the whole threshold.
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
    /// Only the offset accrued *since the stop opened* applies; see `pauseStartWallOffset`.
    public var anchorPausedSince: Date? {
        guard let pauseStartedAt, let pauseStartWallOffset else { return nil }
        return pauseStartedAt.addingTimeInterval(wallOffset - pauseStartWallOffset)
    }

    private func closePause(at instant: RideInstant) {
        guard let pauseStartMonotonic else { return }
        closedPausedSeconds += max(0, instant.monotonicSeconds - pauseStartMonotonic)
        pauseStartedAt = nil
        self.pauseStartMonotonic = nil
        pauseStartWallOffset = nil
    }
```

`checkpoint(at:)` changes its parameter type and **nothing else** — both its stamps stay `instant.date`. Add to its doc comment:

```swift
    /// Both stamps stay on the wall clock, unlike `end(at:)`. A checkpoint row writes `endedAt`
    /// and `checkpointedAt` to the same instant and `RideDuration` disqualifies it on exactly that
    /// equality, so it reports no duration for a monotonic correction to fix — and
    /// `checkpointedAt` is rendered copy ("Recording stops at 2:14 PM", and again in the warning
    /// before an all-devices delete). Spec D3.
```

`end(at:)` derives its end instant:

```swift
    @discardableResult
    public func end(at instant: RideInstant, destinationName: String? = nil) -> Ride {
        // Bank a stop still in progress, or every ride ended while paused over-reports active time
        // by the length of the tail (spec D6).
        closePause(at: instant)
        let paused = closedPausedSeconds
        let start = startedAt ?? instant.date
        // Derived, not `instant.date`: `endedAt - startedAt` is this ride's elapsed time, and a
        // wall pair spanning a clock step is not (ROH-130 D3). After a backward step this sits
        // slightly ahead of the current wall clock; nothing renders `endedAt`, and the alternative
        // is a wrong duration on the number the summary leads with.
        let ended = start.addingTimeInterval(elapsedSeconds(asOf: instant))
        state = .idle
        return Ride(id: rideID, kind: kind, startedAt: start, endedAt: ended,
                    segments: normalizedSegments, stats: stats, pausedSeconds: paused,
                    checkpointedAt: nil,
                    destinationName: destinationName, routeId: nil, destinationPlaceId: nil)
    }
```

Update `pausedSince`'s doc comment (lines 26-31): it is the stored stamp, and `anchorPausedSince` is what the Live Activity uses. Delete the ROH-130 paragraph from `currentPauseSeconds`' old doc comment (lines 142-145).

- [ ] **Step 5: Add the coordinator's seam**

In `RideSessionCoordinator.swift`:

Add beside the other injected collaborators:

```swift
    /// Where every instant in this type comes from. `start`, `pause`, `resume` and `finish` read
    /// the clock themselves, so without a seam a test could inject instants into `refreshElapsed`
    /// and leave the recorder holding two different monotonic origins — which computes stops of
    /// tens of millions of seconds while `>=` assertions keep passing (ROH-130 D7).
    @ObservationIgnored private let clock: any RideClocking
```

Add `clock: any RideClocking = SystemRideClock()` as the **last** initializer parameter and assign it.

Change the four time-injected methods' parameter type from `Date` to `RideInstant` and **drop their `= Date()` defaults**, so nothing can silently read a real clock: `refreshElapsed(now:)`, `pushActivityUpdate(now:)`, `pause(at:)`, `resume(at:)`. Also `flushCheckpoint(at:)`. Derive any `Date` a body still needs as `instant.date`.

`refreshElapsed` becomes:

```swift
    func refreshElapsed(now: RideInstant) {
        guard startedAt != nil else { return }
        // The one place `align` runs on the ticker. Before the reads below and before
        // `pushActivityUpdate`, which consumes the anchors it maintains.
        recorder.align(at: now)
        elapsed = RideDuration.activeSeconds(
            elapsed: .measured(recorder.elapsedSeconds(asOf: now)),
            pausedSeconds: recorder.pausedSeconds(asOf: now))
        currentPauseSeconds = recorder.currentPauseSeconds(asOf: now)
    }
```

and its `currentPauseSeconds` property doc (lines 33-36) becomes:

```swift
    /// Duration of the stop in progress, zero while recording.
    ///
    /// No longer clamped non-decreasing. It was, against a backward wall-clock step; the input is
    /// now a difference of monotonic readings, so within one stop it cannot fall, and a clamp that
    /// cannot fire is a guard nobody can test (ROH-130 D6).
    public private(set) var currentPauseSeconds: TimeInterval = 0
```

Public entry points read the seam:

```swift
    public func pause() { pause(at: clock.now()) }
    public func resume() { resume(at: clock.now()) }
```

In `start()`, replace `let now = Date()` with:

```swift
        let instant = clock.now()
        let now = instant.date
```

and pass `instant` to `recorder.start(at:)`. Everything else in `start()` keeps using `now`, so `coordinator.startedAt` and `recorder.startedAt` are the same value rather than two readings microseconds apart.

**Keep `start()`'s `currentPauseSeconds = 0`** and update its comment: it is the only synchronous zeroing on the reused-coordinator path, and `RideSessionCoordinatorNudgeTests.startingAFreshRideZeroesTheStopClock` asserts on it before any tick runs. Delete `resume()`'s reset and `pause()`'s belt-and-braces reset with its comment — both were scaffolding for the clamp, and `refreshElapsed` now assigns zero from the recorder inside both methods.

In `finish()`: `recorder.end(at: clock.now(), destinationName: destinationName)`.

`flushCheckpoint` records what it actually wrote:

```swift
        do {
            let row = recorder.checkpoint(at: instant, destinationName: destinationName)
            try saving.save(row)
            pendingCheckpoint = PendingCheckpoint(rideID: row.id,
                                                  at: row.checkpointedAt ?? instant.date)
        } catch {
```

The ticker reads one instant for both calls:

```swift
            while !Task.isCancelled {
                guard let self, self.recorder.isRecording else { return }
                // One instant for both, and refreshElapsed first: it runs `recorder.align`, whose
                // `wallOffset` is what `pushActivityUpdate` reads through the anchor properties.
                let now = self.clock.now()
                self.refreshElapsed(now: now)
                self.pushActivityUpdate(now: now)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
```

`pushActivityUpdate` keeps its current body, taking `RideInstant` and passing `now.date` to `RideActiveClock.make` and `now` to `recorder.pausedSeconds(asOf:)`. Task 4 rewrites it.

Delete the ROH-130 sentence at `RideSessionCoordinator.swift:35`.

- [ ] **Step 6: Wire the seam into the test suites**

Run `grep -rn 'RideSessionCoordinator(' AuraCore/Tests` and add `clock: FakeRideClock()` to each construction. Expected 16 sites across `RideSessionCoordinatorTests.swift` (5), `RideSessionCoordinatorPauseTests.swift`, `RideSessionCoordinatorNudgeTests.swift`, `RideSessionCheckpointFlushTests.swift`, `RideSessionCoordinatorDetourTests.swift` (4), `RideSessionCoordinatorDiscoveryTests.swift`, `GroupRide/CoordinatorGroupSinkTests.swift`, `GoldenRidePlaybackTests.swift`.

**Two exceptions, both verified rather than assumed:**

- `RideSessionCoordinatorPauseTests.swift:22`'s factory feeds `elapsedStopsAdvancingWhilePausedAndResumes` (`:113-125`), which drives the real 0.5 s ticker and waits on `c.elapsed > 0`. A frozen fake pins `elapsed` at zero and both `waitUntil`s time out — as a timeout, which reads like flake. Give that factory a `clock:` parameter defaulting to `FakeRideClock()` and pass `SystemRideClock()` from that one test, with a comment saying why.
- `GoldenRidePlaybackTests.swift:23` replays a fixture. Read the suite. If any assertion depends on real elapsed time, leave it on `SystemRideClock()` and say so in a comment; if the assertions come from track timestamps only, use the fake like the rest.

Also fix the two no-argument calls the dropped defaults break: `RideSessionCoordinatorTests.swift:143` and `:154` call `c.pushActivityUpdate()`. Give them an explicit instant from the suite's clock.

- [ ] **Step 7: Run the gate**

Run: `swift test --package-path AuraCore --filter RideClockStepTests`
Expected: PASS, 18 tests.

Run: `swift test --package-path AuraCore`
Expected: PASS, both totals. Two known failures to *retarget*, not silence:

- `RideSessionCoordinatorNudgeTests.swift:206` (`theStopClockNeverCountsDownWithinAStop`) pins the removed coordinator clamp against a backward `Date`. Rewrite it to apply a real step through `FakeRideClock.step` and assert the value does not fall.
- `RideRecorderPauseTests.swift:360` (`currentPauseSecondsClampsToZeroOnABackwardClockStep`) will still pass, because the recorder's `max(0,)` stays and `.coherent` makes the monotonic difference negative. Leave it; its name is now the only accurate part, so update the doc comment to say the clamp is belt-and-braces against a caller, not against the system clock.

Anything else that fails is a real behavior change — read it before touching it.

Run: `bash scripts/check-single-active-definition.sh && bash scripts/check-monotonic-instants.sh && swiftlint lint --strict`
Expected: all PASS. SwiftLint from the repo root.

- [ ] **Step 8: Commit**

```bash
git add AuraCore
git commit -m "fix(roh-130): measure ride durations monotonically behind an injected clock"
```

---

### Task 4: The Live Activity's clock stops depending on `now`

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActiveClock.swift`
- Modify: `AuraCore/Sources/AuraKit/RideSession/RideSessionCoordinator.swift` (`pushActivityUpdate`)
- Modify: `scripts/check-single-active-definition.sh`
- Test: `AuraCore/Tests/AuraCoreTests/RideActiveClockTests.swift` (rewrite five tests)
- Test: `AuraCore/Tests/AuraCoreTests/ActiveTimeAgreementTests.swift`
- Test: `AuraCore/Tests/AuraKitTests/RideSessionClockStepTests.swift` (create)

**Interfaces:**
- Consumes: `RideDuration.runningAnchor` (Task 2); `RideRecorder.anchorStartedAt`, `.anchorPausedSince`, `.activeSecondsAtPause` (Task 3).
- Produces: `struct RideOpenStop { let since: Date; let activeSecondsAtPause: TimeInterval }`, and `RideActiveClock.make(startedAt: Date, pausedSeconds: TimeInterval, openStop: RideOpenStop?, now: Date) -> RideActiveClock`.
- **The `RideActiveClock` enum's cases and labels do not change** — `RideOpenStop` is a parameter type only. See Global Constraints and `RideActiveClockTests.codableRoundTrip`.

- [ ] **Step 1: Write the failing coordinator-level stability tests**

*(Revision 2 of this plan. Revision 1 put these in `RideActiveClockTests` as pure-function tests. After this change `make`'s paused branch is a field copy, so such a test asserts a constant equals itself and cannot fail for any implementation — the ROH-103 trap, one layer down from where the spec's revision 1 hit it. Stability can only break in the wiring, so these run through the coordinator.)*

Create `AuraCore/Tests/AuraKitTests/RideSessionClockStepTests.swift`:

```swift
import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// The cockpit's two numbers and the Live Activity's payload through a system clock step, driven
/// end to end so the ticker path, `align`, and the anchors are all in the loop.
@MainActor
@Suite(.swiftDataSerialized)
struct RideSessionClockStepTests {
    private func startedCoordinator(clock: FakeRideClock)
        throws -> (RideSessionCoordinator, SpyRideActivity, RideStore) {
        let store = try RideStore.inMemory()
        let activity = SpyRideActivity()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: activity,
                                       haptics: HapticSpy(), nudges: NudgeSpy(), clock: clock)
        c.start(location: SpyLocationStream(), saving: store, units: .metric,
                authorization: .authorized)
        return (c, activity, store)
    }

    private func tick(_ c: RideSessionCoordinator, _ clock: FakeRideClock) {
        let now = clock.now()
        c.refreshElapsed(now: now)
        c.pushActivityUpdate(now: now)
    }

    // MARK: the cockpit

    @Test func theHeadlineClockDoesNotJumpOnABackwardStep() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, _, _) = try startedCoordinator(clock: clock)
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
        let (c, _, _) = try startedCoordinator(clock: clock)
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
    /// rather than the guard.
    @Test func theStopChipRisesMonotonicallyAcrossAStep() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, _, _) = try startedCoordinator(clock: clock)
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
        let (c, _, store) = try startedCoordinator(clock: clock)
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

    // MARK: Live Activity payload stability

    /// The push dedupe compares whole payloads, so a clock that moves by a rounding error every
    /// tick turns a forty-minute café stop from one push a minute into one every four seconds.
    /// Driven at production magnitude on tick intervals that are not exact binary fractions,
    /// because `Date`-magnitude readings on exact half-seconds are the condition under which the
    /// old arithmetic cancelled exactly and the old version of this test could not fail.
    @Test func thePausedClockIsIdenticalAcrossFortyTicks() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, activity, _) = try startedCoordinator(clock: clock)
        clock.advance(600)
        c.pause()
        for _ in 0..<40 { clock.advance(0.4999997); tick(c, clock) }
        let paused = activity.clocks.filter(\.isPaused)
        #expect(paused.count >= 40)
        #expect(Set(paused).count == 1)
    }

    /// Slew alone must not flap `align`. A divergence under the threshold changes nothing, so the
    /// stop still costs one payload rather than one every coalescing interval.
    @Test func aSubThresholdDivergenceChangesNothing() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, activity, _) = try startedCoordinator(clock: clock)
        clock.advance(600)
        c.pause()
        clock.step = 1.9
        for _ in 0..<40 { clock.advance(0.4999997); tick(c, clock) }
        #expect(Set(activity.clocks.filter(\.isPaused)).count == 1)
    }

    /// Spec fixture 14: a real step produces exactly one new distinct clock, and the ticks after
    /// it are identical again. One push, then quiet.
    @Test func aStepProducesExactlyOneNewPausedClock() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, activity, _) = try startedCoordinator(clock: clock)
        clock.advance(600)
        c.pause()
        for _ in 0..<10 { clock.advance(0.5); tick(c, clock) }
        clock.step = -40
        for _ in 0..<10 { clock.advance(0.5); tick(c, clock) }
        #expect(Set(activity.clocks.filter(\.isPaused)).count == 2)
    }

    /// The whole reason a step has to move the anchor at all: the widget renders `now - since` on
    /// the OS's wall clock, so an uncorrected `since` leaves the Lock Screen off by the step.
    @Test func aStepDuringAStopMovesTheStopAnchorByTheStep() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, activity, _) = try startedCoordinator(clock: clock)
        clock.advance(600)
        c.pause()
        tick(c, clock)
        let before = try #require(activity.clocks.last)
        clock.step = -40
        clock.advance(0.5)
        tick(c, clock)
        let after = try #require(activity.clocks.last)
        guard case .paused(let s0, _) = before, case .paused(let s1, _) = after else {
            Issue.record("expected two paused clocks"); return
        }
        #expect(s1.timeIntervalSince(s0) == -40)
    }

    /// And the converse: a stop opened *after* the step must not be corrected again. The Lock
    /// Screen's stop timer opens at zero, not at 0:40, and never counts down.
    @Test func aStopOpenedAfterAStepOpensAtZero() throws {
        for step in [-40.0, 40.0] {
            let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
            let (c, activity, _) = try startedCoordinator(clock: clock)
            clock.advance(300)
            clock.step = step
            tick(c, clock)
            clock.advance(300)
            c.pause()
            tick(c, clock)
            guard case .paused(let since, _) = try #require(activity.clocks.last) else {
                Issue.record("expected a paused clock"); return
            }
            #expect(since == clock.now().date, "stop timer opens at zero, step \(step)")
        }
    }
}
```

`SpyRideActivity` needs to record the clocks it is handed. Add to it, wherever it is declared (`grep -rn 'class SpyRideActivity' AuraCore/Tests`):

```swift
    /// Every clock this spy has been pushed, in order — for the dedupe fixtures, which assert on
    /// how many *distinct* values a span of ticks produced.
    private(set) var clocks: [RideActiveClock] = []
```

appended in its `update(...)`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter RideSessionClockStepTests`
Expected: FAIL — `SpyRideActivity` has no `clocks`, and the anchor fixtures fail because `pushActivityUpdate` still builds the clock from the coordinator's `startedAt` and the raw `pausedSince`.

- [ ] **Step 3: Reshape `make`**

In `RideActiveClock.swift`, keep the enum exactly as it is and add above it:

```swift
/// The stop currently in progress, as two values stamped together at the pause.
///
/// One optional instead of two: `since` and `activeSecondsAtPause` are non-nil under exactly the
/// same condition, and a half-supplied pair is a state `make` would have to decide about.
public struct RideOpenStop: Equatable, Sendable {
    /// When this stop began, on the current system clock — `RideRecorder.anchorPausedSince`.
    public let since: Date
    /// The ride's active time frozen at that instant — `RideRecorder.activeSecondsAtPause`, which
    /// is where the floor-at-zero this type does not enforce actually lives.
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
    /// **Nothing here is derived from `now` except the two clamps.** The controller skips a push
    /// when the whole payload is unchanged, which is what keeps a forty-minute café stop to one
    /// heartbeat push a minute. Recomputing either case's value per tick from a monotonic elapsed
    /// and a wall `now` — which cannot be sampled at the same instant — makes every payload
    /// distinct and pushes every coalescing interval instead (ROH-130 D5).
    ///
    /// A real clock step moves `startedAt` and `openStop.since` through the recorder's
    /// `wallOffset`, which emits exactly one push and lets the Lock Screen correct itself.
    public static func make(startedAt: Date,
                            pausedSeconds: TimeInterval,
                            openStop: RideOpenStop?,
                            now: Date) -> RideActiveClock {
        if let openStop {
            // Symmetric with the running clamp, and for the same reason: `Text(_, style: .timer)`
            // counts DOWN from a future instant. `RideRecorder.anchorPausedSince` cannot produce
            // one, so this only ever catches a `RideInstant.now` whose two clocks were sampled
            // across a deschedule.
            return .paused(since: min(now, openStop.since),
                           activeSeconds: openStop.activeSecondsAtPause)
        }
        return .running(anchor: RideDuration.runningAnchor(startedAt: startedAt,
                                                           pausedSeconds: pausedSeconds,
                                                           now: now))
    }
```

Update the type's header comment: the paused case's values are frozen at the pause rather than kept constant by cancellation, and the residual-weakness sentence naming ROH-130 goes.

- [ ] **Step 4: Rewire the coordinator**

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

- [ ] **Step 5: Rewrite the orphaned `RideActiveClock` tests**

`make`'s signature changes, so all eight calls in `RideActiveClockTests.swift` and both in `ActiveTimeAgreementTests.swift` stop compiling. Four of them also lose their subject, because the arithmetic they pin moved into `RideRecorder.pause(at:)` — which `AuraCoreTests` cannot import.

- `runningWithNoPauses` (:11), `runningAfterOnePause` (:20), `runningIsStableAcrossTicks` (:30), `anchorClampedToNow` (:40): re-spell with `openStop: nil`. Expected values are unchanged — verify that, do not adjust them.
- `pausedCarriesStopInstantAndFrozenActive` (:51), `pausedAfterAnEarlierStop` (:62), `frozenActiveClampedAtZero` (:84): **delete**. Their arithmetic is now covered by `RideClockStepTests.activeSecondsAtPauseIsActiveTimeAtTheTap`, `.aSecondStopFreezesActiveTimeNetOfTheFirst`, and — for the floor — `RideDurationTests.activeFloorsAtZeroRatherThanGoingNegative` plus the `max(0,)` inside `RideDuration.activeSeconds` that `pause(at:)` calls. Leave a comment at the deletion site naming where each went, so the next reader does not think coverage was dropped.
- `pausedIsStableAcrossTicks` (:68): **delete**, and note that its replacement is
  `RideSessionClockStepTests.thePausedClockIsIdenticalAcrossFortyTicks`, which drives the wiring
  rather than a field copy.
- `codableRoundTrip` (:89): unchanged, and it must stay — it is what pins the wire format.
- `ActiveTimeAgreementTests.pausedClockMatchesPrimitive` (:33): the paused branch no longer calls the primitive, so this assertion is not expressible there. Replace it with a `RideClockStepTests` case asserting that `recorder.activeSecondsAtPause` equals `RideDuration.activeSeconds` over the recorder's own elapsed and paused at the tap. Keep the running-branch case (`:50`) in place, re-spelled.

- [ ] **Step 6: Add the `betweenStamps` detector**

In `scripts/check-single-active-definition.sh`, extend `detect()`:

```bash
detect() {
  sed -E 's|//.*$||' | grep -E \
    '(-[[:space:]]*[A-Za-z_.]*[Pp]ausedSeconds)|(addingTimeInterval\([A-Za-z_.]*[Pp]ausedSeconds)|(betweenStamps)' \
    || true
}
```

and in `self_test`, before the existing `ok` case:

```bash
  local bad_wall='x.swift:1:      elapsed: .betweenStamps(startedAt: startedAt, endedAt: now),'
  [ -n "$(printf '%s\n' "$bad_wall" | detect)" ] || { echo "SELF-TEST FAIL: missed a wall-derived elapsed"; exit 2; }
  local ok_mono='x.swift:1:      elapsed: .measured(r.elapsedSeconds(asOf: now)),'
  [ -z "$(printf '%s\n' "$ok_mono" | detect)" ] || { echo "SELF-TEST FAIL: flagged a monotonic elapsed"; exit 2; }
```

Mirror the same alternative into the `offenders=` grep pattern so it matches `detect()`.

Update the script's header: three sites compute active time now, not four — the Live Activity's paused branch carries a value the recorder froze rather than computing one. And the second detector exists because a live caller deriving elapsed from a `Date` pair reintroduces ROH-130 while still calling the one definition; `betweenStamps` is a single token, so — unlike a regex over the call itself — a line wrapped at the 140-column limit cannot walk past it.

- [ ] **Step 7: Run the gate**

Run: `swift test --package-path AuraCore`
Expected: PASS, both totals.

Run: `bash scripts/check-single-active-definition.sh && bash scripts/check-monotonic-instants.sh && swiftlint lint --strict`
Expected: all PASS. The first must print `(self-test OK)`.

- [ ] **Step 8: Commit**

```bash
git add AuraCore scripts/check-single-active-definition.sh
git commit -m "fix(roh-130): build the Live Activity clock from stamps, not from now"
```

---

### Task 5: The push policy stops measuring itself on the wall clock

**Files:**
- Modify: `AuraCore/Sources/AuraCore/Ride/RideActivityPushPolicy.swift:29-43`
- Modify: `Aura/Sources/LiveActivity/RideLiveActivityController.swift:36,79,87,100,112-119,149`
- Test: the existing push-policy suite (`grep -rln RideActivityPushPolicy AuraCore/Tests`)

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

Re-spell every existing `decide(last:next:lastPushedAt:now:)` call in that suite as
`secondsSinceLastPush:` with the interval those two dates expressed, changing no expected decision.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path AuraCore --filter PushPolicy`
Expected: FAIL to compile — `decide` takes `lastPushedAt:` and `now:`.

- [ ] **Step 3: Change the policy**

```swift
    /// `secondsSinceLastPush` is nil before the first push of an activity.
    ///
    /// A `TimeInterval` rather than two `Date`s: the caller measures it on the monotonic clock, so
    /// a system clock step cannot make it negative and stall every gate below (ROH-130 D6).
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

Replace `private var lastPushedAt: Date?` (line 36) with:

```swift
    /// Monotonic, so a system clock step cannot stall every push gate at once (ROH-130 D6).
    private var lastPushedMonotonicSeconds: TimeInterval?
```

- Line 79 (`lastPushedAt = startedAt`): `lastPushedMonotonicSeconds = RideInstant.now.monotonicSeconds`
- Lines 87 and 149 (`lastPushedAt = nil`): `lastPushedMonotonicSeconds = nil`
- In `update`, replace line 100 and lines 112-119:

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

`enqueue`'s `staleDate` keeps `Date()` — it is an absolute deadline the OS evaluates on its own wall clock, not an interval this app measures.

- [ ] **Step 5: Run the gate**

Run: `swift test --package-path AuraCore`
Expected: PASS, both totals.

Delegate to the `apple-platform-build-tools:builder` subagent: build scheme `Aura` for an iOS simulator, report failures only.

- [ ] **Step 6: Commit**

```bash
git add AuraCore Aura/Sources/LiveActivity/RideLiveActivityController.swift
git commit -m "fix(roh-130): measure the Live Activity push cadence monotonically"
```

---

### Task 6: Close the loop — Health, docs, and the full gate

**Files:**
- Verify: `Aura/Sources/Health/WorkoutWriter.swift`, `AuraCore/Sources/AuraCore/Health/WorkoutData.swift`, `RideWorkoutGate.swift`
- Modify: any file still describing ROH-130 as open

- [ ] **Step 1: Check the Health write tolerates a derived `endedAt`**

Spec D3's stated residual is that after a backward step a finished ride's `endedAt` sits slightly ahead of the current wall clock. Read all three:

- `WorkoutData.swift:32` — confirm `end` is still `>= start`.
- `RideWorkoutGate.swift:11` — a nil check, confirm it is unaffected.
- `Aura/Sources/Health/WorkoutWriter.swift:59-101` — **this is the one that matters**, and plan revision 1 did not name it. It calls `beginCollection(at:)` / `endCollection(at:)` / `finishWorkout` inside a `do` whose `catch` only logs, so if `HKWorkoutBuilder` rejects a future end date the rider gets no workout in Health and no signal anywhere in Aura.

If `HKWorkoutBuilder` documents a rejection for a future `endDate`, **stop and report** — clamping it here would trade a correct duration for a silent one, which is a spec-level decision, not an implementation detail.

- [ ] **Step 2: Sweep for stale ROH-130 references**

Run: `grep -rn 'ROH-130' --include='*.swift' --include='*.md' --include='*.sh' . | grep -v docs/superpowers`
Every remaining mention must describe the fix or a documented residual, not an open weakness.

- [ ] **Step 3: Run the whole gate**

```bash
swift test --package-path AuraCore
```

```bash
bash scripts/check-single-active-definition.sh && bash scripts/check-monotonic-instants.sh && bash scripts/check-explore-rename.sh && bash scripts/check-terrain-style.sh && swiftlint lint --strict
```

Then delegate to `apple-platform-build-tools:builder`: build scheme `Aura` and run the XCUITest golden-ride suite.

Expected: all green. Read both `swift test` totals.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(roh-130): retire the open-weakness notes the fix closes"
```

---

## After the plan: the device pass

Not a task here, because it is not something a subagent can do and not something the merge should be allowed to imply. It is spec §Device verification, tracked as its own Linear issue, and it stays open after ROH-130 closes. Nothing in the package suite can see the Lock Screen, which is where this change's worst failure mode lives and where a navigated ride's only active-time reading is.
