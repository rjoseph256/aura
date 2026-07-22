import Foundation
import AuraCore

/// The canonical golden-ride fixture (ROH-92): one bundled GPX consumed by the package
/// playback test AND the app's simulated-ride mode, so the two can't drift. The frozen
/// literals below are the ground truth both layers assert against; refresh them
/// deliberately via `GOLDEN_RECORD=1 swift test --filter recordTruthLiterals` and paste —
/// never recompute them at test time (that would let a calculator regression pass).
public enum GoldenRideFixture {
    /// 90 points, 5 s apart: a north leg then an east leg near Plum Boro (gem-free area),
    /// climbing +2 m across 30 samples (29 deltas → +58 m, each above the 1 m noise
    /// threshold), then flat, then descending. ~2.9 km at a steady ~6.5 m/s.
    public static let expectedPointCount = 90
    public static let expectedDistanceMeters = 2889.868948620863
    public static let expectedElevationGainMeters = 58.0
    public static let expectedMovingTimeSeconds = 445.0
    public static let nominalDurationSeconds = 445.0

    /// First trackpoint, frozen like the other truth literals so the navigate E2E's
    /// deep-link URL is built from the fixture instead of a drift-prone hardcoded
    /// pair. Re-record procedure: update these with the other literals.
    public static let startLatitude = 40.48
    public static let startLongitude = -79.76

    public static func track() throws -> GPXTrack {
        guard let url = Bundle.module.url(forResource: "golden-ride", withExtension: "gpx") else {
            throw FixtureError.missingResource
        }
        return try GPXParser.parse(String(contentsOf: url, encoding: .utf8))
    }

    /// The fixture as a preview-able Route (ROH-93): geometry from the track, metadata
    /// from the frozen truth literals — never recomputed at runtime, so a calculator
    /// regression cannot re-derive them into passing.
    public static func route() throws -> Route {
        let points = try track().points
        guard let first = points.first, let last = points.last else {
            throw FixtureError.missingResource
        }
        return Route(origin: first.coordinate,
                     destination: last.coordinate,
                     waypoints: [],
                     geometry: points.map(\.coordinate),
                     profile: .mostPaths,
                     distanceMeters: expectedDistanceMeters,
                     estimatedDurationSeconds: nominalDurationSeconds,
                     elevationGainMeters: expectedElevationGainMeters,
                     elevationProfile: points.compactMap(\.elevation))
    }

    @MainActor
    public static func simulatedProvider(multiplier: Double) throws -> SimulatedLocationProvider {
        SimulatedLocationProvider(track: try track(), speedMultiplier: multiplier)
    }

    public enum FixtureError: Error { case missingResource }
}
