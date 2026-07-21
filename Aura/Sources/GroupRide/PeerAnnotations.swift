import SwiftUI
import MapboxMaps
import AuraCore

/// The live peer dots for a group ride: smooth interpolation (ROH-69) + distinct identity /
/// heading (ROH-72). A thin MapContent fragment — every per-frame decision is resolved into
/// `frame` by `PeerAnnotationDriver`, so this only rebuilds ≤7 annotations. Shared by both hosts.
struct PeerAnnotations: MapContent {
    let frame: PeerFrame

    var body: some MapContent {
        ForEvery(frame.dots, id: \.userID) { dot in
            MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                latitude: dot.coordinate.latitude, longitude: dot.coordinate.longitude)) {
                PeerDotView(monogram: dot.monogram, displayName: dot.displayName, status: dot.status,
                            identityColor: AuraTheme.riderColor(dot.colorIndex), isSelf: false,
                            bearing: dot.bearing, pulsePhase: frame.pulsePhase,
                            showsNameTag: dot.showsNameTag)
                    .offset(x: dot.offset.dx, y: dot.offset.dy)
                    .animation(.easeInOut(duration: 0.25), value: dot.offset)
            }
            .allowOverlapWithPuck(true)
        }
    }
}

/// A single dot's fully-resolved render state for one frame.
struct PeerDot: Identifiable, Equatable {
    var userID: UUID
    var coordinate: Coordinate
    var bearing: Double?
    var status: PeerStatus
    var colorIndex: Int
    var monogram: String
    var displayName: String
    var showsNameTag: Bool
    var offset: ClusterDeclutter.DeclutterOffset
    var id: UUID { userID }
}

struct PeerFrame: Equatable { var dots: [PeerDot]; var pulsePhase: Double }

/// Owns interpolation + all memoised per-set derivations + the pulse clock, bearing deadband, and
/// cluster hysteresis. A PLAIN class (not `@Observable`) held in host `@State`: repaints are driven
/// by the host's `TimelineView` clock and `.onChange(of: peers)`, so it needs no observation — and
/// its per-frame continuity caches can be mutated inside `frame(...)` without any invalidation loop.
final class PeerAnnotationDriver {
    private var interpolators = PeerInterpolators()
    // Memoised on peer-set change (NOT per frame):
    private var visible: [RidePeer] = []
    private var colorIndex: [UUID: Int] = [:]
    private var monograms: [UUID: String] = [:]
    private var displayNames: [UUID: String] = [:]
    private var leaderID: UUID?
    private var anyRiding = false
    private var reduceMotion = false
    // Per-frame continuity caches:
    private var displayBearing: [UUID: Double] = [:]
    private var prevClustered: [Bool] = []

    /// Recompute set-derived data + commit new fixes. Call from `.onChange(of: peers)` / `.onAppear`.
    func updateSet(peers: [RidePeer], selfUserID: UUID?, nameMap: [UUID: String],
                   reduceMotion: Bool, now: Date) {
        self.reduceMotion = reduceMotion
        visible = GroupMapDots.visiblePeers(peers: peers, selfUserID: selfUserID)
        anyRiding = visible.contains { $0.status == .riding }
        let ids = visible.map(\.userID)
        displayNames = Dictionary(uniqueKeysWithValues:
            visible.map { ($0.userID, nameMap[$0.userID] ?? $0.displayName) })
        colorIndex = PeerPalette.assign(userIDs: ids, paletteCount: max(1, AuraTheme.riderPalette.count))
        monograms = RiderMonogram.assign(names: displayNames)
        leaderID = visible.max { ($0.progressMeters ?? -.infinity) < ($1.progressMeters ?? -.infinity) }?.userID
        interpolators.commit(peers: visible, now: now)
        let live = Set(ids)
        displayBearing = displayBearing.filter { live.contains($0.key) }
    }

    /// Keep the clock alive while any tween runs OR (any peer is riding and not Reduce Motion) —
    /// the second clause keeps a stationary rider's liveness pulse animating (it must not freeze
    /// just because they stopped moving).
    func shouldAnimate(now: Date) -> Bool {
        interpolators.anyActive(at: now) || (anyRiding && !reduceMotion)
    }

    /// Resolve the frame for wall-clock `now`. `project` maps a coordinate to a screen point (nil
    /// if off-screen/unavailable). Declutter is the one intentional per-frame derivation (needs live
    /// positions; O(k²), k ≤ 7). Everything else was memoised in `updateSet`.
    func frame(now: Date, project: (Coordinate) -> ClusterDeclutter.Point2D?) -> PeerFrame {
        let coords: [(RidePeer, Coordinate)] = visible.compactMap { p in
            interpolators.position(p.userID, at: now).map { (p, $0) }
        }
        let points = coords.map { project($0.1) }
        let canDeclutter = !points.isEmpty && points.allSatisfy { $0 != nil }
        let input = points.map { $0 ?? ClusterDeclutter.Point2D(x: 0, y: 0) }
        if prevClustered.count != input.count { prevClustered = Array(repeating: false, count: input.count) }
        let offsets: [ClusterDeclutter.DeclutterOffset]
        let clustered: [Bool]
        if canDeclutter {
            offsets = ClusterDeclutter.resolve(points: input, previouslyClustered: prevClustered,
                                               enterRadius: 26, leaveRadius: 40, spread: 18)
            clustered = ClusterDeclutter.clustered(points: input, previouslyClustered: prevClustered,
                                                   enterRadius: 26, leaveRadius: 40)
        } else {
            offsets = Array(repeating: .zero, count: input.count)
            clustered = Array(repeating: false, count: input.count)
        }
        prevClustered = clustered

        let pulsePhase = (anyRiding && !reduceMotion) ? triangleWave(now) : 0
        let dots: [PeerDot] = coords.enumerated().map { i, pc in
            let (peer, coord) = pc
            let shown = displayedBearing(peer.userID, raw: interpolators.bearing(peer.userID, at: now))
            return PeerDot(userID: peer.userID, coordinate: coord, bearing: shown,
                           status: peer.status, colorIndex: colorIndex[peer.userID] ?? 0,
                           monogram: monograms[peer.userID] ?? "?",
                           displayName: displayNames[peer.userID] ?? peer.displayName,
                           showsNameTag: peer.userID == leaderID || (i < clustered.count && clustered[i]),
                           offset: i < offsets.count ? offsets[i] : .zero)
        }
        return PeerFrame(dots: dots, pulsePhase: pulsePhase)
    }

    /// Deadband (~10°) so a noisy bearing doesn't jitter the pointer; Reduce Motion snaps to the
    /// 8-point compass (45° steps) so there's no continuous rotation. Holds last when direction is
    /// unknown, so a stopped dot's pointer (already hidden by status) never resets to north.
    private func displayedBearing(_ id: UUID, raw: Double?) -> Double? {
        guard let raw else { return displayBearing[id] }
        if reduceMotion {
            let coarse = (raw / 45).rounded() * 45
            displayBearing[id] = coarse
            return coarse
        }
        if let prev = displayBearing[id] {
            let diff = abs(((raw - prev) + 540).truncatingRemainder(dividingBy: 360) - 180)
            if diff < 10 { return prev }
        }
        displayBearing[id] = raw
        return raw
    }

    private func triangleWave(_ now: Date) -> Double {
        let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 1.1
        return 1 - abs(t - 1)   // 0 → 1 → 0 over 2.2 s
    }
}
