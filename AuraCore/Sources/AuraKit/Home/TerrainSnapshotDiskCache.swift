import Foundation

/// Pure Foundation disk cache for rendered terrain images, stored as `Data` keyed by a
/// stable `cacheKey`. Kept in AuraKit (no UIKit) so the round-trip is unit-tested on CI; the
/// app target wraps it with UIImage↔pngData. Files live in Caches/ (OS-evictable).
public struct TerrainSnapshotDiskCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for key: String) -> URL { directory.appendingPathComponent("\(key).png") }

    public func read(_ key: String) -> Data? { try? Data(contentsOf: url(for: key)) }

    public func write(_ data: Data, for key: String) {
        try? data.write(to: url(for: key), options: .atomic)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TerrainSnapshots", isDirectory: true)
    }
}
