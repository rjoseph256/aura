import Foundation

public enum PeerStatus: String, Equatable, Sendable {
    case awaiting   // in the roster, no position yet
    case riding
    case stopped
    case dropped    // no signal recently (dead zone / battery / quietly gone)
}

/// A peer's render state on the live map. Display name is carried from the roster /
/// snapshot; live deltas do not repeat it.
public struct RidePeer: Equatable, Sendable {
    public let userID: UUID
    public var displayName: String
    public var coordinate: Coordinate?
    public var progressMeters: Double?
    public var motionState: MotionState?
    public var lastUpdate: Date?
    public var status: PeerStatus

    public init(userID: UUID, displayName: String, coordinate: Coordinate? = nil,
                progressMeters: Double? = nil, motionState: MotionState? = nil,
                lastUpdate: Date? = nil, status: PeerStatus = .awaiting) {
        self.userID = userID
        self.displayName = displayName
        self.coordinate = coordinate
        self.progressMeters = progressMeters
        self.motionState = motionState
        self.lastUpdate = lastUpdate
        self.status = status
    }
}

/// Receiver-side status from the position stream. No raw speed involved — the peer's
/// own `motionState` bit decides riding vs stopped; silence beyond `droppedTimeout`
/// decides dropped.
public enum PeerStatusReducer {
    public static func status(motionState: MotionState?, lastUpdate: Date?,
                              now: Date, droppedTimeout: TimeInterval) -> PeerStatus {
        guard let lastUpdate else { return .awaiting }
        if now.timeIntervalSince(lastUpdate) > droppedTimeout { return .dropped }
        switch motionState {
        case .stopped: return .stopped
        default: return .riding
        }
    }
}
