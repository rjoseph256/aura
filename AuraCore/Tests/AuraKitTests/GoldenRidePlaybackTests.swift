import Testing
import Foundation
import AuraCore
@testable import AuraKit

/// Layer 1 of the ROH-92 golden-ride harness: the real GPX → GPXLocationPlayer →
/// SimulatedLocationProvider chain drives the real coordinator into an in-memory store.
/// The numeric duty for the stats math itself stays with RideStatsCalculatorTests /
/// RideStatsSnapshotTests; the frozen literals here catch assembled-chain breaks and
/// fixture drift (e.g. a fixture that silently loses <ele> and records flat).
@MainActor
@Suite(.swiftDataSerialized)
struct GoldenRidePlaybackTests {
    /// Tolerance for cross-architecture Double drift (snapshot-test precedent), far below
    /// any real regression (flat = -58 m of gain, dropped points = tens of meters).
    private func close(_ a: Double, _ b: Double, within tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func goldenRidePlaysThroughCoordinatorAndPersists() async throws {
        let provider = try GoldenRideFixture.simulatedProvider(multiplier: 10_000)
        let store = try RideStore.inMemory()
        let coordinator = RideSessionCoordinator(
            kind: .freeRide, destinationName: nil,
            screen: SpyScreenWake(), activity: SpyRideActivity())
        let outcome = coordinator.start(location: provider, saving: store,
                                        units: .metric, authorization: .authorized)
        #expect(outcome == .started)

        await coordinator.streamTask?.value   // deterministic drain — never sleep
        coordinator.finish()

        let ride = try #require(coordinator.finishedRide)
        #expect(coordinator.saveFailed == false)
        let stats = try #require(ride.stats)
        #expect(ride.track.count == GoldenRideFixture.expectedPointCount)
        #expect(close(stats.distanceMeters, GoldenRideFixture.expectedDistanceMeters))
        #expect(close(stats.elevationGainMeters, GoldenRideFixture.expectedElevationGainMeters))
        #expect(stats.elevationGainMeters > 0)   // hard floor: silent-flat must fail
        #expect(close(stats.movingTimeSeconds, GoldenRideFixture.expectedMovingTimeSeconds))

        // Persisted round-trip: denormalized columns + thumbnail via summaries().
        let summaries = try store.summaries()
        let summary = try #require(summaries.first { $0.id == ride.id })
        #expect(close(summary.distanceMeters, stats.distanceMeters))
        #expect(close(summary.elevationGainMeters, stats.elevationGainMeters))
        #expect(!summary.thumbnailCoordinates.isEmpty)
    }
}
