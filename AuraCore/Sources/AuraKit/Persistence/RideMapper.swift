import Foundation
import os
import AuraCore

public enum RideMapper {
    private static let log = Logger(subsystem: "app.aura.kit", category: "persistence")

    public static func record(from ride: Ride) throws -> RideRecord {
        let encoder = JSONEncoder()
        // Dual-write (spec D2). `segmentsData` carries the segmented truth; `trackData` and
        // `thumbnailData` stay FLAT and complete, because a V5 build syncing the same CloudKit
        // record reads those two and nothing else — and `thumbnailData` is decoded there with
        // a bare `try?` that falls back to blank (D3), so a shape change would silently blank
        // History on a mixed-version fleet rather than failing loudly.
        let points = ride.flattenedPoints
        let thumb = TrackSimplifier.thumbnail(from: points.map(\.coordinate))
        return RideRecord(
            id: ride.id,
            kindRaw: ride.kind.rawValue,
            startedAt: ride.startedAt,
            endedAt: ride.endedAt,
            trackData: try encoder.encode(points),
            segmentsData: try encoder.encode(ride.segments),
            statsData: try ride.stats.map { try encoder.encode($0) },
            distanceMeters: ride.stats?.distanceMeters ?? 0,
            movingTimeSeconds: ride.stats?.movingTimeSeconds ?? 0,
            pausedSeconds: ride.pausedSeconds,
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
            segments: try segments(from: record, decoder: decoder),
            stats: try record.statsData.map { try decoder.decode(RideStats.self, from: $0) },
            pausedSeconds: record.pausedSeconds,
            destinationName: record.destinationName,
            routeId: record.routeId,
            destinationPlaceId: record.destinationPlaceId)
    }

    /// Prefers `segmentsData`, and degrades to wrapping the flat `trackData` when it is absent
    /// — a row written before V6, or synced from a V5 device — **and** when it is present but
    /// unreadable.
    ///
    /// Degrading rather than throwing is the point: `RideStore.allRides()` calls
    /// `ride(from:)` inside a `.map`, so one throw is not one bad ride, it is an empty History
    /// for every ride the rider owns. The one throw left is a `trackData` blob that is
    /// non-empty and undecodable, which is pre-existing behavior for a corrupt track and is
    /// deliberately not widened here into a silent blank ride.
    private static func segments(from record: RideRecord, decoder: JSONDecoder) throws -> [RideSegment] {
        if let data = record.segmentsData {
            if let decoded = try? decoder.decode([RideSegment].self, from: data) { return decoded }
            log.error("""
                segmentsData unreadable for ride \(record.id, privacy: .public) \
                (\(data.count) bytes); falling back to the flat track, pause boundaries lost
                """)
        }
        // An EMPTY blob is an empty ride, not a corrupt one: `trackData`'s default is `Data()`,
        // which is what CloudKit materializes for a record that never carried the key, and
        // JSONDecoder throws on it.
        guard !record.trackData.isEmpty else { return [] }
        let points = try decoder.decode([TrackPoint].self, from: record.trackData)
        // Zero points is ZERO segments, never one empty segment — `Ride`'s canonical encoding.
        return points.isEmpty ? [] : [RideSegment(points: points)]
    }

    /// Cheap projection for the list/dashboard. Reads only denormalized columns and
    /// the small thumbnail blob; never touches `trackData` or `segmentsData`, so neither
    /// external blob faults.
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
            pausedSeconds: record.pausedSeconds,
            elevationGainMeters: record.elevationGainMeters,
            destinationName: record.destinationName,
            thumbnailCoordinates: coords)
    }
}
