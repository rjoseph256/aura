import Foundation

/// The lightweight projection History and the dashboard read. Carries only cheap,
/// denormalized columns, never the GPS track or the encoded stats blob.
public struct RideSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: Ride.Kind
    public let startedAt: Date
    public let endedAt: Date?
    /// True when the ride was saved with computed stats. Lets the last-ride card
    /// keep showing "—" for a statless ride instead of a real zero.
    public let hasStats: Bool
    public let distanceMeters: Double
    public let movingTimeSeconds: Double
    /// Time the rider spent paused. Active time — the number the summary will lead with — is
    /// `endedAt - startedAt - pausedSeconds` (spec D5). Denormalized beside `movingTimeSeconds`
    /// so the surfaces that come to read it never fault a blob for it.
    ///
    /// **No consumer yet.** Pass 3 persists it; Pass 4/5 render it. `WidgetSnapshot` does not
    /// carry it (or `endedAt`), so the widget will need its own shape change to show active
    /// time.
    ///
    /// `0` for every ride recorded before pause existed, and for every unpaused ride: the two
    /// are not distinguishable, which is accepted because "no pauses were recorded" is a true
    /// statement about both.
    public let pausedSeconds: Double
    /// When the pause-boundary flush last wrote this ride, or nil once the rider ends it.
    /// Non-nil means the row is a checkpoint: either a ride a kill left behind, or one still
    /// being recorded on another device. It is when *recording* stopped, which is not
    /// necessarily when the rider stopped riding — the recording may also be short, if the
    /// rider resumed and was killed later while moving.
    public let checkpointedAt: Date?
    public let elevationGainMeters: Double
    public let destinationName: String?
    /// Simplified route for the thumbnail; empty when the ride has no drawable track.
    public let thumbnailCoordinates: [Coordinate]

    public init(id: UUID, kind: Ride.Kind, startedAt: Date, endedAt: Date?,
                hasStats: Bool, distanceMeters: Double, movingTimeSeconds: Double,
                pausedSeconds: Double = 0,
                checkpointedAt: Date? = nil,
                elevationGainMeters: Double, destinationName: String?,
                thumbnailCoordinates: [Coordinate]) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.hasStats = hasStats
        self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
        self.pausedSeconds = pausedSeconds
        self.checkpointedAt = checkpointedAt
        self.elevationGainMeters = elevationGainMeters
        self.destinationName = destinationName
        self.thumbnailCoordinates = thumbnailCoordinates
    }
}

extension RideSummary {
    /// The rider never ended this ride: it is a pause checkpoint that a kill, or a ride still
    /// running on another device, left behind.
    ///
    /// The `endedAt == nil` clause is not redundant with `checkpointedAt`. It catches rows
    /// written by the PR #90 dev builds, whose `checkpoint(at:)` wrote a nil `endedAt` and no
    /// marker at all.
    public var isUnfinished: Bool { checkpointedAt != nil || endedAt == nil }
}
