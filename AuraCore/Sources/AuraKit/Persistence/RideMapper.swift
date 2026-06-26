import Foundation
import AuraCore

public enum RideMapper {
    public static func record(from ride: Ride) throws -> RideRecord {
        let encoder = JSONEncoder()
        let thumb = TrackSimplifier.thumbnail(from: ride.track.map(\.coordinate))
        return RideRecord(
            id: ride.id,
            kindRaw: ride.kind.rawValue,
            startedAt: ride.startedAt,
            endedAt: ride.endedAt,
            trackData: try encoder.encode(ride.track),
            statsData: try ride.stats.map { try encoder.encode($0) },
            distanceMeters: ride.stats?.distanceMeters ?? 0,
            movingTimeSeconds: ride.stats?.movingTimeSeconds ?? 0,
            elevationGainMeters: ride.stats?.elevationGainMeters ?? 0,
            thumbnailData: thumb.count >= 2 ? try encoder.encode(thumb) : nil,
            destinationName: ride.destinationName,
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
            destinationName: record.destinationName,
            routeId: record.routeId,
            destinationPlaceId: record.destinationPlaceId)
    }

    /// Cheap projection for the list/dashboard. Reads only denormalized columns and
    /// the small thumbnail blob; never touches `trackData`, so the external blob
    /// never faults.
    public static func summary(from record: RideRecord) -> RideSummary {
        let coords: [Coordinate]
        if let data = record.thumbnailData,
           let decoded = try? JSONDecoder().decode([Coordinate].self, from: data) {
            coords = decoded
        } else {
            coords = []
        }
        return RideSummary(
            id: record.id,
            kind: Ride.Kind(rawValue: record.kindRaw) ?? .freeRide,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            hasStats: record.statsData != nil,
            distanceMeters: record.distanceMeters,
            movingTimeSeconds: record.movingTimeSeconds,
            elevationGainMeters: record.elevationGainMeters,
            destinationName: record.destinationName,
            thumbnailCoordinates: coords)
    }
}
