import Foundation

/// Sender-derived motion state. Only this one-bit signal is shared between riders;
/// raw speed never leaves the publishing device (spec: "speed is not shared").
public enum MotionState: String, Codable, Sendable {
    case moving
    case stopped
}

/// One live position update for a rider, in domain form. The app-target Supabase
/// conformer maps the flat Realtime JSON (userID/lat/lon/progressMeters/recordedAt/
/// motionState) into this; this type is the domain payload, not the wire shape.
public struct LivePositionPayload: Codable, Equatable, Sendable {
    public let userID: UUID
    public let coordinate: Coordinate
    public let progressMeters: Double
    public let recordedAt: Date
    public let motionState: MotionState

    public init(userID: UUID, coordinate: Coordinate, progressMeters: Double,
                recordedAt: Date, motionState: MotionState) {
        self.userID = userID
        self.coordinate = coordinate
        self.progressMeters = progressMeters
        self.recordedAt = recordedAt
        self.motionState = motionState
    }
}
