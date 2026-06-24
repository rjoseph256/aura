import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Mapbox map that follows the rider and draws the live track, in the user's chosen style.
struct RideMapView: View {
    let track: [TrackPoint]
    @Environment(SettingsStore.self) private var settings
    @State private var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            if track.count > 1 {
                PolylineAnnotationGroup {
                    PolylineAnnotation(lineCoordinates: track.map {
                        CLLocationCoordinate2D(latitude: $0.coordinate.latitude,
                                               longitude: $0.coordinate.longitude)
                    })
                    .lineColor(StyleColor(UIColor(red: 43 / 255, green: 224 / 255, blue: 138 / 255, alpha: 1)))
                    .lineWidth(6)
                }
            }
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        .ignoresSafeArea()
    }
}
