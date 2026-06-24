import SwiftUI
import MapboxMaps
import AuraCore

/// Dark Mapbox map that follows the rider and draws the live track.
struct RideMapView: View {
    let track: [TrackPoint]
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
        .mapStyle(.dark)
        .ignoresSafeArea()
    }
}
