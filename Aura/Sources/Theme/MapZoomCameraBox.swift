import Foundation
import CoreLocation
import AuraCore

/// Holds the live Mapbox camera for the +/- zoom controls (ROH-57) in an `@Observable` box so
/// `.onCameraChanged` can write it on every camera frame WITHOUT invalidating the hosting view:
/// no view reads these properties in its `body`, so a write triggers no re-render. This is the
/// pattern `HomeMapModel.liveCamera` uses — MapboxMaps explicitly warns against storing the
/// high-frequency camera in SwiftUI `@State`.
///
/// A `+`/`-` tap reads `zoom` on demand to compute the next level via `MapZoomStep`; when the
/// rider has panned off the puck it also reads `center`/`bearing`/`pitch` to re-frame in place
/// instead of snapping back to the puck.
@MainActor
@Observable
final class MapZoomCameraBox {
    var zoom: Double = MapZoomStep.followDefault
    /// nil until the first `.onCameraChanged`; the panned-zoom path falls back to re-following
    /// the puck when it is nil.
    var center: CLLocationCoordinate2D?
    var bearing: Double = 0
    var pitch: Double = 0
}
