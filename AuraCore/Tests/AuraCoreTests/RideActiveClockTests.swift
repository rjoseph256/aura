import Testing
import Foundation
@testable import AuraCore

@Suite("Ride active clock")
struct RideActiveClockTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A ride with no pauses anchors at its start")
    func runningWithNoPauses() {
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 0,
                                         openStop: nil, now: start.addingTimeInterval(600))
        #expect(clock == .running(anchor: start))
        #expect(clock.isPaused == false)
    }

    @Test("After a stop the anchor shifts forward by exactly the paused seconds")
    func runningAfterOnePause() {
        // 10 min of wall clock, 4 of them stopped: active is 6 min, so the anchor sits 4 min in.
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 240,
                                         openStop: nil, now: start.addingTimeInterval(600))
        #expect(clock == .running(anchor: start.addingTimeInterval(240)))
    }

    @Test("A running anchor is identical across a span of ticks")
    func runningIsStableAcrossTicks() {
        // While no stop is open pausedSeconds does not move, so neither may the anchor — a
        // per-tick anchor would be a per-tick payload and the dedupe would never fire.
        let ticks = (0..<200).map { i in
            RideActiveClock.make(startedAt: start, pausedSeconds: 240, openStop: nil,
                                 now: start.addingTimeInterval(600 + Double(i) * 0.5))
        }
        #expect(Set(ticks).count == 1)
    }

    @Test("The anchor is never in the future, so the OS timer cannot count down")
    func anchorClampedToNow() {
        // A backward wall-clock step (NTP correction) makes startedAt + paused exceed now.
        let now = start.addingTimeInterval(100)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 500,
                                         openStop: nil, now: now)
        #expect(clock == .running(anchor: now))
    }

    // The paused branch's arithmetic is no longer here, because `make` no longer performs it: the
    // recorder freezes both halves of the stop at the tap and `make` copies them across. The four
    // tests that used to sit at this point moved with the code, none of them dropped:
    //
    // - `pausedCarriesStopInstantAndFrozenActive` → `RideClockStepTests`
    //   `.activeSecondsAtPauseIsActiveTimeAtTheTap`
    // - `pausedAfterAnEarlierStop` → `RideClockStepTests.aSecondStopFreezesActiveTimeNetOfTheFirst`
    // - `frozenActiveClampedAtZero` → `RideDurationTests.activeFloorsAtZeroRatherThanGoingNegative`
    //   plus the `max(0,)` inside the `RideDuration.activeSeconds` that `RideRecorder.pause(at:)`
    //   calls — the floor lives there now, not in `make`
    // - `pausedIsStableAcrossTicks` → `RideSessionClockStepTests`
    //   `.thePausedClockIsIdenticalAcrossFortyTicks`, which drives the coordinator's wiring. A
    //   pure-function version here would assert that a field copy equals itself and could not
    //   fail for any implementation.
    //
    // They live in `AuraKitTests` because they exercise `RideRecorder`, which `AuraCoreTests`
    // cannot import.

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        let cases: [RideActiveClock] = [
            .running(anchor: start),
            .paused(since: start, activeSeconds: 540)
        ]
        for clock in cases {
            let data = try JSONEncoder().encode(clock)
            #expect(try JSONDecoder().decode(RideActiveClock.self, from: data) == clock)
        }
    }
}
