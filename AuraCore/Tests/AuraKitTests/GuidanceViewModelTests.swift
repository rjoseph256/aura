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

    /// Yields the actor until `condition` holds, so a test can observe a view model whose
    /// `run` loop is still consuming an open stream. Condition-driven rather than a sleep,
    /// and bounded so a condition that never holds fails on the following assertion instead
    /// of hanging the suite.
    private func waitUntil(_ condition: () -> Bool, spins: Int = 1000) async {
        var remaining = spins
        while !condition() && remaining > 0 {
            await Task.yield()
            remaining -= 1
        }
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

    // Renamed + flipped from `test_rerouting_withoutRerouted_leavesFlagSet`, which pinned the
    // pre-fix behavior: a reroute that never resolves into `.rerouted` left `isRerouting` true
    // forever, because nothing but `.rerouted` ever cleared it. That is itself a stuck-pill bug
    // (ROH-221 terminal-event decision) — once the event stream is done for good, a "still
    // recalculating" pill that can never clear is wrong regardless of *why* the stream ended.
    // `run`'s `defer` now clears `isRerouting` on every path out of the loop, so an incomplete
    // reroute is honestly abandoned rather than left showing forever.
    @MainActor
    func test_rerouting_streamEndsWithoutRerouted_clearsFlag() async {
        let session = ScriptedGuidanceSession(script: [.rerouting])
        let vm = GuidanceViewModel(session: session)
        await vm.run(route: makeRoute())
        XCTAssertFalse(vm.isRerouting)
        XCTAssertNil(vm.routeGeometry)
    }

    // Production interleaving: Mapbox keeps publishing progress against the OLD route while
    // it re-fetches after going off-route. The rerouting state must survive those ticks — only
    // `.rerouted` may clear it mid-ride, never a progress tick.
    //
    // This one needs `OpenGuidanceSession`, not the scripted double. `run` clears `isRerouting`
    // on the way out (a pill nothing can ever resolve is its own lie), and a script always
    // finishes before `run` returns — so a scripted version of this test would observe the
    // *exit* clear and could never distinguish it from the progress-tick clear it exists to
    // forbid. Asserting mid-ride, with the stream still open, is the only placement that
    // actually pins the invariant.
    @MainActor
    func test_progressDuringRerouteDoesNotClearIsRerouting() async {
        let session = OpenGuidanceSession()
        let vm = GuidanceViewModel(session: session)
        let running = Task { @MainActor in await vm.run(route: makeRoute()) }

        session.emit(.progress(GuidanceUpdate(distanceToManeuverMeters: 200, instruction: "Continue")))
        session.emit(.rerouting)
        session.emit(.progress(GuidanceUpdate(distanceToManeuverMeters: 150, instruction: "Continue")))
        session.emit(.progress(GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Continue")))

        // Events are consumed in order on this actor, so the third update landing means
        // `.rerouting` and both later progress ticks have all been applied.
        await waitUntil { vm.lastUpdate?.distanceToManeuverMeters == 100 }
        XCTAssertEqual(vm.lastUpdate?.distanceToManeuverMeters, 100, "VM never consumed the scripted ticks")

        XCTAssertTrue(vm.isRerouting)

        session.finish()
        await running.value
    }

    // `.rerouted` must clear both the pill AND the stale fraction: the 0.4 in the progress
    // tick before `.rerouting` measured the OLD route's geometry, and pairing it with the NEW
    // geometry after the swap is exactly the wrong-dim the spec forbids.
    //
    // Asserted mid-stream for the flag, on the open double: after `run` returns, `defer` has
    // cleared `isRerouting` anyway, so a post-return `XCTAssertFalse` would pass whether or not
    // `applyReroute` cleared anything. Only this placement pins the clear to `.rerouted`.
    @MainActor
    func test_reroutedClearsIsReroutingAndStaleFraction() async {
        let session = OpenGuidanceSession()
        let vm = GuidanceViewModel(session: session)
        let running = Task { @MainActor in await vm.run(route: makeRoute()) }
        let geo = [Coordinate(latitude: 40.1, longitude: -80.0),
                   Coordinate(latitude: 40.2, longitude: -80.1)]

        session.emit(.progress(GuidanceUpdate(distanceToManeuverMeters: 200, instruction: "Continue",
                                              fractionTraveled: 0.4)))
        session.emit(.rerouting)
        session.emit(.rerouted(geo))

        await waitUntil { vm.routeGeometry != nil }
        XCTAssertEqual(vm.routeGeometry, geo, "VM never consumed the scripted events")

        XCTAssertFalse(vm.isRerouting)
        XCTAssertNotNil(vm.lastUpdate)
        XCTAssertNil(vm.lastUpdate?.fractionTraveled)

        session.finish()
        await running.value
    }

    // An aborted reroute — Mapbox's `Interrupted` or `Failed` — is the one way the recalculating
    // cue can dead-end. `.rerouted` is yielded only on a route-id change, which a fetch that
    // produces no route never causes, so before `.reroutingAborted` existed the flag survived
    // until the ride ended. That matters beyond the pill: the traveled-dim is gated on
    // `isRerouting`, so a stuck flag holds the route line full-bright for the rest of the ride.
    @MainActor
    func test_reroutingAbortedClearsFlagButKeepsFraction() async {
        let session = OpenGuidanceSession()
        let vm = GuidanceViewModel(session: session)
        let running = Task { @MainActor in await vm.run(route: makeRoute()) }

        session.emit(.progress(GuidanceUpdate(distanceToManeuverMeters: 200, instruction: "Continue",
                                              fractionTraveled: 0.4)))
        session.emit(.rerouting)
        session.emit(.reroutingAborted)
        // A later tick proves the loop is still live and the flag stays down.
        session.emit(.progress(GuidanceUpdate(distanceToManeuverMeters: 150, instruction: "Continue",
                                              fractionTraveled: 0.45)))

        await waitUntil { vm.lastUpdate?.distanceToManeuverMeters == 150 }
        XCTAssertEqual(vm.lastUpdate?.distanceToManeuverMeters, 150, "VM never consumed the events")

        XCTAssertFalse(vm.isRerouting)
        // The rider never left the old route, so the geometry on screen is unchanged.
        XCTAssertNil(vm.routeGeometry)
        // Progress keeps landing normally after the abort. This does NOT pin the "abort must
        // not nil the fraction" rule — the tick above would refill it either way; the sibling
        // `preservesTheFractionItInherits` (no later tick) is what catches that over-reach.
        XCTAssertEqual(vm.lastUpdate?.fractionTraveled, 0.45)

        session.finish()
        await running.value
    }

    // The abort must not discard the fraction it inherits, either — pinned with no later tick,
    // so nothing can refill `lastUpdate` between the abort and the assertion.
    //
    // Emitted in two stages, waiting for each to land. A single batch would not work: the run
    // loop consumes roughly one event per yield, so a condition like "lastUpdate is set and the
    // flag is down" is momentarily true after the FIRST event, before `.rerouting` is even seen,
    // and the wait would exit against a half-applied script. Staging makes each wait uniquely
    // satisfiable by the event it is waiting on.
    @MainActor
    func test_reroutingAborted_preservesTheFractionItInherits() async {
        let session = OpenGuidanceSession()
        let vm = GuidanceViewModel(session: session)
        let running = Task { @MainActor in await vm.run(route: makeRoute()) }

        session.emit(.progress(GuidanceUpdate(distanceToManeuverMeters: 200, instruction: "Continue",
                                              fractionTraveled: 0.4)))
        session.emit(.rerouting)
        await waitUntil { vm.isRerouting }
        XCTAssertTrue(vm.isRerouting, "VM never consumed .rerouting")

        session.emit(.reroutingAborted)
        await waitUntil { !vm.isRerouting }
        XCTAssertFalse(vm.isRerouting, "VM never consumed the abort")

        XCTAssertEqual(vm.lastUpdate?.fractionTraveled, 0.4)

        session.finish()
        await running.value
    }

    // Once fresh progress arrives against the new geometry, the fraction comes back.
    @MainActor
    func test_nextProgressAfterRerouteRestoresFraction() async {
        let a = GuidanceUpdate(distanceToManeuverMeters: 200, instruction: "Continue",
                               fractionTraveled: 0.4)
        let d = GuidanceUpdate(distanceToManeuverMeters: 300, instruction: "Continue",
                               fractionTraveled: 0.05)
        let geo = [Coordinate(latitude: 40.1, longitude: -80.0),
                   Coordinate(latitude: 40.2, longitude: -80.1)]
        let session = ScriptedGuidanceSession(script: [
            .progress(a), .rerouting, .rerouted(geo), .progress(d)
        ])
        let vm = GuidanceViewModel(session: session)
        await vm.run(route: makeRoute())
        XCTAssertEqual(vm.lastUpdate?.fractionTraveled, 0.05)
    }

    @MainActor
    func test_units_propagateToTurnCard() async {
        let session = ScriptedGuidanceSession(script: [
            .progress(.init(distanceToManeuverMeters: 120, instruction: "Right onto Penn Ave"))
        ])
        let vm = GuidanceViewModel(session: session)
        vm.units = .metric

        await vm.run(route: makeRoute())

        XCTAssertEqual(vm.turn.distanceText, "120 m")
        XCTAssertEqual(vm.turn.accessibilityLabel, "In 120 meters, Right onto Penn Ave")
    }

    // Slice 2: the structured maneuver rides the existing .progress event through the
    // scripted session and lands on the turn card — the wire the directional arrow needs.
    func test_progressManeuver_reachesTurnCard() async {
        let update = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right",
                                    maneuver: Maneuver(kind: .turn, modifier: .right))
        let vm = GuidanceViewModel(session: ScriptedGuidanceSession(script: [.progress(update)]))
        await vm.run(route: makeRoute())
        XCTAssertEqual(vm.turn.maneuver?.modifier, .right)
    }

    // The other way out of `run`'s loop: `.arrivedAtDestination` returns early. A rider who
    // goes off-route and then rolls into the destination before the re-fetch resolves must not
    // be left with "Recalculating…" over a finished ride.
    @MainActor
    func test_rerouting_thenArrival_clearsFlag() async {
        let session = ScriptedGuidanceSession(script: [.rerouting, .arrivedAtDestination])
        let vm = GuidanceViewModel(session: session)
        var arrived = false
        vm.onArrive = { arrived = true }
        await vm.run(route: makeRoute())
        XCTAssertTrue(arrived)
        XCTAssertFalse(vm.isRerouting)
    }
}

/// A guidance double whose stream stays **open** until the test finishes it, so state can be
/// observed mid-ride. `ScriptedGuidanceSession` cannot do this: it yields its whole script and
/// finishes, so `run` has always returned — and run's exit clears `isRerouting` — by the time a
/// test gets to look. Buffering is unbounded and the continuation exists from `init`, so events
/// emitted before `run` starts consuming are still delivered in order.
@MainActor
private final class OpenGuidanceSession: GuidanceSession {
    private let stream: AsyncStream<GuidanceEvent>
    private let continuation: AsyncStream<GuidanceEvent>.Continuation
    private(set) var didStop = false

    init() {
        let made = AsyncStream<GuidanceEvent>.makeStream()
        stream = made.stream
        continuation = made.continuation
    }

    func start(route: Route) async -> AsyncStream<GuidanceEvent> { stream }
    func emit(_ event: GuidanceEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func stop() {
        didStop = true
        continuation.finish()
    }
}
