import SwiftUI
import AuraCore
import AuraKit

/// A lightweight, map-free thumbnail of a ride's GPS track: the polyline normalized
/// into the view's bounds (via `PolylineNormalizer`) and stroked with `Canvas`.
///
/// Far cheaper than a live Mapbox map per list row — no GL view, no tiles, no
/// attribution — and the route's *shape* reads clearly even at thumbnail size.
struct RouteThumbnail: View {
    let coordinates: [Coordinate]
    var lineColor: Color = AuraTheme.route
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let pts = PolylineNormalizer.points(coordinates, in: size, inset: lineWidth + 3)
            guard pts.count > 1 else { return }
            var path = Path()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(lineColor),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
