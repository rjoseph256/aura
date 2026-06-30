import XCTest
@testable import AuraCore

final class ElevationSamplingTests: XCTestCase {

    func test_total0_returnsEmpty() {
        XCTAssertEqual(ElevationSampling.sampleIndices(total: 0, count: 12), [])
    }

    func test_total1_returnsSingleIndex() {
        XCTAssertEqual(ElevationSampling.sampleIndices(total: 1, count: 12), [0])
    }

    func test_totalAtMostCount_returnsAllIndices() {
        XCTAssertEqual(ElevationSampling.sampleIndices(total: 5, count: 12), [0, 1, 2, 3, 4])
        // total == count is still "all indices".
        XCTAssertEqual(ElevationSampling.sampleIndices(total: 12, count: 12), Array(0..<12))
    }

    func test_total100_count12_isEvenlySpaced() {
        let indices = ElevationSampling.sampleIndices(total: 100, count: 12)
        XCTAssertEqual(indices.count, 12)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 99)
        // Strictly increasing & unique.
        for i in 1..<indices.count {
            XCTAssertLessThan(indices[i - 1], indices[i])
        }
    }

    func test_total2_returnsBothEndpoints() {
        XCTAssertEqual(ElevationSampling.sampleIndices(total: 2, count: 12), [0, 1])
    }

    func test_indicesAreWithinBounds() {
        let total = 250
        let indices = ElevationSampling.sampleIndices(total: total, count: 12)
        for idx in indices {
            XCTAssertGreaterThanOrEqual(idx, 0)
            XCTAssertLessThan(idx, total)
        }
    }

    // MARK: - proportionalCount (distance-proportional sampling)

    /// A 2-point line along the equator of `degrees` longitude, for a known great-circle length.
    private func equatorLine(degrees: Double) -> [Coordinate] {
        [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: degrees)]
    }

    func test_proportionalCount_degenerateReturnsMinCount() {
        XCTAssertEqual(ElevationSampling.proportionalCount(coordinates: []), 16)
        XCTAssertEqual(ElevationSampling.proportionalCount(coordinates: [Coordinate(latitude: 0, longitude: 0)]), 16)
    }

    func test_proportionalCount_shortRouteClampsToMin() {
        // ~1.1 km → raw ≈ 8, clamps up to the 16 floor (short routes keep prior detail).
        XCTAssertEqual(ElevationSampling.proportionalCount(coordinates: equatorLine(degrees: 0.01)), 16)
    }

    func test_proportionalCount_midRouteScalesWithDistance() {
        // ~5.56 km at 150 m spacing → round(37.06)+1 = 38, between the clamps.
        XCTAssertEqual(ElevationSampling.proportionalCount(coordinates: equatorLine(degrees: 0.05)), 38)
    }

    func test_proportionalCount_longRouteClampsToMax() {
        // ~33 km → raw ≈ 223, clamps down to the 96 ceiling.
        XCTAssertEqual(ElevationSampling.proportionalCount(coordinates: equatorLine(degrees: 0.3)), 96)
    }

    func test_proportionalCount_isMonotonicInDistance() {
        let shortC = ElevationSampling.proportionalCount(coordinates: equatorLine(degrees: 0.02))
        let midC = ElevationSampling.proportionalCount(coordinates: equatorLine(degrees: 0.06))
        let longC = ElevationSampling.proportionalCount(coordinates: equatorLine(degrees: 0.2))
        XCTAssertLessThanOrEqual(shortC, midC)
        XCTAssertLessThanOrEqual(midC, longC)
    }
}
