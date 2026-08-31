import XCTest
import os
@testable import AuraKit

/// One-shot async gate. `wait()` suspends until `open()`; opening is idempotent and a
/// waiter arriving after the gate is open returns immediately. Top level rather than
/// nested in the test case so its `State` stays inside SwiftLint's nesting depth.
private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Opened and ready before any waiter arrives — for the work closures that should not
    /// block at all.
    static func opened() -> Gate {
        let gate = Gate()
        gate.open()
        return gate
    }

    func open() {
        let waiters = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { state -> Bool in
                guard !state.isOpen else { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// Records what the work closures did, from whichever context ran them.
private final class WorkLog: Sendable {
    private struct State {
        var started = 0
        var live = 0
        var peakLive = 0
        var cancelledKeys: [String] = []
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    func enter() {
        lock.withLock { state in
            state.started += 1
            state.live += 1
            state.peakLive = max(state.peakLive, state.live)
        }
    }
    func leave(key: String, cancelled: Bool) {
        lock.withLock { state in
            state.live -= 1
            if cancelled { state.cancelledKeys.append(key) }
        }
    }
    var started: Int { lock.withLock { $0.started } }
    /// The whole point of the slot: this must never exceed 1.
    var peakLive: Int { lock.withLock { $0.peakLive } }
    var cancelledKeys: [String] { lock.withLock { $0.cancelledKeys } }
}

/// Ceiling timers, built by factory functions rather than held in `static let`s: a stored
/// async closure literal trips the repo's `async_closure_default_argument` rule (ROH-110).
private enum Ceiling {
    /// Never fires within the test. Cancellable, so a resolved race stops it.
    static func neverFires() -> @Sendable (Duration) async -> Void {
        { _ in try? await Task.sleep(for: .seconds(3600)) }
    }

    /// Fires the moment it is armed.
    static func firesAtOnce() -> @Sendable (Duration) async -> Void {
        { _ in }
    }

    /// The owner's arm never fires; every later arm fires at once. Lets a test trip a
    /// waiter's ceiling while the pipeline it is waiting on stays healthy.
    static func firesForEveryArmAfterTheFirst() -> @Sendable (Duration) async -> Void {
        let armCount = OSAllocatedUnfairLock(initialState: 0)
        return { _ in
            let isFirst = armCount.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            if isFirst { try? await Task.sleep(for: .seconds(3600)) }
        }
    }

    /// The inverse: the owner's arm fires at once and no later arm ever does. Lets a test
    /// strand a cancelled-but-unfinished pipeline in the slot and then have a same-key
    /// waiter join it and read its result, instead of tripping a ceiling of its own.
    static func firesOnlyForTheFirstArm() -> @Sendable (Duration) async -> Void {
        let armCount = OSAllocatedUnfairLock(initialState: 0)
        return { _ in
            let isFirst = armCount.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            if !isFirst { try? await Task.sleep(for: .seconds(3600)) }
        }
    }
}

/// Covers the share-map slot machine — the region the second whole-branch review called
/// out as having zero tests, and where its one confirmed defect lived (blocker 2: the
/// ceiling arm cleared the slot without cancelling the pipeline that owned it, so a
/// successor started a second pipeline beside a live one).
///
/// The ceiling is injected rather than waited out and the work closures block on explicit
/// gates, so no test spends wall-clock time. It is not fully order-independent, and the
/// two places that are not are called out at their tests: `Ceiling.firesForEveryArmAfterTheFirst`
/// is defined by which arm reaches the lock first, and `settle` drains the main actor by
/// yielding rather than by any guarantee. Gates are opened wherever a regression should
/// fail an assertion instead of hanging the suite.
@MainActor
final class SharePipelineSlotTests: XCTestCase {

    // MARK: - Harness

    /// Work that blocks on `gate`, then reports whether it observed cancellation. Returns
    /// `value` unless it was cancelled, which models a pipeline rejecting.
    private func blockingWork(
        key: String, gate: Gate, log: WorkLog, value: String
    ) -> @MainActor () async -> String? {
        { @MainActor in
            log.enter()
            await gate.wait()
            let cancelled = Task.isCancelled
            log.leave(key: key, cancelled: cancelled)
            return cancelled ? nil : value
        }
    }

    /// Lets the actor and the unstructured tasks the slot creates make progress. The slot
    /// is `@MainActor`, so a handful of yields drains everything that is ready to run.
    private func settle(_ turns: Int = 20) async {
        for _ in 0..<turns { await Task.yield() }
    }

    /// Starts a concurrent request. `Task` rather than `async let` on purpose: the test
    /// case is `@MainActor`, and an `async let` child would have to send `self` across
    /// isolation, while an unstructured `Task` inherits the main actor.
    private func begin(
        _ slot: SharePipelineSlot<String>, key: String, work: @escaping @MainActor () async -> String?
    ) -> Task<SlotOutcome<String>, Never> {
        Task { await slot.run(key: key, work: work) }
    }

    // MARK: - Single-flight

    func testSameKeyRequestsShareOnePipeline() async {
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())
        let gate = Gate(), log = WorkLog()
        let work = blockingWork(key: "a", gate: gate, log: log, value: "raster-a")

        let first = begin(slot, key: "a", work: work)
        let second = begin(slot, key: "a", work: work)
        await settle()
        gate.open()

        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.finished("raster-a"), .finished("raster-a")],
                       "the joiner gets the owner's result")
        XCTAssertEqual(log.started, 1, "two same-key requests must run exactly one pipeline")
    }

    func testDifferentKeysNeverRunTwoPipelinesAtOnce() async {
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())
        let gateA = Gate(), gateB = Gate(), log = WorkLog()

        let first = begin(slot, key: "a", work: blockingWork(key: "a", gate: gateA, log: log, value: "a"))
        await settle()
        let second = begin(slot, key: "b", work: blockingWork(key: "b", gate: gateB, log: log, value: "b"))
        await settle()

        XCTAssertEqual(log.started, 1, "the second key must wait rather than start beside the first")
        gateA.open()
        await settle()
        gateB.open()

        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.finished("a"), .finished("b")])
        XCTAssertEqual(log.peakLive, 1, "at most one pipeline alive at a time")
    }

    // MARK: - The ceiling (blocker 2)

    /// The regression test for the confirmed defect. Before the fix, the ceiling arm
    /// cleared the slot while the pipeline it was abandoning was demonstrably still
    /// alive, so the next request started a second pipeline alongside it.
    func testCeilingDoesNotLetASecondPipelineStartBesideALiveOne() async {
        // The owner's ceiling fires at once; nothing opens the gate, so its pipeline is
        // still running when the ceiling trips. That is the reproduction exactly.
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.firesAtOnce())
        let gateA = Gate(), gateB = Gate(), log = WorkLog()

        let first = await slot.run(key: "a", work: blockingWork(key: "a", gate: gateA, log: log, value: "a"))
        XCTAssertEqual(first, .stoppedWaiting, "the ceiling stops its caller waiting")
        XCTAssertTrue(slot.isRunning, "the abandoned pipeline still owns the slot")

        // A successor arrives while pipeline A is still alive.
        let second = begin(slot, key: "b", work: blockingWork(key: "b", gate: gateB, log: log, value: "b"))
        await settle()

        XCTAssertEqual(log.started, 1, "no second pipeline may start while the first is alive")
        XCTAssertEqual(log.peakLive, 1)

        // Let A unwind; only then may B run.
        gateA.open()
        await settle()
        gateB.open()
        _ = await second.value
        XCTAssertEqual(log.peakLive, 1, "the invariant held across the whole sequence")
    }

    func testCeilingCancelsThePipelineItStopsWaitingOn() async {
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.firesAtOnce())
        let gate = Gate(), log = WorkLog()

        _ = await slot.run(key: "a", work: blockingWork(key: "a", gate: gate, log: log, value: "a"))
        // The slot is still held here: `blockingWork` parks in a `withCheckedContinuation`,
        // which is not a cancellation point, so the pipeline cannot notice the cancel until
        // the gate lets it run. That is the state the fix guarantees and the pre-fix code
        // did not — asserted before opening the gate, so the harness is not what proves it.
        XCTAssertTrue(slot.isRunning, "the cancelled-but-unfinished pipeline still owns the slot")

        gate.open()
        await settle()

        XCTAssertEqual(log.cancelledKeys, ["a"],
                       "the ceiling must cancel the pipeline, not merely stop waiting on it")
        XCTAssertFalse(slot.isRunning, "and the slot is released once it unwinds")
    }

    /// A waiter's ceiling unblocks that waiter and nothing else: it must not cancel a
    /// pipeline it does not own, and it must not clear the slot.
    ///
    /// Order-dependent by construction — `firesForEveryArmAfterTheFirst` distinguishes the
    /// arms by which reaches the lock first, and this test needs the owner to win. The
    /// waiter's gate is opened up front so that a regression to "the waiter starts its own
    /// pipeline" fails on `log.started` rather than hanging the suite on a gate nobody opens.
    func testWaiterCeilingLeavesTheOwnersPipelineAlone() async {
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.firesForEveryArmAfterTheFirst())
        let gateA = Gate(), log = WorkLog()

        let owner = begin(slot, key: "a", work: blockingWork(key: "a", gate: gateA, log: log, value: "a"))
        await settle()
        let waiter = await slot.run(key: "b", work: blockingWork(key: "b", gate: .opened(), log: log, value: "b"))

        XCTAssertEqual(waiter, .stoppedWaiting, "the waiter's ceiling stops it waiting rather than looping")
        XCTAssertTrue(slot.isRunning, "and leaves the owner's slot alone")
        XCTAssertEqual(log.cancelledKeys, [], "and does not cancel a pipeline it does not own")
        XCTAssertEqual(log.started, 1, "and never starts a pipeline of its own")

        gateA.open()
        let ownerResult = await owner.value
        XCTAssertEqual(ownerResult, .finished("a"), "the owner's pipeline completed normally")
        XCTAssertEqual(log.started, 1)
    }

    /// A retry arriving while the cancelled pipeline is still unwinding must not start a
    /// second pipeline for a key one is already running — the defect this type exists to
    /// prevent.
    ///
    /// What it gets back here is `.stoppedWaiting`, and the reason is worth stating because
    /// the old name for this test claimed otherwise. `Ceiling.firesAtOnce()` fires for every
    /// arm, the retry's included, so the retry trips its OWN waiter ceiling and returns
    /// before the dying pipeline has produced anything — nothing opens that pipeline's gate
    /// until after the assertions. Not reasoning: the `onCeiling` sequence is asserted
    /// below, and it is an owner's ceiling followed by a waiter's. So this test does not
    /// demonstrate a retry inheriting the dying pipeline's nil; that shape needs a ceiling
    /// that spares the waiter, and it is covered by
    /// `testSameKeyRetryInheritsTheDyingPipelinesNil`.
    func testSameKeyRetryDuringUnwindStartsNoSecondPipeline() async {
        let ceilings = OSAllocatedUnfairLock(initialState: [String]())
        let slot = SharePipelineSlot<String>(
            ceilingTimer: Ceiling.firesAtOnce(),
            onCeiling: { key, isOwner in ceilings.withLock { $0.append("\(key):\(isOwner)") } })
        let gate = Gate(), log = WorkLog()

        _ = await slot.run(key: "a", work: blockingWork(key: "a", gate: gate, log: log, value: "a"))
        XCTAssertTrue(slot.isRunning)

        let retry = await slot.run(key: "a", work: blockingWork(key: "a", gate: .opened(), log: log, value: "retry"))
        XCTAssertEqual(retry, .stoppedWaiting, "the retry's own ceiling stops it waiting")
        XCTAssertEqual(log.started, 1, "and does not run a second pipeline for a live key")
        // Asserted rather than claimed in prose: the docs above say the retry trips its own
        // waiter ceiling, and an unchecked comment saying exactly that is what got this test
        // miscited three times.
        XCTAssertEqual(ceilings.withLock { $0 }, ["a:true", "a:false"],
                       "an owner's ceiling, then the retry's OWN waiter ceiling")

        gate.open()
        await settle()
        XCTAssertFalse(slot.isRunning)
    }

    /// The same-key waiter path, which is the one the ROH-161 retry gate rests on: a joiner
    /// reports the owner's TASK's result, not the owner's own outcome. Here the owner's
    /// ceiling fired and cancelled it, so that task produces nil and the waiter reads
    /// `.finished(nil)` — a pipeline that is over — while the owner itself got
    /// `.stoppedWaiting`. Those are different answers to the same pipeline and the
    /// distinction is the whole point of `SlotOutcome`.
    ///
    /// Needs a ceiling that fires for the owner and spares the waiter, hence
    /// `firesOnlyForTheFirstArm`; with `firesAtOnce` the waiter trips its own ceiling first
    /// and never observes the pipeline, which is what the test above covers.
    func testSameKeyRetryInheritsTheDyingPipelinesNil() async {
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.firesOnlyForTheFirstArm())
        let gate = Gate(), log = WorkLog()

        let owner = await slot.run(key: "a", work: blockingWork(key: "a", gate: gate, log: log, value: "a"))
        XCTAssertEqual(owner, .stoppedWaiting)
        XCTAssertTrue(slot.isRunning)

        let retry = begin(slot, key: "a", work: blockingWork(key: "a", gate: .opened(), log: log, value: "retry"))
        await settle()
        XCTAssertEqual(log.started, 1, "no second pipeline for a live key")

        gate.open()
        let outcome = await retry.value
        XCTAssertEqual(outcome, .finished(nil),
                       "the joiner inherits the owner's cancelled nil — not .stoppedWaiting")
        XCTAssertEqual(log.started, 1, "and never ran its own work")
        XCTAssertEqual(log.cancelledKeys, ["a"])
    }

    func testCeilingIsReportedForDiagnosis() async {
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let slot = SharePipelineSlot<String>(
            ceilingTimer: Ceiling.firesAtOnce(),
            onCeiling: { key, isOwner in seen.withLock { $0.append("\(key):\(isOwner)") } })
        let gate = Gate(), log = WorkLog()

        _ = await slot.run(key: "a", work: blockingWork(key: "a", gate: gate, log: log, value: "a"))

        XCTAssertEqual(seen.withLock { $0 }, ["a:true"],
                       "an owner's ceiling is reported — the only trace a wedge ever leaves")
        gate.open()
        await settle()
    }

    // MARK: - Slot release

    func testSlotIsReleasedWhenWorkReturnsNil() async {
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())

        let rejected = await slot.run(key: "a") { nil }
        XCTAssertEqual(rejected, .finished(nil))
        XCTAssertFalse(slot.isRunning, "a rejecting pipeline must release the slot, not wedge it")

        // There is deliberately no negative cache: the same key runs again in full.
        let retried = await slot.run(key: "a") { "a" }
        XCTAssertEqual(retried, .finished("a"))
        XCTAssertFalse(slot.isRunning)
    }

    func testSequentialRequestsEachRunTheirOwnPipeline() async {
        let slot = SharePipelineSlot<String>(ceilingTimer: Ceiling.neverFires())
        let log = WorkLog()

        for key in ["a", "b", "a"] {
            _ = await slot.run(key: key, work: blockingWork(key: key, gate: .opened(), log: log, value: key))
        }
        XCTAssertEqual(log.started, 3, "a finished pipeline is not a cache — each request runs again")
        XCTAssertEqual(log.peakLive, 1)
    }
}
