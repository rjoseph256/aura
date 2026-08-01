import Testing
import Foundation
import AuraCore
@testable import AuraKit

@MainActor
@Suite(.swiftDataSerialized) struct RideSessionCoordinatorDiscoveryTests {
    final class SpySink: RideDiscoverySink {
        var coordinates: [Coordinate] = []
        func rideDidUpdateLocation(_ point: TrackPoint) { coordinates.append(point.coordinate) }
    }

    @Test func forwardsEachLocationFixToTheDiscoverySink() async throws {
        let point = TrackPoint(coordinate: Coordinate(latitude: 40.44, longitude: -80.0),
                               elevation: nil, timestamp: Date())
        let location = ScriptedLocationProvider([point])
        let saving = try RideStore.inMemory()
        let coordinator = RideSessionCoordinator(kind: .freeRide, destinationName: nil,
                                                 screen: SpyScreenWake(), activity: SpyRideActivity(),
                                                 haptics: HapticSpy(), nudges: NudgeSpy(),
                                                 clock: FakeRideClock())
        let sink = SpySink()
        coordinator.start(location: location, saving: saving, units: .metric,
                          authorization: .authorized, discoverySink: sink)
        await coordinator.streamTask?.value
        #expect(sink.coordinates == [point.coordinate])
    }
}
