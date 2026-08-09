# ROH-161 — Share-upgrade terminal state and retry: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Revision 2**, after a three-reviewer plan gate against revision 1. See §What revision 1 got
wrong — it is kept because the failures are properties of this work, not of one draft.

**Goal:** Give the post-ride share-map upgrade a deadline, a terminal state that offers another
attempt, and a retry — so a rider who loses the map is told, and can ask again.

**Architecture:** `SharePipelineSlot.run` stops collapsing "the pipeline produced nothing" and "a
ceiling fired while you waited" into one `nil`; `ShareMapRasterProviding` carries that up as a
`ShareMapOutcome`; a `ShareUpgradePresenter` in AuraKit owns every timing rule behind injected
timers so they are unit-tested in CI. `RideSummaryView` renders the phase and supplies effects.

**Spec:** `docs/superpowers/specs/2026-08-06-roh161-share-upgrade-terminal-state-design.md`
(**revision 5** — read it first; revisions 2–4 differ materially).

**Commands.** Package tests: `swift test --package-path AuraCore --no-parallel`. The app build
goes to the `apple-platform-build-tools` builder subagent — never run `xcodebuild` inline.

---

## The code in Tasks 1–2 is verified, not sketched

Revision 1's pasted Swift did not compile: an undeclared property, an initializer that disagreed
with its own tests, and an `async let` that violated Swift 6 isolation in the very file that
documents that trap. Two reviewers demonstrated it by building it.

Everything in Task 2 below was compiled and run in a scratch SwiftPM package under Swift 6.3
language mode before being written here: **16 tests, 0 failures.** Two defects were found that
way and are already fixed in the text you are about to paste — a test-harness race that *hung*
two tests rather than failing them, and a missing absorbing rule that let a newer attempt's
reject retract a map the rider already had.

Task 1's slot change was likewise built and run green by a reviewer.

## Corrections carried into spec revision 5

Recorded here because the plan gate found them and they are now fixed in the spec: the ride-end
call site is `AuraApp.swift:131` (not the HUD views); `run` has two literal `return nil` sites
(not three); `SlotOutcome`'s conditional `Equatable` is right but **not** because `UIImage` isn't
`Equatable` — it is, via `NSObject`.

---

### Task 1: `SlotOutcome` — stop collapsing "rejected" into "stopped waiting"

**Files:**
- Modify: `AuraCore/Sources/AuraKit/Sharing/SharePipelineSlot.swift:89-136`
- Test: `AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift`

- [ ] **Step 1: Add the type and change the return**

Above the class:

```swift
/// What a caller learned from one trip through the slot.
///
/// The distinction is the point. The slot was rewritten (ROH-126) so a ceiling stops the
/// *caller* waiting without stopping the *pipeline*; `run` used to return nil for both,
/// which told a caller that wanted to offer a retry nothing about whether a retry would be
/// a second attempt or a re-join of a pipeline still running.
public enum SlotOutcome<Value: Sendable>: Sendable {
    /// The pipeline ran to completion. `nil` means it produced nothing.
    ///
    /// Not quite "it exhausted itself": a same-key waiter at `:96` returns whatever the
    /// OWNER produced, and an owner whose ceiling fired returns nil through
    /// `cancelledBeforeStarting`. A retry is still a real second attempt in both cases,
    /// which is all `Retryability.freshAttempt` promises. Spec revision 5, §The finding.
    case finished(Value?)
    /// A ceiling fired. The pipeline may still be alive and holding the slot.
    case stoppedWaiting
}

/// Conditional because an unconditional conformance would constrain `Value` for no reason.
/// NOT because `UIImage` isn't `Equatable` — it is, via `NSObject`. Revision 1 said otherwise.
extension SlotOutcome: Equatable where Value: Equatable {}
```

Then `run` returns `SlotOutcome<Value>`, with `:96` and `:128` → `.finished(value)` and `:111`
and `:134` → `.stoppedWaiting`. **Change nothing else** — not the ceiling policy, not who
cancels, not who frees the slot, not `onCeiling`.

- [ ] **Step 2: Update the existing tests — and the `begin` harness**

Revision 1 called this "mechanical, assertions only." It is not: `begin` at
`SharePipelineSlotTests.swift:142` returns `Task<String?, Never>` and must become
`Task<SlotOutcome<String>, Never>`, and `:303` has a generic-parameter conflict. Both are
compile errors, not assertion updates.

**Preserve each test's meaning.** `testSameKeyRetryDuringUnwindJoinsTheDyingPipeline` (`:261`)
keeps its `log.started == 1` assertion untouched; its `XCTAssertNil(retry)` becomes
`XCTAssertEqual(retry, .stoppedWaiting)`. Do **not** relabel it "the retry inherits the dying
pipeline's outcome" — a reviewer instrumented it and the retry trips its own waiter ceiling
without ever observing that pipeline. The spec carries this as an erratum.

- [ ] **Step 3: Add exactly two new tests**

Only two, and **inside the class body** — `blockingWork`, `begin` and `settle` are private
*instance methods* of the test case (`:118`, `:132`, `:142`), so appending at file scope puts
them out of reach. Revision 1 said "append to the file", which does not work.

```swift
func testAPipelineThatProducesNothingReportsFinishedNil() async {
    let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())
    let outcome = await slot.run(key: "a", work: { nil })
    XCTAssertEqual(outcome, .finished(nil),
                   "ran to completion and produced nothing — a retry is a real second attempt")
}

func testASuccessfulPipelineReportsFinishedValue() async {
    let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())
    XCTAssertEqual(await slot.run(key: "a", work: { "map" }), .finished("map"))
}
```

