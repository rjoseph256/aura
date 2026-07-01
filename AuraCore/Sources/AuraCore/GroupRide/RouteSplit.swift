import Foundation

/// Splits a route's geometry into "already ridden" / "still ahead" segments at a
/// given cumulative distance, so the map can draw a dimmed-behind / bright-ahead
/// ribbon relative to the rider's own progress. Pure geometry walk — no map or
/// annotation types involved.
public enum RouteSplit {
    /// The index into `geometry` where cumulative great-circle distance first
    /// reaches `atMeters`, clamped to `0...geometry.count`.
    ///
    /// - Fewer than two points (nothing to walk) → 0.
    /// - `atMeters <= 0` → 0 (nothing ridden yet).
    /// - `atMeters` at or beyond the total route length → `geometry.count`.
    public static func splitIndex(geometry: [Coordinate], atMeters: Double) -> Int {
        guard geometry.count > 1, atMeters > 0 else { return 0 }

        var cumulative = 0.0
        for index in 1..<geometry.count {
            cumulative += Geo.distance(geometry[index - 1], geometry[index])
            if cumulative >= atMeters { return index }
        }
        return geometry.count
    }
}
