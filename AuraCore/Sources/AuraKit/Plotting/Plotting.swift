import CoreGraphics
import AuraCore

/// Projects a geographic polyline into view points for a map-free route thumbnail —
/// far cheaper than a live Mapbox map per list row. Pure + testable.
public enum PolylineNormalizer {
    /// Equirectangular projection (longitude scaled by cos(mean latitude) so the shape
    /// isn't stretched at city scale), fit *uniformly* into `size` minus `inset` on all
    /// sides, north-up (Y flipped). Returns `[]` for fewer than 2 points or empty size.
    public static func points(_ coords: [Coordinate], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard coords.count > 1, size.width > 0, size.height > 0 else { return [] }

        let meanLat = coords.reduce(0) { $0 + $1.latitude } / Double(coords.count)
        let k = cos(meanLat * .pi / 180)
        let xs = coords.map { $0.longitude * k }
        let ys = coords.map { $0.latitude }

        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let spanX = max(maxX - minX, 1e-12), spanY = max(maxY - minY, 1e-12)

        let availW = max(size.width - inset * 2, 1)
        let availH = max(size.height - inset * 2, 1)
        let scale = min(availW / spanX, availH / spanY)          // uniform → preserve aspect
        let drawnW = spanX * scale, drawnH = spanY * scale
        let offX = inset + (availW - drawnW) / 2
        let offY = inset + (availH - drawnH) / 2

        return (0..<coords.count).map { i in
            CGPoint(x: offX + (xs[i] - minX) * scale,
                    y: offY + (maxY - ys[i]) * scale)            // flip Y so north is up
        }
    }
}

/// Normalizes a 1-D value series (e.g. an elevation profile) into sparkline points.
/// Pure + testable.
public enum Sparkline {
    /// X is evenly spaced across the width; Y maps `[min, max] → [bottom, top]` within
    /// `inset`, so higher values sit higher. A flat series renders along the vertical
    /// center. Returns `[]` for fewer than 2 values or empty size.
    public static func points(values: [Double], in size: CGSize, inset: CGFloat) -> [CGPoint] {
        guard values.count > 1, size.width > 0, size.height > 0 else { return [] }

        let minV = values.min()!, maxV = values.max()!
        let span = maxV - minV
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
}
