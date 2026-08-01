import Testing
import Foundation
@testable import AuraCore

@Suite("Ride active clock")
struct RideActiveClockTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A ride with no pauses anchors at its start")
    func runningWithNoPauses() {
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 0,
                                         pausedSince: nil, now: start.addingTimeInterval(600))
        #expect(clock == .running(anchor: start))
        #expect(clock.isPaused == false)
    }

    @Test("After a stop the anchor shifts forward by exactly the paused seconds")
    func runningAfterOnePause() {
        // 10 min of wall clock, 4 of them stopped: active is 6 min, so the anchor sits 4 min in.
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 240,
                                         pausedSince: nil, now: start.addingTimeInterval(600))
        #expect(clock == .running(anchor: start.addingTimeInterval(240)))
    }

    @Test("A running anchor is identical across a span of ticks")
    func runningIsStableAcrossTicks() {
        // While no stop is open pausedSeconds does not move, so neither may the anchor — a
        // per-tick anchor would be a per-tick payload and the dedupe would never fire.
        let ticks = (0..<200).map { i in
            RideActiveClock.make(startedAt: start, pausedSeconds: 240, pausedSince: nil,
                                 now: start.addingTimeInterval(600 + Double(i) * 0.5))
        }
        #expect(Set(ticks).count == 1)
    }

    @Test("The anchor is never in the future, so the OS timer cannot count down")
    func anchorClampedToNow() {
        // A backward wall-clock step (NTP correction) makes startedAt + paused exceed now.
        let now = start.addingTimeInterval(100)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 500,
                                         pausedSince: nil, now: now)
        #expect(clock == .running(anchor: now))
    }

    @Test("A stop carries its own instant and the active time frozen at that instant")
    func pausedCarriesStopInstantAndFrozenActive() {
        // Stop opened at start+600 with nothing paused before it. 90 s later the recorder
        // reports pausedSeconds(asOf: now) == 90, so active is 690 - 90 = 600 — which is
        // exactly the active time at the instant the stop began.
        let stoppedAt = start.addingTimeInterval(600)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 90,
                                         pausedSince: stoppedAt,
                                         now: stoppedAt.addingTimeInterval(90))
        #expect(clock == .paused(since: stoppedAt, activeSeconds: 600))
        #expect(clock.isPaused)
    }

    @Test("A second stop freezes active time net of the first stop")
    func pausedAfterAnEarlierStop() {
        // 60 s banked from an earlier stop; this stop opens at start+900 and is 90 s old.
        let stoppedAt = start.addingTimeInterval(900)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 150,
                                         pausedSince: stoppedAt,
                                         now: stoppedAt.addingTimeInterval(90))
        #expect(clock == .paused(since: stoppedAt, activeSeconds: 840))
    }

    @Test("The paused value is identical across a span of ticks")
    func pausedIsStableAcrossTicks() {
        // The trap that killed spec revision 1: pausedSeconds(asOf:) grows every tick while a
        // stop is open, so anything carrying it raw changes every tick and defeats the dedupe.
        let stoppedAt = start.addingTimeInterval(600)
        let ticks = (0..<200).map { i -> RideActiveClock in
            let now = stoppedAt.addingTimeInterval(Double(i) * 0.5)
            return .make(startedAt: start, pausedSeconds: Double(i) * 0.5,
                         pausedSince: stoppedAt, now: now)
        }
        #expect(Set(ticks).count == 1)
    }

    @Test("Frozen active seconds never go negative")
    func frozenActiveClampedAtZero() {
        let stoppedAt = start.addingTimeInterval(10)
        let clock = RideActiveClock.make(startedAt: start, pausedSeconds: 999,
                                         pausedSince: stoppedAt, now: stoppedAt)
        #expect(clock == .paused(since: stoppedAt, activeSeconds: 0))
    }

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
