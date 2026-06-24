import XCTest
import AuraCore
@testable import AuraKit

final class SimulatedLocationProviderTests: XCTestCase {
    private func pt(_ lat: Double, t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -80.0), elevation: 250,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func test_emitsAllPointsInOrder() async {
        let track = GPXTrack(points: [pt(40.40, t: 0), pt(40.41, t: 10), pt(40.42, t: 20)])
        // Large multiplier => offsets≈0 => negligible sleeps, fast & deterministic content.
        let provider = SimulatedLocationProvider(track: track, speedMultiplier: 100_000)
        var collected: [TrackPoint] = []
        for await p in provider.points() { collected.append(p) }
        XCTAssertEqual(collected, track.points)
    }

    func test_emptyTrack_finishesWithNoPoints() async {
        let provider = SimulatedLocationProvider(track: GPXTrack(points: []))
        var count = 0
        for await _ in provider.points() { count += 1 }
        XCTAssertEqual(count, 0)
    }
}
