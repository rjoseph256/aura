import XCTest
import os
@testable import AuraKit

// Shared by ShareUpgradePresenterTests, ShareUpgradeFailedTapTests and
// ShareUpgradeAnnouncementTests. Internal rather than private only so those classes can live
// in more than one file; nothing outside the ShareUpgrade tests should reach for these.

/// Hand-fired and **re-armable**: each `fire()` releases everyone waiting at that moment, and a
/// later arm suspends again. A one-shot gate cannot express a test that arms the same hop twice.
final class ManualTimer: Sendable {
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

/// Counts the hops parked in a never-firing sleep RIGHT NOW. `neverFires()` hands out closures
/// that check in before parking and check out when the sleep ends — fired or, in practice,
/// cancelled — so a test's `tearDown` can prove the presenter released every hop it armed
/// instead of trusting a comment that says it does (ROH-233).
///
/// Who cancels them: `attempt` itself, through `cancelHops()` when the newest attempt resolves
/// and again at the start of the next attempt, and `noUpgradePossible()`. The dwell hop is the
/// deliberate exception (ROH-186) and never takes a never-firing timer in this file: `attempt`
/// waits on the gate that hop opens, so a never-firing dwell would not leak a task, it would
/// park the test for an hour.
final class HopLedger: Sendable {
    private struct Counts { var parked = 0; var released = 0 }
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    /// Hops that have ever checked in, and hops that have ever checked out. Both are MONOTONE,
    /// which is what a condition-driven wait needs: `liveCount` passes through intermediate
    /// values while one attempt's hops check out and the next attempt's check in, and a wait
    /// on it can return on a transient (it did, once in 40 loaded runs). Wait on these, then
    /// assert on `liveCount`.
    var parkedCount: Int { counts.withLock { $0.parked } }
    var releasedCount: Int { counts.withLock { $0.released } }
    var liveCount: Int { counts.withLock { $0.parked - $0.released } }

    /// For hops a test never intends to fire. A long cancellable sleep rather than a continuation
    /// nobody resumes, so cancellation actually ends it.
    func neverFires() -> @Sendable (Duration) async -> Void {
        { [counts] _ in
            counts.withLock { $0.parked += 1 }
            try? await Task.sleep(for: .seconds(3600))
            counts.withLock { $0.released += 1 }
        }
    }
}

/// Every presenter-driving test class owns a ledger and refuses to end while a never-firing hop
/// is still parked. This is a BACKSTOP, not a proof: a test that arms no never-firing hop, or
/// whose hops have not checked in yet when it ends, passes it on 0 == 0. The positive controls
/// are the two ledger tests in `ShareUpgradePresenterTests`, which wait for the check-ins first.
/// It also sees only `neverFires()` hops — a hop parked on an unfired `ManualTimer` is invisible
/// to it, by design, since that timer ignores cancellation (ROH-186).
class ShareUpgradeHopLedgerTestCase: XCTestCase {
    let ledger = HopLedger()

    override func tearDown() async throws {
        // Cancelled sleeps check out asynchronously, on the global executor, after
        // `cancelHops()` — so this is a condition-driven wait, not a read. Same shape as
        // `eventually`: yield first, then sleep between polls so a starved pool thread gets a core.
        let deadline = ContinuousClock.now + .seconds(5)
        var polls = 0
        while ledger.liveCount != 0, ContinuousClock.now < deadline {
            polls += 1
            if polls < 1_000 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
        }
        XCTAssertEqual(ledger.liveCount, 0, "a never-firing hop outlived its test: nothing cancelled it")
        try await super.tearDown()
    }
}

/// Observes, on the main actor and in the same turn in which the hop resumes, that a hop has
/// come BACK from its timer. That is the moment the hop evaluates its guard, so a test that fires
/// a timer and then asserts the phase did NOT change can wait for `happened` instead of betting
/// that a pool round-trip plus a main-actor hop finished inside 12 yields. The wrapper is
/// `@MainActor`, so the flag is written after the inner timer's pool hop has already returned to
/// main; by the time the test observes it, the hop's continuation is either already past its
/// guard or already enqueued on the same FIFO executor, and one `settle()` drains it.
final class HopReturn: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var happened: Bool { flag.withLock { $0 } }

