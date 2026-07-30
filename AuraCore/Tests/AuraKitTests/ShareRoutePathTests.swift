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

    func testPointsPassThroughUnchanged() {
        let points = run(3)
        let path = try! XCTUnwrap(ShareRoutePath.path(runs: [points]))
        var seen: [CGPoint] = []
        path.applyWithBlock { seen.append($0.pointee.points[0]) }
        XCTAssertEqual(seen, points)
    }
}
