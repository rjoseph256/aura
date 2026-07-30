import Testing
import Foundation
@testable import AuraKit
import AuraCore

@MainActor
final class SpyGroupSink: GroupLocationSink {
    struct Update: Equatable {
        let coordinate: Coordinate
        /// nil while the rider is paused: no progress is published (spec D7).
        let progressMeters: Double?
        let speed: Double
        let at: Date
    }
    var updates: [Update] = []
    func locationDidUpdate(coordinate: Coordinate, progressMeters: Double?, speed: Double, at: Date) {
        updates.append(Update(coordinate: coordinate, progressMeters: progressMeters, speed: speed, at: at))
    }
}

@MainActor
@Suite(.swiftDataSerialized)
struct CoordinatorGroupSinkTests {
    @Test func coordinatorForwardsRecordedPointsToTheGroupSink() async throws {
        let sink = SpyGroupSink()
        let coordinator = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: SpyScreenWake(), activity: SpyRideActivity(), haptics: HapticSpy(), nudges: NudgeSpy())
        let location = ScriptedLocationProvider([
            TrackPoint(coordinate: Coordinate(latitude: 1, longitude: 2),
                       elevation: nil, timestamp: Date(timeIntervalSince1970: 1),
                       speedMetersPerSecond: 5)
        ])
        coordinator.start(location: location, saving: try RideStore.inMemory(), units: .metric,
                          authorization: .authorized, groupSink: sink)
        await coordinator.streamTask?.value
        #expect(sink.updates.count == 1)
        #expect(sink.updates.first?.coordinate == Coordinate(latitude: 1, longitude: 2))
    }
}
