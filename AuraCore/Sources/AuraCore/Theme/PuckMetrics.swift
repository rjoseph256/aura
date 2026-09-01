/// Geometry for the Aura puck bitmaps (ROH-219/220). Pure `Double` so the macOS
/// package job builds it. `PuckImageRenderer` (app target) rasterizes from these.
/// Values are the PO-approved gate-1a design (2026-08-31); tune at gate 1b only
/// within these tests' invariants.
public struct BrowsePuckMetrics: Sendable {
    public let coreDiameter: Double     // white core, including the ink outline
    public let inkOutlineWidth: Double
    public let mintRingWidth: Double
    public let wedgeTipRadius: Double   // canvas center → heading-wedge tip
    public let canvasSide: Double       // square bitmap side (pt)

    public static let standard = BrowsePuckMetrics(
        coreDiameter: 18, inkOutlineWidth: 1.5, mintRingWidth: 2,
        wedgeTipRadius: 16, canvasSide: 34)
}

public struct RidingPuckMetrics: Sendable {
    public let arrowLength: Double      // triangle height, tip to base
    public let arrowWidth: Double       // base width
    public let cornerRadius: Double
    public let inkOutlineWidth: Double
    public let mintEdgeWidth: Double    // 2.5 — PO-bumped at gate 1a
    public let canvasSide: Double

    public static let standard = RidingPuckMetrics(
        arrowLength: 22, arrowWidth: 20, cornerRadius: 3,
        inkOutlineWidth: 1.5, mintEdgeWidth: 2.5, canvasSide: 32)
}
