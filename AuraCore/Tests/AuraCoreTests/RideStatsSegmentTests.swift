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

    /// Two short northward runs, separated by a big jump in space and time.
    private var first: [TrackPoint] {
        [pt(40.4400, -80.0, ele: 250, t: 0), pt(40.4410, -80.0, ele: 256, t: 20)]
    }
    private var second: [TrackPoint] {
        [pt(40.5400, -80.0, ele: 400, t: 900), pt(40.5410, -80.0, ele: 406, t: 920)]
    }

    func test_singleSegment_matchesFlatEntryPointExactly() {
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
        let a = RideStatsCalculator.stats(from: first)
        let b = RideStatsCalculator.stats(from: second)
        XCTAssertEqual(combined.maxSpeedMetersPerSecond,
                       max(a.maxSpeedMetersPerSecond, b.maxSpeedMetersPerSecond), accuracy: 1e-9)
    }

    func test_averageSpeed_isTotalDistanceOverTotalMovingTime_notAnAverageOfAverages() {
        let combined = RideStatsCalculator.stats(segments: [RideSegment(points: first),
                                                            RideSegment(points: second)])
        XCTAssertEqual(combined.averageSpeedMetersPerSecond,
                       combined.distanceMeters / combined.movingTimeSeconds, accuracy: 1e-9)
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
