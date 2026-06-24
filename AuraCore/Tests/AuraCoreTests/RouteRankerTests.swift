import XCTest
@testable import AuraCore

final class RouteRankerTests: XCTestCase {
    private let origin = Coordinate(latitude: 40.44, longitude: -80.0)
    private let dest = Coordinate(latitude: 40.45, longitude: -80.01)

    private func candidate(dur: Double, ele: Double, offRoad: Double) -> CandidateRoute {
        CandidateRoute(geometry: [origin, dest], distanceMeters: 1000,
                       estimatedDurationSeconds: dur, elevationGainMeters: ele, offRoadFraction: offRoad)
    }

    func test_labelsThreeDistinctWinners() {
        let fast = candidate(dur: 200, ele: 80, offRoad: 0.1)   // fastest
        let flat = candidate(dur: 400, ele: 5,  offRoad: 0.2)   // flattest
        let paths = candidate(dur: 350, ele: 60, offRoad: 0.9)  // most paths
        let result = RouteRanker.label(origin: origin, destination: dest,
                                       candidates: [fast, flat, paths])
        let byProfile = Dictionary(uniqueKeysWithValues: result.map { ($0.profile, $0) })
        XCTAssertEqual(byProfile[.fastest]?.estimatedDurationSeconds, 200)
        XCTAssertEqual(byProfile[.flattest]?.elevationGainMeters, 5)
        XCTAssertEqual(byProfile[.mostPaths]?.geometry, [origin, dest])
        XCTAssertEqual(result.count, 3)
    }

    func test_dedupesWhenOneCandidateWinsMultipleCriteria() {
        // A single candidate that is fastest AND flattest AND most-paths → returned once.
        let allRounder = candidate(dur: 100, ele: 1, offRoad: 0.99)
        let worse = candidate(dur: 500, ele: 90, offRoad: 0.05)
        let result = RouteRanker.label(origin: origin, destination: dest,
                                       candidates: [allRounder, worse])
        XCTAssertEqual(result.count, 1)
        // Highest-priority label wins: mostPaths > flattest > fastest
        XCTAssertEqual(result.first?.profile, .mostPaths)
    }

    func test_emptyCandidates_returnsEmpty() {
        XCTAssertTrue(RouteRanker.label(origin: origin, destination: dest, candidates: []).isEmpty)
    }
}
