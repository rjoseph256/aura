import Testing
@testable import AuraCore

@Suite struct DetourMachineTests {
    private func gem(_ id: String) -> Gem {
        Gem(id: id, name: id, coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
            category: .park, tier: .card, source: .curated)
    }

    @Test func requestFromInactiveStartsRouting() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.inactive, on: .request(g))
        #expect(phase == .routing(g))
        #expect(fx == [.startRouting(g)])
    }

    @Test func routeReadyStartsGuiding() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.routing(g), on: .routeReady)
        #expect(phase == .guiding(g))
        #expect(fx == [.startGuidance(g)])
    }

    @Test func routeFailedOfflineFallsBackToHeading() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.routing(g), on: .routeFailedOffline)
        #expect(phase == .headingOnly(g))
        #expect(fx == [.startHeadingOnly(g)])
    }

    @Test func arrivalWhileGuidingDetachesAndConfirms() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.guiding(g), on: .arrived)
        #expect(phase == .inactive)
        #expect(fx == [.stopGuidance, .confirmArrival(g), .detached])
    }

    @Test func arrivalWhileHeadingOnlyDetachesAndConfirms() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.headingOnly(g), on: .arrived)
        #expect(phase == .inactive)
        #expect(fx == [.stopHeading, .confirmArrival(g), .detached])
    }

    @Test func networkRecoveredUpgradesToRouting() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.headingOnly(g), on: .networkRecovered)
        #expect(phase == .routing(g))
        #expect(fx == [.stopHeading, .startRouting(g)])
    }

    @Test func retargetFromGuidingRoutesToNewGem() {
        let g1 = gem("a"); let g2 = gem("b")
        let (phase, fx) = DetourMachine.reduce(.guiding(g1), on: .retarget(g2))
        #expect(phase == .routing(g2))
        #expect(fx == [.stopGuidance, .stopHeading, .startRouting(g2)])
    }

    @Test func cancelFromEveryPhaseDetaches() {
        let g = gem("a")
        for phase in [DetourPhase.inactive, .routing(g), .guiding(g), .headingOnly(g)] {
            let (next, fx) = DetourMachine.reduce(phase, on: .cancel)
            #expect(next == .inactive)
            #expect(fx == [.stopGuidance, .stopHeading, .detached])
        }
    }

    @Test func staleRouteReadyFromInactiveIsNoOp() {
        // Reachable only via a late route completion after cancel (R2). Must not start guiding.
        let (phase, fx) = DetourMachine.reduce(.inactive, on: .routeReady)
        #expect(phase == .inactive)
        #expect(fx.isEmpty)
    }

    @Test func retargetWhileInactiveIsNoOp() {
        let (phase, fx) = DetourMachine.reduce(.inactive, on: .retarget(gem("b")))
        #expect(phase == .inactive)
        #expect(fx.isEmpty)
    }

    @Test func arrivedWhileRoutingIsNoOp() {
        let g = gem("a")
        let (phase, fx) = DetourMachine.reduce(.routing(g), on: .arrived)
        #expect(phase == .routing(g))
        #expect(fx.isEmpty)
    }
}
