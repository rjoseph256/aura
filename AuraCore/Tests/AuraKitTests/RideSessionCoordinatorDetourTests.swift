import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite struct RideSessionCoordinatorDetourTests {
    final class SpyGuidance: GuidanceControlling {
        var detourFlag = false
        private(set) var detachCount = 0
        private(set) var updates = 0
        var isDetouring: Bool { detourFlag }
        var isGuiding: Bool { detourFlag }
        func riderDidUpdate(_ point: TrackPoint) { updates += 1 }
        func detach() { detachCount += 1 }
    }

    @Test func finishDetachesGuidance() throws {
        let spy = SpyGuidance()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       guidance: spy)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.finish()
        #expect(spy.detachCount == 1)
    }

    @Test func cancelDetachesGuidance() throws {
        let spy = SpyGuidance()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       guidance: spy)
        c.start(location: ScriptedLocationProvider([]), saving: try RideStore.inMemory(),
                units: .metric, authorization: .authorized)
        c.cancel()
        #expect(spy.detachCount == 1)
    }

    @Test func isDetouringReflectsController() {
        let spy = SpyGuidance()
        let c = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                       screen: SpyScreenWake(), activity: SpyRideActivity(),
                                       guidance: spy)
        #expect(c.isDetouring == false)
        spy.detourFlag = true
        #expect(c.isDetouring == true)
    }

    @Test func forwardsEachLocationFixToGuidance() async throws {
        let point = TrackPoint(coordinate: Coordinate(latitude: 40.44, longitude: -80.0),
                               elevation: nil, timestamp: Date())
        let location = ScriptedLocationProvider([point])
        let saving = try RideStore.inMemory()
        let spy = SpyGuidance()
        let coordinator = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                                 screen: SpyScreenWake(), activity: SpyRideActivity(),
                                                 guidance: spy)
        coordinator.start(location: location, saving: saving, units: .metric,
                          authorization: .authorized)
        await coordinator.streamTask?.value
        #expect(spy.updates > 0)
    }
}
