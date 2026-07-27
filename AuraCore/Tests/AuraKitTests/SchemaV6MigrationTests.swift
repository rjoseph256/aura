import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

/// Spec D2, as revised at the Pass 3 review gate. V6 redeclares `RideRecord` with an optional
/// `segmentsData` blob and a defaulted `pausedSeconds` column, which is exactly what a
/// **lightweight** stage handles — so the launch-path migration must be *inert*: it adds
/// columns, moves no data, and cannot fail.
///
/// The backfill that fills those columns is `RideSegmentBackfiller`, off the launch path. This
/// suite therefore asserts the two properties a lightweight stage owes: nothing is lost, and
/// nothing is rewritten. An un-backfilled row still has to read correctly, because that is
/// also the permanent state of any ride a V5 device records after this migration runs.
///
/// `.serialized, .swiftDataSerialized`: these are file-backed stores, and from V6 on **two
/// `@Model` classes share the CoreData entity name `RideRecord`** — `RideSchemaV2.RideRecord`
/// (V2–V5) and `RideSchemaV6.RideRecord`. CoreData caches entity descriptions process-globally
/// by name, so a concurrent suite holding the other version can bind an object to the wrong
/// one. Same hazard `SavedPlaceRecord` hit in ROH-65.
@Suite("Schema V6 migration", .serialized, .swiftDataSerialized)
@MainActor
struct SchemaV6MigrationTests {
    /// A unique directory per test holding the store and its `_SUPPORT` external-data
    /// sidecar, so the whole subtree goes away with one remove.
    private func tempStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-v6-\(UUID().uuidString)", isDirectory: true)
    }

    private func point(_ lat: Double, _ t: TimeInterval) -> TrackPoint {
        TrackPoint(coordinate: .init(latitude: lat, longitude: -79.99), elevation: 250,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    /// Opens the store at `url` on the exact V5 model set (V2's `RideRecord`, V5's
    /// `SavedPlaceRecord`, V4's `SeenGemRecord`) with no migration plan, so SwiftData stamps
    /// it as V5, and inserts the given pre-V6 rows. `cloudKitDatabase: .none` because macOS CI
    /// has no CloudKit entitlement (see `SchemaV5MigrationTests`).
    private func writeV5Store(at url: URL, rows: [(id: UUID, trackData: Data)]) throws {
        let v5 = try ModelContainer(
            for: RideSchemaV2.RideRecord.self, RideSchemaV5.SavedPlaceRecord.self,
            RideSchemaV4.SeenGemRecord.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = ModelContext(v5)
        for row in rows {
            context.insert(RideSchemaV2.RideRecord(
                id: row.id, kindRaw: "freeRide",
                startedAt: Date(timeIntervalSince1970: 1000),
                endedAt: Date(timeIntervalSince1970: 2000),
                trackData: row.trackData, statsData: nil,
                distanceMeters: 1234, movingTimeSeconds: 900, elevationGainMeters: 42,
                thumbnailData: nil, destinationName: "Frick Park",
                routeId: nil, destinationPlaceId: nil))
        }
        try context.save()
    }

    /// Reopens the same file on the current model set through the migration plan, which is
    /// what runs V5→V6.
    private func openV6(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: RideRecord.self, SavedPlaceRecord.self, SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
    }

    @Test func migratingLosesNothingAndRewritesNothing() throws {
        let dir = tempStoreDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rides.store")

        let id = UUID()
        let track = (0..<40).map { point(40.0 + Double($0) * 0.001, TimeInterval($0)) }
        let encoded = try JSONEncoder().encode(track)
        try writeV5Store(at: url, rows: [(id, encoded)])

        let context = ModelContext(try openV6(at: url))
        let record = try #require(try context.fetch(FetchDescriptor<RideRecord>()).first)

        // Every V5 column survives byte-for-byte.
        #expect(record.trackData == encoded)
        #expect(record.distanceMeters == 1234)
        #expect(record.movingTimeSeconds == 900)
        #expect(record.elevationGainMeters == 42)
        #expect(record.destinationName == "Frick Park")

        // And the stage did NO data work. This is the assertion that keeps the backfill off
        // the launch path: `ModelContainer.init` runs stages inside `AuraApp.init()`, before
        // the first frame, where a long history is a watchdog kill.
        #expect(record.segmentsData == nil,
                "the V5→V6 stage must stay lightweight — RideSegmentBackfiller owns the backfill")
        #expect(record.pausedSeconds == 0, "0 is the correct reading for every pre-pause ride")
    }

    /// An un-backfilled row is not a broken row: it is the shape every V5-recorded ride has,
    /// including ones that arrive by CloudKit long after this migration ran.
    @Test func anUnbackfilledRowStillReadsAsAWholeRide() throws {
        let dir = tempStoreDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rides.store")

        let id = UUID()
        let track = [point(40.0, 0), point(40.1, 10), point(40.2, 20)]
        try writeV5Store(at: url, rows: [(id, try JSONEncoder().encode(track))])

        let store = RideStore(container: try openV6(at: url))
        let ride = try #require(try store.ride(id: id))
        #expect(ride.segments.count == 1, "a flat track reads as one segment")
        #expect(ride.flattenedPoints == track)
        #expect(ride.pausedSeconds == 0)

        let summary = try #require(try store.summaries().first)
        #expect(summary.distanceMeters == 1234)
        #expect(summary.pausedSeconds == 0)
        #expect(try store.allRides().count == 1)
    }

    /// `trackData`'s default is `Data()` — what CloudKit materializes for a record that never
    /// carried the key — and `JSONDecoder` throws on it. `allRides()` maps over every row, so
    /// one such row must not be able to fail the fetch for every other ride with it.
    @Test func aRowWithAnEmptyTrackBlobReadsAsAnEmptyRide() throws {
        let dir = tempStoreDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rides.store")

        let emptyId = UUID()
        let goodId = UUID()
        let track = [point(40.0, 0), point(40.1, 10)]
        try writeV5Store(at: url, rows: [
            (emptyId, Data()),
            (goodId, try JSONEncoder().encode(track))
        ])

        let store = RideStore(container: try openV6(at: url))
        let all = try store.allRides()
        #expect(all.count == 2, "the empty-blob row degrades; it does not take History down")
        #expect(all.first { $0.id == emptyId }?.segments.isEmpty == true)
        #expect(all.first { $0.id == goodId }?.flattenedPoints == track)
    }
}
