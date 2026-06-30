import Foundation

/// The receiver's view of every peer on the ride. Seeded from the roster so members
/// have a dot before their first point (status `awaiting`); deltas upgrade them and a
/// clock-driven `tick` ages silent peers to `dropped`. Pure value type — the @MainActor
/// session owns an instance and mutates it.
public struct LivePresenceState: Equatable, Sendable {
    private var byID: [UUID: RidePeer]
    private let droppedTimeout: TimeInterval

    public init(roster: [RidePeer], droppedTimeout: TimeInterval) {
        self.byID = Dictionary(uniqueKeysWithValues: roster.map { ($0.userID, $0) })
        self.droppedTimeout = droppedTimeout
    }

    /// Peers in a deterministic order (by userID) for stable rendering and tests.
    public var peers: [RidePeer] {
        byID.values.sorted { $0.userID.uuidString < $1.userID.uuidString }
    }

    public mutating func apply(_ payload: LivePositionPayload, now: Date) {
        var peer = byID[payload.userID]
            ?? RidePeer(userID: payload.userID, displayName: "")   // unknown peer: nameless until re-seed
        peer.coordinate = payload.coordinate
        peer.progressMeters = payload.progressMeters
        peer.motionState = payload.motionState
        peer.lastUpdate = payload.recordedAt
        peer.status = PeerStatusReducer.status(motionState: payload.motionState,
                                               lastUpdate: payload.recordedAt,
                                               now: now, droppedTimeout: droppedTimeout)
        byID[payload.userID] = peer
    }

    public mutating func remove(userID: UUID) {
        byID[userID] = nil
    }

    public mutating func tick(now: Date) {
        for (id, var peer) in byID {
            peer.status = PeerStatusReducer.status(motionState: peer.motionState,
                                                   lastUpdate: peer.lastUpdate,
                                                   now: now, droppedTimeout: droppedTimeout)
            byID[id] = peer
        }
    }
}
