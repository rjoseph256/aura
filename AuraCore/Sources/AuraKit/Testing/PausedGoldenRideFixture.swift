import Foundation
import AuraCore

/// The paused counterpart to `GoldenRideFixture` (ROH-98): the same authored-GPX approach,
/// but two `<trkseg>`s separated by a 600 s stop during which the rider moved ~507 m east
/// and ~42 m up on foot.
///
/// It is a *second* fixture rather than a re-recording of the first on purpose. Leaving
/// `golden-ride.gpx`'s literals byte-identical is what proves segmentation changed nothing
/// for an unpaused ride; re-recording it would have destroyed that evidence and forced a
/// coupled edit across `GoldenRideFixture`, `GoldenRidePlaybackTests` and the non-derived
/// hero bands in `RideE2EUITests`.
///
/// Both the segmented and the flattened literals are frozen. The flattened ones are the
/// *wrong* answer, kept so a regression that silently flattens is caught by an equality
/// failure rather than by a fuzzy inequality. Refresh via
/// `GOLDEN_RECORD=1 swift test --filter recordPausedTruthLiterals` and paste — never
/// recompute at test time.
///
/// Note this fixture cannot contain an EMPTY segment: `GPXParser` drops `<trkseg>`s with no
/// usable points. The empty-segment cases spec D6 makes legal are covered directly in
/// `RideStatsSegmentTests` and `TrackRibbonTests`, and Pass 2 owns producing them live.
public enum PausedGoldenRideFixture {
    public static let expectedSegmentCount = 2
    public static let expectedSegmentPointCounts = [30, 30]
    public static let expectedPointCount = 60

    /// Segment-aware truth: the pause contributes no distance, no moving time, no climb.
    public static let expectedDistanceMeters = 1883.3458682058288
    public static let expectedElevationGainMeters = 58.0
    public static let expectedMovingTimeSeconds = 290.0

    /// What the same points produce if a consumer flattens them — the bug this pass exists
    /// to make unrepresentable.
    public static let flattenedDistanceMeters = 2390.752780489432
    public static let flattenedElevationGainMeters = 100.0
    public static let flattenedMovingTimeSeconds = 890.0

    public static func track() throws -> GPXTrack {
        guard let url = Bundle.module.url(forResource: "golden-ride-paused",
                                          withExtension: "gpx") else {
            throw GoldenRideFixture.FixtureError.missingResource
        }
        return try GPXParser.parse(String(contentsOf: url, encoding: .utf8))
    }

    /// The fixture as a finished two-segment `Ride`, for the surfaces that take a ride.
    public static func ride() throws -> Ride {
        let segments = try track().segments
        let points = segments.flatMap(\.points)
        return Ride(kind: .freeRide,
                    startedAt: points.first?.timestamp ?? Date(timeIntervalSince1970: 0),
                    endedAt: points.last?.timestamp,
                    segments: segments,
                    stats: RideStatsCalculator.stats(segments: segments),
                    routeId: nil, destinationPlaceId: nil)
    }
}
