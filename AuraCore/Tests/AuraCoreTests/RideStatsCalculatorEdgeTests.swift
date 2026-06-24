import XCTest
@testable import AuraCore

/// Edge-case tests for `RideStatsCalculator.stats(from:movingSpeedThreshold:elevationNoiseThreshold:)`.
///
/// Defaults under test: movingSpeedThreshold = 0.5 m/s, elevationNoiseThreshold = 1.0 m.
/// Both guards use `>=` (speed `>= threshold` counts as moving; elevation
/// `delta >= threshold` counts as gain).
final class RideStatsCalculatorEdgeTests: XCTestCase {

    private func pt(_ lat: Double, _ lon: Double, ele: Double?, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: ele,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    // MARK: Duplicate timestamps (dt == 0)

    func test_duplicateTimestamps_noCrashNoNaNNoInf() {
        // Two points that differ in position but share a timestamp → dt == 0.
        // The `dt > 0` guard must keep us out of the divide, so no NaN/Inf speed
        // and no contribution to moving time.
        let track = [
            pt(40.4400, -80.0000, ele: 250, t: 100),
            pt(40.4410, -80.0000, ele: 250, t: 100), // dt == 0
        ]
        let s = RideStatsCalculator.stats(from: track)

        XCTAssertFalse(s.maxSpeedMetersPerSecond.isNaN)
        XCTAssertFalse(s.maxSpeedMetersPerSecond.isInfinite)
        XCTAssertFalse(s.averageSpeedMetersPerSecond.isNaN)
        XCTAssertFalse(s.averageSpeedMetersPerSecond.isInfinite)
        // Distance still accumulates even when dt is zero.
        XCTAssertGreaterThan(s.distanceMeters, 0)
        // No positive dt → no moving time, so avg/max speed stay 0.
        XCTAssertEqual(s.movingTimeSeconds, 0)
        XCTAssertEqual(s.maxSpeedMetersPerSecond, 0)
        XCTAssertEqual(s.averageSpeedMetersPerSecond, 0)
    }

    // MARK: Out-of-order timestamps (dt < 0)

    func test_outOfOrderTimestamps_noCrashNoInflatedNegativeSpeed() {
        // Second point is earlier in time → dt < 0. The `dt > 0` guard rejects
        // the segment entirely: no negative/inflated speed, no negative moving time.
        let track = [
            pt(40.4400, -80.0000, ele: 250, t: 200),
            pt(40.4410, -80.0000, ele: 250, t: 100), // dt == -100
        ]
        let s = RideStatsCalculator.stats(from: track)

        XCTAssertFalse(s.maxSpeedMetersPerSecond.isNaN)
        XCTAssertFalse(s.maxSpeedMetersPerSecond.isInfinite)
        XCTAssertEqual(s.movingTimeSeconds, 0)
        XCTAssertEqual(s.maxSpeedMetersPerSecond, 0)
        XCTAssertEqual(s.averageSpeedMetersPerSecond, 0)
        XCTAssertGreaterThanOrEqual(s.maxSpeedMetersPerSecond, 0)
        // Distance is unsigned (haversine) so it still accumulates.
        XCTAssertGreaterThan(s.distanceMeters, 0)
    }

    // MARK: All-stopped ride

    func test_allStoppedRide_averageSpeedIsZeroNotNaN() {
        // Identical coordinates across all points → ~0 m moving, but time advances.
        // movingTime stays 0 (speed 0 < 0.5 threshold), so the avg-speed branch
        // returns 0 rather than dividing by zero.
        let track = [
            pt(40.4400, -80.0000, ele: 250, t: 0),
            pt(40.4400, -80.0000, ele: 250, t: 30),
            pt(40.4400, -80.0000, ele: 250, t: 60),
        ]
        let s = RideStatsCalculator.stats(from: track)

        XCTAssertEqual(s.distanceMeters, 0, accuracy: 1e-6)
        XCTAssertEqual(s.movingTimeSeconds, 0)
        XCTAssertEqual(s.averageSpeedMetersPerSecond, 0)
        XCTAssertFalse(s.averageSpeedMetersPerSecond.isNaN)
        XCTAssertEqual(s.maxSpeedMetersPerSecond, 0)
    }

    // MARK: Partial-nil elevation

    func test_partialNilElevation_carriesLastKnownElevationAcrossNilGap() {
        // Middle point has nil elevation. Gain is measured against the last *known*
        // elevation (carry-forward), so the climb that "straddles" the nil point is
        // bridged rather than lost: 100 → (nil) → 200 counts as +100, then 200 → 210
        // counts as +10.
        let track = [
            pt(40.4400, -80.0000, ele: 100, t: 0),
            pt(40.4410, -80.0000, ele: nil, t: 20),   // nil → carried over, last known stays 100
            pt(40.4420, -80.0000, ele: 200, t: 40),   // +100 vs last known (100) → counted
            pt(40.4430, -80.0000, ele: 210, t: 60),   // +10 vs previous (200) → counted
        ]
        let s = RideStatsCalculator.stats(from: track)

        // Carry-forward bridges the gap: 100 + 10 = 110 m total gain.
        XCTAssertEqual(s.elevationGainMeters, 110, accuracy: 1e-6)
        XCTAssertGreaterThan(s.distanceMeters, 0)
    }

    func test_leadingNilElevation_establishesBaselineFromFirstKnown() {
        // Ride starts before elevation fixes. The first known elevation sets the
        // baseline (no gain attributed for reaching it); subsequent climbs count.
        let track = [
            pt(40.4400, -80.0000, ele: nil, t: 0),
            pt(40.4410, -80.0000, ele: 100, t: 20),   // first known → baseline, no gain
            pt(40.4420, -80.0000, ele: 105, t: 40),   // +5 vs baseline → counted
        ]
        let s = RideStatsCalculator.stats(from: track)
        XCTAssertEqual(s.elevationGainMeters, 5, accuracy: 1e-6)
    }

    func test_allNilElevation_zeroGainNoCrash() {
        let track = [
            pt(40.4400, -80.0000, ele: nil, t: 0),
            pt(40.4410, -80.0000, ele: nil, t: 20),
        ]
        let s = RideStatsCalculator.stats(from: track)
        XCTAssertEqual(s.elevationGainMeters, 0)
    }

    // MARK: Moving-speed threshold boundary (~0.5 m/s)

    // NOTE on exactness: an EXACTLY-0.5 m/s segment is not reliably constructible
    // here. Two independent rounding sources defeat it: (1) the haversine in
    // `Geo.distance`, and (2) `Date`'s internal storage relative to the 2001
    // reference epoch, which means `Date(timeIntervalSince1970: dt)` does not
    // round-trip `dt` exactly (e.g. 9.98876452071135 comes back as
    // 9.988764524459839). So `distance / dt` drifts to 0.49999999981, landing
    // just under the `>=` guard. These tests therefore bracket the threshold from
    // just-above and just-below, which is what matters for the guard's behavior.

    func test_speedJustAtOrAboveMovingThreshold_countsAsMoving() {
        // ~5.01 m over an integer 10 s → ~0.5004 m/s ≥ 0.5 → moving.
        // Integer dt = 10 s survives the Date round-trip cleanly.
        let start = Coordinate(latitude: 0, longitude: 0)
        let end = Coordinate(latitude: 0, longitude: 5.01 / 111_320.0)
        let track = [
            TrackPoint(coordinate: start, elevation: nil, timestamp: Date(timeIntervalSince1970: 0)),
            TrackPoint(coordinate: end, elevation: nil, timestamp: Date(timeIntervalSince1970: 10)),
        ]
        let s = RideStatsCalculator.stats(from: track)

        // At/just-above threshold counts as moving: moving time = full 10 s.
        XCTAssertEqual(s.movingTimeSeconds, 10, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(s.maxSpeedMetersPerSecond, 0.5)
        XCTAssertEqual(s.maxSpeedMetersPerSecond, 0.5004, accuracy: 1e-3)
    }

    func test_speedJustBelowMovingThreshold_excluded() {
        // ~4.99 m over an integer 10 s → ~0.499 m/s < 0.5 → excluded.
        let start = Coordinate(latitude: 0, longitude: 0)
        let end = Coordinate(latitude: 0, longitude: 5.0 / 111_320.0)
        let track = [
            TrackPoint(coordinate: start, elevation: nil, timestamp: Date(timeIntervalSince1970: 0)),
            TrackPoint(coordinate: end, elevation: nil, timestamp: Date(timeIntervalSince1970: 10)),
        ]
        let s = RideStatsCalculator.stats(from: track)

        XCTAssertEqual(s.movingTimeSeconds, 0)
        XCTAssertEqual(s.maxSpeedMetersPerSecond, 0)
        XCTAssertEqual(s.averageSpeedMetersPerSecond, 0)
    }

    // MARK: Elevation-noise threshold boundary (exactly 1.0 m)

    func test_elevationDeltaExactlyAtNoiseThreshold_counted() {
        // delta == 1.0 m, guard is `delta >= elevationNoiseThreshold` → counted.
        let track = [
            pt(40.4400, -80.0000, ele: 100.0, t: 0),
            pt(40.4410, -80.0000, ele: 101.0, t: 20), // +1.0 exactly
        ]
        let s = RideStatsCalculator.stats(from: track)
        XCTAssertEqual(s.elevationGainMeters, 1.0, accuracy: 1e-9)
    }

    func test_elevationDeltaJustBelowNoiseThreshold_ignored() {
        // +0.9 m < 1.0 threshold → treated as GPS noise, not counted.
        let track = [
            pt(40.4400, -80.0000, ele: 100.0, t: 0),
            pt(40.4410, -80.0000, ele: 100.9, t: 20),
        ]
        let s = RideStatsCalculator.stats(from: track)
        XCTAssertEqual(s.elevationGainMeters, 0, accuracy: 1e-9)
    }
}
