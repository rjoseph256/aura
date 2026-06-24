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
}
