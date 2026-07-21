import Foundation

/// Screen-space overlap handling for peer dots. Given projected dot centres, it groups those
/// that overlap (with two-radius hysteresis so membership doesn't flip-flop) and returns a
/// per-dot offset that fans a cluster evenly around its centroid so stacked riders — and their
/// name tags, which ride above the spread dots — separate. Pure geometry (no Mapbox/UIKit): the
/// app projects coordinates to points, feeds back the last membership, and applies the offsets
/// as an animated `.offset`. Input order is preserved (caller keys by `userID`).
public enum ClusterDeclutter {
    public struct Point2D: Equatable, Sendable {
        public var x: Double; public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public struct DeclutterOffset: Equatable, Sendable {
        public var dx: Double; public var dy: Double
        public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
        public static let zero = DeclutterOffset(dx: 0, dy: 0)
    }

    /// Union points into clusters with two-radius hysteresis. A pair links when closer than
    /// `enterRadius`, or — if both were previously clustered — until farther than `leaveRadius`.
    /// Order is preserved. `previouslyClustered` must be index-aligned to `points`.
    private static func clusters(_ points: [Point2D], previouslyClustered: [Bool],
                                 enterRadius: Double, leaveRadius: Double) -> [[Int]] {
        var parent = Array(points.indices)
        func find(_ i: Int) -> Int { var r = i; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        func wasClustered(_ i: Int) -> Bool { i < previouslyClustered.count && previouslyClustered[i] }
        for i in points.indices {
            for j in (i + 1)..<points.count {
                let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                let d = (dx * dx + dy * dy).squareRoot()
                let threshold = (wasClustered(i) && wasClustered(j)) ? leaveRadius : enterRadius
                if d < threshold { union(i, j) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in points.indices { groups[find(i), default: []].append(i) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    public static func clustered(points: [Point2D], previouslyClustered: [Bool],
                                 enterRadius: Double, leaveRadius: Double) -> [Bool] {
        var flags = Array(repeating: false, count: points.count)
        for group in clusters(points, previouslyClustered: previouslyClustered,
                              enterRadius: enterRadius, leaveRadius: leaveRadius) where group.count > 1 {
            for i in group { flags[i] = true }
        }
        return flags
    }

    public static func resolve(points: [Point2D], previouslyClustered: [Bool],
                               enterRadius: Double, leaveRadius: Double, spread: Double) -> [DeclutterOffset] {
        var offsets = Array(repeating: DeclutterOffset.zero, count: points.count)
        for group in clusters(points, previouslyClustered: previouslyClustered,
                             enterRadius: enterRadius, leaveRadius: leaveRadius) where group.count > 1 {
            let cx = group.map { points[$0].x }.reduce(0, +) / Double(group.count)
            let cy = group.map { points[$0].y }.reduce(0, +) / Double(group.count)
            let step = 2 * Double.pi / Double(group.count)
            for (k, idx) in group.enumerated() {                    // group is sorted → stable
                let angle = step * Double(k) - Double.pi / 2         // start at top, clockwise
                let tx = cx + spread * cos(angle)
                let ty = cy + spread * sin(angle)
                offsets[idx] = DeclutterOffset(dx: tx - points[idx].x, dy: ty - points[idx].y)
            }
        }
        return offsets
    }
}