Revision 1 proposed four. Two of them duplicated `testWaiterCeilingLeavesTheOwnersPipelineAlone`
(`:237`) and `testSlotIsReleasedWhenWorkReturnsNil` (`:294`), which after Step 2 already assert
the ceiling and nil cases. One of those duplicates also used `async let`, which does not compile:
the test case is `@MainActor` and an `async let` child would send `self` across isolation —
`:137-138` documents exactly this and is why `begin` exists.

- [ ] **Step 4: Run the package suite**

```bash
swift test --package-path AuraCore --no-parallel
```

Expected: green, no test deleted, none weakened.

- [ ] **Step 5: Commit**

```bash
git add AuraCore/Sources/AuraKit/Sharing/SharePipelineSlot.swift AuraCore/Tests/AuraKitTests/SharePipelineSlotTests.swift
git commit -m "feat(roh-161): SharePipelineSlot.run reports whether the pipeline finished"
```

---

### Task 2: `ShareUpgradePresenter` — every timing rule, in a target that has tests

`Aura/project.yml` declares `Aura`, `AuraWidgets` and `AuraUITests` and no unit-test target, so
anything load-bearing in the app target is untestable. That is the documented reason the ROH-126
ceiling defect survived to a whole-branch review.

Revision 1 spread this over five tasks whose intermediate states did not compile and whose test
list was half comment-only stubs — two of which it labelled "THE" regression test. It is one task
because the verified artifact is one artifact.

**Files:**
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePhase.swift`
- Create: `AuraCore/Sources/AuraKit/Sharing/ShareUpgradePresenter.swift`
- Create: `AuraCore/Tests/AuraKitTests/ShareUpgradePresenterTests.swift`

- [ ] **Step 1: Write the tests first and watch them fail to compile**

The full file, verified. Expected first run: `cannot find 'ShareUpgradePresenter' in scope`.

```swift
import XCTest
import os
@testable import AuraKit

/// Hand-fired and **re-armable**: each `fire()` releases everyone waiting at that moment, and a
/// later arm suspends again. A one-shot gate cannot express a test that arms the same hop twice.
private final class ManualTimer: Sendable {
    private struct State {
        var credits = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var closure: @Sendable (Duration) async -> Void {
        { [state] _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyFired = state.withLock { s -> Bool in
                    guard s.credits > 0 else { s.waiters.append(continuation); return false }
                    s.credits -= 1
                    return true
                }
                if alreadyFired { continuation.resume() }
            }
        }
    }

    /// Releases everyone waiting now, and BANKS A CREDIT for an arm that has not registered yet.
    /// Without the credit this is a race: a hop armed synchronously inside `attempt` may not have
    /// reached its `await` when the test fires, and then waits forever. Two tests hung on exactly
    /// that before the credit existed, and a hung test is far worse than a failing one — it burns
    /// the agent gate's whole timeout and reads as a slow machine.
    func fire() {
        let pending = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            guard s.waiters.isEmpty else { defer { s.waiters = [] }; return s.waiters }
            s.credits += 1
            return []
        }
        for waiter in pending { waiter.resume() }
    }
}

/// For hops a test never intends to fire. A long cancellable sleep rather than a continuation
/// nobody resumes, so nothing is left suspended at teardown.
private func neverFires() -> @Sendable (Duration) async -> Void {
    { _ in try? await Task.sleep(for: .seconds(3600)) }
}

/// Holds `work` open until the test resolves it.
private final class WorkGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [CheckedContinuation<ShareUpgradeResult, Never>]())
    func result() async -> ShareUpgradeResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShareUpgradeResult, Never>) in
            state.withLock { $0.append(continuation) }
        }
    }
    func resolve(_ value: ShareUpgradeResult) {
        let pending = state.withLock { s -> [CheckedContinuation<ShareUpgradeResult, Never>] in
            defer { s = [] }
            return s
        }
        for p in pending { p.resume(returning: value) }
    }
}

private func settle() async {
    for _ in 0..<12 { await Task.yield() }
}

@MainActor
final class ShareUpgradePresenterTests: XCTestCase {

    private func makePresenter(showDelay: ManualTimer? = nil,
                               deadline: ManualTimer? = nil,
                               dwell: ManualTimer? = nil) -> ShareUpgradePresenter {
        ShareUpgradePresenter(showDelayTimer: showDelay?.closure ?? neverFires(),
                              deadlineTimer: deadline?.closure ?? neverFires(),
                              dwellTimer: dwell?.closure ?? neverFires())
    }

    // MARK: show-delay

    func testTheIndicatorIsHiddenUntilTheShowDelayFires() async {
        let showDelay = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await settle()
        XCTAssertEqual(presenter.phase, .upgrading, "in flight, nothing on screen yet")

        showDelay.fire(); await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible)

