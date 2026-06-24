import Foundation

public struct Ride: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case navigate, freeRide }
    public var id: UUID
    public var kind: Kind
    public var startedAt: Date
    public var endedAt: Date?
    public var track: [TrackPoint]
    public var stats: RideStats?
    /// Human-readable destination (e.g. "The Church Brew Works") for a navigate ride,
    /// denormalized so History can show it without re-resolving the Place. nil for free rides.
    public var destinationName: String?
    public var routeId: UUID?
    public var destinationPlaceId: UUID?

    public init(id: UUID = UUID(), kind: Kind, startedAt: Date, endedAt: Date?,
                track: [TrackPoint], stats: RideStats?, destinationName: String? = nil,
                routeId: UUID?, destinationPlaceId: UUID?) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.track = track; self.stats = stats; self.destinationName = destinationName
        self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
    }
}
