import Foundation
import AuraCore

public enum RideMapper {
    public static func record(from ride: Ride) throws -> RideRecord {
        let encoder = JSONEncoder()
        return RideRecord(
            id: ride.id,
            kindRaw: ride.kind.rawValue,
            startedAt: ride.startedAt,
            endedAt: ride.endedAt,
            trackData: try encoder.encode(ride.track),
            statsData: try ride.stats.map { try encoder.encode($0) },
            routeId: ride.routeId,
            destinationPlaceId: ride.destinationPlaceId)
    }

    public static func ride(from record: RideRecord) throws -> Ride {
        let decoder = JSONDecoder()
        return Ride(
            id: record.id,
            kind: Ride.Kind(rawValue: record.kindRaw) ?? .freeRide,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            track: try decoder.decode([TrackPoint].self, from: record.trackData),
            stats: try record.statsData.map { try decoder.decode(RideStats.self, from: $0) },
            routeId: record.routeId,
            destinationPlaceId: record.destinationPlaceId)
    }
}
