import XCTest
@testable import AuraCore

/// Segment-aware stats. The contract is that nothing is ever measured *between* two
/// segments: the pause gap contributes no distance, no moving time, no elevation gain and
/// cannot set max speed.
final class RideStatsSegmentTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double, ele: Double?, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: ele, timestamp: Date(timeIntervalSince1970: t))
    }

    /// Two short northward runs, separated by a big jump in space and time. `first` and
    /// `second` cover the same Δlat (and so the same distance, since Δlon = 0 makes
    /// `Geo.distance` exact and latitude-independent) but different durations — 20 s vs 60 s —
    /// so their per-segment speeds genuinely differ (~5.56 m/s vs ~1.85 m/s). That separation
    /// is what lets the average/max-speed tests below distinguish a correct total-over-total
    /// (or max-over-segments) implementation from a wrong average-of-averages (or
    /// order-dependent max) one. Equal durations would make the two algebraically
    /// indistinguishable — see the comment on the average-speed test.
    private var first: [TrackPoint] {
        [pt(40.4400, -80.0, ele: 250, t: 0), pt(40.4410, -80.0, ele: 256, t: 20)]
    }
    private var second: [TrackPoint] {
        [pt(40.5400, -80.0, ele: 400, t: 900), pt(40.5410, -80.0, ele: 406, t: 960)]
    }

    func test_singleSegment_matchesFlatEntryPointExactly() {
        // This only exercises `Accumulator().merge(x)` vs `x` — it cannot detect drift from
        // the pre-refactor arithmetic itself, since both sides route through the same private
        // `walk`. The actual pre-refactor-drift guard is the frozen full-precision reference
        // in RideStatsSnapshotTests; keep this one for the merge/wrap behavior it does cover.
        let flat = RideStatsCalculator.stats(from: first)
        let segmented = RideStatsCalculator.stats(segments: [RideSegment(points: first)])
        XCTAssertEqual(segmented, flat)   // exact, not approximate: unpaused rides must not move
    }

    func test_distanceAndMovingTime_sumAcrossSegments_excludingTheGap() {
        let a = RideStatsCalculator.stats(from: first)
        let b = RideStatsCalculator.stats(from: second)
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        XCTAssertEqual(combined.distanceMeters, a.distanceMeters + b.distanceMeters, accuracy: 1e-9)
        XCTAssertEqual(combined.movingTimeSeconds, a.movingTimeSeconds + b.movingTimeSeconds,
                       accuracy: 1e-9)
        // The gap is ~11 km and 880 s. Flattening would swamp both numbers.
        let flattened = RideStatsCalculator.stats(from: first + second)
        XCTAssertLessThan(combined.distanceMeters, flattened.distanceMeters - 1000)
        XCTAssertLessThan(combined.movingTimeSeconds, flattened.movingTimeSeconds - 500)
    }

    func test_maxSpeed_isTheMaxOverSegments_neverTheGap() {
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        // Hand-computed, not max(a.maxSpeed, b.maxSpeed): Geo.distance is exact and
        // latitude-independent when Δlon == 0 (h reduces to sin(dLat/2)^2), so both legs
        // cover R * (0.001° in radians) = 111.19492664455875 m. `first` covers it in 20 s
        // (~5.5597463 m/s), `second` in 60 s (~1.8532488 m/s) — `first` is the faster one.
        let legMeters = 6_371_000.0 * (0.001 * Double.pi / 180)
        let firstSpeed = legMeters / 20.0
        XCTAssertEqual(combined.maxSpeedMetersPerSecond, firstSpeed, accuracy: 1e-6)
    }

    func test_averageSpeed_isTotalDistanceOverTotalMovingTime_notAnAverageOfAverages() {
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        // Hand-computed expected value, asserted independently of the struct's own
        // distance/movingTime fields (a self-referential comparison against those would only
        // pin internal consistency, never the actual number). Total distance is 2 * 111.19...
        // m over a total moving time of 80 s: 222.38985328911750 / 80 = 2.7798731661139686 m/s.
        // A wrong average-of-averages implementation — mean((111.19.../20), (111.19.../60)) —
        // would instead return ~3.706497554818625 m/s, about 33% higher; this test fails loudly
        // against that bug because the two segments deliberately have unequal durations.
        XCTAssertEqual(combined.averageSpeedMetersPerSecond, 2.7798731661139686, accuracy: 1e-6)
    }

    func test_elevationBaseline_resetsAtSegmentBoundary() {
        // Segment 1 climbs +6, segment 2 climbs +6. The +144 step *between* them is not a
        // climb the rider rode, so it must not appear in gain.
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        XCTAssertEqual(combined.elevationGainMeters, 12, accuracy: 1e-9)
    }

    func test_elevationBaseline_stillBridgesNilWithinASegment() {
        let bridged = [pt(40.44, -80.0, ele: 250, t: 0),
                       pt(40.441, -80.0, ele: nil, t: 20),
                       pt(40.442, -80.0, ele: 256, t: 40)]
        let stats = RideStatsCalculator.stats(segments: [RideSegment(points: bridged)])
        XCTAssertEqual(stats.elevationGainMeters, 6, accuracy: 1e-9)
    }

    // MARK: Degenerate segments — reachable once pause exists (spec D6)

    func test_emptySegments_contributeNothingAndDoNotCrash() {
        let stats = RideStatsCalculator.stats(segments: [RideSegment(points: []),
                                                         RideSegment(points: first),
                                                         RideSegment(points: [])])
        XCTAssertEqual(stats, RideStatsCalculator.stats(from: first))
    }

    func test_singlePointSegments_contributeNothing() {
        let stats = RideStatsCalculator.stats(segments: [RideSegment(points: [first[0]]),
                                                         RideSegment(points: first)])
        XCTAssertEqual(stats, RideStatsCalculator.stats(from: first))
    }

    func test_noSegments_isZero() {
        XCTAssertEqual(RideStatsCalculator.stats(segments: []), .zero)
    }

    func test_onlyEmptySegments_isZero() {
        XCTAssertEqual(RideStatsCalculator.stats(segments: [RideSegment(points: []),
                                                            RideSegment(points: [])]), .zero)
    }
}
