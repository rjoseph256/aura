import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct GoldenRideFixtureTests {
    @Test func fixtureLoadsWithExpectedShape() throws {
        let track = try GoldenRideFixture.track()
        #expect(track.points.count == GoldenRideFixture.expectedPointCount)
        #expect(track.points.first?.elevation == 240)
        // Every point parsed (lat/lon/time all present in the authored file).
        #expect(track.points.last?.timestamp.timeIntervalSince(track.points[0].timestamp)
                == GoldenRideFixture.nominalDurationSeconds)
    }

    /// Re-record helper (the documented refresh procedure, mirroring the snapshot-test
    /// policy): run with GOLDEN_RECORD=1 and paste the printed literals into
    /// GoldenRideFixture. Skipped otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLDEN_RECORD"] != nil))
    func recordTruthLiterals() throws {
        let track = try GoldenRideFixture.track()
        let stats = RideStatsCalculator.stats(from: track.points)
        print("""
        GOLDEN_RECORD →
            expectedPointCount = \(track.points.count)
            expectedDistanceMeters = \(stats.distanceMeters)
            expectedElevationGainMeters = \(stats.elevationGainMeters)
            expectedMovingTimeSeconds = \(stats.movingTimeSeconds)
        """)
    }
}
