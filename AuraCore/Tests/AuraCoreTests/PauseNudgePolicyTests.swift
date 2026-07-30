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
        #expect(PauseNudgePolicy.rungs.allSatisfy { $0.body.contains("isn't recording") })
    }

    @Test("The ladder is bounded, so a jetsam orphan cannot nag forever")
    func ladderIsBounded() {
        #expect(PauseNudgePolicy.rungs.count == 5)
        #expect(PauseNudgePolicy.rungs.last?.after == 7200)
    }
}
