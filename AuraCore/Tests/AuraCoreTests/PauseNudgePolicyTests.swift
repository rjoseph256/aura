import Testing
import Foundation
@testable import AuraCore

@Suite("Pause nudge policy")
struct PauseNudgePolicyTests {
    @Test("The ladder backs off rather than repeating at a fixed interval")
    func ladderBacksOff() {
        let offsets = PauseNudgePolicy.rungs.map(\.after)
        #expect(offsets == [600, 1500, 2700, 4500, 7200])
    }

    @Test("The ladder is strictly increasing")
    func strictlyIncreasing() {
        let offsets = PauseNudgePolicy.rungs.map(\.after)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("Every rung is a positive interval, which is all a non-repeating trigger requires")
    func everyRungIsPositive() {
        // Not 60 seconds: that floor applies to `repeats: true`, and no rung repeats.
        #expect(PauseNudgePolicy.rungs.allSatisfy { $0.after > 0 })
    }

    @Test("The first rung is late enough that an ordinary stop never fires it")
    func firstRungClearsAnOrdinaryStop() {
        // A coffee queue, a mechanical or a photo stop must not trigger a nudge.
        #expect((PauseNudgePolicy.rungs.first?.after ?? 0) >= 600)
    }

    @Test("Identifiers are unique, so cancellation removes every rung")
    func identifiersAreUnique() {
        let ids = PauseNudgePolicy.allIdentifiers
        #expect(ids.count == PauseNudgePolicy.rungs.count)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Each rung states its own duration, which a repeating trigger could not")
    func bodyStatesTheDuration() {
        #expect(PauseNudgePolicy.rungs[0].body.contains("10 minutes"))
        #expect(PauseNudgePolicy.rungs[1].body.contains("25 minutes"))
        #expect(PauseNudgePolicy.rungs[4].body.contains("2 hours"))
    }

    @Test("No rung claims the ride is still recording")
    func copyIsHonest() {
        #expect(PauseNudgePolicy.rungs.allSatisfy {
            $0.body.contains("hasn't recorded anything")
        })
    }

    @Test("No rung asserts a live pause, which a jetsam kill would make false")
    func copySurvivesAJetsamKill() {
        // A long stop is the likeliest end of the app's process, and these fire from the
        // system after it. "Your ride has been paused for 2 hours" is then a lie told by the
        // rung most likely to be the one that fires. Every rung states what has NOT been
        // recorded since the pause instead, which holds whether the ride is paused or gone.
        for rung in PauseNudgePolicy.rungs {
            #expect(rung.title == "Aura isn't recording")
            #expect(rung.body.hasPrefix("Aura hasn't recorded anything since you paused"))
            #expect(!rung.body.contains("is paused"))
            #expect(!rung.body.contains("has been paused"))
            #expect(!rung.body.contains("still paused"))
        }
    }

    @Test("The ladder is bounded, so a jetsam orphan cannot nag forever")
    func ladderIsBounded() {
        #expect(PauseNudgePolicy.rungs.count == 5)
        #expect(PauseNudgePolicy.rungs.last?.after == 7200)
    }

    // MARK: pendingRungs — the feature's only arithmetic

    @Test("A pause scheduled the instant it happens arms the whole ladder, offsets untouched")
    func aFreshPauseArmsEveryRung() {
        let pending = PauseNudgePolicy.pendingRungs(elapsedSincePause: 0)
        #expect(pending.count == 5)
        #expect(pending.map(\.interval) == [600, 1500, 2700, 4500, 7200])
        #expect(pending.map(\.rung) == PauseNudgePolicy.rungs)
    }

    @Test("A rung already past is dropped, and the survivors count from now, not from the pause")
    func rungsAlreadyPastAreDropped() {
        // 20 minutes into the stop: the 10-minute rung has gone, and the 25-minute rung is
        // five minutes away — not twenty-five.
        let pending = PauseNudgePolicy.pendingRungs(elapsedSincePause: 1200)
        #expect(pending.map(\.rung.identifier) == ["pause.nudge.2", "pause.nudge.3",
                                                   "pause.nudge.4", "pause.nudge.5"])
        #expect(pending.map(\.interval) == [300, 1500, 3300, 6000])
    }

    @Test("A rung landing exactly now is dropped: a trigger needs a positive interval")
    func aRungExactlyDueIsDropped() {
        let pending = PauseNudgePolicy.pendingRungs(elapsedSincePause: 600)
        #expect(pending.allSatisfy { $0.interval > 0 })
        #expect(!pending.contains { $0.rung.identifier == "pause.nudge.1" })
        #expect(pending.count == 4)
    }

    @Test("A stop that outran the ladder arms nothing rather than scheduling the past")
    func aStopPastEveryRungArmsNothing() {
        #expect(PauseNudgePolicy.pendingRungs(elapsedSincePause: 7200).isEmpty)
        #expect(PauseNudgePolicy.pendingRungs(elapsedSincePause: 86_400).isEmpty)
    }

    @Test("A negative elapsed is treated as this instant, not as extra runway")
    func aNegativeElapsedDoesNotPushTheLadderOut() {
        // A backward wall-clock step between the tap and the schedule call. Clamping keeps the
        // ladder anchored where it would have been rather than firing an hour late.
        let pending = PauseNudgePolicy.pendingRungs(elapsedSincePause: -3600)
        #expect(pending.map(\.interval) == PauseNudgePolicy.rungs.map(\.after))
    }

    @Test("Every armed interval is positive, whatever the elapsed")
    func everyArmedIntervalIsPositive() {
        for elapsed in stride(from: -100.0, through: 7500.0, by: 137) {
            let pending = PauseNudgePolicy.pendingRungs(elapsedSincePause: elapsed)
            #expect(pending.allSatisfy { $0.interval > 0 }, "elapsed \(elapsed)")
        }
    }
}
