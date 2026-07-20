import Testing
import Foundation
@testable import AuraKit

@Suite struct TerrainSnapshotDiskCacheTests {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachetest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func writeThenReadRoundTrips() {
        let cache = TerrainSnapshotDiskCache(directory: tmpDir())
        let payload = Data([0x1, 0x2, 0x3, 0x4])
        cache.write(payload, for: "k1")
        #expect(cache.read("k1") == payload)
    }
    @Test func missReturnsNil() {
        #expect(TerrainSnapshotDiskCache(directory: tmpDir()).read("absent") == nil)
    }
    @Test func keysAreIsolated() {
        let cache = TerrainSnapshotDiskCache(directory: tmpDir())
        cache.write(Data([0xAA]), for: "a")
        #expect(cache.read("b") == nil)
    }
    @Test func pruneEvictsOldestUntilUnderLimit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("terrain-prune-\(UUID().uuidString)", isDirectory: true)
        let cache = TerrainSnapshotDiskCache(directory: dir)
        for key in ["a", "b", "c"] {
            cache.write(Data(repeating: 0, count: 10), for: key)
            let date = Date(timeIntervalSince1970: Double(["a", "b", "c"].firstIndex(of: key)!))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: cache.url(for: key).path)
        }
        #expect(cache.totalBytes() == 30)
        cache.prune(toMaxBytes: 15)
        #expect(cache.read("a") == nil)   // oldest evicted
        #expect(cache.read("c") != nil)   // newest kept
        #expect(cache.totalBytes() <= 15)
    }
}
