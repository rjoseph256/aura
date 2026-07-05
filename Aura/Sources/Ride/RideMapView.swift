import SwiftUI
import MapboxMaps
import AuraCore
import AuraKit

/// Mapbox map that follows the rider and draws the live track, in the user's chosen style.
/// In a group ride, also renders peer dots (with heading cones + a live pulse) and splits
/// the route ribbon into a dimmed "behind" segment and a bright "ahead" segment relative to
/// the rider's own progress. Both are no-ops for the solo path (`peers` empty, default args).
struct RideMapView: View {
    let track: [TrackPoint]
    var peers: [RidePeer] = []
    var nameMap: [UUID: String] = [:]
    var selfProgress: Double = 0
    var gems: [Gem] = []
    var seenGemIDs: Set<String> = []
    var onSelectGem: (Gem) -> Void = { _ in }

    @Environment(SettingsStore.self) private var settings
    @Binding var viewport: Viewport
    /// Each peer's previous fix, so a heading cone can be derived on-device between
    /// consecutive updates (the wire carries no bearing — see `PeerBearing`).
    @State private var previousPeerCoordinates: [UUID: Coordinate] = [:]

    /// Only the leader (furthest along) gets a name tag on the map, so peer dots don't
    /// clutter the view — the full roster lives elsewhere.
    private var leaderID: UUID? {
        peers.filter { $0.coordinate != nil }
            .max { ($0.progressMeters ?? -.infinity) < ($1.progressMeters ?? -.infinity) }?
            .userID
    }

    private var trackCoordinates: [CLLocationCoordinate2D] {
        track.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude,
                                           longitude: $0.coordinate.longitude) }
    }

    var body: some View {
        Map(viewport: $viewport) {
            Puck2D(bearing: .heading)
            routeRibbon
            ForEvery(peers.filter { $0.coordinate != nil }, id: \.userID) { peer in
                if let coordinate = peer.coordinate {
                    MapViewAnnotation(coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                                         longitude: coordinate.longitude)) {
                        PeerDotView(displayName: nameMap[peer.userID] ?? peer.displayName,
                                   status: peer.status,
                                   isSelf: false,
                                   bearing: PeerBearing.heading(from: previousPeerCoordinates[peer.userID],
                                                                to: coordinate),
                                   showsNameTag: peer.userID == leaderID)
                    }
                    .allowOverlapWithPuck(true)
                }
            }
            ForEvery(gems, id: \.id) { gem in
                MapViewAnnotation(coordinate: CLLocationCoordinate2D(latitude: gem.coordinate.latitude,
                                                                     longitude: gem.coordinate.longitude)) {
                    GemPinView(gem: gem, isSeen: seenGemIDs.contains(gem.id)) { onSelectGem(gem) }
                }
                .allowOverlapWithPuck(true)
            }
        }
        .mapStyle(settings.mapStyle.mapboxStyle)
        .ignoresSafeArea()
        .onChange(of: peers) { _, newPeers in
            for peer in newPeers {
                if let coordinate = peer.coordinate {
                    previousPeerCoordinates[peer.userID] = coordinate
                }
            }
        }
    }

    /// The lit/dimmed route ribbon. When there are no peers to share progress against,
    /// this collapses to the original single bright polyline (unchanged solo behavior).
    @MapContentBuilder
    private var routeRibbon: some MapContent {
        if track.count > 1 {
            if peers.isEmpty {
                PolylineAnnotationGroup {
                    PolylineAnnotation(lineCoordinates: trackCoordinates)
                        .lineColor(StyleColor(AuraTheme.routeUIColor))
                        .lineWidth(6)
                }
            } else {
                let splitIndex = RouteSplit.splitIndex(geometry: track.map(\.coordinate),
                                                       atMeters: selfProgress)
                let behind = Array(trackCoordinates.prefix(splitIndex))
                let ahead = Array(trackCoordinates.suffix(from: min(splitIndex, trackCoordinates.count - 1)))
                PolylineAnnotationGroup {
                    if behind.count > 1 {
                        PolylineAnnotation(lineCoordinates: behind)
                            .lineColor(StyleColor(UIColor(AuraTheme.routeLine.opacity(0.25))))
                            .lineWidth(6)
                    }
                    if ahead.count > 1 {
                        PolylineAnnotation(lineCoordinates: ahead)
                            .lineColor(StyleColor(AuraTheme.routeUIColor))
                            .lineWidth(6)
                    }
                }
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
    return RideMapView(track: track, peers: peers,
                       nameMap: [:], selfProgress: 550, viewport: $viewport)
        .environment(SettingsStore())
}
