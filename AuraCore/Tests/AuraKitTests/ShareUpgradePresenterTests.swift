import XCTest
import os
@testable import AuraKit

@MainActor
final class ShareUpgradePresenterTests: ShareUpgradeHopLedgerTestCase {

    private func makePresenter(showDelay: ManualTimer? = nil,
                               deadline: ManualTimer? = nil,
                               dwell: ManualTimer? = nil) -> ShareUpgradePresenter {
        // The dwell default is NOT `neverFires()`: `attempt` waits on the gate the dwell hop
        // opens, so a never-firing dwell on any test that shows an indicator would park that
        // test for an hour (the ROH-233 hang class). A test that cares about the dwell floor
        // injects a `ManualTimer`; one that does not gets a gate that opens at once.
        ShareUpgradePresenter(showDelayTimer: showDelay?.closure ?? ledger.neverFires(),
                              deadlineTimer: deadline?.closure ?? ledger.neverFires(),
                              dwellTimer: dwell?.closure ?? firesImmediately())
    }

    // MARK: show-delay

    func testTheIndicatorIsHiddenUntilTheShowDelayFires() async {
        let showDelay = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await eventually { presenter.phase == .upgrading }
        XCTAssertEqual(presenter.phase, .upgrading, "in flight, nothing on screen yet")

        // The 2026-09-01 CI red (ROH-233): `settle()` here lost the fire → pool thread → main
        // actor race and read `.upgrading` one hop too early.
        showDelay.fire()
        await eventually { presenter.phase == .upgradingVisible }
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
        await eventually { presenter.phase == .upgradingVisible }
        XCTAssertEqual(presenter.phase, .upgradingVisible, "the rider pressed a button")

        work.resolve(.gotMap); dwell.fire(); await running.value
    }

    // MARK: deadline

    func testTheDeadlineOffersTheMapWhileTheAttemptIsStillOutstanding() async {
        let showDelay = ManualTimer(), deadline = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, deadline: deadline, dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await eventually { presenter.phase == .upgrading }
        showDelay.fire(); await eventually { presenter.phase == .upgradingVisible }
        deadline.fire(); await eventually { presenter.phase == .unavailable(.mayRejoin) }

        XCTAssertEqual(presenter.phase, .unavailable(.mayRejoin),
                       "the pipeline may still be running — that is exactly what mayRejoin says")

        work.resolve(.gotMap); dwell.fire(); await running.value
    }

    func testTheDeadlineIsInertOnceTheAttemptHasResolved() async {
        let deadline = ManualTimer(), returned = HopReturn()
        let presenter = ShareUpgradePresenter(showDelayTimer: ledger.neverFires(),
                                              deadlineTimer: returned.wrapping(deadline.closure),
                                              dwellTimer: firesImmediately())

        await presenter.attempt(origin: .first) { .gotMap }
        // A negative control: the phase must NOT move. `eventually` on the phase would return
        // at once and pin nothing, so wait for the hop to come back from its timer — the turn in
        // which it evaluates the guard this test exists for — then drain it with `settle()`.
        deadline.fire()
        await eventually { returned.happened }
        await settle()

        XCTAssertEqual(presenter.phase, .upgraded(confirming: false),
                       "a fired deadline must never resurrect an offer over a finished attempt")
    }

    func testAnAttemptThatSucceedsAfterTheDeadlineEndsUpgraded() async {
        let showDelay = ManualTimer(), deadline = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, deadline: deadline, dwell: dwell)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await eventually { presenter.phase == .upgrading }
        // The final assertion needs the indicator to have been ON SCREEN before the deadline
        // fired. With a bare `settle()` between the two fires, a lost race lets the deadline
        // land on `.upgrading` and the test ends `.upgraded(confirming: false)`.
        showDelay.fire(); await eventually { presenter.phase == .upgradingVisible }
        deadline.fire(); await eventually { presenter.phase == .unavailable(.mayRejoin) }

        work.resolve(.gotMap); dwell.fire(); await running.value

