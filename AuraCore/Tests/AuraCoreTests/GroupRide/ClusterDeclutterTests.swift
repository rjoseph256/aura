import Testing
import Foundation
@testable import AuraCore

struct ClusterDeclutterTests {
    func p(_ x: Double, _ y: Double) -> ClusterDeclutter.Point2D { .init(x: x, y: y) }
    let none = [false, false]

    @Test func nonOverlappingPointsGetNoOffset() {
        let pts = [p(0, 0), p(100, 100)]
        let offs = ClusterDeclutter.resolve(points: pts, previouslyClustered: none,
                                            enterRadius: 24, leaveRadius: 36, spread: 18)
        #expect(offs == [.init(dx: 0, dy: 0), .init(dx: 0, dy: 0)])
        #expect(ClusterDeclutter.clustered(points: pts, previouslyClustered: none,
                                           enterRadius: 24, leaveRadius: 36) == [false, false])
    }

    @Test func twoOverlappingPointsSpreadApart() {
        let pts = [p(0, 0), p(4, 0)]                 // 4px apart, within enterRadius
        let offs = ClusterDeclutter.resolve(points: pts, previouslyClustered: none,
                                            enterRadius: 24, leaveRadius: 36, spread: 18)
        #expect(offs[0] != .init(dx: 0, dy: 0))
        #expect(offs[1] != .init(dx: 0, dy: 0))
        let f0 = (pts[0].x + offs[0].dx, pts[0].y + offs[0].dy)
        let f1 = (pts[1].x + offs[1].dx, pts[1].y + offs[1].dy)
        let d = ((f0.0 - f1.0) * (f0.0 - f1.0) + (f0.1 - f1.1) * (f0.1 - f1.1)).squareRoot()
        #expect(abs(d - 36) < 1.0)                   // 2 * spread(18)
        #expect(ClusterDeclutter.clustered(points: pts, previouslyClustered: none,
                                           enterRadius: 24, leaveRadius: 36) == [true, true])
    }

    @Test func hysteresisHoldsClusterBetweenRadii() {
        let pts = [p(0, 0), p(30, 0)]                 // 30px: > enter(24), < leave(36)
        // not previously clustered → stays apart
        #expect(ClusterDeclutter.clustered(points: pts, previouslyClustered: none,
                                           enterRadius: 24, leaveRadius: 36) == [false, false])
        // previously clustered → held together until beyond leaveRadius
        #expect(ClusterDeclutter.clustered(points: pts, previouslyClustered: [true, true],
                                           enterRadius: 24, leaveRadius: 36) == [true, true])
    }

    @Test func resultIsDeterministicForSameInput() {
        let pts = [p(1, 1), p(3, 1), p(2, 2)]
        let a = ClusterDeclutter.resolve(points: pts, previouslyClustered: [false, false, false],
                                         enterRadius: 24, leaveRadius: 36, spread: 18)
        let b = ClusterDeclutter.resolve(points: pts, previouslyClustered: [false, false, false],
                                         enterRadius: 24, leaveRadius: 36, spread: 18)
        #expect(a == b)
    }
}
