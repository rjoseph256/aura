import UIKit
import AuraCore

/// Rasterizes the Aura puck bitmaps from `PuckMetrics` + theme tokens (ROH-219/220).
/// `static let` is load-bearing: MapboxMaps diffs Puck2D configurations by UIImage
/// POINTER identity, and the navigate HUD's Map content can re-evaluate at 30 Hz — a
/// fresh image per pass would re-upload bitmaps to the style every frame.
enum AuraPuck {
    /// Browse core: white disc, ink outline, mint ring. "White = me" (spec §2).
    static let browseTop: UIImage = {
        let m = BrowsePuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let coreRadius = CGFloat(m.coreDiameter) / 2
            fillCircle(c, center: center, radius: coreRadius + CGFloat(m.mintRingWidth),
                       color: AuraTheme.routeUIColor)                    // mint ring
            fillCircle(c, center: center, radius: coreRadius,
                       color: AuraTheme.routeCasingUIColor)              // ink outline
            fillCircle(c, center: center, radius: coreRadius - CGFloat(m.inkOutlineWidth),
                       color: .white)                                    // white core
        }
    }()

    /// Browse heading wedge — MINT with an ink backing, so it reads on the dark
    /// terrain (plan-review finding: a near-black wedge on a near-black basemap is
    /// invisible). Paints UNDER the top image; only the part beyond the ring shows,
    /// which PuckMetricsTests pins.
    static let browseBearing: UIImage = {
        let m = BrowsePuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let ringRadius = CGFloat(m.coreDiameter) / 2 + CGFloat(m.mintRingWidth)
            // Ink backing wedge (slightly larger, gives the mint tip a dark seat).
            wedge(c, center: center, tipRadius: CGFloat(m.wedgeTipRadius) + 1.5,
                  base: (half: ringRadius * 0.5, radius: ringRadius * 0.55),
                  color: AuraTheme.routeCasingUIColor)
            // Mint wedge on top.
            wedge(c, center: center, tipRadius: CGFloat(m.wedgeTipRadius),
                  base: (half: ringRadius * 0.4, radius: ringRadius * 0.6),
                  color: AuraTheme.routeUIColor)
        }
    }()

    /// Riding puck: ROUNDED TRIANGLE, locked at PO gate 1a (2026-08-31) — white
    /// body, ink outline, bumped 2.5pt mint edge. Corner rounding comes from
    /// fill+stroke with a round line join (stroke width = 2 × cornerRadius).
    static let ridingBearing: UIImage = {
        let m = RidingPuckMetrics.standard
        let side = CGFloat(m.canvasSide)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            c.setLineJoin(.round)
            let layers: [(scale: Double, color: UIColor)] = [
                (1.0, AuraTheme.routeUIColor),
                (insetScale(m, by: m.mintEdgeWidth), AuraTheme.routeCasingUIColor),
                (insetScale(m, by: m.mintEdgeWidth + m.inkOutlineWidth), .white)
            ]
            for layer in layers {
                let path = trianglePath(m, center: center, scale: layer.scale)
                c.setFillColor(layer.color.cgColor)
                c.setStrokeColor(layer.color.cgColor)
                c.setLineWidth(2 * CGFloat(m.cornerRadius) * CGFloat(layer.scale))
                c.addPath(path.cgPath)
                c.drawPath(using: .fillStroke)
            }
        }
    }()

    /// Mandatory transparent top for the riding state: a nil topImage falls back to
    /// Mapbox's stock blue dot rendered ON TOP of the bearing arrow (spec §3.1).
    static let clearTop: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    // MARK: - Drawing helpers (no force casts — the TaskCompleted gate lints --strict)

    private static func fillCircle(_ c: CGContext, center: CGPoint, radius: CGFloat,
                                   color: UIColor) {
        c.setFillColor(color.cgColor)
        c.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2))
    }

    private static func wedge(_ c: CGContext, center: CGPoint, tipRadius: CGFloat,
                              base: (half: CGFloat, radius: CGFloat), color: UIColor) {
        c.setFillColor(color.cgColor)
        c.move(to: CGPoint(x: center.x, y: center.y - tipRadius))
        c.addLine(to: CGPoint(x: center.x - base.half, y: center.y - base.radius))
        c.addLine(to: CGPoint(x: center.x + base.half, y: center.y - base.radius))
        c.closePath()
        c.fillPath()
    }

    private static func trianglePath(_ m: RidingPuckMetrics, center: CGPoint,
                                     scale: Double) -> UIBezierPath {
        let halfL = CGFloat(m.arrowLength * scale) / 2
        let halfW = CGFloat(m.arrowWidth * scale) / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center.x, y: center.y - halfL))
        path.addLine(to: CGPoint(x: center.x + halfW, y: center.y + halfL))
        path.addLine(to: CGPoint(x: center.x - halfW, y: center.y + halfL))
        path.close()
        return path
    }

    /// Scale that insets the triangle by `points` all around (height-ratio
    /// approximation — gate 1b judges the pixels).
    private static func insetScale(_ m: RidingPuckMetrics, by points: Double) -> Double {
        max(0, (m.arrowLength - 2 * points) / m.arrowLength)
    }
}
