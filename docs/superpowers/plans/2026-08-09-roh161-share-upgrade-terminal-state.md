# ROH-161 — Share-upgrade terminal state and retry: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the post-ride share-map upgrade a presentation deadline, a terminal state that
offers another attempt, and a retry — so a rider who loses the map is told, and can ask again.

**Architecture:** Three layers, bottom-up. `SharePipelineSlot.run` stops collapsing "the pipeline
produced nothing" and "a ceiling fired while you waited" into one `nil` and returns a
`SlotOutcome` instead; `ShareMapRasterProviding` carries that distinction up as a
`ShareMapOutcome`; a new `ShareUpgradePresenter` in AuraKit owns every timing rule (show-delay,
6 s deadline, 1 s minimum dwell, one-shot automatic retry) behind injected timers so it is
unit-tested in CI. `RideSummaryView` renders the presenter's phase and supplies the effects.

**Tech stack:** Swift 6 strict concurrency, SwiftUI, `@Observable`, XCTest. Package code in
`AuraCore/Sources/AuraKit`, app code in `Aura/Sources`.

**Spec:** `docs/superpowers/specs/2026-08-06-roh161-share-upgrade-terminal-state-design.md`
(revision 4). Read it before starting. Where this plan and the spec disagree, the spec wins on
intent and this plan wins on file paths — see *Corrections to the spec* below.

---

## Corrections to the spec

Verified against the tree at `775ac72`. Fix these as you go; do not propagate them.

1. **The ride-end call site is `Aura/Sources/AuraApp.swift:131`, not the HUD views.** The spec's
   Files table names `RideHUDView.swift` and `NavigateHUDView.swift`. Neither constructs a
   `RideSummaryView`. There are exactly two call sites: `AuraApp.swift:131` (ride-end) and
   `Aura/Sources/History/HistoryView.swift:53` (History).
2. **`SharePipelineSlot.run` has two literal `return nil` sites, not three** — `:111` (waiter
   ceiling) and `:134` (owner ceiling). The other two returns are `:96` and `:128`, which return
   a `Value?` that may itself be nil. The mapping the spec intends is still exactly right: both
   ceilings become `.stoppedWaiting`, both completions become `.finished(value)`.

## Assumption carried forward

The spec marks its ride-end-only scope "**Assumption, overturnable** — recommended and not
explicitly ratified." This plan builds it as specified: the terminal state and retry appear at
ride end only, History keeps today's silent behaviour. If that is reversed, the change is the
default on the `presentation:` parameter in Task 9 plus one line in Task 11; no other task moves.

## File structure

| File | Responsibility | Task |
|---|---|---|
| `AuraCore/Sources/AuraKit/Sharing/SharePipelineSlot.swift` | modify — `run` returns `SlotOutcome<Value>`; no policy change | 1 |
| `AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift` | modify — mechanical update, plus one new test per outcome case | 1 |
| `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift` | create — `ShareUpgradePhase`, `Retryability`, `ShareUpgradeResult`. Types only | 2 |
| `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift` | create — every timing rule, behind three injected timers | 2–6 |
| `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift` | create — the whole presenter contract | 2–6 |
| `Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift` | modify — `ShareMapOutcome`; protocol return type | 7 |
| `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift` | modify — map `SlotOutcome` onto `ShareMapOutcome` | 7 |
| `Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift` | modify — generation is per-attempt | 8 |
| `Aura/Sources/AuraApp.swift`, `Aura/Sources/History/HistoryView.swift` | modify — pass `presentation:` | 9 |
| `Aura/Sources/Ride/RideSummaryView.swift` | modify — parameter, extracted `runUpgrade`, reserved phase row, Try again, background-return handler, announcements | 9–12 |

**Commands.** Package tests: `swift test --package-path AuraCore --no-parallel`. Add
`--filter <TestClass>/<testName>` to run one. The app build goes to the
`apple-platform-build-tools` builder subagent (CLAUDE.md) — never run `xcodebuild` inline, it
takes ~13 minutes and floods the session.

---

### Task 1: `SlotOutcome` — stop collapsing "rejected" into "stopped waiting"

This is the spec's central finding made real. `SharePipelineSlot` already knows which case it is
in and throws the distinction away at the return.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Sharing/SharePipelineSlot.swift:89-136`
- Test: `AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `SharePipelineSlotTests.swift`. These use the file's existing private helpers —
`Gate`, `WorkLog`, `Ceiling`, `blockingWork`, `settle` — which are already in the file; do not
redefine them.

