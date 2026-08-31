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

/// The inverse of `neverFires()`: a hop whose timing a test does not care about. Written as a
/// factory for the same reason — a bare `{ _ in }` literal on the right of `??` is not inferred
/// as `@Sendable` and fails strict concurrency.
private func firesImmediately() -> @Sendable (Duration) async -> Void {
    { _ in }
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
                       "an indicator was on screen, so a visible result is owed")
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

        // Open the newer attempt's dwell gate BEFORE the older one resolves. Without this the
        // older attempt parks on that gate and returns without ever reaching the generation
        // guard, so this test passed with the guard deleted — a mutation run proved it, twice
        // over (both `mine == generation` sites removed, 16/16 green, 3 runs of 3).
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
        await settle()
        let newer = Task { await presenter.attempt(origin: .riderTap) { await second.result() } }
        await settle()

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
                                              deadlineTimer: neverFires(),
                                              dwellTimer: { try? await Task.sleep(for: $0) })

        let start = ContinuousClock.now
        await presenter.attempt(origin: .riderTap) { .rejected }
        let elapsed = ContinuousClock.now - start

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200),
                                    "the indicator must hold for the dwell; ROH-186 made this ~0")
        XCTAssertEqual(presenter.phase, .unavailable(.freshAttempt))
    }
}

// MARK: - the connectivity caption

@MainActor
final class ShareUpgradeCopyTests: XCTestCase {

    func testTheCaptionIsWithheldUntilARiderTapHasFailed() {
        let terminal = ShareUpgradePhase.unavailable(.freshAttempt)
        XCTAssertNil(ShareUpgradeCopy.caption(for: terminal, hasFailedARiderTap: false),
                     "the first offer stands alone; the rider has not tried anything yet")
        XCTAssertEqual(ShareUpgradeCopy.caption(for: terminal, hasFailedARiderTap: true),
                       ShareUpgradeCopy.connectivityHint)
    }

    func testTheCaptionNeverShowsOutsideATerminalOffer() {
        for phase: ShareUpgradePhase in [.idle, .upgrading, .upgradingVisible,
                                         .upgraded(confirming: true), .upgraded(confirming: false)] {
            XCTAssertNil(ShareUpgradeCopy.caption(for: phase, hasFailedARiderTap: true),
                         "\(phase) shows no offer, so it can carry no caption for one")
        }
    }

    func testBothRetryabilitiesCarryTheCaption() {
        for retryability: Retryability in [.freshAttempt, .mayRejoin] {
            XCTAssertEqual(
                ShareUpgradeCopy.caption(for: .unavailable(retryability), hasFailedARiderTap: true),
                ShareUpgradeCopy.connectivityHint,
                "both render the same live offer, so both earn the same caption")
        }
    }

    func testAFailedTapDoesNotAnnounceLikeASuccessfulOne() {
        let failed = ShareUpgradeCopy.announcement(for: .unavailable(.mayRejoin),
                                                   hasFailedARiderTap: true)
        let succeeded = ShareUpgradeCopy.announcement(for: .upgraded(confirming: true),
                                                      hasFailedARiderTap: true)
        XCTAssertNotNil(failed)
        XCTAssertNotEqual(failed, succeeded)
        XCTAssertEqual(succeeded, ShareUpgradeCopy.confirmation)
    }

    /// The row and the announcement must agree, or a VoiceOver rider and a sighted rider are told
    /// different things about the same state.
    func testTheAnnouncementCarriesTheHintExactlyWhenTheCaptionDoes() {
        for hasFailed in [true, false] {
            let phase = ShareUpgradePhase.unavailable(.freshAttempt)
            let announced = ShareUpgradeCopy.announcement(for: phase, hasFailedARiderTap: hasFailed)
            let captioned = ShareUpgradeCopy.caption(for: phase, hasFailedARiderTap: hasFailed)
            XCTAssertEqual(announced?.contains(ShareUpgradeCopy.connectivityHint), captioned != nil)
        }
    }

    func testNonTerminalPhasesAnnounceNothing() {
        for phase: ShareUpgradePhase in [.idle, .upgrading, .upgradingVisible] {
            XCTAssertNil(ShareUpgradeCopy.announcement(for: phase, hasFailedARiderTap: true))
        }
    }
}

// MARK: - the presenter records a failed rider tap

@MainActor
final class ShareUpgradeFailedTapTests: XCTestCase {

    private func presenter() -> ShareUpgradePresenter {
        ShareUpgradePresenter(showDelayTimer: { _ in },
                              deadlineTimer: { _ in try? await Task.sleep(for: .seconds(3600)) },
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
final class ShareUpgradeAnnouncementTests: XCTestCase {

    private func makePresenter(deadline: ManualTimer? = nil,
                               dwell: ManualTimer? = nil) -> ShareUpgradePresenter {
        ShareUpgradePresenter(showDelayTimer: { _ in },
                              deadlineTimer: deadline?.closure ?? neverFires(),
                              dwellTimer: dwell?.closure ?? firesImmediately())
    }

    func testNothingIsAnnouncedWhileAnAttemptIsInFlight() async {
        let presenter = makePresenter()
        let work = WorkGate()
        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await settle()

        XCTAssertEqual(presenter.phase, .upgradingVisible)
        XCTAssertEqual(presenter.announcements, 0, "a spinner is not news")

        work.resolve(.gotMap); _ = await running.value
    }

    func testTheDeadlineAndItsOwnRejectAnnounceOnce() async {
        let deadline = ManualTimer()
        let presenter = makePresenter(deadline: deadline)
        let work = WorkGate()

        let running = Task { await presenter.attempt(origin: .first) { await work.result() } }
        await settle()
        deadline.fire(); await settle()
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