        work.resolve(.gotMap); dwell.fire(); await running.value
    }

    func testAResultBeforeTheShowDelayNeverShowsTheIndicator() async {
        let presenter = makePresenter()
        await presenter.attempt(origin: .first) { .gotMap }
        XCTAssertEqual(presenter.phase, .upgraded(confirming: false),
                       "a warm hit must not flash the hint, and must not claim a confirmation")
    }

    func testARiderTapShowsItsIndicatorImmediately() async {
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .riderTap) { await work.result() } }
        await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible, "the rider pressed a button")

        work.resolve(.gotMap); dwell.fire(); await running.value
    }

    // MARK: deadline

    func testTheDeadlineOffersTheMapWhileTheAttemptIsStillOutstanding() async {
        let showDelay = ManualTimer(), deadline = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, deadline: deadline, dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await settle(); showDelay.fire(); await settle()
        deadline.fire(); await settle()

        XCTAssertEqual(presenter.phase, .unavailable(.mayRejoin),
                       "the pipeline may still be running — that is exactly what mayRejoin says")

        work.resolve(.gotMap); dwell.fire(); await running.value
    }

    func testTheDeadlineIsInertOnceTheAttemptHasResolved() async {
        let deadline = ManualTimer()
        let presenter = makePresenter(deadline: deadline)

        await presenter.attempt(origin: .first) { .gotMap }
        deadline.fire(); await settle()

        XCTAssertEqual(presenter.phase, .upgraded(confirming: false),
                       "a fired deadline must never resurrect an offer over a finished attempt")
    }

    func testAnAttemptThatSucceedsAfterTheDeadlineEndsUpgraded() async {
        let showDelay = ManualTimer(), deadline = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, deadline: deadline, dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await settle(); showDelay.fire(); await settle(); deadline.fire(); await settle()

        work.resolve(.gotMap); dwell.fire(); await running.value

        XCTAssertEqual(presenter.phase, .upgraded(confirming: true),
                       "an indicator was on screen and no automatic retry was behind it")
    }

    // MARK: dwell

    func testAnIndicatorHoldsForTheDwellBeforeATerminalPhaseIsApplied() async {
        let showDelay = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await settle(); showDelay.fire(); await settle()

        work.resolve(.rejected); await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible, "still held by the dwell")

        dwell.fire(); await running.value
        XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt))
    }

    func testAWarmRiderTapStillShowsItsIndicatorForTheDwell() async {
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)

        let running = Task { await presenter.attempt(origin: .riderTap) { .gotMap } }
        await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible,
                       "without the dwell a warm tap changes nothing the rider can see")

        dwell.fire(); await running.value
        XCTAssertEqual(presenter.phase, .upgraded(confirming: true))
    }

    // MARK: terminal outcomes and staleness

    func testRejectedAndStoppedWaitingReachDifferentRetryabilities() async {
        let rejected = makePresenter()
        await rejected.attempt(origin: .first) { .rejected }
        XCTAssertEqual(rejected.phase, .unavailable(.freshAttempt))

        let stopped = makePresenter()
        await stopped.attempt(origin: .first) { .stoppedWaiting }
        XCTAssertEqual(stopped.phase, .unavailable(.mayRejoin))
    }

    func testAStaleAttemptsRejectDoesNotOverwriteALiveIndicator() async {
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)
        let first = WorkGate(), second = WorkGate()

        let older = Task { await presenter.attempt(origin: .first) { await first.result() } }
        await settle()
        let newer = Task { await presenter.attempt(origin: .riderTap) { await second.result() } }
        await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible)

        first.resolve(.rejected); await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible,
                       "the older attempt's reject must not overwrite the newer attempt's indicator")

        second.resolve(.rejected); dwell.fire()
        _ = await older.value; _ = await newer.value
        XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt))
    }

    func testAStaleAttemptsMapIsStillApplied() async {
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)
        let first = WorkGate(), second = WorkGate()

        let older = Task { await presenter.attempt(origin: .first) { await first.result() } }
        await settle()
        let newer = Task { await presenter.attempt(origin: .riderTap) { await second.result() } }
        await settle()

        first.resolve(.gotMap); dwell.fire(); await settle()
        XCTAssertEqual(presenter.phase, .upgraded(confirming: true), "a map is a map")

        second.resolve(.rejected)
        _ = await older.value; _ = await newer.value
    }

    func testNoUpgradePossibleParksInIdle() async {
        let presenter = makePresenter()
        presenter.noUpgradePossible()
        XCTAssertEqual(presenter.phase, .idle)
    }

    // MARK: automatic retry

    func testArmingDuringAnInFlightAttemptFiresWhenItLaterRejects() async {
        let showDelay = ManualTimer(), deadline = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, deadline: deadline, dwell: dwell)
        let work = WorkGate()
        let fired = OSAllocatedUnfairLock(initialState: 0)
        let flagWhenFired = OSAllocatedUnfairLock(initialState: true)
        presenter.onAutomaticRetry = {
            fired.withLock { $0 += 1 }
            // Read on the MainActor, outside the lock's Sendable closure.
            let inFlight = presenter.isAttempting
            flagWhenFired.withLock { $0 = inFlight }
        }

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await settle(); showDelay.fire(); await settle(); deadline.fire(); await settle()

        // The pocketed phone: the scene edge arrives while the parked pipeline is still
        // unwinding, so evaluating the phase here would find mayRejoin and do nothing.
        presenter.armAutomaticRetry()
        await settle()
        XCTAssertEqual(fired.withLock { $0 }, 0, "nothing to retry yet")

        work.resolve(.rejected); dwell.fire(); await running.value
        await settle()

        XCTAssertEqual(fired.withLock { $0 }, 1, "consumed when the phase became freshAttempt")
        XCTAssertFalse(flagWhenFired.withLock { $0 },
                       "must fire with no attempt in flight, or the retry it triggers is swallowed")
    }

    func testArmingNeverFiresOnMayRejoin() async {
        let presenter = makePresenter()
        let fired = OSAllocatedUnfairLock(initialState: 0)
        presenter.onAutomaticRetry = { fired.withLock { $0 += 1 } }

        await presenter.attempt(origin: .first) { .stoppedWaiting }
        presenter.armAutomaticRetry()
        await settle()

        XCTAssertEqual(presenter.phase, .unavailable(.mayRejoin))
        XCTAssertEqual(fired.withLock { $0 }, 0,
                       "re-joining a live pipeline on the rider's behalf is what mayRejoin forbids")
    }

    func testOnlyOneAutomaticRetryPerPresentation() async {
        // The dwell timer is firable because the SECOND attempt has origin .automatic, which
        // shows its indicator immediately and therefore waits on the dwell. A test that leaves
        // it unfirable does not fail — it hangs, and `swift test --no-parallel` wedges until the
        // agent gate's 900 s timeout reports it as a slow machine.
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)
        let fired = OSAllocatedUnfairLock(initialState: 0)
        presenter.onAutomaticRetry = { fired.withLock { $0 += 1 } }

        await presenter.attempt(origin: .first) { .rejected }
        presenter.armAutomaticRetry(); await settle()
        XCTAssertEqual(fired.withLock { $0 }, 1)

        let second = Task { await presenter.attempt(origin: .automatic) { .rejected } }
        await settle(); dwell.fire(); await second.value
        presenter.armAutomaticRetry(); await settle()
        XCTAssertEqual(fired.withLock { $0 }, 1, "one per presentation, however many background cycles")
    }

    func testTheAutomaticRetryNeverShowsAConfirmation() async {
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)

        let running = Task { await presenter.attempt(origin: .automatic) { .gotMap } }
        await settle(); dwell.fire(); await running.value

        XCTAssertEqual(presenter.phase, .upgraded(confirming: false),
                       "the rider did not ask; the map simply appears")
    }
}
```

- [ ] **Step 2: Create `ShareUpgradePhase.swift`**

```swift
import Foundation