```swift
func testOwnerCeilingReportsStoppedWaitingRatherThanAFinishedNil() async {
    let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.firesAtOnce())
    let gate = Gate(), log = WorkLog()

    let outcome = await slot.run(key: "a", work: blockingWork(key: "a", gate: gate, log: log, value: "a"))

    XCTAssertEqual(outcome, .stoppedWaiting,
                   "the owner's ceiling cancelled the pipeline but it is still alive and holds the slot")
    gate.open()
    await settle()
}

func testWaiterCeilingReportsStoppedWaiting() async {
    let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.firesForEveryArmAfterTheFirst())
    let gate = Gate(), log = WorkLog()

    async let owner = slot.run(key: "a", work: blockingWork(key: "a", gate: gate, log: log, value: "a"))
    await settle()
    let waiter = await slot.run(key: "b", work: blockingWork(key: "b", gate: .opened(), log: log, value: "b"))

    XCTAssertEqual(waiter, .stoppedWaiting, "a waiter's ceiling says nothing about the pipeline")
    gate.open()
    _ = await owner
    await settle()
}

func testAPipelineThatProducesNothingReportsFinishedNil() async {
    let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())

    let outcome = await slot.run(key: "a", work: { nil })

    XCTAssertEqual(outcome, .finished(nil),
                   "the pipeline ran to completion and produced nothing — a retry is a real second attempt")
}

func testASuccessfulPipelineReportsFinishedValue() async {
    let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())

    let outcome = await slot.run(key: "a", work: { "map" })

    XCTAssertEqual(outcome, .finished("map"))
}
```

`SlotOutcome` must be `Equatable` where `Value: Equatable` for these assertions. Declare it
`Equatable` conditionally, not unconditionally — `Value` is `UIImage` in production and
`Equatable` on it would be a lie.

- [ ] **Step 2: Run them and watch them fail**

```bash
swift test --package-path AuraCore --no-parallel --filter SharePipelineSlotTests
```

Expected: compile failure — `cannot find type 'SlotOutcome' in scope`.

- [ ] **Step 3: Add the type and change the return**

In `SharePipelineSlot.swift`, above the class:

```swift
/// What a caller learned from one trip through the slot.
///
/// The distinction is the point. `SharePipelineSlot` was rewritten (ROH-126) so that a
/// ceiling stops the *caller* waiting without stopping the *pipeline* — `run` used to
/// return nil for both, which told a caller that wanted to offer a retry nothing about
/// whether a retry would be a second attempt or a re-join of the pipeline still running.
/// `SharePipelineSlotTests.testSameKeyRetryDuringUnwindJoinsTheDyingPipeline` is the
/// checked-in proof that they are different.
public enum SlotOutcome<Value: Sendable>: Sendable {
    /// The pipeline ran to completion. `nil` means it produced nothing — there is no
    /// negative cache, so a later request re-runs it in full.
    case finished(Value?)
    /// A ceiling fired. The pipeline may still be alive and holding the slot; this says
    /// nothing about whether a map is obtainable.
    case stoppedWaiting
}

extension SlotOutcome: Equatable where Value: Equatable {}
```

Then change `run`'s signature to `-> SlotOutcome<Value>` and its four returns:

| Line (before) | Was | Becomes |
|---|---|---|
| `:96` | `return value` | `return .finished(value)` |
| `:111` | `return nil` | `return .stoppedWaiting` |
| `:128` | `return value` | `return .finished(value)` |
| `:134` | `return nil` | `return .stoppedWaiting` |

**Change nothing else.** Not the ceiling policy, not who cancels, not who frees the slot, not
`onCeiling`. This task is additive information and must be provably behaviour-free.

Update the doc comment on `run` to say what the return now carries.

- [ ] **Step 4: Update the existing tests mechanically**

Every existing `SharePipelineSlotTests` assertion on `run`'s result needs rewriting against the
new type. **Preserve each test's meaning exactly** — in particular
`testSameKeyRetryDuringUnwindJoinsTheDyingPipeline` (`:261`) still asserts the retry does not
start a second pipeline; its `XCTAssertNil(retry, ...)` becomes
`XCTAssertEqual(retry, .stoppedWaiting, "the retry inherits the cancelled pipeline's outcome")`
and the `log.started == 1` assertion is untouched. If a rewrite makes a test weaker, stop and
say so rather than landing it.

- [ ] **Step 5: Run the whole package suite**

```bash
swift test --package-path AuraCore --no-parallel
```

Expected: PASS, with no test deleted and none made weaker.

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Sharing/SharePipelineSlot.swift AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift
git commit -m "feat(roh-161): SharePipelineSlot.run reports whether the pipeline finished

A ceiling stopping a caller and a pipeline producing nothing were both nil.
A design that offers a retry has to tell them apart: only one of them means
the retry is a second attempt. No policy changes."
```

---

### Task 2: The phase types and the show-delay

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift`
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import os
@testable import AuraKit

/// A hand-fired timer: `fire()` releases whoever is sleeping on it. One per hop, because a
/// single shared closure can only be told apart by matching on its `Duration` — which means
/// hardcoding production constants into the test — or by call order.
private final class ManualTimer: Sendable {
    private let gate = TimerGate()
    var closure: @Sendable (Duration) async -> Void { { [gate] _ in await gate.wait() } }
    func fire() { gate.open() }
}

@MainActor
final class ShareUpgradePresenterTests: XCTestCase {

