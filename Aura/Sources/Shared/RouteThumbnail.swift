import SwiftUI
import AuraCore
import AuraKit

/// A lightweight, map-free thumbnail of a ride's GPS track: the polyline normalized
/// into the view's bounds (via `PolylineNormalizer`) and stroked with `Canvas`.
///
/// Far cheaper than a live Mapbox map per list row — no GL view, no tiles, no
/// attribution — and the route's *shape* reads clearly even at thumbnail size.
struct RouteThumbnail: View {
    /// One coordinate run per ride segment, fitted through a single shared scale.
    let segments: [[Coordinate]]
    var lineColor: Color = AuraTheme.routeLine
    var lineWidth: CGFloat = 2

    /// Flat-track convenience for the callers that read the pre-baked, deliberately
    /// un-segmented `thumbnailData` blob (History rows, Last Ride card, widgets).
    init(coordinates: [Coordinate], lineColor: Color = AuraTheme.routeLine,
         lineWidth: CGFloat = 2) {
        self.init(segments: [coordinates], lineColor: lineColor, lineWidth: lineWidth)
    }

    init(segments: [[Coordinate]], lineColor: Color = AuraTheme.routeLine,
         lineWidth: CGFloat = 2) {
        self.segments = segments
        self.lineColor = lineColor
        self.lineWidth = lineWidth
    }

    var body: some View {
        Canvas { context, size in
            let runs = PolylineNormalizer.points(segments: segments, in: size,
                                                 inset: lineWidth + 3)
            var path = Path()
            for pts in runs where pts.count > 1 {
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(lineColor),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
