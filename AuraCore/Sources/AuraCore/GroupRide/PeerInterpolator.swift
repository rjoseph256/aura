import Foundation

/// Renders a peer dot's position/bearing by tweening between successive fixes, so the dot
/// glides instead of teleporting once per broadcast (ROH-69). Pure and deterministic: all
/// time is injected. Keyed on each fix's `recordedAt` (sender-truthful, ~monotonic, the same
/// basis presence/`droppedTimeout` use) so snap-on-silence, duration, and the ROH-66 boundary
/// stay coherent, and stale/duplicate/heartbeat fixes are filtered by one guard.
public struct PeerInterpolator: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var minDuration: TimeInterval
        public var maxDuration: TimeInterval
        public var snapSilence: TimeInterval
        public var maxSpeed: Double
        public var coincidentMeters: Double
        public init(minDuration: TimeInterval = 0.5, maxDuration: TimeInterval = 8,
                    snapSilence: TimeInterval = 40, maxSpeed: Double = 25,
                    coincidentMeters: Double = 0.5) {
            self.minDuration = minDuration; self.maxDuration = maxDuration
            self.snapSilence = snapSilence; self.maxSpeed = maxSpeed
            self.coincidentMeters = coincidentMeters
        }
    }

    private let config: Config
    private var from: Coordinate
    private var to: Coordinate
    private var startWall: Date
    private var duration: TimeInterval
    private var fromBearing: Double?
    private var toBearing: Double?
    private var lastRecordedAt: Date?
    public private(set) var didSnap: Bool

    public init(config: Config = .init()) {
        self.config = config
        self.from = Coordinate(latitude: 0, longitude: 0)
        self.to = Coordinate(latitude: 0, longitude: 0)
        self.startWall = Date(timeIntervalSince1970: 0)
        self.duration = 0
        self.lastRecordedAt = nil
        self.didSnap = false
    }

    public mutating func commit(fix: Coordinate, recordedAt: Date, now: Date) {
        guard let last = lastRecordedAt else {                 // first fix: appear in place
            from = fix; to = fix; startWall = now; duration = 0
            fromBearing = nil; toBearing = nil
            lastRecordedAt = recordedAt; didSnap = false
            return
        }
        guard recordedAt > last else { return }                // stale / duplicate / unchanged
        let gap = recordedAt.timeIntervalSince(last)
        let origin = position(at: now)                         // freeze current rendered point
        let dist = Geo.distance(origin, fix)
        let implausible = gap > 0 && (dist / gap) > config.maxSpeed
        let silent = gap > config.snapSilence

        if silent || implausible {                             // teleport: no glide, no stale cone
            from = fix; to = fix; startWall = now; duration = 0
            fromBearing = nil; toBearing = nil
            didSnap = true
        } else if dist <= config.coincidentMeters {            // heartbeat / stationary: hold, no anim
            from = fix; to = fix; startWall = now; duration = 0
            didSnap = false                                    // bearings retained (hold last heading)
        } else {
            let heading = PeerBearing.heading(from: origin, to: fix)
            fromBearing = bearing(at: now) ?? heading
            toBearing = heading
            from = origin; to = fix; startWall = now
            duration = min(max(gap, config.minDuration), config.maxDuration)
            didSnap = false
        }
        lastRecordedAt = recordedAt
    }

    public func position(at now: Date) -> Coordinate {
        guard duration > 0 else { return to }
        let t = min(max(now.timeIntervalSince(startWall) / duration, 0), 1)   // linear + clamp
        return Coordinate(latitude: from.latitude + (to.latitude - from.latitude) * t,
                          longitude: from.longitude + (to.longitude - from.longitude) * t)
    }

    public func bearing(at now: Date) -> Double? {
        guard let toB = toBearing else { return fromBearing }
        guard let fromB = fromBearing, duration > 0 else { return toB }
        let t = min(max(now.timeIntervalSince(startWall) / duration, 0), 1)
        return PeerInterpolator.angularLerp(fromB, toB, t)
    }

    public func isActive(at now: Date) -> Bool {
        duration > 0 && now.timeIntervalSince(startWall) < duration
    }

    /// Shortest-arc interpolation between two compass bearings, handling the 0/360 seam.
    public static func angularLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let r = (a + delta * t).truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

/// The receiver's set of per-peer interpolators. Commit is per-peer and guarded, so a
/// different peer moving never resets another's tween. Prunes peers that have left.
public struct PeerInterpolators: Equatable, Sendable {
    private var byID: [UUID: PeerInterpolator]
    private let config: PeerInterpolator.Config
    public init(config: PeerInterpolator.Config = .init()) {
        self.byID = [:]; self.config = config
    }

    public mutating func commit(peers: [RidePeer], now: Date) {
        var live = Set<UUID>()
        for peer in peers {
            guard let coord = peer.coordinate, let recordedAt = peer.lastUpdate else { continue }
            live.insert(peer.userID)
            var interp = byID[peer.userID] ?? PeerInterpolator(config: config)
            interp.commit(fix: coord, recordedAt: recordedAt, now: now)
            byID[peer.userID] = interp
        }
        byID = byID.filter { live.contains($0.key) }
    }

    public func position(_ id: UUID, at now: Date) -> Coordinate? { byID[id]?.position(at: now) }
    public func bearing(_ id: UUID, at now: Date) -> Double? { byID[id]?.bearing(at: now) }
    public func anyActive(at now: Date) -> Bool { byID.values.contains { $0.isActive(at: now) } }
}