public enum Retryability: Equatable, Sendable {
    case freshAttempt
    case mayRejoin
}

public enum ShareUpgradePhase: Equatable, Sendable {
    case idle
    case upgrading
    case upgradingVisible
    case unavailable(Retryability)
    case upgraded(confirming: Bool)
}

public enum AttemptOrigin: Equatable, Sendable {
    case first
    case riderTap
    case automatic
}

public enum ShareUpgradeResult: Equatable, Sendable {
    case gotMap
    case rejected
    case stoppedWaiting
}
```

Doc-comment each case from spec revision 5 §Phases when you paste it — the types above are the
verified shape, not the finished file. `slow` is **gone** (revision 5); `AttemptOrigin` replaces
revision 1's `isRetry`, which conflated "the rider asked" with "skip the show-delay" and so would
have given the pocketed-phone rider an unprompted spinner and an unprompted "Map added".

- [ ] **Step 3: Create `ShareUpgradePresenter.swift`**

```swift
import Foundation
import Observation

/// Opened once; waiters arriving after it is open return immediately.
@MainActor
private final class DwellGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resuming = waiters
        waiters = []
        for waiter in resuming { waiter.resume() }
    }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Observable @MainActor
public final class ShareUpgradePresenter {
    public private(set) var phase: ShareUpgradePhase = .idle

    @ObservationIgnored public var onAutomaticRetry: (@MainActor () -> Void)?

    @ObservationIgnored private let showDelayDuration: Duration
    @ObservationIgnored private let deadlineDuration: Duration
    @ObservationIgnored private let dwellDuration: Duration
    @ObservationIgnored private let showDelayTimer: @Sendable (Duration) async -> Void
    @ObservationIgnored private let deadlineTimer: @Sendable (Duration) async -> Void
    @ObservationIgnored private let dwellTimer: @Sendable (Duration) async -> Void

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attemptsInFlight = 0
    @ObservationIgnored private var indicatorShown = false
    @ObservationIgnored private var dwellGate: DwellGate?
    @ObservationIgnored private var hops: [Task<Void, Never>] = []
    @ObservationIgnored private var armedAutomaticRetry = false
    @ObservationIgnored private var hasAutomaticallyRetried = false

    public init(showDelay: Duration = .milliseconds(300),
                deadline: Duration = .seconds(6),
                minimumDwell: Duration = .seconds(1),
                showDelayTimer: (@Sendable (Duration) async -> Void)? = nil,
                deadlineTimer: (@Sendable (Duration) async -> Void)? = nil,
                dwellTimer: (@Sendable (Duration) async -> Void)? = nil) {
        self.showDelayDuration = showDelay
        self.deadlineDuration = deadline
        self.dwellDuration = minimumDwell
        self.showDelayTimer = showDelayTimer ?? { try? await Task.sleep(for: $0) }
        self.deadlineTimer = deadlineTimer ?? { try? await Task.sleep(for: $0) }
        self.dwellTimer = dwellTimer ?? { try? await Task.sleep(for: $0) }
    }

    public var isAttempting: Bool { attemptsInFlight > 0 }

    public func noUpgradePossible() {
        cancelHops()
        generation += 1
        phase = .idle
    }

