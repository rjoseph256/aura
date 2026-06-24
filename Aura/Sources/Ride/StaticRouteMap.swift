import SwiftUI
import MapboxMaps
import Turf
import AuraCore
import AuraKit

/// A non-interactive map that draws a route/track polyline fit to an overview,
/// in the rider's chosen map style. Used for the post-ride summary (and reusable
/// for History thumbnails).
struct StaticRouteMap: View {
    let coordinates: [Coordinate]

    @Environment(SettingsStore.self) private var settings
    @State private var viewport: Viewport = .styleDefault

    private var clCoords: [CLLocationCoordinate2D] {
        coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        Map(viewport: $viewport) {
            if clCoords.count > 1 {
                PolylineAnnotationGroup {
                    PolylineAnnotation(lineCoordinates: clCoords)
                        .lineColor(StyleColor(UIColor(red: 43 / 255, green: 224 / 255,
                                                      blue: 138 / 255, alpha: 1)))
                        .lineWidth(5)
                }
            }
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        .allowsHitTesting(false)
        .onAppear(perform: fit)
    }

    private func fit() {
        guard clCoords.count > 1 else { return }
        viewport = .overview(
            geometry: LineString(clCoords),
            geometryPadding: .init(top: 24, leading: 24, bottom: 24, trailing: 24),
            maxZoom: 16
        )
    }
}