    func wrapping(_ timer: @escaping @Sendable (Duration) async -> Void) -> @Sendable (Duration) async -> Void {
        { @MainActor [flag] duration in
            await timer(duration)
            flag.withLock { $0 = true }
        }
    }
}

/// The inverse of `neverFires()`: a hop whose timing a test does not care about. Written as a
/// factory for the same reason — a bare `{ _ in }` literal on the right of `??` is not inferred
/// as `@Sendable` and fails strict concurrency.
func firesImmediately() -> @Sendable (Duration) async -> Void {
    { _ in }
}

/// Holds `work` open until the test resolves it. LEVEL-TRIGGERED, like `ManualTimer` and the
/// lobby tests' `SleepGate`: a `resolve` that lands before `result()` has parked its continuation
/// is BANKED, not dropped. `result()` is a nonisolated async call, so it registers on a
/// global-pool thread one executor hop after `attempt` invokes it, and a test that has only
/// `settle()`d on the main actor can resolve inside that window. The edge-triggered version lost
/// that race and `attempt` then waited forever on a gate nobody would resolve again — the ROH-233
/// wedge, reproduced and sampled at `testARiderTapShowsItsIndicatorImmediately` on 2026-09-08.
/// The assertion before the resolve had already passed, so nothing was ever reported: XCTest
/// simply sat in `waitForExpectations` with every pool thread idle.
final class WorkGate: Sendable {
    private struct State {
        var banked: ShareUpgradeResult?
        var waiters: [CheckedContinuation<ShareUpgradeResult, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func result() async -> ShareUpgradeResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ShareUpgradeResult, Never>) in
            let ready = state.withLock { s -> ShareUpgradeResult? in
                if let value = s.banked { s.banked = nil; return value }
                s.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Releases everyone waiting now; with nobody waiting, banks the value for the next `result()`.
    func resolve(_ value: ShareUpgradeResult) {
        let pending = state.withLock { s -> [CheckedContinuation<ShareUpgradeResult, Never>] in
            guard !s.waiters.isEmpty else { s.banked = value; return [] }
            defer { s.waiters = [] }
            return s.waiters
        }
        for p in pending { p.resume(returning: value) }
    }
}

/// A bounded yield for asserting that a state has NOT changed. Twelve yields is a budget, not a
/// quiescence bound, so on its own it is only a bet that the thing which must NOT move has
/// actually had its chance to. The negative sites in this file therefore first wait on an
/// observable that proves the presenter has processed the event (`HopReturn`, or a flag set by
/// the work closure), and use `settle()` only to drain a continuation already enqueued on the
/// main actor. It is the wrong tool for a state a fired timer or a just-started `Task` must
/// PRODUCE — that is `eventually`'s job.
func settle() async {
    for _ in 0..<12 { await Task.yield() }
}

/// Yield until the condition holds, up to a generous budget. Use before asserting on state a
/// fired timer or a just-started `Task` must produce. Every timer closure in this file is a
/// nonisolated `@Sendable` async function, and under Swift 6 language mode without
/// `nonisolated(nonsending)` each call hops to the global executor: `fire()` resumes the hop on
/// a global-pool thread, which then re-enqueues on the main actor. A bare `settle()` there is a
/// bet that the pool thread gets scheduled within 12 main-queue yields — a bet the Swift 6.3
/// canary lost first (ROH-217) and main's own runners then lost three times between 2026-08-31
/// and 09-03, at lines 109 and 408 (ROH-233). A real behavior break still fails: the budget
/// exhausts and the following assertion fires exactly as before.
///
/// The budget is a wall-clock ceiling rather than a yield count, and after the first thousand
/// yields the loop sleeps a millisecond between polls, so a starved pool thread gets the core
/// the main thread would otherwise keep hot spinning against it.
@MainActor
func eventually(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    var polls = 0
    while !condition(), ContinuousClock.now < deadline {
        polls += 1
        if polls < 1_000 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
    }
}
