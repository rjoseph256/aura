import Foundation

/// Downsamples a coordinate list to a small, fixed-size polyline for History
/// thumbnails, so the list can draw a route shape without decoding the full track.
/// Uniform stride that always keeps the first and last points. Deterministic.
public enum TrackSimplifier {
    public static func thumbnail(from coordinates: [Coordinate], maxPoints: Int = 60) -> [Coordinate] {
        guard maxPoints >= 2 else { return Array(coordinates.prefix(1)) }
        guard coordinates.count > maxPoints else { return coordinates }
        let last = coordinates.count - 1
        return (0..<maxPoints).map { i in
            let t = Double(i) / Double(maxPoints - 1)   // 0...1, inclusive of both ends
            return coordinates[Int((t * Double(last)).rounded())]
        }
    }
}
