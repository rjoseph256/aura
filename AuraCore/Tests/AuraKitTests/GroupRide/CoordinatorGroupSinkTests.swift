import Testing
import Foundation
@testable import AuraKit
import AuraCore

@MainActor
final class SpyGroupSink: GroupLocationSink {
    var updates: [(Coordinate, Double, Double, Date)] = []
    func locationDidUpdate(coordinate: Coordinate, progressMeters: Double, speed: Double, at: Date) {
        updates.append((coordinate, progressMeters, speed, at))
    }
}

@MainActor
struct CoordinatorGroupSinkTests {
    @Test func coordinatorForwardsRecordedPointsToTheGroupSink() async throws {
        let sink = SpyGroupSink()
        let coordinator = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: SpyScreenWake(), activity: SpyRideActivity())
        let location = ScriptedLocationProvider([
            TrackPoint(coordinate: Coordinate(latitude: 1, longitude: 2),
                       elevation: nil, timestamp: Date(timeIntervalSince1970: 1),
                       speedMetersPerSecond: 5)
        ])
        coordinator.start(location: location, saving: try RideStore.inMemory(), units: .metric,
                          authorization: .authorized, groupSink: sink)
        await coordinator.streamTask?.value
        #expect(sink.updates.count == 1)
        #expect(sink.updates.first?.0 == Coordinate(latitude: 1, longitude: 2))
    }
}
