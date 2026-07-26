import CoreGraphics
import AuraCore

/// Projects a geographic polyline into view points for a map-free route thumbnail —
/// far cheaper than a live Mapbox map per list row. Pure + testable.
public enum PolylineNormalizer {
    /// Equirectangular projection (longitude scaled by cos(mean latitude) so the shape
    /// isn't stretched at city scale), fit *uniformly* into `size` minus `inset` on all
    /// sides, north-up (Y flipped). Returns `[]` for fewer than 2 points or empty size.
    public static func points(_ coords: [Coordinate], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard let transform = Transform(coords: coords, in: size, inset: inset) else { return [] }
        return coords.map(transform.apply)
    }

    /// Several runs fitted through ONE shared transform, so a paused ride's segments keep
    /// their real separation and scale instead of each filling the box (same reasoning as
    /// `Sparkline`'s shared `range`). Runs of fewer than two coordinates stroke nothing and
    /// are dropped. Single-segment input is byte-identical to the flat function above.
    public static func points(segments: [[Coordinate]], in size: CGSize,
                              inset: CGFloat) -> [[CGPoint]] {
        let runs = segments.filter { $0.count > 1 }
        guard let transform = Transform(coords: runs.flatMap { $0 }, in: size, inset: inset)
        else { return [] }
        return runs.map { $0.map(transform.apply) }
    }

    /// The projection + fit, extracted so the flat and segmented entry points cannot drift.
    private struct Transform {
        let k: Double, minX: Double, maxY: Double, scale: Double, offX: CGFloat, offY: CGFloat

        init?(coords: [Coordinate], in size: CGSize, inset: CGFloat) {
            guard coords.count > 1, size.width > 0, size.height > 0 else { return nil }

            let meanLat = coords.reduce(0) { $0 + $1.latitude } / Double(coords.count)
            // Local, not `self.k`: capturing a partially-initialized `self` in the closures
            // below is a compile error.
            let kk = cos(meanLat * .pi / 180)
            let xs = coords.map { $0.longitude * kk }
            let ys = coords.map { $0.latitude }

            let lowX = xs.min()!, maxX = xs.max()!
            let minY = ys.min()!, highY = ys.max()!
            let spanX = max(maxX - lowX, 1e-12), spanY = max(highY - minY, 1e-12)

            let availW = max(size.width - inset * 2, 1)
            let availH = max(size.height - inset * 2, 1)
            let s = min(availW / spanX, availH / spanY)   // uniform → preserve aspect
            let drawnW = spanX * s, drawnH = spanY * s

            k = kk
            minX = lowX
            maxY = highY
            scale = s
            offX = inset + (availW - drawnW) / 2
            offY = inset + (availH - drawnH) / 2
        }

        func apply(_ c: Coordinate) -> CGPoint {
            CGPoint(x: offX + (c.longitude * k - minX) * scale,
                    y: offY + (maxY - c.latitude) * scale)   // flip Y so north is up
        }
    }
}

/// Normalizes a 1-D value series (e.g. an elevation profile) into sparkline points.
/// Pure + testable.
public enum Sparkline {
    /// X is evenly spaced across the width; Y maps `range → [bottom, top]` within `inset`,
    /// so higher values sit higher. Passing an explicit `range` lets several sparklines
    /// share ONE vertical scale, so a flat series and a hilly one compare honestly. A
    /// zero/inverted span renders flat at center. Returns `[]` for < 2 values or empty size.
    public static func points(values: [Double], in size: CGSize, inset: CGFloat,
                              range: ClosedRange<Double>) -> [CGPoint] {
        guard values.count > 1, size.width > 0, size.height > 0 else { return [] }

        let minV = range.lowerBound
        let span = range.upperBound - range.lowerBound
        let availW = max(size.width - inset * 2, 1)
        let availH = max(size.height - inset * 2, 1)
        let last = CGFloat(values.count - 1)

        return values.enumerated().map { i, v in
            let x = inset + availW * CGFloat(i) / last
            let t: CGFloat = span > 1e-12 ? CGFloat((v - minV) / span) : 0.5   // flat → center
            let y = inset + availH * (1 - t)                                    // higher value → higher
            return CGPoint(x: x, y: y)
        }
    }

    /// Self-scaling variant: maps each series against its OWN min...max. Unchanged
    /// behavior for callers that don't share a scale.
    public static func points(values: [Double], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard let lo = values.min(), let hi = values.max() else { return [] }
        return points(values: values, in: size, inset: inset, range: lo...hi)
    }
}
