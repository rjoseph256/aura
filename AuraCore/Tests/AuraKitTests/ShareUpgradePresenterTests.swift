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
