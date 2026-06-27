import Testing
import AuraCore

struct TurnHapticEngineTests {
    @Test func approachFiresOnceWhenCrossingThreshold() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 200, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 160, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
    }

    @Test func approachDoesNotFireAboveThreshold() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 300, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 151, maneuverKey: "A") == nil)
    }

    @Test func approachFiresImmediatelyWhenFirstUpdateAlreadyWithin() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 120, maneuverKey: "A") == .approach)
    }

    @Test func approachDoesNotDoubleFireForSameManeuver() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
        #expect(engine.onProgress(distanceToManeuverMeters: 120, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 100, maneuverKey: "A") == nil)
    }

    @Test func keyChangeReArmsForNextManeuver() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
        #expect(engine.onProgress(distanceToManeuverMeters: 300, maneuverKey: "B") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "B") == .approach)
    }

    @Test func sameKeyDoesNotReFireAfterRecedeAndReApproach() {
        // Non-monotonic distance (a stop or a position re-snap) must not double-fire
        // the same turn — the once-per-key guard, not a hysteresis band, handles this.
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 140, maneuverKey: "A") == .approach)
        #expect(engine.onProgress(distanceToManeuverMeters: 185, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 130, maneuverKey: "A") == nil)
    }

    @Test func arrivalFiresOnceOnly() {
        var engine = TurnHapticEngine()
        #expect(engine.onArrival() == .arrival)
        #expect(engine.onArrival() == nil)
    }

    @Test func finalManeuverFiresApproachThenArrival() {
        var engine = TurnHapticEngine()
        #expect(engine.onProgress(distanceToManeuverMeters: 120, maneuverKey: "Arriving") == .approach)
        #expect(engine.onArrival() == .arrival)
    }

    @Test func customThresholdHonored() {
        var engine = TurnHapticEngine(approachWithinMeters: 50)
        #expect(engine.onProgress(distanceToManeuverMeters: 80, maneuverKey: "A") == nil)
        #expect(engine.onProgress(distanceToManeuverMeters: 50, maneuverKey: "A") == .approach)
    }
}
