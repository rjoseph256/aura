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
}
