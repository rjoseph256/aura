import SwiftUI
import AuraKit

/// A compact area sparkline of a route's elevation profile, for comparing how hilly
/// each route option is at a glance. The geometry comes from `Sparkline`; this view
/// just paints the filled area and the line on top.
struct ElevationSparkline: View {
    let elevations: [Double]
    var stroke: Color
    var fill: Color
    var lineWidth: CGFloat = 1.5
    /// Shared vertical scale across the visible route options; nil → self-scale.
    var range: ClosedRange<Double>?

    var body: some View {
        Canvas { context, size in
            let pts = range.map { Sparkline.points(values: elevations, in: size, inset: lineWidth, range: $0) }
                ?? Sparkline.points(values: elevations, in: size, inset: lineWidth)
            guard pts.count > 1 else { return }

            var line = Path()
            line.move(to: pts[0])
            for p in pts.dropFirst() { line.addLine(to: p) }

            // Soft area fill under the trace.
            var area = line
            area.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: pts.first!.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(fill))

            context.stroke(line, with: .color(stroke),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
