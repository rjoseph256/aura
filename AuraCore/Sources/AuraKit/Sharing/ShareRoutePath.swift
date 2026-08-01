import CoreGraphics

/// Builds the route stroke path for the share-card composite (spec ROH-126 rev 4,
/// §Route drawing). Input is the overlay-captured projected points, one run per ride
/// segment: each run becomes its own subpath (its own `move(to:)`), so pause gaps are
/// never bridged by a line the rider never rode. The caller strokes the single path
/// twice — casing then mint — and both passes inherit the per-run separation.
public enum ShareRoutePath {
    /// `nil` when no run has at least 2 finite points — nothing strokeable was captured,
    /// and the pipeline must reject rather than ship a routeless map card. Non-finite
    /// points are dropped per point, and runs left with fewer than 2 points are skipped
    /// (a lone point has no line to stroke).
    public static func path(runs: [[CGPoint]]) -> CGPath? {
        // Drop non-finite points BEFORE the run test: CoreGraphics silently ignores an
        // invalid `move(to:)`, so a non-finite run head would fuse two runs into one
        // stroke across a pause gap — exactly the line this type exists to never draw.
        let strokeable = runs
            .map { $0.filter { $0.x.isFinite && $0.y.isFinite } }
            .filter { $0.count >= 2 }
        guard !strokeable.isEmpty else { return nil }
        let path = CGMutablePath()
        for run in strokeable {
            path.move(to: run[0])
            for point in run.dropFirst() { path.addLine(to: point) }
        }
        return path
    }
}