        XCTAssertEqual(presenter.phase, .upgraded(confirming: true),
                       "an indicator was on screen, so a visible result is owed")
    }

    // MARK: dwell

    func testAnIndicatorHoldsForTheDwellBeforeATerminalPhaseIsApplied() async {
        let showDelay = ManualTimer(), dwell = ManualTimer()
        let presenter = makePresenter(showDelay: showDelay, dwell: dwell)
        let work = WorkGate()

        // `delivered` flips on the main actor in the same turn in which `attempt` receives the
        // result and reaches the dwell gate, so the negative assertion below is about the dwell
        // and not about a result that simply has not arrived yet.
        let delivered = OSAllocatedUnfairLock(initialState: false)
        let running = Task {
            await presenter.attempt(origin: .first) {
                let result = await work.result()
                delivered.withLock { $0 = true }
                return result
            }
        }
        await eventually { presenter.phase == .upgrading }
        showDelay.fire(); await eventually { presenter.phase == .upgradingVisible }

        work.resolve(.rejected)
        await eventually { delivered.withLock { $0 } }
        await settle()
        XCTAssertEqual(presenter.phase, .upgradingVisible, "still held by the dwell")

        dwell.fire(); await running.value
        XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt))
    }

    func testAWarmRiderTapStillShowsItsIndicatorForTheDwell() async {
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)

        let running = Task { await presenter.attempt(origin: .riderTap) { .gotMap } }
        await eventually { presenter.phase == .upgradingVisible }
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

        // "Older" and "newer" are a claim about ORDER, and the wait between the two starts is
        // what makes it true: the first attempt must be in flight before the second is created.
        let older = Task { await presenter.attempt(origin: .first) { await first.result() } }
        await eventually { presenter.phase == .upgrading }
        let newer = Task { await presenter.attempt(origin: .riderTap) { await second.result() } }
        await eventually { presenter.phase == .upgradingVisible }
        XCTAssertEqual(presenter.phase, .upgradingVisible)

        // Open the newer attempt's dwell gate BEFORE the older one resolves. Without this the
        // older attempt parks on that gate and returns without ever reaching the generation
        // guard, so this test passed with the guard deleted — a mutation run proved it, twice
        // over (both `mine == generation` sites removed, 16/16 green, 3 runs of 3).
        //
        // `settle()` rather than `eventually`: the gate opening is not observable through the
        // phase, so there is no condition to wait on. It is also not load-bearing for timing —
        // `ManualTimer.fire()` banks a credit if the dwell hop has not parked yet, and `attempt`
        // waits on the gate if it is not open yet — so a lost race here changes nothing.
        dwell.fire(); await settle()

        first.resolve(.rejected); _ = await older.value
        XCTAssertEqual(presenter.phase, .upgradingVisible,
                       "the older attempt's reject must not overwrite the newer attempt's indicator")

        second.resolve(.rejected); _ = await newer.value
        XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt))
    }

    func testAStaleAttemptsMapIsStillApplied() async {
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)
        let first = WorkGate(), second = WorkGate()

        let older = Task { await presenter.attempt(origin: .first) { await first.result() } }
        await eventually { presenter.phase == .upgrading }
        let newer = Task { await presenter.attempt(origin: .riderTap) { await second.result() } }
        await eventually { presenter.phase == .upgradingVisible }

        // `_ = await older.value` rather than `settle()`: 12 `Task.yield()`s is not a
        // quiescence bound, and this assertion failed 7 times in 20 runs against it.
        first.resolve(.gotMap); dwell.fire(); _ = await older.value
        XCTAssertEqual(presenter.phase, .upgraded(confirming: true), "a map is a map")

        second.resolve(.rejected); _ = await newer.value
    }

    func testNoUpgradePossibleParksInIdle() async {
        let presenter = makePresenter()
        presenter.noUpgradePossible()
        XCTAssertEqual(presenter.phase, .idle)
    }

    // MARK: the dwell floor actually exists (ROH-186)

    /// The ONLY test in this file whose dwell timer honours cancellation, which is why it is the
    /// only one that could ever have caught ROH-186. `ManualTimer` ignores cancellation; the
    /// production timer is `try? await Task.sleep`, which swallows it and returns immediately. So
    /// `cancelHops()` — one line before `attempt` awaits the dwell gate — used to open that gate
    /// instantly and collapse a 1000 ms floor to ~10 ms. Every other assertion here passed
    /// throughout, because they all assert the fake's semantics on this axis.
    func testTheDwellSurvivesTerminalPathHopCancellation() async {
        let presenter = ShareUpgradePresenter(showDelay: .zero,
                                              deadline: .seconds(3600),
                                              minimumDwell: .milliseconds(300),
                                              showDelayTimer: { _ in },
                                              deadlineTimer: ledger.neverFires(),
                                              dwellTimer: { try? await Task.sleep(for: $0) })

        let start = ContinuousClock.now
        await presenter.attempt(origin: .riderTap) { .rejected }
        let elapsed = ContinuousClock.now - start

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200),
                                    "the indicator must hold for the dwell; ROH-186 made this ~0")
        XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt))
    }

    // MARK: the fixture's own gate (ROH-233)

    /// Pins `WorkGate` as level-triggered. `result()` registers on a global-pool thread one hop
    /// after it is called, so a resolve issued from the main actor can beat it; edge-triggered,
    /// the value was dropped and the awaiting `attempt` never returned. The waiter is an
    /// unstructured task polled under `eventually`'s wall-clock ceiling, so the old shape FAILS
    /// here after five seconds instead of wedging the whole suite.
    func testAResolveThatBeatsTheWaiterIsBankedNotLost() async {
        let gate = WorkGate()
        gate.resolve(.gotMap)

        let landed = OSAllocatedUnfairLock(initialState: ShareUpgradeResult?.none)
        let waiter = Task { let value = await gate.result(); landed.withLock { $0 = value } }
        await eventually { landed.withLock { $0 } != nil }

        XCTAssertEqual(landed.withLock { $0 }, .gotMap,
                       "a resolve nobody was waiting for must be held for the next waiter")
        // On the regression path `waiter` stays parked for the rest of the process and its
        // continuation leaks; cancelling it would not help, since `result()` is not
        // cancellation-aware. A leaked task inside a failing test is the acceptable outcome here.
        _ = waiter
    }

    // MARK: never-firing hops are released, not leaked (ROH-233)

    /// The ledger's positive control, so the `tearDown` check is known to be watching something.
    /// Two never-firing hops — the show-delay and the deadline — are parked while the attempt is
    /// outstanding, and both are gone once it resolves, because `attempt` cancels its own hops
    /// on the way out. Without the first assertion the second is vacuous: a ledger nobody checks
    /// in with reads zero forever.
    func testResolvingTheNewestAttemptReleasesItsNeverFiringHops() async {
        let presenter = makePresenter()
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await eventually { ledger.parkedCount == 2 }
        XCTAssertEqual(ledger.liveCount, 2, "show-delay and deadline are parked in hour-long sleeps")

        work.resolve(.gotMap); await running.value
        await eventually { ledger.releasedCount == 2 }
        XCTAssertEqual(ledger.liveCount, 0, "resolving the newest attempt cancelled both")
    }

    /// The other releaser: a newer attempt cancels the older attempt's hops at its own start, so
    /// an attempt that is superseded rather than resolved does not leak either.
    func testANewerAttemptReleasesTheOlderAttemptsNeverFiringHops() async {
        // The rider tap shows an indicator, so its attempt waits on the dwell gate before it can
        // return: the dwell MUST be fired below, or `await newer.value` parks forever. (This test
        // wedged the suite once on its first run for exactly that omission.)
        let dwell = ManualTimer()
        let presenter = makePresenter(dwell: dwell)
        let first = WorkGate(), second = WorkGate()

        let older = Task { await presenter.attempt(origin: .first) { await first.result() } }
        await eventually { ledger.parkedCount == 2 }
        XCTAssertEqual(ledger.liveCount, 2)

        let newer = Task { await presenter.attempt(origin: .riderTap) { await second.result() } }
        // The newer attempt arms only a deadline (a rider tap has no show-delay), so once the
        // older pair has checked out and the newer deadline has checked in, exactly one is live.
        // Waited on the monotone counters, not on `liveCount == 1`, which is also a transient
        // state on the way there.
        await eventually { ledger.releasedCount == 2 && ledger.parkedCount == 3 }
        XCTAssertEqual(ledger.liveCount, 1, "older pair released; newer deadline parked")

        first.resolve(.rejected); _ = await older.value
        second.resolve(.rejected); dwell.fire(); _ = await newer.value
        await eventually { ledger.releasedCount == 3 }
        XCTAssertEqual(ledger.liveCount, 0)
    }
}

