import XCTest
import SnapshotTesting
@testable import AuraCore

/// JSON snapshot of computed ride stats. Unlike a pixel screenshot, the recorded
/// reference is plain text: on a mismatch swift-snapshot-testing prints the JSON
/// diff inline in the failure, so a numeric regression is reviewable as text and
/// the reference file is diffable in code review.
///
/// Note: distance/speed come from Haversine math, so the recorded doubles are
/// deterministic on a given machine but may drift in the last digits across
/// architectures. If this ever fails on a different machine, re-record rather
/// than chase ULP differences.
final class RideStatsSnapshotTests: XCTestCase {
    private func pt(_ lat: Double, _ lon: Double, ele: Double, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                   elevation: ele,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    /// Short climb-and-descend track that exercises distance, moving time,
    /// average/max speed, and elevation-gain noise filtering together.
    private var sampleTrack: [TrackPoint] {
        [
            pt(40.4400, -80.0000, ele: 250, t: 0),
            pt(40.4410, -80.0000, ele: 255, t: 20),   // climb +5
            pt(40.4420, -80.0000, ele: 252, t: 40),   // descent, ignored for gain
            pt(40.4430, -80.0000, ele: 258, t: 60),   // climb +6
        ]
    }

    func test_rideStats_jsonSnapshot() {
        let stats = RideStatsCalculator.stats(from: sampleTrack)
        assertSnapshot(of: stats, as: .json)
    }
}
