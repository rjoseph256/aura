import XCTest
import AuraCore
@testable import AuraKit

@MainActor
final class GuidanceViewModelTests: XCTestCase {

    /// A throwaway route — the scripted session ignores it; the VM only needs *a* route.
    private func makeRoute() -> Route {
        let o = Coordinate(latitude: 40.44, longitude: -79.99)
        let d = Coordinate(latitude: 40.45, longitude: -79.95)
        return Route(origin: o, destination: d, waypoints: [], geometry: [o, d],
                     profile: .fastest, distanceMeters: 3000,
                     estimatedDurationSeconds: 600, elevationGainMeters: 20)
    }

    func test_progressEvents_driveTurnCard() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 400, instruction: "Continue on Forbes Ave")),
            .progress(.init(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)

        await vm.run(route: makeRoute())

        // Reflects the LAST progress update.
        XCTAssertEqual(vm.turn.primaryText, "Right onto Penn Ave")
        XCTAssertEqual(vm.turn.distanceText, "390 ft") // 120 m → nearest 10 ft
        XCTAssertTrue(vm.turn.isExpanded)              // within 150 m threshold

        // Raw numbers behind that update are exposed for the Live Activity.
        XCTAssertEqual(vm.lastUpdate?.distanceToManeuverMeters, 120)
        XCTAssertEqual(vm.lastUpdate?.instruction, "Right onto Penn Ave")
    }

    func test_lastUpdate_nilUntilFirstProgress() async {
        let session = ScriptedGuidanceSession(script: [
            .spokenInstruction("Head north")  // no progress event
        ])
        let vm = GuidanceViewModel(session: session)

        await vm.run(route: makeRoute())

        XCTAssertNil(vm.lastUpdate)
    }

    func test_spokenInstructions_forwardedToOnSpeak() async {
        let session = ScriptedGuidanceSession(script: [
            .spokenInstruction("In 400 feet, turn right"),
            .progress(.init(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave")),
            .spokenInstruction("Turn right onto Penn Avenue")
        ])
        let vm = GuidanceViewModel(session: session)
        var spoken: [String] = []
        vm.onSpeak = { spoken.append($0) }

        await vm.run(route: makeRoute())

        XCTAssertEqual(spoken, ["In 400 feet, turn right", "Turn right onto Penn Avenue"])
    }

    func test_arrival_invokesOnArrive() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 30, instruction: "Arriving")),
            .arrivedAtDestination
        ])
        let vm = GuidanceViewModel(session: session)
        var arrived = false
        vm.onArrive = { arrived = true }

        await vm.run(route: makeRoute())

        XCTAssertTrue(arrived)
    }

    func test_emptyStream_degradesToUnavailable() async {
        let session = ScriptedGuidanceSession(script: [])
        let vm = GuidanceViewModel(session: session)

        await vm.run(route: makeRoute())

        XCTAssertEqual(vm.turn, .unavailable)
    }

    func test_arrivalWithoutProgress_doesNotShowUnavailable() async {
        // Arriving immediately is not a guidance failure — don't clobber with "unavailable".
        let session = ScriptedGuidanceSession(script: [.arrivedAtDestination])
        let vm = GuidanceViewModel(session: session)

        await vm.run(route: makeRoute())

        XCTAssertEqual(vm.turn, .starting) // never received progress, but didn't fail either
    }

    func test_stop_tearsDownSession() {
        let session = ScriptedGuidanceSession(script: [])
        let vm = GuidanceViewModel(session: session)

        vm.stop()

        XCTAssertTrue(session.didStop)
    }

    @MainActor
    func test_rerouting_setsFlag_thenReroutedSwapsGeometryAndClears() async {
        let geo = [Coordinate(latitude: 40.1, longitude: -80.0),
                   Coordinate(latitude: 40.2, longitude: -80.1)]
        let session = ScriptedGuidanceSession(script: [
            .rerouting,
            .rerouted(geo),
            .progress(GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn"))
        ])
        let vm = GuidanceViewModel(session: session)
        await vm.run(route: makeRoute())
        XCTAssertEqual(vm.routeGeometry, geo)
        XCTAssertFalse(vm.isRerouting)
    }

    @MainActor
    func test_rerouting_withoutRerouted_leavesFlagSet() async {
        let session = ScriptedGuidanceSession(script: [.rerouting])
        let vm = GuidanceViewModel(session: session)
        await vm.run(route: makeRoute())
        XCTAssertTrue(vm.isRerouting)
        XCTAssertNil(vm.routeGeometry)
    }
}