    func testTheIndicatorIsHiddenUntilTheShowDelayFires() async {
        let showDelay = ManualTimer()
        let presenter = ShareUpgradePresenter(showDelayTimer: showDelay.closure,
                                              deadlineTimer: ManualTimer().closure,
                                              dwellTimer: ManualTimer().closure)
        let work = WorkGate()

        let running = Task { await presenter.attempt(isRetry: false) { await work.result() } }
        await settle()
        XCTAssertEqual(presenter.phase, .upgrading, "in flight, but nothing on screen yet")

        showDelay.fire()
        await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible)

        work.resolve(.gotMap)
        await running.value
    }

    func testAResultBeforeTheShowDelayNeverShowsTheIndicator() async {
        let showDelay = ManualTimer()
        let presenter = ShareUpgradePresenter(showDelayTimer: showDelay.closure,
                                              deadlineTimer: ManualTimer().closure,
                                              dwellTimer: ManualTimer().closure)

        await presenter.attempt(isRetry: false) { .gotMap }

        XCTAssertEqual(presenter.phase, .upgraded(confirming: false),
                       "a warm hit must not flash the hint — ROH-126 §Share flow step 4")
    }

    func testARetryShowsItsIndicatorImmediately() async {
        let showDelay = ManualTimer()   // never fired
        let presenter = ShareUpgradePresenter(showDelayTimer: showDelay.closure,
                                              deadlineTimer: ManualTimer().closure,
                                              dwellTimer: ManualTimer().closure)
        let work = WorkGate()

        let running = Task { await presenter.attempt(isRetry: true) { await work.result() } }
        await settle()

        XCTAssertEqual(presenter.phase, .upgradingVisible,
                       "the rider just pressed a button and needs to see it registered")
        work.resolve(.gotMap)
        await running.value
    }
}
```

Write `TimerGate`, `WorkGate` (a one-shot gate returning a `ShareUpgradeResult`) and `settle()`
as private helpers in this file, modelled on `SharePipelineSlotTests`' `Gate` and `settle`. Keep
them top-level-private in the file so SwiftLint's nesting rule stays happy — the slot tests
document that constraint at their own `Gate`.

- [ ] **Step 2: Run and watch it fail**

```bash
swift test --package-path AuraCore --no-parallel --filter ShareUpgradePresenterTests
```

Expected: compile failure — no `ShareUpgradePresenter`.

- [ ] **Step 3: Create the types**

`ShareUpgradePhase.swift` — types only, no behaviour:

```swift
import Foundation

/// Whether a retry from this terminal state is a real second attempt.
public enum Retryability: Equatable, Sendable {
    /// The pipeline ran and produced nothing. There is no negative cache, so a retry
    /// re-runs it in full — this is the offline-at-the-trailhead case that ROH-161 exists
    /// for, and the only case the automatic retry is allowed to fire on.
    case freshAttempt
    /// A ceiling fired. A retry may warm-hit a cache the pipeline filled after we stopped
    /// waiting, or re-join the pipeline still running. Still worth offering to a rider who
    /// asks — but never done on their behalf.
    case mayRejoin
}

public enum ShareUpgradePhase: Equatable, Sendable {
    case idle
    case upgrading
    case upgradingVisible
    case slow
    case unavailable(Retryability)
    case upgraded(confirming: Bool)
}

/// What one attempt produced, with no `UIImage` in it — the presenter stays in AuraKit and
/// the app keeps the image.
public enum ShareUpgradeResult: Sendable {
    case gotMap
    case rejected
    case stoppedWaiting
}
```

- [ ] **Step 4: Create the presenter with the show-delay only**

```swift
import Foundation
import Observation

@Observable @MainActor
public final class ShareUpgradePresenter {
    public private(set) var phase: ShareUpgradePhase = .idle

    @ObservationIgnored private let showDelay: @Sendable (Duration) async -> Void
    @ObservationIgnored private var isAttempting = false
    @ObservationIgnored private var showDelayHop: Task<Void, Never>?

    /// Timers are `nil`-defaulted and the real closures are built HERE, in the defining
    /// module. ROH-110: an async closure *default argument* is duplicated into every module
    /// that references the declaration and the copies can disagree about frame size, which
    /// aborts the process. `SharePipelineSlot.swift:59-67` carries the same note.
    public init(showDelay showDelayDuration: Duration = .milliseconds(300),
                showDelayTimer: (@Sendable (Duration) async -> Void)? = nil) {
        self.showDelayDuration = showDelayDuration
        self.showDelay = showDelayTimer ?? { try? await Task.sleep(for: $0) }
    }

