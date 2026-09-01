import Testing
@testable import AuraCore

struct PuckMetricsTests {
    // Spec §3 invariant 2: Mapbox paints shadow → bearing → top, so the wedge
    // (bearingImage) draws UNDER the core. Its tip must clear the core + ring.
    @Test func browseWedgeTipClearsTheCoreAndRing() {
        let m = BrowsePuckMetrics.standard
        #expect(m.wedgeTipRadius > m.coreDiameter / 2 + m.mintRingWidth)
    }

    // Bearing images rotate about the canvas center: content must fit the
    // inscribed circle or rotation clips it.
    @Test func browseCanvasContainsTheRotatingWedge() {
        let m = BrowsePuckMetrics.standard
        #expect(m.canvasSide >= 2 * m.wedgeTipRadius)
    }

    @Test func ridingTriangleSurvivesRotation() {
        let m = RidingPuckMetrics.standard
        let diagonal = (m.arrowLength * m.arrowLength + m.arrowWidth * m.arrowWidth)
            .squareRoot()
        #expect(m.canvasSide >= diagonal)
    }

    @Test func ridingCornersLeaveAFlatBase() {
        let m = RidingPuckMetrics.standard
        #expect(m.cornerRadius * 2 < m.arrowWidth)
    }

    // The riding renderer derives its layer insets from these — they must nest.
    @Test func ridingEdgeAndOutlineNestInsideTheTriangle() {
        let m = RidingPuckMetrics.standard
        #expect(2 * (m.mintEdgeWidth + m.inkOutlineWidth) < m.arrowLength)
    }
}