// MARK: - the presenter records a failed rider tap

@MainActor
final class ShareUpgradeFailedTapTests: ShareUpgradeHopLedgerTestCase {

    private func presenter() -> ShareUpgradePresenter {
        ShareUpgradePresenter(showDelayTimer: { _ in },
                              deadlineTimer: ledger.neverFires(),
                              dwellTimer: { _ in })
    }

    func testAFailedFirstAttemptDoesNotEarnTheCaption() async {
        let p = presenter()
        await p.attempt(origin: .first) { .rejected }
        XCTAssertFalse(p.hasFailedARiderTap, "the rider has not asked for anything yet")
        XCTAssertNil(ShareUpgradeCopy.caption(for: p.phase, hasFailedARiderTap: p.hasFailedARiderTap))
    }

    func testAFailedRiderTapEarnsTheCaption() async {
        let p = presenter()
        await p.attempt(origin: .first) { .rejected }
        await p.attempt(origin: .riderTap) { .rejected }
        XCTAssertTrue(p.hasFailedARiderTap)
        XCTAssertEqual(ShareUpgradeCopy.caption(for: p.phase, hasFailedARiderTap: p.hasFailedARiderTap),
                       ShareUpgradeCopy.connectivityHint)
    }

    func testACeilingOnARiderTapEarnsItToo() async {
        let p = presenter()
        await p.attempt(origin: .riderTap) { .stoppedWaiting }
        XCTAssertTrue(p.hasFailedARiderTap, "stoppedWaiting is a tap that produced no map")
    }

