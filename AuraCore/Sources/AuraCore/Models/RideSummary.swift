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
    /// Time the rider spent paused. Active time — the number the summary leads with — is
    /// `endedAt - startedAt - pausedSeconds` (spec D5). Denormalized beside
    /// `movingTimeSeconds` so History and the weekly widget read it without faulting a blob.
    ///
    /// `0` for every ride recorded before pause existed, and for every unpaused ride: the two
    /// are not distinguishable, which is accepted because "no pauses were recorded" is a true
    /// statement about both.
    public let pausedSeconds: Double
    public let elevationGainMeters: Double
    public let destinationName: String?
    /// Simplified route for the thumbnail; empty when the ride has no drawable track.
    public let thumbnailCoordinates: [Coordinate]

    public init(id: UUID, kind: Ride.Kind, startedAt: Date, endedAt: Date?,
                hasStats: Bool, distanceMeters: Double, movingTimeSeconds: Double,
                pausedSeconds: Double = 0,
                elevationGainMeters: Double, destinationName: String?,
                thumbnailCoordinates: [Coordinate]) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.hasStats = hasStats
        self.distanceMeters = distanceMeters; self.movingTimeSeconds = movingTimeSeconds
        self.pausedSeconds = pausedSeconds
        self.elevationGainMeters = elevationGainMeters
        self.destinationName = destinationName
        self.thumbnailCoordinates = thumbnailCoordinates
    }
}
