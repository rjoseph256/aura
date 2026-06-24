/// The swappable elevation interface. v1 ships a Mapbox Tilequery-backed
/// implementation (in the app target); a self-hosted Valhalla/BRouter engine
/// that returns native elevation profiles can replace it without touching callers.
public protocol ElevationProvider: Sendable {
    /// Best-effort elevation (meters) sampled in order along `coordinates`.
    /// Returns [] when no data is available (callers treat that as "unknown / flat").
    func elevations(along coordinates: [Coordinate]) async -> [Double]
}

/// Default no-op (keeps elevation at 0). Used as a safe fallback and in tests.
public struct NullElevationProvider: ElevationProvider {
    public init() {}
    public func elevations(along coordinates: [Coordinate]) async -> [Double] { [] }
}

/// Pure, testable helper for choosing evenly-spaced sample indices when
/// downsampling a route's geometry before querying an elevation source.
public enum ElevationSampling {
    /// Returns up to `count` evenly-spaced indices into a sequence of `total`
    /// elements. Always includes the first and last index when `total >= 2`.
    /// Empty when `total == 0`. Indices are strictly increasing and unique.
    public static func sampleIndices(total: Int, count: Int) -> [Int] {
        guard total > 0 else { return [] }
        guard total > 1 else { return [0] }
        // Asking for >= as many samples as we have: just return every index.
        guard count >= 1 else { return [0, total - 1] }
        if total <= count {
            return Array(0..<total)
        }
        // Spread `count` samples across [0, total-1] inclusive.
        var indices: [Int] = []
        let last = total - 1
        for i in 0..<count {
            // Evenly spaced positions including both endpoints.
            let pos = Double(i) * Double(last) / Double(count - 1)
            indices.append(Int((pos).rounded()))
        }
        // Rounding can collide on adjacent samples; dedupe while preserving order.
        var seen = Set<Int>()
        var unique: [Int] = []
        for idx in indices where !seen.contains(idx) {
            seen.insert(idx)
            unique.append(idx)
        }
        return unique
    }
}
