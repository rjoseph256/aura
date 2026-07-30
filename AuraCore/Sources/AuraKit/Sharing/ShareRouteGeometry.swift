import Foundation
import AuraCore

/// Input hygiene for the share-card map snapshot (spec ROH-126 rev 4, step 1). This is
/// the real guard for `Snapshotter.camera(for:)`, which is exception-unsafe on
/// degenerate input — garbage must never reach it.
public enum ShareRouteGeometry {
    public static let maxPointsPerSegment = 600
    /// Minimum bounding span (degrees) below which a "route" is treated as stationary.
    public static let minimumSpanDegrees = 0.0002   // ~22 m

    public struct Prepared: Equatable, Sendable {
        public let segments: [[Coordinate]]
        /// FNV-1a over quantized coordinates — the route's content identity for the
        /// cache key (ride rows are upserted/backfilled/merged, so the id alone is not
        /// a route identity; spec step 2).
        public let contentHash: UInt32
    }

    public static func prepare(segments: [[Coordinate]]) -> Prepared? {
        let clean = segments
            .map { $0.filter { $0.latitude.isFinite && $0.longitude.isFinite } }
            .filter { $0.count > 1 }
        let all = clean.flatMap { $0 }
        guard all.count >= 2 else { return nil }
        guard Set(all.map(quantized)).count >= 2 else { return nil }
        let lats = all.map(\.latitude), lons = all.map(\.longitude)
        guard (lats.max()! - lats.min()!) > minimumSpanDegrees
                || (lons.max()! - lons.min()!) > minimumSpanDegrees else { return nil }
        let decimated = clean.map(decimate)
        return Prepared(segments: decimated, contentHash: contentHash(of: decimated))
    }

    /// Coordinate identity at ~1 m resolution. Numeric on purpose: distinctness and the
    /// content hash run over every point of a ride, and Double→String is a hot-path cost.
    private struct QuantizedPoint: Hashable {
        let lat: Int
        let lon: Int
    }

    private static func quantized(_ c: Coordinate) -> QuantizedPoint {
        QuantizedPoint(lat: Int((c.latitude * 1e5).rounded()), lon: Int((c.longitude * 1e5).rounded()))
    }

    /// Stride decimation that force-includes the segment's bbox-extremal points so the
    /// camera fit can't drift from the full track (spec step 1). Four slots are reserved
    /// up front so the cap holds *including* the forced extremes.
    private static func decimate(_ points: [Coordinate]) -> [Coordinate] {
        guard points.count > maxPointsPerSegment else { return points }
        var keep = Set<Int>()
        let budget = maxPointsPerSegment - 4
        let stride = Double(points.count - 1) / Double(budget - 1)
        for i in 0..<budget { keep.insert(Int((Double(i) * stride).rounded())) }
        for key in [\Coordinate.latitude, \Coordinate.longitude] {
            keep.insert(points.indices.min { points[$0][keyPath: key] < points[$1][keyPath: key] }!)
            keep.insert(points.indices.max { points[$0][keyPath: key] < points[$1][keyPath: key] }!)
        }
        return keep.sorted().map { points[$0] }
    }

    /// FNV-1a (same constants as `TerrainSnapshotRequest.fnv1a`) fed the quantized
    /// coordinate ints byte-by-byte — no intermediate string is ever built.
    private static func contentHash(of segments: [[Coordinate]]) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        func feed(_ value: Int) {
            withUnsafeBytes(of: Int64(value).littleEndian) {
                for byte in $0 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
            }
        }
        for segment in segments {
            for c in segment {
                let q = quantized(c)
                feed(q.lat)
                feed(q.lon)
            }
            hash = (hash ^ 0xFF) &* 16_777_619   // segment separator: pause gaps are identity
        }
        return hash
    }
}
