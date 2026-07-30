import Testing
import AuraCore
@testable import AuraKit

@MainActor
struct GuidanceViewModelHapticsTests {
    private func makeRoute() -> Route {
        let o = Coordinate(latitude: 40.44, longitude: -79.99)
        let d = Coordinate(latitude: 40.45, longitude: -79.95)
        return Route(origin: o, destination: d, waypoints: [], geometry: [o, d],
                     profile: .fastest, distanceMeters: 3000,
                     estimatedDurationSeconds: 600, elevationGainMeters: 20)
    }

    @Test func enabledFiresApproachThenArrival() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 200, instruction: "Right onto Penn Ave")),
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Right onto Penn Ave")),
            .arrivedAtDestination
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        await vm.run(route: makeRoute())
        #expect(spy.cues == [.approach, .arrival])
    }

    @Test func disabledFiresNothing() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Turn")),
            .arrivedAtDestination
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = false
        await vm.run(route: makeRoute())
        #expect(spy.cues.isEmpty)
    }

    @Test func doesNotDoubleFireApproach() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Turn")),
            .progress(.init(distanceToManeuverMeters: 120, instruction: "Turn"))
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        await vm.run(route: makeRoute())
        #expect(spy.cues == [.approach])
    }

    @Test func prepareCalledOnStart() {
        let session = ScriptedGuidanceSession(script: [])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.start(route: makeRoute())
        #expect(spy.prepareCount == 1)
        vm.stop()
    }

    @Test func pausedFiresNoTurnHaptic() async {
        // Spoken instructions are already suppressed while paused. Leaving the haptic firing
        // means a rider at lunch with the phone pocketed still gets buzzed about turns they
        // are not taking, and on an accidental pause the surviving buzz is what convinces them
        // nothing is wrong while the voice has gone silent.
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        vm.rideDidSetPaused(true)
        await vm.run(route: makeRoute())
        #expect(spy.cues.isEmpty)
    }

    @Test func aCrossingTakenWhilePausedDoesNotBurnTheManeuversOnlyBuzz() async {
        // The pause gate must skip the engine, not just the play. `TurnHapticEngine` fires once
        // per maneuver key, so a threshold crossing consumed during the stop would spend this
        // turn's only trigger — and the rider resumes 140 m from a turn they are never buzzed
        // for. `ScriptedGuidanceSession` replays its script on each `start`, so the second run
        // is the same maneuver, at the same distance, with the ride recording again.
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true

        vm.rideDidSetPaused(true)
        await vm.run(route: makeRoute())
        #expect(spy.cues.isEmpty)

        vm.rideDidSetPaused(false)
        await vm.run(route: makeRoute())
        #expect(spy.cues == [.approach],
                "the crossing taken while paused burned this maneuver's only approach buzz")
    }

    @Test func resumingRestoresTurnHaptics() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 140, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        let spy = HapticSpy()
        vm.haptics = spy
        vm.hapticsEnabled = true
        vm.rideDidSetPaused(true)
        vm.rideDidSetPaused(false)
        await vm.run(route: makeRoute())
        #expect(spy.cues == [.approach])
    }
}
