import Testing
import Foundation
import AuraCore
@testable import AuraKit

struct PausedGoldenRideFixtureTests {
    private func close(_ a: Double, _ b: Double, within tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func fixtureLoadsAsTwoSegments() throws {
        let track = try PausedGoldenRideFixture.track()
        #expect(track.segments.count == PausedGoldenRideFixture.expectedSegmentCount)
        #expect(track.segments.map(\.points.count) == PausedGoldenRideFixture.expectedSegmentPointCounts)
        #expect(track.points.count == PausedGoldenRideFixture.expectedPointCount)
        #expect(track.segments[0].points.first?.elevation == 240)
        #expect(track.segments[1].points.first?.elevation == 340)
    }

    @Test func pauseGapIsRealInSpaceAndTime() throws {
        let track = try PausedGoldenRideFixture.track()
        let lastOfFirst = try #require(track.segments[0].points.last)
        let firstOfSecond = try #require(track.segments[1].points.first)
        #expect(firstOfSecond.timestamp.timeIntervalSince(lastOfFirst.timestamp) == 600)
        #expect(Geo.distance(lastOfFirst.coordinate, firstOfSecond.coordinate) > 400)
    }

    @Test func segmentedStatsMatchTheFrozenLiterals() throws {
        let stats = RideStatsCalculator.stats(segments: try PausedGoldenRideFixture.track().segments)
        #expect(close(stats.distanceMeters, PausedGoldenRideFixture.expectedDistanceMeters))
        #expect(close(stats.elevationGainMeters, PausedGoldenRideFixture.expectedElevationGainMeters))
        #expect(close(stats.movingTimeSeconds, PausedGoldenRideFixture.expectedMovingTimeSeconds))
        #expect(stats.elevationGainMeters > 0)   // hard floor: silent-flat must fail
    }

    /// The regression the whole pass exists to prevent: flattening the segments inflates
    /// every headline number. Frozen on both sides so a drift in either is a hard failure.
    @Test func flatteningInflatesEveryNumber() throws {
        let track = try PausedGoldenRideFixture.track()
        let flat = RideStatsCalculator.stats(from: track.points)
        #expect(close(flat.distanceMeters, PausedGoldenRideFixture.flattenedDistanceMeters))
        #expect(close(flat.elevationGainMeters, PausedGoldenRideFixture.flattenedElevationGainMeters))
        #expect(close(flat.movingTimeSeconds, PausedGoldenRideFixture.flattenedMovingTimeSeconds))

        let segmented = RideStatsCalculator.stats(segments: track.segments)
        #expect(flat.distanceMeters > segmented.distanceMeters + 400)
        #expect(flat.movingTimeSeconds > segmented.movingTimeSeconds + 500)
        #expect(flat.elevationGainMeters > segmented.elevationGainMeters + 40)
    }

    /// The read surfaces migrated in this pass, exercised against a real two-segment ride.
    @Test func rideReadSurfacesStaySegmented() throws {
        let ride = try PausedGoldenRideFixture.ride()
        #expect(ride.segments.count == 2)
        #expect(ride.flattenedPoints.count == PausedGoldenRideFixture.expectedPointCount)

        // Share card: two runs, never one.
        #expect(ShareCardContent(ride: ride, units: .metric).routeSegments.count == 2)

        // Live/summary ribbon: no piece spans the gap.
        #expect(TrackRibbon.pieces(segments: ride.segments).count == 2)

        // HealthKit route flattens deliberately (spec: pause events out of scope).
        #expect(WorkoutData(from: ride).route.count == PausedGoldenRideFixture.expectedPointCount)
    }

    /// Three literals describe the same track and must agree. Nothing checked that they did.
    @Test func segmentDistancesSumToTheRideDistance() throws {
        let perSegment = PausedGoldenRideFixture.expectedSegmentDistanceMeters
        #expect(perSegment.count == PausedGoldenRideFixture.expectedSegmentCount)
        #expect(close(perSegment.reduce(0, +), PausedGoldenRideFixture.expectedDistanceMeters))

        // And they are the frozen truth, not a recomputation: each matches the fixture.
        let segments = try PausedGoldenRideFixture.track().segments
        for (index, segment) in segments.enumerated() {
            #expect(close(RideStatsCalculator.stats(segments: [segment]).distanceMeters,
                          perSegment[index]))
        }
    }

    /// Re-record helper, mirroring `GoldenRideFixtureTests.recordTruthLiterals`. Run with
    /// GOLDEN_RECORD=1 and paste the printed literals. Skipped otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GOLDEN_RECORD"] != nil))
    func recordPausedTruthLiterals() throws {
        let track = try PausedGoldenRideFixture.track()
        let segmented = RideStatsCalculator.stats(segments: track.segments)
        let flat = RideStatsCalculator.stats(from: track.points)
        let perSegment = track.segments.map {
            RideStatsCalculator.stats(segments: [$0]).distanceMeters
        }
        print("""
        GOLDEN_RECORD (paused) →
            expectedSegmentCount = \(track.segments.count)
            expectedSegmentPointCounts = \(track.segments.map(\.points.count))
            expectedSegmentDistanceMeters = \(perSegment)
            expectedPointCount = \(track.points.count)
            expectedDistanceMeters = \(segmented.distanceMeters)
            expectedElevationGainMeters = \(segmented.elevationGainMeters)
            expectedMovingTimeSeconds = \(segmented.movingTimeSeconds)
            flattenedDistanceMeters = \(flat.distanceMeters)
            flattenedElevationGainMeters = \(flat.elevationGainMeters)
            flattenedMovingTimeSeconds = \(flat.movingTimeSeconds)
        """)
    }
}
