import XCTest
import CoreGraphics
@testable import AuraKit

final class ShareRoutePathTests: XCTestCase {
    private func run(_ n: Int, x0: CGFloat = 10, y0: CGFloat = 10) -> [CGPoint] {
        (0..<n).map { CGPoint(x: x0 + CGFloat($0) * 5, y: y0 + CGFloat($0) * 3) }
    }

    private func elements(of path: CGPath) -> [CGPathElementType] {
        var types: [CGPathElementType] = []
        path.applyWithBlock { types.append($0.pointee.type) }
        return types
    }

    func testNilWhenNoRunHasTwoPoints() {
        XCTAssertNil(ShareRoutePath.path(runs: []))
        XCTAssertNil(ShareRoutePath.path(runs: [[]]))
        XCTAssertNil(ShareRoutePath.path(runs: [[CGPoint(x: 1, y: 1)]]))
        XCTAssertNil(ShareRoutePath.path(runs: [[CGPoint(x: 1, y: 1)], [], [CGPoint(x: 2, y: 2)]]))
    }

    func testSingleRunIsOneSubpath() {
        let path = try! XCTUnwrap(ShareRoutePath.path(runs: [run(4)]))
        let types = elements(of: path)
        XCTAssertEqual(types.filter { $0 == .moveToPoint }.count, 1)
        XCTAssertEqual(types.filter { $0 == .addLineToPoint }.count, 3)
    }

    func testRunsNeverConnectAcrossPauseGaps() {
        // One moveTo per run is the invariant: a stroke across a pause gap would draw a
        // line the rider never rode.
        let path = try! XCTUnwrap(ShareRoutePath.path(runs: [run(4), run(3, x0: 200), run(2, y0: 200)]))
        let types = elements(of: path)
        XCTAssertEqual(types.filter { $0 == .moveToPoint }.count, 3)
        XCTAssertEqual(types.filter { $0 == .addLineToPoint }.count, 3 + 2 + 1)
    }

    func testSubTwoPointRunsAreSkippedNotConnected() {
        let path = try! XCTUnwrap(ShareRoutePath.path(runs: [[CGPoint(x: 5, y: 5)], run(3), []]))
        let types = elements(of: path)
        XCTAssertEqual(types.filter { $0 == .moveToPoint }.count, 1)
        XCTAssertEqual(types.filter { $0 == .addLineToPoint }.count, 2)
    }

    private func decompose(_ path: CGPath) -> (moves: Int, lineTargets: [CGPoint]) {
        var moves = 0
        var lineTargets: [CGPoint] = []
        path.applyWithBlock {
            switch $0.pointee.type {
            case .moveToPoint: moves += 1
            case .addLineToPoint: lineTargets.append($0.pointee.points[0])
            default: break
            }
        }
        return (moves, lineTargets)
    }

    func testNonFiniteRunHeadDoesNotFuseRunsAcrossPauseGap() {
        // CoreGraphics silently ignores `move(to:)` with a NaN point; an unfiltered
        // implementation would then addLine(to: (300,300)) as a continuation of the
        // FIRST run — a stroke across the pause gap. The NaN-headed run has only one
        // finite point, so it must be skipped entirely.
        let runs: [[CGPoint]] = [
            [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)],
            [CGPoint(x: CGFloat.nan, y: 5), CGPoint(x: 300, y: 300)]
        ]
        let path = try! XCTUnwrap(ShareRoutePath.path(runs: runs))
        let (moves, lineTargets) = decompose(path)
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(lineTargets, [CGPoint(x: 20, y: 20)])
        XCTAssertFalse(lineTargets.contains(CGPoint(x: 300, y: 300)))
    }

    func testMidRunNonFinitePointIsDroppedButRunStillStrokes() {
        // Filtering is per POINT, not per run: a run with 2+ finite points survives a
        // non-finite sample in the middle.
        let runs: [[CGPoint]] = [
            [CGPoint(x: 10, y: 10), CGPoint(x: CGFloat.nan, y: CGFloat.nan), CGPoint(x: 20, y: 20)]
        ]
        let path = try! XCTUnwrap(ShareRoutePath.path(runs: runs))
        let (moves, lineTargets) = decompose(path)
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(lineTargets, [CGPoint(x: 20, y: 20)])
    }

    func testNilWhenOnlyNonFinitePointsRemain() {
        XCTAssertNil(ShareRoutePath.path(runs: [
            [CGPoint(x: CGFloat.nan, y: 5), CGPoint(x: 3, y: CGFloat.infinity)]
        ]))
    }

    func testPointsPassThroughUnchanged() {
        let points = run(3)
        let path = try! XCTUnwrap(ShareRoutePath.path(runs: [points]))
        var seen: [CGPoint] = []
        path.applyWithBlock { seen.append($0.pointee.points[0]) }
        XCTAssertEqual(seen, points)
    }
}
