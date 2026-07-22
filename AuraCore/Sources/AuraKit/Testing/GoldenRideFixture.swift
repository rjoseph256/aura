import Foundation
import AuraCore

/// The canonical golden-ride fixture (ROH-92): one bundled GPX consumed by the package
/// playback test AND the app's simulated-ride mode, so the two can't drift. The frozen
/// literals below are the ground truth both layers assert against; refresh them
/// deliberately via `GOLDEN_RECORD=1 swift test --filter recordTruthLiterals` and paste —
/// never recompute them at test time (that would let a calculator regression pass).
public enum GoldenRideFixture {
    /// 90 points, 5 s apart: a north leg then an east leg near Plum Boro (gem-free area),
    /// climbing +2 m/sample for 30 samples (all above the 1 m noise threshold), then flat,
    /// then descending. ~2.9 km at a steady ~6.5 m/s.
    public static let expectedPointCount = 90
    public static let expectedDistanceMeters = 2889.868948620863
    public static let expectedElevationGainMeters = 58.0
    public static let expectedMovingTimeSeconds = 445.0
    public static let nominalDurationSeconds = 445.0

    public static func track() throws -> GPXTrack {
        guard let url = Bundle.module.url(forResource: "golden-ride", withExtension: "gpx") else {
            throw FixtureError.missingResource
        }
        return try GPXParser.parse(String(contentsOf: url, encoding: .utf8))
    }

    @MainActor
    public static func simulatedProvider(multiplier: Double) throws -> SimulatedLocationProvider {
        SimulatedLocationProvider(track: try track(), speedMultiplier: multiplier)
    }

    public enum FixtureError: Error { case missingResource }
}
