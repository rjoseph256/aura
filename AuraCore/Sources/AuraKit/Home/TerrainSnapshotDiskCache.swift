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

    public static let defaultMaxBytes = 25 * 1024 * 1024

    private func pngFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))?
            .filter { $0.pathExtension == "png" } ?? []
    }

    public func totalBytes() -> Int {
        pngFiles().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    public func prune(toMaxBytes maxBytes: Int) {
        struct Entry { let url: URL; let size: Int; let modified: Date }
        let files = pngFiles().map { url -> Entry in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Entry(url: url, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        for entry in files.sorted(by: { $0.modified < $1.modified }) {
            if total <= maxBytes { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