    /// Runs one attempt end to end. There is no `begin`/`finish` pair to leave unpaired —
    /// which matters because an unpaired `finish` is a permanent spinner, this issue's own
    /// bug reintroduced.
    public func attempt(isRetry: Bool, _ work: () async -> ShareUpgradeResult) async {
        guard !isAttempting else { return }
        isAttempting = true
        defer { isAttempting = false }

        if isRetry {
            phase = .upgradingVisible
        } else {
            phase = .upgrading
            showDelayHop = Task { [weak self] in
                await self?.showDelay(self?.showDelayDuration ?? .milliseconds(300))
                guard !Task.isCancelled, let self, self.phase == .upgrading else { return }
                self.phase = .upgradingVisible
            }
        }

        let result = await work()
        showDelayHop?.cancel()
        phase = terminalPhase(for: result, isRetry: isRetry)
    }
}
```

(Tasks 3–6 grow this; `terminalPhase(for:isRetry:)` arrives properly in Task 5. For now give it
the minimal body that satisfies these three tests: `.gotMap → .upgraded(confirming: isRetry)`,
everything else `→ .unavailable(.freshAttempt)`.)

- [ ] **Step 5: Run the tests**

```bash
swift test --package-path AuraCore --no-parallel --filter ShareUpgradePresenterTests
```

Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift
git commit -m "feat(roh-161): ShareUpgradePresenter with the show-delay

One wrapping attempt() rather than begin/finish, so there is no way to start
an attempt without ending it. A retry skips the show-delay: the rider just
pressed a button."
```

---

### Task 3: The 6 s presentation deadline

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift`
- Test: `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testTheDeadlineMovesAVisibleUpgradeToSlow() async {
    let showDelay = ManualTimer(), deadline = ManualTimer()
    let presenter = ShareUpgradePresenter(showDelayTimer: showDelay.closure,
                                          deadlineTimer: deadline.closure,
                                          dwellTimer: ManualTimer().closure)
    let work = WorkGate()
    let running = Task { await presenter.attempt(isRetry: false) { await work.result() } }
    await settle()
    showDelay.fire(); await settle()

    deadline.fire(); await settle()

    XCTAssertEqual(presenter.phase, .slow)
    work.resolve(.gotMap)
    await running.value
}

func testTheDeadlineDoesNothingOnceTheAttemptHasResolved() async {
    let deadline = ManualTimer()
    let presenter = ShareUpgradePresenter(showDelayTimer: ManualTimer().closure,
                                          deadlineTimer: deadline.closure,
                                          dwellTimer: ManualTimer().closure)

    await presenter.attempt(isRetry: false) { .gotMap }
    deadline.fire(); await settle()

    XCTAssertEqual(presenter.phase, .upgraded(confirming: false),
                   "a fired deadline must never resurrect a spinner over a finished attempt")
}

func testASlowAttemptThatSucceedsEndsUpgradedAndNeverClaimsFailure() async {
    let showDelay = ManualTimer(), deadline = ManualTimer(), dwell = ManualTimer()
    let presenter = ShareUpgradePresenter(showDelayTimer: showDelay.closure,
                                          deadlineTimer: deadline.closure,
                                          dwellTimer: dwell.closure)
    let work = WorkGate()
    let running = Task { await presenter.attempt(isRetry: false) { await work.result() } }
    await settle(); showDelay.fire(); await settle(); deadline.fire(); await settle()

    work.resolve(.gotMap)
    dwell.fire()
    await running.value

    XCTAssertEqual(presenter.phase, .upgraded(confirming: false))
}
```

- [ ] **Step 2: Run and watch it fail**

Expected: compile failure on the `deadlineTimer:` argument.

- [ ] **Step 3: Add the deadline hop**

A second injected timer and a second hop, armed alongside the show-delay hop and cancelled at
the same place. The hop's guard is `phase == .upgradingVisible || phase == .upgrading` —
the deadline can fire before the show-delay on a device where the attempt is slow and the two
hops raced, and `slow` is the honest phase either way.

**The deadline must not cancel `work`.** It changes what is on screen and nothing else. The
pipeline's own comments argue this at length (`ShareMapSnapshotter.swift:161-178`): a late
cancel throws away a style load and an SDK render and, with no negative cache, makes the next
request pay for all of it again.

- [ ] **Step 4: Run the tests** — expect PASS (6 total).

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(roh-161): the 6 s presentation deadline

A fourth timeout, and deliberately none of the three that exist — the ceiling
protects the singleton, the belts bound SDK calls, and none of them serve the
rider. It stops the spinner, never the work."
```

---

### Task 4: Minimum dwell, so nothing flashes

The rule that replaces tuning a constant: **any indicator the presenter shows stays for at least
1 s.** `upgradingVisible` and `slow` each get their own dwell.

Implement it clock-free, so it is testable with a hand-fired timer: entering an indicator phase
sets `dwellSatisfied = false` and arms the dwell hop; a terminal phase arriving while
`dwellSatisfied` is false is parked in `pendingTerminal` and applied by the hop when it fires.
A terminal phase arriving from `.upgrading` (no indicator was ever shown) applies immediately.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift`
- Test: `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testAnIndicatorHoldsForTheDwellBeforeATerminalPhaseIsApplied() async {
    let showDelay = ManualTimer(), dwell = ManualTimer()
    let presenter = ShareUpgradePresenter(showDelayTimer: showDelay.closure,
                                          deadlineTimer: ManualTimer().closure,
                                          dwellTimer: dwell.closure)
    let work = WorkGate()
    let running = Task { await presenter.attempt(isRetry: false) { await work.result() } }
    await settle(); showDelay.fire(); await settle()

    work.resolve(.rejected)
    await settle()
    XCTAssertEqual(presenter.phase, .upgradingVisible, "still held by the dwell")

    dwell.fire()
    await running.value
    XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt))
}