    public func attempt(origin: AttemptOrigin, _ work: () async -> ShareUpgradeResult) async {
        generation += 1
        let mine = generation
        attemptsInFlight += 1
        cancelHops()

        if origin == .first {
            indicatorShown = false
            phase = .upgrading
            arm { [weak self] in
                guard let self else { return }
                await self.showDelayTimer(self.showDelayDuration)
                guard !Task.isCancelled, mine == self.generation, self.phase == .upgrading else { return }
                self.enterIndicator()
            }
        } else {
            enterIndicator()
        }

        arm { [weak self] in
            guard let self else { return }
            await self.deadlineTimer(self.deadlineDuration)
            guard !Task.isCancelled, mine == self.generation,
                  self.phase == .upgrading || self.phase == .upgradingVisible else { return }
            self.phase = .unavailable(.mayRejoin)
        }

        let result = await work()
        attemptsInFlight -= 1

        // Only the newest attempt's terminal outcome may set the phase. An older attempt's
        // MAP is still applied — a map is a map.
        guard mine == generation || result == .gotMap else { return }
        if mine == generation { cancelHops() }

        if indicatorShown, let gate = dwellGate { await gate.wait() }
        guard mine == generation || result == .gotMap else { return }
        // `.upgraded` absorbs. A newer attempt's reject must never retract a map the rider
        // already has — reachable whenever an older attempt's map lands while a newer one is
        // still outstanding, which is exactly what the "a map is a map" rule creates.
        if case .upgraded = phase { return }

        phase = terminal(for: result, origin: origin)
        consumeAutomaticRetryIfDue()
    }

    /// A real background→foreground return happened. Arms one automatic retry, consumed when the
    /// phase next becomes `.unavailable(.freshAttempt)` — or now, if it already is and nothing is
    /// in flight. Never evaluated at the scene edge: on resume the parked belts are many
    /// main-actor hops behind, so reading the phase there would always be too early.
    public func armAutomaticRetry() {
        guard !hasAutomaticallyRetried else { return }
        armedAutomaticRetry = true
        consumeAutomaticRetryIfDue()
    }

    private func consumeAutomaticRetryIfDue() {
        guard armedAutomaticRetry, !hasAutomaticallyRetried, attemptsInFlight == 0,
              phase == .unavailable(.freshAttempt) else { return }
        armedAutomaticRetry = false
        hasAutomaticallyRetried = true
        let callback = onAutomaticRetry
        // NEVER invoked synchronously from inside `attempt`: the callback re-enters this type,
        // and a hop keeps that re-entry out of the current attempt's unwind.
        Task { @MainActor in callback?() }
    }

    private func enterIndicator() {
        indicatorShown = true
        phase = .upgradingVisible
        let gate = DwellGate()
        dwellGate = gate
        arm { [weak self] in
            guard let self else { return }
            await self.dwellTimer(self.dwellDuration)
            gate.open()
        }
    }

    private func terminal(for result: ShareUpgradeResult, origin: AttemptOrigin) -> ShareUpgradePhase {
        switch result {
        case .gotMap:        return .upgraded(confirming: origin != .automatic && indicatorShown)
        case .rejected:      return .unavailable(.freshAttempt)
        case .stoppedWaiting: return .unavailable(.mayRejoin)
        }
    }

    private func arm(_ body: @escaping @MainActor () async -> Void) {
        hops.append(Task { await body() })
    }

