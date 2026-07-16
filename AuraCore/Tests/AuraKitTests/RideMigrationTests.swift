import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

// .serialized: this suite includes a file-backed ModelConfiguration(url:) migration test, and
// running it concurrently with other SwiftData suites under full-suite parallel `swift test`
// causes intermittent CoreData/temp-store contention crashes (passes in isolation/on re-run).
@Suite("Ride migration", .serialized, .swiftDataSerialized)
@MainActor
struct RideMigrationTests {
    /// A unique on-disk store URL per run; cleaned up after.
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-migration-\(UUID().uuidString).store")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    /// Writes two V1-shaped rows to `url`, then releases the container.
    private func writeV1Rows(navId: UUID, freeId: UUID, track: [TrackPoint], stats: RideStats,
                             url: URL) throws {
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
        try writeV1Rows(navId: navId, freeId: freeId, track: track, stats: stats, url: url)

        // 2. Reopen the same file through the migration plan on the current schema (all
        // live model types, so the destination resolves unambiguously and every lightweight
        // stage after V2→V3 runs too).
        let cfg = ModelConfiguration(url: url)
        let v2 = try ModelContainer(for: RideRecord.self, SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self,
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

        // The V2→V3 lightweight stage ran: the new entity is live in the same store.
        let context = v2.mainContext
        context.insert(SavedPlaceRecord(SavedPlace(
            name: "Post-migration save", subtitle: nil,
            coordinate: Coordinate(latitude: 40.44, longitude: -79.99),
            category: .custom, kind: .favorite,
            savedAt: Date(timeIntervalSince1970: 1))))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SavedPlaceRecord>()).count == 1)
    }

    /// The path every new user hits: a brand-new store opened through the migration
    /// plan should start cleanly on V2 and round-trip a saved ride.
    @Test func freshStoreThroughMigrationPlanWorks() throws {
        let container = try ModelContainer(
            for: RideRecord.self, SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = RideStore(container: container)
        let ride = Ride(kind: .freeRide, startedAt: Date(timeIntervalSince1970: 0),
                        endedAt: Date(timeIntervalSince1970: 60), track: [], stats: nil,
                        routeId: nil, destinationPlaceId: nil)
        try store.save(ride)
        #expect(try store.allRides().count == 1)
    }
}
