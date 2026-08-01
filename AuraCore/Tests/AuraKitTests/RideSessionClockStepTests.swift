import Foundation
import Testing
import AuraCore
@testable import AuraKit

/// The cockpit's two numbers and the Live Activity's payload through a system clock step, driven
/// end to end so the ticker path, `align`, and the anchors are all in the loop.
@MainActor
@Suite(.swiftDataSerialized)
struct RideSessionClockStepTests {
    /// Two returns, not three, because `large_tuple` caps them at two — the store is reachable
    /// through the coordinator, and only the reuse fixture below needs to name it, so that one
    /// makes its own and passes it in.
    private func startedCoordinator(clock: FakeRideClock, store: RideStore)
        -> (RideSessionCoordinator, SpyRideActivity) {
        let activity = SpyRideActivity()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: activity,
                                       haptics: HapticSpy(), nudges: NudgeSpy(), clock: clock)
        c.start(location: ScriptedLocationProvider([]), saving: store, units: .metric,
                authorization: .authorized)
        return (c, activity)
    }

    private func startedCoordinator(clock: FakeRideClock)
        throws -> (RideSessionCoordinator, SpyRideActivity) {
        startedCoordinator(clock: clock, store: try RideStore.inMemory())
    }

    private func tick(_ c: RideSessionCoordinator, _ clock: FakeRideClock) {
        let now = clock.now()
        c.refreshElapsed(now: now)
        c.pushActivityUpdate(now: now)
    }

    // MARK: the cockpit

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
    /// rather than the guard.
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
        let store = try RideStore.inMemory()
        let (c, _) = startedCoordinator(clock: clock, store: store)
        clock.advance(600)
        c.pause()
        clock.advance(600)
        c.refreshElapsed(now: clock.now())
        #expect(c.currentPauseSeconds > 0)
        c.finish()
        c.start(location: ScriptedLocationProvider([]), saving: store, units: .metric,
                authorization: .authorized)
        #expect(c.currentPauseSeconds == 0, "start() zeroes this synchronously, before any tick")
    }

    // MARK: Live Activity payload stability

    /// The push dedupe compares whole payloads, so a clock that moves every tick turns a
    /// forty-minute café stop from one push a minute into one every four seconds.
    ///
    /// **What this pins, measured rather than assumed:** that neither field of the paused payload
    /// is a raw per-tick reading. A `since` of `now`, or an `activeSeconds` carrying
    /// `pausedSeconds(asOf: now)` unmodified, goes red here.
    ///
    /// **What it does not catch:** a per-tick *recomputation* that happens to cancel on a coherent
    /// clock. Restoring the old `betweenStamps(startedAt, now) - pausedSeconds` arithmetic, and
    /// deriving `since` as `now - currentPauseSeconds`, were both mutated in and both stayed green
    /// through this fixture. `aSubThresholdDivergenceChangesNothing` below is the discriminating
    /// one for that class: its slew moves the wall half off the monotonic timeline, so anything
    /// recomputed from a wall reading stops cancelling and the payload flaps. The odd tick interval
    /// here is production realism, not a discriminator — the old arithmetic survives this fixture
    /// at any interval.
    @Test func thePausedClockIsIdenticalAcrossFortyTicks() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, activity) = try startedCoordinator(clock: clock)
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
        let (c, activity) = try startedCoordinator(clock: clock)
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
        let (c, activity) = try startedCoordinator(clock: clock)
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
        let (c, activity) = try startedCoordinator(clock: clock)
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
            let (c, activity) = try startedCoordinator(clock: clock)
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

    /// Pins the *running* anchor's clock-step correction. Every other fixture in this file steps
    /// the clock during a stop; this is the majority case none of them cover — a ride with no
    /// pause open at all, which is where a navigated rider spends almost the whole ride. That
    /// rider has no active-time cell on the cockpit, so the Lock Screen's
    /// `Text(anchor, style: .timer)` is their only reading of active time, and this surface had no
    /// step coverage until this fixture: `pushActivityUpdate` builds the running anchor from
    /// `recorder.anchorStartedAt`, which carries `wallOffset`, but passing `recorder.startedAt` —
    /// the raw, uncorrected stamp — instead compiles, type-checks, and left the entire package and
    /// app suite green, because every existing Live Activity fixture drives the paused branch.
    @Test func aStepWhileRunningMovesTheRunningAnchorByTheStepThenSettles() throws {
        let clock = FakeRideClock(date: Date(timeIntervalSinceReferenceDate: 1_000_000))
        let (c, activity) = try startedCoordinator(clock: clock)
        clock.advance(600)
        tick(c, clock)
        let before = try #require(activity.clocks.last)

        clock.step = -40
        clock.advance(0.5)
        tick(c, clock)
        let after = try #require(activity.clocks.last)

        guard case .running(let anchor0) = before, case .running(let anchor1) = after else {
            Issue.record("expected two running clocks"); return
        }
        #expect(anchor1.timeIntervalSince(anchor0) == -40, "one step, one anchor move")

        for _ in 0..<5 { clock.advance(0.5); tick(c, clock) }
        let runningClocks = Set(activity.clocks.filter { !$0.isPaused })
        #expect(runningClocks.count == 2, "one step costs exactly one push, then it settles")
    }
}