    private func cancelHops() {
        for hop in hops { hop.cancel() }
        hops = []
    }
}
```

Five things in there are load-bearing and are the plan gate's findings made structural. Do not
"simplify" any of them without re-reading §What revision 1 got wrong:

1. **`generation` is checked inside every hop**, not just `Task.isCancelled`. A hop armed under
   attempt *n* can still be suspended when attempt *n+1* starts, and `withCheckedContinuation` is
   not a cancellation point, so cancellation alone does not stop it. A reviewer reproduced a stale
   hop re-applying attempt *n*'s terminal phase over attempt *n+1*'s live indicator — in the
   pocketed-phone case specifically, ending with an "Add map to card" button that did nothing.
2. **`attempt` awaits the dwell gate; there is no `defer` that applies a terminal phase.**
   Revision 1 had both a park-and-return hop *and* a defer, and the defer ran a second before the
   hop and won every time, making the dwell a no-op on the happy path. Its own dwell test went red
   three tasks later. There is also no cancellation defer at all, because spec revision 5 records
   that `attempt` never returns on cancellation in production: `slot.run` has no cancellation
   point, so `work()` never returns.
3. **`consumeAutomaticRetryIfDue` hops via `Task { }`.** Revision 1 instead instructed "clear the
   flag, apply the terminal phase, then consume the arming", which is unsatisfiable — `defer`s run
   in reverse declaration order, so no point in `attempt` has the flag clear and the phase applied.
   The hop makes the ordering true by construction instead of by paragraph, and
   `testArmingDuringAnInFlightAttemptFiresWhenItLaterRejects` asserts `isAttempting == false` at
   callback time so the invariant is enforced by a line.
4. **`if case .upgraded = phase { return }` — `.upgraded` absorbs.** Found by running the tests:
   without it, an older attempt's map lands, then the newer attempt's reject retracts it.
5. **`onAutomaticRetry` is `@ObservationIgnored`.** It is set from the view; without this,
   assigning it is a tracked mutation and can invalidate during view update.

- [ ] **Step 4: Run**

```bash
swift test --package-path AuraCore --no-parallel --filter ShareUpgradePresenterTests
```

Expected: **16 tests, 0 failures.** If any test *hangs* rather than fails, you have changed
`ManualTimer` — its banked credit is what stops a hop that arms after `fire()` from waiting
forever. A hung test burns the agent gate's full 900 s and reads as a slow machine.

- [ ] **Step 5: Commit**

---

### Task 3: `ShareMapOutcome` — the seam AND its consumer, in one commit

Revision 1 split these across Tasks 7 and 10, which left the tree **not compiling** for three
tasks that each claimed "compiles clean" — `RideSummaryView.swift:187` does `if let raster` on
what would now be a non-optional enum. At ~13 minutes per build through the builder subagent,
that is a real cost. They land together.

Revision 1 also said to "update any test double conforming to `ShareMapRasterProviding`" and gave
a grep. **There is no test double** — `ShareMapSnapshotter` is the only conformer — so the grep
returns nothing and an implementer would conclude they were done, having missed the one call site
that actually breaks.

**Files:**
- Modify: `Aura/Sources/Ride/ShareCard/ShareMapRasterProviding.swift:15-20`
- Modify: `Aura/Sources/Ride/ShareCard/ShareMapSnapshotter.swift:143-158`
- Modify: `Aura/Sources/Ride/RideSummaryView.swift:185-193` (the consumer, minimally — full
  rewiring is Task 6)

- [ ] **Step 1:**

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

- [ ] **Step 2: Map in `raster(for:)`**

| Source | Result |
|---|---|
| Disk-cache fast path (`:150`) | `.map(image)` |
| `.finished(image)` | `.map(image)` |
| `.finished(nil)` | `.rejected` |
| `.stoppedWaiting` | `.stoppedWaiting` |
| `self` deallocated (`:155-157`) | `.rejected` |

`prefetchShareMap` already discards its result and needs no change beyond compiling.

- [ ] **Step 3: Switch at the consumer**, preserving today's `!Task.isCancelled` guard — Task 6
      decides its fate deliberately, this task must not drop it silently.
- [ ] **Step 4: Delegate a build.** Expected: compiles clean. This is the first step in the plan
      where that claim is actually true.
- [ ] **Step 5: Commit.**

---

### Task 4: Per-attempt generations in `ShareCardFileStore`

**Files:** `Aura/Sources/Ride/ShareCard/ShareCardFileStore.swift:10, 26-31`

- [ ] **Step 1:** Update the doc comment — generation 0 is the fallback and each upgrade attempt
      that produces a card writes the next generation. `url(generation:)` needs no signature
      change; the counter lives in the view.
- [ ] **Step 2:** Record the accepted cost: files accumulate per attempt under the presentation's
      UUID directory, bounded by rider taps, in `tmp`, and `sweepOtherRides()` structurally cannot
      collect the current ride's subtree.
- [ ] **Step 3: Commit.**

---

### Task 5: Close the share-sheet hazard (spec revision 5 moved this in scope)

`beginShareSheetWatch` polls for the sheet 20 × 100 ms and gives up (`RideSummaryView.swift:398`).
On a cold first share `UIActivityViewController` can take longer, so `shareSheetUp` goes false
under a live sheet and a late upgrade assigns `shareImage` beneath it — which the 2026-07-31
device pass watched dismiss a presented sheet. Retry is what makes late landings routine, so this
change is what makes the hazard reachable.

- [ ] **Step 1:** `applyOrDeferUpgrade` (`:376-382`) re-checks `SharePresentation.isPresenting` at
      assignment time rather than trusting the latch alone, and defers if any modal is up.
- [ ] **Step 2:** Note in the comment that `isPresenting` is true for *any* modal, so an unrelated
      system alert also defers. That is the safe direction.
- [ ] **Step 3: Delegate a build. Commit.**

---

### Task 6: Wire the presenter into `RideSummaryView`

**Files:** `Aura/Sources/Ride/RideSummaryView.swift:26-37`, `:132-196`

- [ ] **Step 1:** `isUpgrading` and `showHint` go; add
      `@State private var upgrade = ShareUpgradePresenter()` and `@State private var generation = 0`.
      Keep `shareImage`, `shareSheetUp`, `deferredUpgrade` as they are.

- [ ] **Step 2: Extract `runUpgrade(glanceDebounce:origin:)`**

**The 0.8 s sleep stays OUTSIDE `presenter.attempt`.** Putting `attempt` first would arm the
300 ms show-delay inside the sleep, so "Adding your map…" appears at t+0.3 s — mid-entrance on
every ride end, as a hard insert. That is verbatim the rev-3 rejection in the ROH-155 record:
"the one drawing operation the rider actually sees during the entrance, and it was the one left
ungated."

```
func runUpgrade(glanceDebounce: Bool, origin: AttemptOrigin) async {
    if glanceDebounce {
        try? await Task.sleep(for: .seconds(0.8))   // keep the three-job comment verbatim
        guard !Task.isCancelled else { return }
    }
    await upgrade.attempt(origin: origin) {
        switch await shareMap.provider.raster(for: request) {
        case .map(let raster):
            let next = generation + 1          // NOT `generation += 1` then read back:
            generation = next                  // @State read-after-write outside `body` is
            guard let upgraded = await RideCardRenderer.make(   // not a documented guarantee,
                    content, mapImage: raster, title: title,    // and a stale read would
                    writeTo: fileStore.url(generation: next))   // overwrite generation 0.
            else { return .stoppedWaiting }    // see below
            applyOrDeferUpgrade(upgraded)
            return .gotMap
        case .rejected:       return .rejected
        case .stoppedWaiting: return .stoppedWaiting
        }
    }
}
```

**A render failure returns `.stoppedWaiting`, not `.rejected`.** Spec revision 5 §Error handling:
the raster is now cached, so an automatic retry would warm-hit and fail at the same renderer,
deterministically — spending the one-shot budget on something that cannot succeed. `.mayRejoin`
still offers the rider the button; it just refuses to press it for them.

- [ ] **Step 3:** `.task` keeps its guards and its fallback render, and calls
      `runUpgrade(glanceDebounce: true, origin: .first)`. Where it currently returns because
      `ShareMapRequest.init` gave nil (`:146-147`) or the fallback render failed (`:145`), call
      `upgrade.noUpgradePossible()` first — those are the two paths that must never show an offer.

- [ ] **Step 4:** Hold `content`, `fileStore`, `title`, `request` in `@State`. `ShareCardFileStore`
      mints its `presentationID` in `init`, so build it **once** and never rebuild it in the retry
      path. Add `.id(ride.id)` where `HistoryView` presents the sheet, so a reused content view
      cannot carry another ride's file store.

- [ ] **Step 5:** Decide the `!Task.isCancelled` guard **explicitly**. It exists today at `:187`
      and stops a 1080×1350 main-actor `ImageRenderer` pass running for a view being torn down.
      Keep it for the `.first` path; for `.riderTap`/`.automatic` the enclosing task is not
      `.task`'s, so state what you chose in a comment. Revision 1 dropped it silently.

- [ ] **Step 6: Delegate a build. Commit.**

---

### Task 7: The reserved row and the offer

**Files:** `Aura/Sources/Ride/RideSummaryView.swift:107-114`

- [ ] **Step 1: The row**

| Phase | Content |
|---|---|
| `.idle`, `.upgrading`, `.upgraded(confirming: false)` | empty |
| `.upgradingVisible` | `ProgressView` + "Adding your map…" |
| `.unavailable` (either) | **"Add map to card"** — a button, no sentence |
| `.upgraded(confirming: true)` | "Map added" — persists, does not self-clear |

**An offer, not an apology.** No failure sentence, no destructive colour, no warning glyph, no
"couldn't", and explicitly **not** `GroupLobbyView.startRetryRow`'s amber treatment — that row
reports a failure, this one makes an offer. Nothing is broken: the card is finished and Share
works. The label names its destination because there is a real `StaticRouteMap` at the top of this
screen (`:57`) and the share card is never rendered on it.

Specify the treatment rather than leaving it to inherit the current `.font(.caption)` +
`secondaryText` chain, which would render the button as small grey text that looks disabled:
accent-coloured, `minHeight: 44`, `.contentShape(Rectangle())` — the hit-target lesson from
`GroupLobbyView.swift:225-234`, which is worth keeping even though its colour is not. **No SF
Symbol**: `arrow.clockwise` would reintroduce the retry-after-failure reading the copy avoids.

- [ ] **Step 2: Reserve the height — as a `ZStack`, not a fixed frame**

Render every phase's content in a `ZStack`, only the active one visible, the rest
`.accessibilityHidden(true)`. That sizes to the tallest state at **any** Dynamic Type size by
construction. A fixed `.frame(height: 44)` breaks at AX3+, where the button label wraps to two
lines and Done moves — for the rider least able to recover from it.

Gate the whole row on `request != nil`, **not** on `phase != .idle`: `.idle` is both "no upgrade
possible" and "none attempted yet", and at ride end the presenter sits in `.idle` for the first
~0.8 s because the debounce is outside `attempt`. Gating on the phase either puts dead space on a
no-route ride or pops the row in mid-entrance.

Done must not move: it is the only exit (`AuraApp.swift:124-135` hides the nav bar, the back
button and swipe-back) and sits below the fold, so a rider scrolling to it as the row grows lands
on the offer and starts a pipeline they never wanted.

- [ ] **Step 3:** Both presentations. Spec revision 5 reversed the ride-end-only scope, so there is
      no `presentation:` parameter and no call-site change.
- [ ] **Step 4:** `Button("Add map to card") { Task { await runUpgrade(glanceDebounce: false, origin: .riderTap) } }`
- [ ] **Step 5:** Give the row a `reduceMotion`-aware cross-fade. With the height reserved it is
      free, and unspecified means a hard pop.
- [ ] **Step 6: Delegate a build. Commit.**

---

### Task 8: Background return and accessibility

- [ ] **Step 1: The edge**

```swift
.onChange(of: scenePhase) { _, phase in
    // A REAL background cycle. AuraApp.swift:262-268 carries the same warning: a transient
    // `.inactive` — Control Center, a notification banner, a permission alert — is not one,
    // and gating on `.active` would spend the one-shot budget on a notification banner.
    if phase == .background { wasBackgrounded = true }
    if phase == .active, wasBackgrounded {
        wasBackgrounded = false
        upgrade.armAutomaticRetry()
    }
}
```

Set `upgrade.onAutomaticRetry` in `.task`, before the first `attempt` — **not** in `body` — to
`{ Task { await runUpgrade(glanceDebounce: false, origin: .automatic) } }`.

Note the edge is wider than "the rider pocketed the phone": sharing to another app, saving to
Files, taking a call and following a link all produce a real `.background`. That is why the
arming is gated on `.freshAttempt` and bounded to one, and why device-pass item 7 exists.

- [ ] **Step 2: Announcements** — posted by the view; AuraKit imports no UIKit.
  - Announce entry into `unavailable` **once**.
  - **Not** a second `unavailable` from a failed automatic retry. `AttemptOrigin` is what makes
    this expressible — the phase carries no provenance, so revision 1 asked the view to suppress
    something it had no way to detect.
  - Button accessibility label: "Add the map to your share card".
- [ ] **Step 3: Delegate a build. Commit.**

---

### Task 9: Instrument the measurement the device pass depends on

The 6 s constant rests on device-pass item 1, and nothing in revision 1 made it measurable — the
tester's only tool was eyeballing Console timestamps across nine reject strings, one of which
covers four code paths.

- [ ] **Step 1:** Log attempt duration and outcome once per attempt, at `.notice`, in the existing
      `app.aura.ios` / `ShareCard` category, so a sysdiagnose answers "how long do upgrades
      actually take at ride end, on wifi and on cellular" without inference.
- [ ] **Step 2: Commit.**

---

### Task 10: Verification

- [ ] **Step 1:** `swift test --package-path AuraCore --no-parallel`
- [ ] **Step 2:** App build via the `apple-platform-build-tools` builder subagent.
- [ ] **Step 3: Device pass — a real device.** A clean build proves nothing here.

1. **Measure** (Task 9's log): upgrade durations and reject timings at ride end, wifi and
   cellular. Check 6 s against reality rather than against arithmetic.
2. Airplane mode at ride end → offer appears; confirm it reads as an offer, not a failure.
3. Re-enable wifi, tap it → map lands, "Map added" shows and stays.
4. Tap it while still offline → indicator held ≥1 s, back to the offer, no flicker. **This is a
   button that visibly does nothing, repeatable forever — judge whether that is acceptable or
   whether the second consecutive failure needs to name connectivity.** Recorded as an open
   question, not a pass/fail.
5. Pocket the phone **during the attempt** → map present on unlock, no interaction. (Auto-apply,
   not the auto-retry — the spec calls this the primary mechanism.)
6. Pocket the phone **after the offer appears** → exactly one automatic retry on unlock.
7. Control Center during `unavailable`, dismiss → **no automatic retry.** Then: share to Messages,
   come back → confirm the card does not swap under you.
8. Reach for Done as the phase changes → **Done must not move.** Repeat at AX3 and confirm the
   button is still one line and still 44 pt.
9. Tap Share **during a retry, on a cold first share** → the sheet must survive (Task 5).
10. VoiceOver: `unavailable` announced once; a failed automatic retry silent; **and check where
    focus goes when the row changes from a `Text` to a `Button`** — that identity change drops
    focus, and no earlier revision tested it.
11. Tap the offer, then immediately tap Done → clean dismissal, no state write on a torn-down view.

Revision 1's "Reduce Motion → identical deadline behaviour" is **cut**: the deadline has no Reduce
Motion coupling by construction, so it confirmed that 6 s equals 6 s. What needs looking at under
Reduce Motion is Task 7's cross-fade.

Items 8 and 9 overlap **ROH-140** on this surface — worth closing what you can in the same session.

- [ ] **Step 4: Answer the spec's open questions**, which the pass exists to answer, not confirm.
      Question 3 — does the offer make riders wait to share who otherwise would not have — is a
      field question that one tester cannot settle. Record it as unmeasured rather than hand-waved.
- [ ] **Step 5:** Whole-branch review on the most capable model, then PR, then ROH-161 → In Review.

---

## What revision 1 got wrong

Kept because the failures are properties of this work, not of one draft. Three reviewers, two of
whom built reproduction packages.

1. **Four of five pasted Swift blocks did not compile** — an undeclared `showDelayDuration`, an
   initializer taking two parameters its own tests called with three (twice), and an `async let`
   sending `@MainActor` self in the one file that documents that exact trap.
2. **Tasks 2, 3 and 4 could not each end on a green suite**, which was the plan's own per-task
   contract and what `.claude/agent-gate.sh` enforces. Two of them committed a non-compiling test
   module, which fails every test in the package.
3. **Task 4 made three earlier tests hang rather than fail**, on anonymous timers nothing held a
   reference to — 15 minutes of gate timeout that reads as a slow machine.
4. **The dwell was a no-op in every path.** Task 5's `defer` beat Task 4's hop by a second, so
   Task 4's own flagship test went red three tasks after it was written.
5. **A stale dwell hop could re-apply a previous attempt's terminal phase over a live retry**, in
   the pocketed-phone case, ending with a dead button and a forbidden second announcement.
6. **Task 6's ordering instruction was unsatisfiable** against Task 2's `defer`, and its own tests
   could not detect the violation — the invariant was a paragraph, not a line.
7. **The tree did not compile between Tasks 7 and 10**, while three tasks claimed clean builds.
8. **Nine of eighteen presenter tests were comment-only stubs**, including both labelled "THE"
   regression test. An empty XCTest method passes, so two load-bearing green gates were satisfied
   by nothing.
9. **"Map added, ~2 s, then empty" had no owner** — no timer, no test, no phase to return to.
10. **It dropped the `!Task.isCancelled` guard** at `:187` silently.
11. **It said to grep for a test double that does not exist**, so the grep returns nothing and the
    one call site that breaks goes unnoticed.
12. **`isRetry` conflated "the rider asked" with "skip the show-delay"**, so the automatic retry
    would have announced itself to a rider who had just unlocked their phone — and a slow *first*
    attempt that succeeded showed no confirmation at all, which is this issue's own symptom.

What held up: every file:line anchor and both quotations were verified correct by the skeptic, and
both corrections revision 1 made to the spec's file table were right.

> `humanizer` is mandated by CLAUDE.md for prose deliverables and is **not installed on this
> machine**, so this plan did not go through it.