func testAWarmRetryStillShowsItsIndicatorForTheDwell() async {
    let dwell = ManualTimer()
    let presenter = ShareUpgradePresenter(showDelayTimer: ManualTimer().closure,
                                          deadlineTimer: ManualTimer().closure,
                                          dwellTimer: dwell.closure)

    let running = Task { await presenter.attempt(isRetry: true) { .gotMap } }
    await settle()
    XCTAssertEqual(presenter.phase, .upgradingVisible,
                   "without the dwell a warm retry is unavailable → upgrading → upgraded with nothing visible")

    dwell.fire()
    await running.value
    XCTAssertEqual(presenter.phase, .upgraded(confirming: true))
}

func testEnteringSlowRestartsTheDwell() async {
    // upgradingVisible's dwell has already been satisfied; slow gets its own.
}
```

Fill in the third test body following the same shape.

- [ ] **Step 2: Run and watch it fail.**
- [ ] **Step 3: Implement `dwellSatisfied` / `pendingTerminal` as described above.**
- [ ] **Step 4: Run the tests** — expect PASS (9 total).
- [ ] **Step 5: Commit.**

---

### Task 5: Terminal phases, re-entrancy, and cancellation

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift`
- Test: `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testRejectedAndStoppedWaitingReachDifferentRetryabilities() async {
    // .rejected → .unavailable(.freshAttempt)
    // .stoppedWaiting → .unavailable(.mayRejoin)
}

func testASecondAttemptWhileOneIsInFlightIsANoOp() async {
    // and arms no second deadline hop — assert the phase does not jump and the
    // in-flight attempt still completes normally
}

func testACancelledAttemptStillLandsInATerminalPhase() async {
    // cancel the Task running attempt(); assert the phase is terminal, never an
    // absorbing spinner. This is THE regression test for this issue's own bug.
}

func testNoUpgradePossibleParksInIdleAndFiresNoHop() async {
}
```

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Implement**

`terminalPhase(for:isRetry:)`:

| Result | Phase |
|---|---|
| `.gotMap` | `.upgraded(confirming: isRetry)` |
| `.rejected` | `.unavailable(.freshAttempt)` |
| `.stoppedWaiting` | `.unavailable(.mayRejoin)` |

**The cancellation path needs care and is the one place `defer` is not enough.** A Swift `defer`
block cannot `await`, so it cannot wait out the dwell. Structure it as: the normal path awaits
the dwell remainder and then applies the terminal phase; a `defer` applies the terminal phase
*synchronously, skipping the dwell*, if and only if it has not already been applied. A cancelled
attempt means the view is going away and a minimum visible duration is pointless. Track
"already applied" with a local flag, not by inspecting `phase` — the phase could legitimately
have been moved by a hop.

`noUpgradePossible()` sets `.idle` and cancels every hop.

- [ ] **Step 4: Run the tests** — expect PASS (13 total).
- [ ] **Step 5: Commit.**

---

### Task 6: The one-shot automatic retry

Two things the spec is emphatic about, both of which killed revision 1:

- **Trigger on a return from a real background**, tracked with a `wasBackgrounded` flag set on
  `scenePhase == .background` — not on `.active` from anything. `AuraApp.swift:262-268` already
  documents why: "a transient `.inactive` — Control Center, a notification banner, a permission
  alert" is not a background cycle. The flag lives in the **view** (Task 12); the presenter only
  receives "a real foreground return happened."
- **Never evaluate the phase at the scene edge.** On resume the parked belts are five-plus
  main-actor hops behind, so the `scenePhase` update wins that race and would read `slow`.
  Arming is consumed when the phase *next becomes* `.unavailable(.freshAttempt)` — or
  immediately, if it already is.

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift`
- Test: `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testArmingDuringAnInFlightAttemptFiresWhenItLaterRejects() async {
    // THE pocketed-phone test. Arm while .slow; the attempt then rejects;
    // onAutomaticRetry fires exactly once, after the terminal phase is applied.
}

func testArmingWhenAlreadyUnavailableFreshFiresImmediately() async {}

func testArmingNeverFiresOnMayRejoin() async {
    // re-joining a live pipeline on the rider's behalf is exactly what the
    // Retryability distinction exists to forbid
}

func testOnlyOneAutomaticRetryPerPresentation() async {
    // arm, consume, arm again → the second never fires
}

func testArmingNeverFiresFromIdle() async {}
```

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Implement**

```swift
/// Invoked at most once per presenter, when an armed automatic retry is consumed. The view
/// supplies it; the presenter cannot start work itself.
public var onAutomaticRetry: (@MainActor () -> Void)?

