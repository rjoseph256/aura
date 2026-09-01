import SwiftUI
import MapboxMaps
import Turf
import AuraCore
import AuraKit

/// A non-interactive map that draws a route/track polyline fit to an overview,
/// in the rider's chosen map style. Used for the post-ride summary (and reusable
/// for History thumbnails).
struct StaticRouteMap: View {
    /// One coordinate run per ride segment. Separate polylines, so a pause gap never
    /// becomes a straight line across the map.
    let segments: [[Coordinate]]

    @Environment(SettingsStore.self) private var settings
    @State private var viewport: Viewport = .styleDefault

    private var clSegments: [[CLLocationCoordinate2D]] {
        segments
            .filter { $0.count > 1 }
            .map { $0.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
    }

    /// Every drawn point, for the camera fit. Fitting the overview *across* segments is
    /// correct — only stroking across them is not.
    private var allCoords: [CLLocationCoordinate2D] { clSegments.flatMap { $0 } }

    var body: some View {
        Map(viewport: $viewport) {
            // Every segment piece is cased, so a pause split does not read as a change of
            // line. Casing is the annotation's own `lineBorder*` (one layer, z-correct by
            // construction) — not a second polyline underneath. Matches the share card,
            // which already draws the same ride cased.
            PolylineAnnotationGroup(Array(clSegments.enumerated()), id: \.offset) { item in
                PolylineAnnotation(lineCoordinates: item.element)
                    .lineColor(StyleColor(AuraTheme.routeUIColor))
                    // 8 − 2×1.5 = 5pt of mint. The border is INSET; see RoutePreviewView.
                    .lineWidth(8)
                    .lineBorderColor(StyleColor(AuraTheme.routeCasingUIColor))
                    .lineBorderWidth(1.5)
            }
            // Caps/joins are layer-level in MapboxMaps 11, so they live on the group. Round
            // caps also blunt the two ends a pause split exposes.
            .lineCap(.round)
            .lineJoin(.round)
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        .allowsHitTesting(false)
        .onAppear(perform: fit)
    }

    private func fit() {
        guard allCoords.count > 1 else { return }
        viewport = .overview(
            geometry: LineString(allCoords),
            geometryPadding: .init(top: 24, leading: 24, bottom: 24, trailing: 24),
            maxZoom: 16
        )
    }
}
