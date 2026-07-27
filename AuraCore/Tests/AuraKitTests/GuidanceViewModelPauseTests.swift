import XCTest
import AuraCore
@testable import AuraKit

/// Spec D7: a rider pauses *at* the destination they navigated to — inside the arrival radius.
/// Left untouched, arrival calls `onArrive`, which ends the ride and pushes the summary with
/// no confirmation, under a rider who is standing next to their bike.
@MainActor
final class GuidanceViewModelPauseTests: XCTestCase {
    private func makeRoute() -> Route {
        let o = Coordinate(latitude: 40.44, longitude: -79.99)
        let d = Coordinate(latitude: 40.45, longitude: -79.95)
        return Route(origin: o, destination: d, waypoints: [], geometry: [o, d],
                     profile: .fastest, distanceMeters: 3000,
                     estimatedDurationSeconds: 600, elevationGainMeters: 20)
    }

    func test_arrivalWhilePaused_doesNotEndTheRide() async {
        let session = ScriptedGuidanceSession(script: [
            .arrivedAtDestination,
            .progress(.init(distanceToManeuverMeters: 90, instruction: "Continue on Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        var arrivals = 0
        vm.onArrive = { arrivals += 1 }
        vm.isPaused = true

        await vm.run(route: makeRoute())

        XCTAssertEqual(arrivals, 0)
        XCTAssertEqual(vm.lastUpdate?.instruction, "Continue on Penn Ave",
                       "suppressing arrival must not stop consuming the stream")
    }

    func test_arrivalWhenNotPaused_stillEndsTheRide() async {
        let session = ScriptedGuidanceSession(script: [.arrivedAtDestination])
        let vm = GuidanceViewModel(session: session)
        var arrivals = 0
        vm.onArrive = { arrivals += 1 }

        await vm.run(route: makeRoute())

        XCTAssertEqual(arrivals, 1)
    }

    /// The lesser half of the same change: voice guidance talking over the rider's music
    /// during a café stop.
    func test_spokenInstructionsAreSuppressedWhilePaused() async {
        let session = ScriptedGuidanceSession(script: [
            .spokenInstruction("In 400 feet, turn right")
        ])
        let vm = GuidanceViewModel(session: session)
        var spoken: [String] = []
        vm.onSpeak = { spoken.append($0) }
        vm.isPaused = true

        await vm.run(route: makeRoute())

        XCTAssertTrue(spoken.isEmpty)
    }
}