/// A real background→foreground return happened. Arms one automatic retry, consumed when
/// the phase next becomes `.unavailable(.freshAttempt)` — or now, if it already is.
public func armAutomaticRetry()
```

**Ordering trap, state it in a comment:** the callback re-enters `attempt`, and `attempt` is a
no-op while `isAttempting` is true. So the callback must fire *after* `isAttempting` has been
cleared, or the automatic retry silently does nothing. Clear the flag, apply the terminal phase,
*then* consume the arming.

- [ ] **Step 4: Run the whole package suite** — expect PASS.
- [ ] **Step 5: Commit.**

---

### Task 7: `ShareMapOutcome` — carry the distinction across the app seam

**Files:**
- Modify: `Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift:15-20`
- Modify: `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift:143-158`

No unit test: this is app-target code and `Aura/project.yml` declares no unit-test target for
it. The mapping is exercised by Task 13's build and the device pass. Keep it trivial enough that
this is honest — all the judgement lives in the tested presenter.

- [ ] **Step 1: Add the outcome type and change the protocol**

```swift
enum ShareMapOutcome: Sendable {
    case map(UIImage)
    /// The pipeline ran and produced no acceptable map. A retry is a real second attempt.
    case rejected
    /// A ceiling fired. A retry may warm-hit or re-join a pipeline still running.
    case stoppedWaiting
}

@MainActor
protocol ShareMapRasterProviding: Sendable {
    func raster(for request: ShareMapRequest) async -> ShareMapOutcome
}
```

- [ ] **Step 2: Map the outcomes in `ShareMapSnapshotter.raster(for:)`**

| Source | Result |
|---|---|
| Disk-cache fast path hits (`:150`) | `.map(image)` |
| `slot.run` → `.finished(image)` | `.map(image)` |
| `slot.run` → `.finished(nil)` | `.rejected` |
| `slot.run` → `.stoppedWaiting` | `.stoppedWaiting` |
| `self` deallocated (`:155-157`) | `.rejected` |

- [ ] **Step 3: Update the prefetch call site**

`ShareMapProviderBox.prefetchShareMap:54` already discards its result (`_ = await ...`) and needs
no change beyond compiling.

- [ ] **Step 4: Update any test double** conforming to `ShareMapRasterProviding`.

```bash
grep -rn "ShareMapRasterProviding" Aura AuraCore
```

- [ ] **Step 5: Delegate a build** to the `apple-platform-build-tools` builder subagent. Expected:
      compiles clean. Fix and re-delegate until it does.
- [ ] **Step 6: Commit.**

---

### Task 8: Per-attempt generations in `ShareCardFileStore`

Today generation is documented as "0 = fallback card, 1 = map". With retry, more than one
upgrade render can succeed in a presentation, and reusing generation 1 would overwrite a file a
still-live share-sheet consumer may read lazily — the exact hazard the per-presentation UUID
exists to prevent.

**Files:**
- Modify: `Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift:10, 26-31`

- [ ] **Step 1:** Change the doc comment: generation 0 is the fallback, and each upgrade attempt
      that produces a card writes the next generation. `url(generation:)` itself already takes an
      `Int` and needs no signature change — the counter lives in the view (Task 10).
- [ ] **Step 2:** Record the accepted cost in the comment: files accumulate per attempt under the
      presentation's UUID directory, bounded by rider taps, in `tmp`, and `sweepOtherRides()`
      structurally cannot collect the current ride's subtree.
- [ ] **Step 3: Commit.**

---

### Task 9: The `presentation:` parameter and both call sites

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:6-14`
- Modify: `Aura/Sources/AuraApp.swift:131`
- Modify: `Aura/Sources/History/HistoryView.swift:53`

- [ ] **Step 1: Add the parameter**

```swift
/// Which presentation this is. The terminal state and the retry are ride-end only:
/// there is no negative cache, so every History open re-runs the pipeline, and offline a
/// rider paging through old rides would collect an offer on every one of them — for a
/// share card they did not ask for and cannot see on that screen. ROH-126 designated the
/// History reopen as the *recovery* path; making it the complaint path inverts that.
enum SummaryPresentation { case rideEnd, history }

let presentation: SummaryPresentation
```

**Explicitly not** derived from `onDone == nil` (`:13-14`). That correlates today but it is a
callback, not a policy flag.

- [ ] **Step 2:** `AuraApp.swift:131` passes `presentation: .rideEnd`; `HistoryView.swift:53`
      passes `presentation: .history`.
- [ ] **Step 3: Delegate a build.** Expected: compiles clean.
- [ ] **Step 4: Commit.**

---

