import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

@MainActor
struct RideMigrationTests {
    /// A unique on-disk store URL per run; cleaned up after.
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-migration-\(UUID().uuidString).store")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    @Test func migratesV1StoreToV2BackfillingColumnsAndThumbnail() throws {
        let url = tempStoreURL()
        defer {
            for ext in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ext))
            }
        }

        let navId = UUID()
        let freeId = UUID()
        let track = (0..<200).map {
            TrackPoint(coordinate: .init(latitude: Double($0) * 0.001, longitude: Double($0) * 0.001),
                       elevation: nil, timestamp: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        let stats = RideStats(distanceMeters: 5000, movingTimeSeconds: 1800,
                              averageSpeedMetersPerSecond: 2.7, maxSpeedMetersPerSecond: 9,
                              elevationGainMeters: 120)

        // 1. Write two V1-shaped rows, then release the container.
        do {
            let cfg = ModelConfiguration(url: url)
            let v1 = try ModelContainer(for: RideSchemaV1.RideRecord.self, configurations: cfg)
            let ctx = v1.mainContext
            ctx.insert(RideSchemaV1.RideRecord(
                id: navId, kindRaw: "navigate", startedAt: Date(timeIntervalSince1970: 1000),
                endedAt: Date(timeIntervalSince1970: 2800),
                trackData: try encode(track), statsData: try encode(stats),
                destinationName: "Frick Park", routeId: nil, destinationPlaceId: nil))
            ctx.insert(RideSchemaV1.RideRecord(
                id: freeId, kindRaw: "freeRide", startedAt: Date(timeIntervalSince1970: 500),
                endedAt: nil, trackData: try encode([TrackPoint]()), statsData: nil,
                destinationName: nil, routeId: nil, destinationPlaceId: nil))
            try ctx.save()
        }

        // 2. Reopen the same file through the migration plan on V2.
        let cfg = ModelConfiguration(url: url)
        let v2 = try ModelContainer(for: RideRecord.self,
                                    migrationPlan: RideMigrationPlan.self,
                                    configurations: cfg)
        let records = try v2.mainContext.fetch(
            FetchDescriptor<RideRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))

        #expect(records.count == 2)
        let nav = try #require(records.first { $0.id == navId })
        let free = try #require(records.first { $0.id == freeId })

        // Track bytes intact.
        let decodedTrack = try JSONDecoder().decode([TrackPoint].self, from: nav.trackData)
        #expect(decodedTrack.count == 200)

        // Stat columns backfilled from the old statsData blob.
        #expect(nav.distanceMeters == 5000)
        #expect(nav.movingTimeSeconds == 1800)
        #expect(nav.elevationGainMeters == 120)
        #expect(free.distanceMeters == 0)

        // Thumbnail backfilled for the ride with a track, nil for the empty one.
        #expect(nav.thumbnailData != nil)
        #expect(free.thumbnailData == nil)
    }
}
