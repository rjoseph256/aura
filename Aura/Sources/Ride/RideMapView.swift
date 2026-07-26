import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Mapbox map that follows the rider and draws the live track, in the user's chosen style.
/// In a group ride, also renders peer dots (with heading cones + a live pulse) and splits
/// the route ribbon into a dimmed "behind" segment and a bright "ahead" segment relative to
/// the rider's own progress. Both are no-ops for the solo path (`peers` empty, default args).
struct RideMapView: View {
    /// The recorded ride, split at pauses. One polyline per segment, so the map never
    /// strokes the chord across a stop.
    let segments: [RideSegment]
    var peers: [RidePeer] = []
    /// The rider's own id, so they aren't drawn as a peer dot on top of the location puck.
    /// nil on the solo path, which passes no peers at all.
    var selfUserID: UUID?
    var nameMap: [UUID: String] = [:]
    var selfProgress: Double = 0
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var viewport: Viewport
    /// Drives peer-dot interpolation, identity, and declutter (ROH-69 / ROH-72). A plain class
    /// held in `@State`; the `TimelineView` clock and `.onChange(of: peers)` drive repaints.
    @State private var peerModel = PeerAnnotationDriver()

    private var ribbonPieces: [TrackRibbon.Piece] {
        // Solo rides (no peers) draw one bright ribbon; group rides dim what's already
        // ridden at the rider's own progress.
        TrackRibbon.pieces(segments: segments, splitAtMeters: peers.isEmpty ? nil : selfProgress)
    }

    private var detourRouteCoordinates: [CLLocationCoordinate2D] {
        detourRoute.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        MapReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !peerModel.shouldAnimate(now: Date()))) { context in
                Map(viewport: $viewport) {
                    Puck2D(bearing: .heading)
                    routeRibbon
                    detourPolyline
                    PeerAnnotations(frame: peerModel.frame(now: context.date,
                                                           project: { project($0, proxy) }))
                    gemAnnotations
                }
                .mapStyle(settings.mapStyle.mapboxStyle)
                // Mirror the live camera into the zoom box. Must precede `.ignoresSafeArea()`
                // (a type-erasing View modifier) to stay in the Map-only modifier chain.
                .onCameraChanged { ctx in
                    guard let cameraBox else { return }
                    cameraBox.zoom = ctx.cameraState.zoom
                    cameraBox.center = ctx.cameraState.center
                    cameraBox.bearing = ctx.cameraState.bearing
                    cameraBox.pitch = ctx.cameraState.pitch
                }
                .ignoresSafeArea()
            }
        }
        .onAppear { syncPeers() }
        .onChange(of: peers) { syncPeers() }
        .onChange(of: reduceMotion) { syncPeers() }
    }

    private func syncPeers() {
        peerModel.updateSet(peers: peers, selfUserID: selfUserID, nameMap: nameMap,
                            reduceMotion: reduceMotion, now: Date())
    }

    /// Real Mapbox projection for declutter; nil when the coordinate is off-screen/unavailable.
    private func project(_ c: Coordinate, _ proxy: MapProxy) -> ClusterDeclutter.Point2D? {
        guard let map = proxy.map else { return nil }
        let pt = map.point(for: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        guard pt.x.isFinite, pt.y.isFinite else { return nil }
        return ClusterDeclutter.Point2D(x: Double(pt.x), y: Double(pt.y))
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

    /// The lit/dimmed route ribbon. When there are no peers to share progress against,
    /// this collapses to the original single bright polyline (unchanged solo behavior).
    /// While a detour is active (`detourRoute` non-empty), the recorded track dims to a
    /// quarter opacity so the bright `detourPolyline` reads as the thing to follow.
    @MapContentBuilder
    private var routeRibbon: some MapContent {
        // Keep the emptiness guard: an empty group still creates a Mapbox annotation manager
        // (a style source + layer) per map mount, where today there was none.
        let pieces = ribbonPieces
        if !pieces.isEmpty {
            PolylineAnnotationGroup(Array(pieces.enumerated()), id: \.offset) { item in
                PolylineAnnotation(lineCoordinates: item.element.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .lineColor(StyleColor(item.element.isBehind || !detourRoute.isEmpty
                    ? UIColor(AuraTheme.routeLine.opacity(0.25))
                    : AuraTheme.routeUIColor))
                .lineWidth(6)
            }
        }
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
    let peers: [RidePeer] = [
        RidePeer(userID: UUID(), displayName: "Mara",
                coordinate: Coordinate(latitude: 37.7752, longitude: -122.4192),
                progressMeters: 900, motionState: .moving, status: .riding),
        RidePeer(userID: UUID(), displayName: "Devon",
                coordinate: Coordinate(latitude: 37.7742, longitude: -122.4182),
                progressMeters: 450, motionState: .stopped, status: .stopped),
        RidePeer(userID: UUID(), displayName: "Priya",
                coordinate: Coordinate(latitude: 37.7732, longitude: -122.4172),
                progressMeters: 200, status: .awaiting),
        RidePeer(userID: UUID(), displayName: "Sam",
                coordinate: nil, progressMeters: nil, status: .dropped)
    ]
    let track = stride(from: 0, through: 1200, by: 40).map { meters in
        TrackPoint(coordinate: Coordinate(latitude: 37.7700 + Double(meters) * 0.00003,
                                          longitude: -122.4210 + Double(meters) * 0.00002),
                  elevation: nil, timestamp: Date())
    }
    return RideMapView(segments: [RideSegment(points: track)], peers: peers,
                       nameMap: [:], selfProgress: 550, viewport: $viewport)
        .environment(SettingsStore())
}