### Task 10: Wire the presenter into `RideSummaryView`

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:26-37` (state), `:132-196` (the `.task`)

- [ ] **Step 1: Replace the ad-hoc flags with the presenter**

`isUpgrading` and `showHint` go. `@State private var upgrade = ShareUpgradePresenter()`. Keep
`shareImage`, `shareSheetUp`, `deferredUpgrade` exactly as they are.

Add `@State private var generation = 0` for Task 8's counter.

- [ ] **Step 2: Extract `runUpgrade(glanceDebounce:isRetry:)`**

**The 0.8 s sleep stays OUTSIDE `presenter.attempt`, and this is load-bearing.** Putting
`attempt` at the top of the extracted function puts the 300 ms show-delay hop inside the 0.8 s
sleep, so "Adding your map…" appears at t+0.3 s — mid-entrance on every ride end, as a hard
insert. That is verbatim the rev-3 rejection in the ROH-155 record: *"the one drawing operation
the rider actually sees during the entrance, and it was the one left ungated."*

Shape:

```
func runUpgrade(glanceDebounce: Bool, isRetry: Bool) async {
    if glanceDebounce {
        try? await Task.sleep(for: .seconds(0.8))    // keep the three-job comment verbatim
        guard !Task.isCancelled else { return }
    }
    await upgrade.attempt(isRetry: isRetry) {
        switch await shareMap.provider.raster(for: request) {
        case .map(let raster):
            generation += 1
            guard let upgraded = await RideCardRenderer.make(content, mapImage: raster,
                                                             title: title,
                                                             writeTo: fileStore.url(generation: generation))
            else { return .rejected }      // fallback kept, Share stays enabled
            applyOrDeferUpgrade(upgraded)
            return .gotMap
        case .rejected:       return .rejected
        case .stoppedWaiting: return .stoppedWaiting
        }
    }
}
```

Retry passes `glanceDebounce: false` — the debounce exists to stop a *sub-second glance*
committing the slot, and an explicit tap is the case it was never meant to catch.

- [ ] **Step 3: The `.task` calls it**

`.task` keeps its `guard ride.stats != nil, shareImage == nil`, its fallback render, and its
`guard shareImage != nil`. Where it currently gives up because `ShareMapRequest.init` returned
nil (`:146-147`), call `upgrade.noUpgradePossible()` first — that is the no-route path and it
must never show an offer. Same for the failed-fallback path at `:145`.

Store `content`, `fileStore`, `title` and `request` in `@State` so the retry has them.
`ShareCardFileStore` mints a `presentationID` in its initializer, so it must be created **once**
and held — never rebuilt in the retry path, or a retry writes into a different directory.

- [ ] **Step 4: Delegate a build.**
- [ ] **Step 5: Commit.**

---

### Task 11: The reserved phase row and Try again

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:107-114` (the current bare hint)

- [ ] **Step 1: Build the row**

| Phase | Content |
|---|---|
| `.upgrading`, `.idle`, `.upgraded(confirming: false)` | empty (reserved height only) |
| `.upgradingVisible` | `ProgressView` + "Adding your map…" |
| `.slow` | `ProgressView` + "Still adding your map…" |
| `.unavailable` (either) | **"Add the map"** — a button, no sentence |
| `.upgraded(confirming: true)` | "Map added", ~2 s, then empty |

**The terminal state is an offer, not an apology.** No failure sentence, no destructive colour,
no warning glyph, no "couldn't". Nothing is broken — the card is finished and Share is enabled.
Note this overrides the amber `GroupLobbyView.startRetryRow` treatment: that row reports a
failure, this one makes an offer.

There is also a real `StaticRouteMap` at the top of this screen (`:57`), itself rendering
degraded tiles when offline. Any sentence about a map failing, on a screen showing a degraded
map, reads as a diagnosis of the route the rider is looking at. A button cannot be misread that
way.

- [ ] **Step 2: Reserve the height — the requirement, not a nicety**

**The slot reserves its height for the whole presentation whenever an upgrade is possible, so
Done never moves** — not on a phase change, and not when the map lands and the row empties.
Size to the tallest state at the current Dynamic Type size.

Without this: Done sits below the fold on most devices (under map + title + hero + elevation
band + stats + Share), so a rider scrolling to it reaches as the row grows, and lands on **Add
the map** — starting a pipeline they never wanted. The ROH-155 record already names the
mechanism: the hint today "is a hard insert that shoves the Done button down."

- [ ] **Step 3: Gate on presentation**

`presentation == .history` shows the `upgradingVisible` hint exactly as today and never `slow`,
`unavailable` or `upgraded(confirming:)`. **If the ride-end-only scope is reversed, this step is
the one line that changes.**

- [ ] **Step 4: Wire the button**

```swift
Button("Add the map") { Task { await runUpgrade(glanceDebounce: false, isRetry: true) } }
```

`attempt`'s in-flight guard already makes a double-tap a no-op, so no separate debounce.

- [ ] **Step 5: Delegate a build.**
- [ ] **Step 6: Commit.**

---

### Task 12: Background return and accessibility

**Files:**
- Modify: `Aura/Sources/Ride/RideSummaryView.swift`

- [ ] **Step 1: The background-return handler**