    func testASuccessfulRiderTapDoesNotEarnIt() async {
        let p = presenter()
        await p.attempt(origin: .riderTap) { .gotMap }
        XCTAssertFalse(p.hasFailedARiderTap)
    }
}

/// The announcement counter. Its whole reason for existing is that `phase` cannot carry these
/// events — see `ShareUpgradePresenter.announcements`.
@MainActor
final class ShareUpgradeAnnouncementTests: ShareUpgradeHopLedgerTestCase {

    private func makePresenter(deadline: ManualTimer? = nil,
                               dwell: ManualTimer? = nil) -> ShareUpgradePresenter {
        ShareUpgradePresenter(showDelayTimer: { _ in },
                              deadlineTimer: deadline?.closure ?? ledger.neverFires(),
                              dwellTimer: dwell?.closure ?? firesImmediately())
    }

    func testNothingIsAnnouncedWhileAnAttemptIsInFlight() async {
        let presenter = makePresenter()
        let work = WorkGate()
        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        // main went red on this line three times (2026-08-31, 09-01, 09-03): even a `{ _ in }`
        // show-delay is a nonisolated async call, so it still round-trips the global executor.
        await eventually { presenter.phase == .upgradingVisible }

        XCTAssertEqual(presenter.phase, .upgradingVisible)
        XCTAssertEqual(presenter.announcements, 0, "a spinner is not news")

        work.resolve(.gotMap); _ = await running.value
    }

    func testTheDeadlineAndItsOwnRejectAnnounceOnce() async {
        let deadline = ManualTimer()
        let presenter = makePresenter(deadline: deadline)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await eventually { presenter.phase == .upgradingVisible }
        deadline.fire()
        await eventually { presenter.phase == .unavailable(.mayRejoin) }
        XCTAssertEqual(presenter.phase, .unavailable(.mayRejoin))
        XCTAssertEqual(presenter.announcements, 1)

        // The attempt itself now resolves, four seconds later in real time, and moves the
        // retryability. The rider has already been told there is no map.
        work.resolve(.rejected); _ = await running.value
        XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt), "the phase did change")
        XCTAssertEqual(presenter.announcements, 1, "and the rider is not told the same thing twice")
    }

    func testAFailedTapIsAnnouncedEvenThoughThePhaseEndsWhereItStarted() async {
        let presenter = makePresenter()
        await presenter.attempt(origin: .first) { .rejected }
        XCTAssertEqual(presenter.announcements, 1)
        let before = presenter.phase

        await presenter.attempt(origin: .riderTap) { .rejected }

        XCTAssertEqual(presenter.phase, before,
                       "same phase in and out — which is why watching the phase cannot work")
        XCTAssertEqual(presenter.announcements, 2, "the rider asked, so the rider is answered")
        XCTAssertEqual(ShareUpgradeCopy.announcement(for: presenter.phase,
                                                     hasFailedARiderTap: presenter.hasFailedARiderTap),
                       "No map yet. \(ShareUpgradeCopy.connectivityHint).")
    }

    func testAMapThatLandsWithNoIndicatorOnScreenIsSilent() async {
        let presenter = makePresenter()
        await presenter.attempt(origin: .first) { .gotMap }
        XCTAssertEqual(presenter.phase, .upgraded(confirming: false))
        XCTAssertEqual(presenter.announcements, 0,
                       "the entrance is not interrupted to report something nobody asked about")
    }

    func testAMapTheRiderWaitedForIsAnnouncedOnce() async {
        let presenter = makePresenter()
        await presenter.attempt(origin: .riderTap) { .gotMap }
        XCTAssertEqual(presenter.phase, .upgraded(confirming: true))
        XCTAssertEqual(presenter.announcements, 1)
        XCTAssertEqual(ShareUpgradeCopy.announcement(for: presenter.phase,
                                                     hasFailedARiderTap: presenter.hasFailedARiderTap),
                       ShareUpgradeCopy.confirmation)
    }
}
