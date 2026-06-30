import XCTest
@testable import AuraCore

final class RouteRankerTests: XCTestCase {
    private let origin = Coordinate(latitude: 40.44, longitude: -80.0)
    private let dest = Coordinate(latitude: 40.45, longitude: -80.01)

    private func candidate(dur: Double, ele: Double, walk: Double) -> CandidateRoute {
        CandidateRoute(geometry: [origin, dest], distanceMeters: 1000,
                       estimatedDurationSeconds: dur, elevationGainMeters: ele, walkFraction: walk)
    }

    func test_labelsThreeDistinctWinners() {
        let fast = candidate(dur: 200, ele: 80, walk: 0.5)   // fastest (lowest dur)
        let flat = candidate(dur: 400, ele: 5, walk: 0.4)   // flattest (lowest ele)
        let paths = candidate(dur: 350, ele: 60, walk: 0.1)  // most paths (least walking)
        let result = RouteRanker.label(origin: origin, destination: dest,
                                       candidates: [fast, flat, paths])
        let byProfile = Dictionary(uniqueKeysWithValues: result.map { ($0.profile, $0) })
        XCTAssertEqual(byProfile[.fastest]?.estimatedDurationSeconds, 200)
        XCTAssertEqual(byProfile[.flattest]?.elevationGainMeters, 5)
        // The least-walking candidate (dur 350) wins "Most paths".
        XCTAssertEqual(byProfile[.mostPaths]?.estimatedDurationSeconds, 350)
        XCTAssertEqual(result.count, 3)
    }

    func test_dedupesWhenOneCandidateWinsMultipleCriteria() {
        // A single candidate that is fastest AND flattest AND most-paths → returned once.
        let allRounder = candidate(dur: 100, ele: 1, walk: 0.0)
        let worse = candidate(dur: 500, ele: 90, walk: 0.8)
        let result = RouteRanker.label(origin: origin, destination: dest,
                                       candidates: [allRounder, worse])
        XCTAssertEqual(result.count, 1)
        // Highest-priority label wins: mostPaths > flattest > fastest
        XCTAssertEqual(result.first?.profile, .mostPaths)
    }

    func test_mostPaths_avoidsForcedWalking() {
        // A route that forces you to dismount and push most of the way must NOT be
        // labeled "Most paths"; the most-rideable candidate (least walking) wins —
        // even when the pushy route happens to be a little faster.
        let rideable = candidate(dur: 320, ele: 50, walk: 0.0)
        let pushy    = candidate(dur: 300, ele: 40, walk: 0.9)
        let result = RouteRanker.label(origin: origin, destination: dest,
                                       candidates: [rideable, pushy])
        let mostPaths = result.first { $0.profile == .mostPaths }
        XCTAssertEqual(mostPaths?.estimatedDurationSeconds, 320)
    }

    func test_emptyCandidates_returnsEmpty() {
        XCTAssertTrue(RouteRanker.label(origin: origin, destination: dest, candidates: []).isEmpty)
    }

    // MARK: - labeled() carries the source index

    func test_labeled_carriesSourceIndexPerProfile() {
        let fast = candidate(dur: 200, ele: 80, walk: 0.5)    // index 0 → fastest
        let paths = candidate(dur: 350, ele: 60, walk: 0.1)   // index 1 → most paths
        let flat = candidate(dur: 400, ele: 5, walk: 0.4)     // index 2 → flattest
        let result = RouteRanker.labeled(origin: origin, destination: dest,
                                         candidates: [fast, paths, flat])
        let indexByProfile = Dictionary(uniqueKeysWithValues: result.map { ($0.route.profile, $0.sourceIndex) })
        XCTAssertEqual(indexByProfile[.fastest], 0)
        XCTAssertEqual(indexByProfile[.mostPaths], 1)
        XCTAssertEqual(indexByProfile[.flattest], 2)
    }

    func test_labeled_equalDistanceCandidatesGetDistinctSourceIndices() {
        // The old bug: two candidates with identical distanceMeters (1000, the helper
        // default) could mis-map under distance-Double correlation. sourceIndex doesn't
        // rely on distance, so the two labeled routes get distinct indices.
        let a = candidate(dur: 100, ele: 50, walk: 0.5)   // index 0 → fastest
        let b = candidate(dur: 200, ele: 10, walk: 0.1)   // index 1 → flattest + most paths
        let result = RouteRanker.labeled(origin: origin, destination: dest, candidates: [a, b])
        XCTAssertEqual(Set(result.map(\.sourceIndex)), [0, 1])
    }

    func test_label_matchesLabeledRoutes() {
        // label() is a thin wrapper over labeled(); the chosen winners (profiles, in order,
        // with their distances) must match. Route.id is a fresh UUID per construction, so
        // compare the stable fields rather than whole-Route equality.
        let cands = [candidate(dur: 200, ele: 80, walk: 0.5),
                     candidate(dur: 350, ele: 60, walk: 0.1),
                     candidate(dur: 400, ele: 5, walk: 0.4)]
        let viaLabel = RouteRanker.label(origin: origin, destination: dest, candidates: cands)
        let viaLabeled = RouteRanker.labeled(origin: origin, destination: dest, candidates: cands).map(\.route)
        XCTAssertEqual(viaLabel.map(\.profile), viaLabeled.map(\.profile))
        XCTAssertEqual(viaLabel.map(\.distanceMeters), viaLabeled.map(\.distanceMeters))
    }
}
