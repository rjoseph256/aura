import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Mapbox map that follows the rider and draws the live recorded track, in the user's chosen
/// style. Explore-HUD only, and solo by construction: group rides run through
/// `NavigateHUDView`, which strokes the *planned route* and owns its own peer dots.
struct RideMapView: View {
    /// The recorded ride, split at pauses. One polyline per segment, so the map never
    /// strokes the chord across a stop.
    let segments: [RideSegment]
    /// Whether the ride is stopped. Styles the run the rider paused in, so the map itself says
    /// recording has stopped (ROH-105 D5's pure discriminator, computed in `TrackRibbon`).
    ///
    /// Required, not defaulted, for the same reason the coordinator's seams are: a silently
    /// unwired paused signal compiles clean and ships dead. Update the `#Preview` in this file.
    let isPaused: Bool
    var gems: [Gem] = []
    var seenGemIDs: Set<String> = []
    var onSelectGem: (Gem) -> Void = { _ in }
    /// The active detour route geometry, if any. When non-empty, the recorded track dims
    /// (see `routeRibbon`) so the bright detour polyline reads as the thing to follow.
    var detourRoute: [Coordinate] = []
    /// Mirrors the live camera for the +/- zoom pill (ROH-57); nil in previews. Written every
    /// frame by `.onCameraChanged`, read only at tap time (see `MapZoomCameraBox`).
    var cameraBox: MapZoomCameraBox?

    @Environment(SettingsStore.self) private var settings
    @Binding var viewport: Viewport

    private var ribbonPieces: [TrackRibbon.Piece] {
        TrackRibbon.pieces(segments: segments, isPaused: isPaused)
    }

    private var detourRouteCoordinates: [CLLocationCoordinate2D] {
        detourRoute.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            routeRibbon
            detourPolyline
            gemAnnotations
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        // Mirror the live camera into the zoom box. Must precede `.ignoresSafeArea()`, which
        // type-erases the view: `onCameraChanged` is declared on `Map` and returns `Self`, so
        // ordering it after `.ignoresSafeArea()` fails to compile.
        .onCameraChanged { ctx in
            guard let cameraBox else { return }
            cameraBox.zoom = ctx.cameraState.zoom
            cameraBox.center = ctx.cameraState.center
            cameraBox.bearing = ctx.cameraState.bearing
            cameraBox.pitch = ctx.cameraState.pitch
        }
        .ignoresSafeArea()
    }

    @MapContentBuilder
    private var gemAnnotations: some MapContent {
        ForEvery(gems, id: \.id) { gem in
            MapViewAnnotation(coordinate: CLLocationCoordinate2D(latitude: gem.coordinate.latitude,
                                                                 longitude: gem.coordinate.longitude)) {
                GemPinView(gem: gem, isSeen: seenGemIDs.contains(gem.id)) { onSelectGem(gem) }
            }
            .allowOverlapWithPuck(true)
        }
    }

    /// The recorded track. While a detour is active (`detourRoute` non-empty), its *recording*
    /// pieces dim to a quarter opacity so the bright `detourPolyline` reads as the thing to
    /// follow; paused pieces keep their grey — see `strokeColor(for:)`.
    @MapContentBuilder
    private var routeRibbon: some MapContent {
        // Keep the emptiness guard: an empty group still creates a Mapbox annotation manager
        // (a style source + layer) per map mount, where today there was none. Hit on every
        // ride start, since recording begins in a `.task` that runs after the first body pass.
        let pieces = ribbonPieces
        if !pieces.isEmpty {
            PolylineAnnotationGroup(pieces, id: \.sourceIndex) { piece in
                PolylineAnnotation(lineCoordinates: piece.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .lineColor(StyleColor(strokeColor(for: piece)))
                .lineWidth(6)
                .lineOpacity(piece.style == .paused ? 0.55 : 1)
            }
        }
    }

    /// The recorded track's stroke. A **recording** piece is mint, dimmed to a quarter while a
    /// detour is active so the bright detour line wins. A **paused** piece is neutral grey, and
    /// is not dimmed by a detour — so while detouring it renders brighter than the live track
    /// around it. That is deliberate, not an oversight: the detour dim exists to stop a *mint*
    /// line competing with the mint detour for "the thing to follow", and grey does not compete.
    /// Stacking the quarter dim on top of the paused run's 0.55 `lineOpacity` would leave it at
    /// roughly 0.14 alpha, erasing the very distinction the next paragraph argues for.
    ///
    /// Grey rather than a second hue on purpose: mint against `textSecondary` grey differs in
    /// **lightness**, so the paused run stays distinguishable to a rider who cannot separate the
    /// two by colour. `lineDasharray` would have read even better, but it does not exist on
    /// `PolylineAnnotation` in the pinned MapboxMaps 11.27.0 — it is a layer-level property on
    /// `PolylineAnnotationGroup`, which would dash every piece and defeat the point.
    private func strokeColor(for piece: TrackRibbon.Piece) -> UIColor {
        if piece.style == .paused {
            return UIColor(AuraTheme.textSecondary)
        }
        return detourRoute.isEmpty
            ? AuraTheme.routeUIColor
            : UIColor(AuraTheme.routeLine.opacity(0.25))
    }

    /// The bright detour route line, drawn on top of the (now-dimmed) recorded track while
    /// a gem detour is active. Same Mapbox v11 API as `routeRibbon`.
    @MapContentBuilder
    private var detourPolyline: some MapContent {
        if detourRoute.count > 1 {
            PolylineAnnotationGroup {
                PolylineAnnotation(lineCoordinates: detourRouteCoordinates)
                    .lineColor(StyleColor(AuraTheme.routeUIColor))
                    .lineWidth(6)
            }
        }
    }
}

#Preview {
    @Previewable @State var viewport: Viewport = .followPuck(zoom: 16, bearing: .heading)
    let track = stride(from: 0, through: 1200, by: 40).map { meters in
        TrackPoint(coordinate: Coordinate(latitude: 37.7700 + Double(meters) * 0.00003,
                                          longitude: -122.4210 + Double(meters) * 0.00002),
                  elevation: nil, timestamp: Date())
    }
    return RideMapView(segments: [RideSegment(points: track)], isPaused: false, viewport: $viewport)
        .environment(SettingsStore())
}
