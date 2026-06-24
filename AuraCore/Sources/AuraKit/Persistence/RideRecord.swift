import Foundation
import SwiftData

@Model
public final class RideRecord {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var startedAt: Date
    public var endedAt: Date?
    public var trackData: Data        // JSON-encoded [TrackPoint]
    public var statsData: Data?       // JSON-encoded RideStats
    public var routeId: UUID?
    public var destinationPlaceId: UUID?

    public init(id: UUID, kindRaw: String, startedAt: Date, endedAt: Date?,
                trackData: Data, statsData: Data?, routeId: UUID?, destinationPlaceId: UUID?) {
        self.id = id; self.kindRaw = kindRaw; self.startedAt = startedAt; self.endedAt = endedAt
        self.trackData = trackData; self.statsData = statsData
        self.routeId = routeId; self.destinationPlaceId = destinationPlaceId
    }
}