```swift
@Environment(\.scenePhase) private var scenePhase
@State private var wasBackgrounded = false
```

```swift
.onChange(of: scenePhase) { _, phase in
    // A REAL background cycle, not `.active` from anything. AuraApp.swift:262-268 carries
    // the same warning: a transient `.inactive` — Control Center, a notification banner, a
    // permission alert — is not a background cycle, and gating on `.active` would spend the
    // one-shot budget on a notification banner.
    if phase == .background { wasBackgrounded = true }
    if phase == .active, wasBackgrounded {
        wasBackgrounded = false
        guard presentation == .rideEnd else { return }
        upgrade.armAutomaticRetry()
    }
}
```

Set `upgrade.onAutomaticRetry` in the same place the presenter is first used, to
`{ Task { await runUpgrade(glanceDebounce: false, isRetry: true) } }`.

- [ ] **Step 2: The announcements**

Posted by the **view** — AuraKit imports no UIKit and cannot post one.

- Announce the transition **into `unavailable`** only.
- **Not** `slow`.
- **Not** a second `unavailable` reached by a failed automatic retry — that would interrupt a
  VoiceOver rider unprompted, seconds after they unlocked the phone.
- The button's accessibility label names what it acts on: "Add the map to your share card".
  "Add the map" alone has an ambiguous antecedent on a screen that also shows a route map.

- [ ] **Step 3: Delegate a build.**
- [ ] **Step 4: Commit.**

---

### Task 13: Full verification

- [ ] **Step 1: Package suite**

```bash
swift test --package-path AuraCore --no-parallel
```

- [ ] **Step 2: App build** via the `apple-platform-build-tools` builder subagent.

- [ ] **Step 3: The device pass — a real device, per CLAUDE.md**

A clean build proves nothing here. Work through the spec's §Testing device list in order:

1. **Measure the real distribution** of upgrade durations and reject timings at ride end, on
   wifi and on cellular. Revision 1 asserted a success envelope that was two timeout caps added
   together. Check 6 s against reality.
2. Airplane mode at ride end → fast `unavailable(.freshAttempt)` + the offer.
3. Re-enable wifi, tap it → map lands, "Map added" shows.
4. Tap it *while still offline* → indicator held ≥1 s, back to the offer, no flicker.
5. Pocket the phone during the window, unlock later on wifi → map present without interaction.
6. Pull down Control Center during `unavailable`, dismiss → **the automatic retry must not fire.**
7. Reach for Done as the phase changes → **Done must not move.** Repeat at an accessibility text
   size.
8. Retry while the share sheet is open → sheet stays up, card swaps on dismissal.
9. VoiceOver: `unavailable` announced once; a failed automatic retry does not announce again.
10. Reduce Motion on → identical deadline behaviour.

Items 7 and 8 overlap **ROH-140** (the ROH-126 device-verification tail) on this same surface —
worth closing what you can of it in the same session on the same phone.

- [ ] **Step 4: Answer the spec's three open questions**, which the device pass exists to answer
      rather than confirm:
      1. Is 6 s right, or does the offer appear too eagerly ahead of a pipeline about to land?
      2. Does the auto-applied swap read as delightful or as a glitch?
      3. **Does the offer change sharing behaviour** — do riders wait for a map they would not
         otherwise have waited for? This is the one risk that argues for the feature's absence.

- [ ] **Step 5: Whole-branch review** on the most capable model (CLAUDE.md pipeline step 6),
      then open the PR and move ROH-161 to **In Review**.

---

## Known risks carried from the spec

Not solved here. Each is stated so nobody discovers them as surprises.

- **The share-sheet latch has a 2 s appearance bound** (`RideSummaryView.swift:398`). If
  `UIActivityViewController` takes longer than 2 s to present, `shareSheetUp` goes false while a
  sheet is up and a late upgrade assigns `shareImage` underneath it — which the 2026-07-31 device
  pass watched dismiss a presented sheet. Today it is nearly unreachable because upgrades resolve
  at ~1.5 s; **retry makes late landings routine and therefore makes this reachable.** Device-pass
  item 8 covers the happy path only. Probably a separate issue — raise it rather than widening
  this one.
- **A committed retry cannot be retracted.** `slot.run` has no cancellation point, so a rider who
  taps and immediately leaves has left a pipeline running for a ride nobody is looking at. Bounded
  by taps on a screen the rider is looking at; not solvable at this layer.
- **`SharePresentation.isPresenting` is true for any modal** (`:437-444`), so an unrelated system
  alert during a retry pins `shareSheetUp`.
- **`@State` copies of `content`/`title` freeze the units** at first render, so a retry after a
  remote units change re-renders with stale units. Present today; retry makes it visible.
- **The `saveFailed` + no-checkpoint case** is where the share card is the only artifact of the
  ride that will ever exist, and Done destroys the retry. Treated identically here; whether it
  deserves special handling is a real product question, deferred.

> `humanizer` is mandated by CLAUDE.md for prose deliverables and is **not installed on this
> machine**, so this plan did not go through it.
