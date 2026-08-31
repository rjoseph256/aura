import SwiftUI
import MapboxMaps
import AuraCore

/// The live peer dots for a group ride: smooth interpolation (ROH-69) + distinct identity /
/// heading (ROH-72). A thin MapContent fragment — every per-frame decision is resolved into
/// `frame` by `PeerAnnotationDriver`, so this only rebuilds ≤7 annotations. `NavigateHUDView`
/// is the only host; `RideMapView` carried a second, dead copy until ROH-105.
struct PeerAnnotations: MapContent {
    let frame: PeerFrame

    var body: some MapContent {
        ForEvery(frame.dots, id: \.userID) { dot in
            MapViewAnnotation(coordinate: CLLocationCoordinate2D(
                latitude: dot.coordinate.latitude, longitude: dot.coordinate.longitude)) {
                PeerDotView(monogram: dot.monogram, displayName: dot.displayName, status: dot.status,
                            identityColor: AuraTheme.riderColor(dot.colorIndex),
                            identityInk: AuraTheme.riderInk(dot.colorIndex), isSelf: false,
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
    /// Screen angle (camera bearing already subtracted), not geographic — ROH-213.
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
    // Snap-on-silence must trip on the same boundary as the `.dropped` status flip (spec §3.3),
    // so the interpolator's `snapSilence` is pinned to the cadence's `droppedTimeout` rather than
    // a matching literal — the two can't silently diverge if the timeout is retuned.
    private var interpolators = PeerInterpolators(
        config: .init(snapSilence: LiveShareCadence().droppedTimeout))
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
    /// if off-screen/unavailable). `cameraBearing` is the live map rotation: annotation views are
    /// screen-aligned, so each dot's geographic bearing is converted to a screen angle here
    /// (ROH-213) — the deadband below stays in geographic space, where "the peer turned" and "the
    /// camera turned" are distinct. Declutter is the one intentional per-frame derivation (needs
    /// live positions; O(k²), k ≤ 7). Everything else was memoised in `updateSet`.
    func frame(now: Date, cameraBearing: Double,
               project: (Coordinate) -> ClusterDeclutter.Point2D?) -> PeerFrame {
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
            let shown = PeerBearing.screenAngle(
                bearing: displayedBearing(peer.userID, raw: interpolators.bearing(peer.userID, at: now)),
                cameraBearing: cameraBearing)
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

/// The peer-dot states that can actually reach the map, over a real one. Rebuilt in ROH-105:
/// the fixture this replaces (on `RideMapView`) set no `lastUpdate`, so the interpolator
/// skipped every peer and it rendered an empty map from the day it was written.
///
/// Covers riding, stopped and dropped styling; the heading pointer for the two `.riding` peers
/// (Devon is `.stopped` and Sam is `.dropped`, and `PeerDotView.showsPointer` requires
/// `.riding`, so those two correctly never show one); a single frame of the liveness pulse
/// (there's no `TimelineView` here, so it doesn't animate); monogram widening (Mara / Mira
/// collide on "M" at width 1, then separate cleanly at width 2 — "MA" / "MI"); and declutter
/// (Mara and Mira's final fixes sit ~14pt apart, inside the 26pt enter radius). The `.awaiting`
/// dot is deliberately absent: an awaiting peer has no coordinate by definition,
/// `GroupMapDots.visiblePeers` filters on exactly that, so it can never appear here. Its
/// styling is covered by `GroupRosterSheet`'s previews.
#Preview {
    @Previewable @State var viewport: Viewport = .camera(
        center: CLLocationCoordinate2D(latitude: 37.7746, longitude: -122.4186), zoom: 15)
    let now = Date()
    let driver = PeerAnnotationDriver()
    let maraID = UUID(), miraID = UUID(), devonID = UUID(), samID = UUID()
    // Devon and Sam never move between the two fixes below, so they're identical in both
    // peer sets — they stay on `PeerInterpolator`'s stationary branch and never get a bearing,
    // which is correct: neither is `.riding`.
    let devon = RidePeer(userID: devonID, displayName: "Devon",
                          coordinate: Coordinate(latitude: 37.7742, longitude: -122.4182),
                          progressMeters: 450, motionState: .stopped,
                          lastUpdate: now, status: .stopped)
    // A dropped peer keeps its last known fix; what makes it dropped is the silence since.
    let sam = RidePeer(userID: samID, displayName: "Sam",
                        coordinate: Coordinate(latitude: 37.7732, longitude: -122.4172),
                        progressMeters: 200, motionState: .stopped,
                        lastUpdate: now.addingTimeInterval(-120), status: .dropped)
    // A bearing only resolves once `PeerInterpolator.commit` has seen TWO fixes with increasing
    // `lastUpdate` (its moving branch) — a single fix always lands on the first-fix branch,
    // which sets no bearing at all. So Mara and Mira each get a prior fix ~30m back along their
    // final heading, 3s before the final fix: 30m / 3s = 10 m/s, under the interpolator's
    // 25 m/s implausibility gate and over its 0.5m coincident threshold, so `commit` takes the
    // moving branch and a bearing actually resolves.
    let priorFixTime = now.addingTimeInterval(-3)
    let priorPeers = [
        RidePeer(userID: maraID, displayName: "Mara",
                 coordinate: Coordinate(latitude: 37.77493, longitude: -122.4192),
                 progressMeters: 900, motionState: .moving,
                 lastUpdate: priorFixTime, status: .riding),
        RidePeer(userID: miraID, displayName: "Mira",
                 coordinate: Coordinate(latitude: 37.77483, longitude: -122.4191),
                 progressMeters: 880, motionState: .moving,
                 lastUpdate: priorFixTime, status: .riding),
        devon, sam
    ]
    let finalPeers = [
        RidePeer(userID: maraID, displayName: "Mara",
                 coordinate: Coordinate(latitude: 37.7752, longitude: -122.4192),
                 progressMeters: 900, motionState: .moving,
                 lastUpdate: now, status: .riding),
        RidePeer(userID: miraID, displayName: "Mira",
                 coordinate: Coordinate(latitude: 37.7751, longitude: -122.4191),
                 progressMeters: 880, motionState: .moving,
                 lastUpdate: now, status: .riding),
        devon, sam
    ]
    driver.updateSet(peers: priorPeers, selfUserID: nil, nameMap: [:],
                     reduceMotion: false, now: priorFixTime)
    driver.updateSet(peers: finalPeers, selfUserID: nil, nameMap: [:],
                     reduceMotion: false, now: now)
    // A linear stand-in for Mapbox's projection: ~10 points per 0.0001°, enough for the
    // declutter radii to mean what they mean on screen. A preview has no live MapProxy, and
    // returning nil for any peer disables declutter entirely (`canDeclutter`, above).
    let project: (Coordinate) -> ClusterDeclutter.Point2D? = { c in
        ClusterDeclutter.Point2D(x: (c.longitude + 122.4200) * 100_000,
                                 y: (37.7760 - c.latitude) * 100_000)
    }
    // The tween duration is `min(max(gap, 0.5), 8)` = 3s (the gap between the two fixes above),
    // so resolving at `now + 3s` lands exactly at t=1: the final coordinates, not the prior
    // ones. Resolving at `now` instead would render Mara/Mira mid-glide and break the declutter
    // geometry this preview claims to show.
    return Map(viewport: $viewport) {
        // A `.camera` viewport with no bearing is north-up, so the screen angle equals the raw one.
        PeerAnnotations(frame: driver.frame(now: now.addingTimeInterval(3), cameraBearing: 0,
                                            project: project))
    }
    .ignoresSafeArea()
}
