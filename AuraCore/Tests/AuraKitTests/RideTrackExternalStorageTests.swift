import Testing
import Foundation
import SwiftData
import AuraCore
@testable import AuraKit

/// Regression guard for ROH-64. A long ride's GPS track exceeds SwiftData's inline
/// threshold, so `@Attribute(.externalStorage) trackData` spills the JSON blob to an
/// external file and the row keeps only a small reference (the `0x02` + UUID form seen
/// in the raw `ZTRACKDATA` column). The ticket read that raw reference as "no track".
/// These tests prove the opposite: every point survives a real on-disk save →
/// container release → reopen, so the reported rides are not data loss — the track is
/// externalized and rehydrates transparently through the model layer.
///
/// `.serialized, .swiftDataSerialized`: file-backed `ModelConfiguration(url:)` stores
/// contend under full-suite parallel `swift test` (see RideMigrationTests).
@Suite("Ride track external storage", .serialized, .swiftDataSerialized)
@MainActor
struct RideTrackExternalStorageTests {
    /// A unique on-disk directory per run holding the store and its `_SUPPORT`
    /// external-data sidecar, so the whole subtree can be scanned and cleaned up.
    private func tempStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aura-track-\(UUID().uuidString)", isDirectory: true)
    }

    /// The current on-disk model set + migration plan, matching `RideStore.persistent()`
    /// (minus the CloudKit config, which tests can't use).
    private func makeStore(at url: URL) throws -> RideStore {
        let container = try ModelContainer(
            for: RideRecord.self, SavedPlaceRecord.self, RideSchemaV4.SeenGemRecord.self,
            migrationPlan: RideMigrationPlan.self,
            configurations: ModelConfiguration(url: url))
        return RideStore(container: container)
    }

    /// A track large enough to force `.externalStorage` off the inline path: 3000 points
    /// of realistic JSON is ~300 KB, well over CoreData's ~128 KB externalization
    /// threshold. Roughly the size of the ~9 km ride reported in ROH-64.
    private func longTrack(count: Int = 3000) -> [TrackPoint] {
        (0..<count).map { i in
            let offset = Double(i) * 0.00001
            let latitude: Double = 40.44 + offset
            let longitude: Double = -79.99 + offset
            let elevation: Double = 250 + Double(i % 60)
            let timestamp = Date(timeIntervalSince1970: TimeInterval(i))
            let speed: Double = 4 + Double(i % 7)
            return TrackPoint(
                coordinate: Coordinate(latitude: latitude, longitude: longitude),
                elevation: elevation,
                timestamp: timestamp,
                speedMetersPerSecond: speed)
        }
    }

    @Test func longTrackSurvivesSaveReleaseAndReopen() throws {
        let dir = tempStoreDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rides.store")

        let track = longTrack()
        let rideId = UUID()

        // 1. Save through the real production path (RideMapper.record → externalStorage
        //    trackData), then release the container so the next open is a cold read.
        do {
            let store = try makeStore(at: url)
            let ride = Ride(id: rideId, kind: .freeRide,
                            startedAt: Date(timeIntervalSince1970: 0),
                            endedAt: Date(timeIntervalSince1970: 3000),
                            track: track,
                            stats: RideStats(distanceMeters: 9300, movingTimeSeconds: 3000,
                                             averageSpeedMetersPerSecond: 3.1,
                                             maxSpeedMetersPerSecond: 11,
                                             elevationGainMeters: 180),
                            routeId: nil, destinationPlaceId: nil)
            try store.save(ride)
        }

        // 2. The blob really was externalized — the ticket's exact observation. If this
        //    fails the track went inline and the test no longer exercises the 0x02 path.
        #expect(hasExternalData(in: dir),
                "expected a SwiftData _EXTERNAL_DATA sidecar — the track should externalize")

        // 3. Reopen cold and read the full ride back. Every point must survive byte-for-byte.
        let reopened = try makeStore(at: url)
        let ride = try #require(try reopened.ride(id: rideId))
        #expect(ride.flattenedPoints.count == track.count)
        #expect(ride.flattenedPoints == track)

        // And the list read path (allRides) rehydrates the same track.
        let all = try reopened.allRides()
        #expect(all.count == 1)
        #expect(all.first?.flattenedPoints == track)
    }

    /// Reads through the store's external-data sidecar directory (`.<store>_SUPPORT/
    /// _EXTERNAL_DATA/…`) rather than hardcoding its exact name, which varies by OS.
    private func hasExternalData(in dir: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let fileURL as URL in walker
        where fileURL.deletingLastPathComponent().lastPathComponent == "_EXTERNAL_DATA" {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
    }
}
