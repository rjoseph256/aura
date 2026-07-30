import Foundation

/// Acceptance gate for the share-card map raster (spec ROH-126 rev 4, step 6). A raster
/// is used only when it demonstrably rendered map content: the caller downsamples the
/// bare snapshot (no route ink) to a grayscale buffer and this predicate requires
/// texture — per-cell standard deviation over a 4×4 grid — across enough of the map
/// interior. Flat fills, blank offline tiles, and partially loaded rasters all reject.
///
/// The thresholds are `let` (Swift 6 forbids nonisolated global mutable state); tuning
/// and tests pass overrides through the parameters instead. Real-map fixture crops of
/// the three styles land after device verification (plan Task 14) — the seeded-noise
/// fixtures here validate the mechanics, not the thresholds' discriminating power.
public enum ShareRasterAcceptance {
    /// Minimum per-cell grayscale standard deviation for a cell to count as textured.
    /// Tuned against a real device capture (ROH-126 verification): a fully-loaded
    /// authored-dark-terrain raster scores 1.9–5.9 per cell at the 90×60 downsample —
    /// the initial 4.0 rejected it — while a flat fill scores ~0. 1.0 keeps a wide
    /// margin in both directions; the capture is pinned as a test fixture.
    public static let stddevThreshold: Double = 1.0
    /// Minimum fraction of grid cells that must be textured for the raster to pass.
    public static let texturedCellFraction: Double = 0.5
    /// The sampled interior is scored on a 4×4 grid of cells.
    static let gridSize = 4

    /// - Parameters:
    ///   - pixels: grayscale buffer, exactly `width * height` bytes, row-major with NO
    ///     row padding (create the CGContext with `bytesPerRow: width` explicitly — a
    ///     padded buffer fails the count guard and rejects).
    ///   - excludedBottomRows: rows of the DOWNSAMPLED buffer (not raster points) cut
    ///     from the bottom before sampling — the SDK chrome strip. At the pipeline's
    ///     90×60 buffer the 36 pt strip is 9 rows.
    public static func accepts(
        pixels: [UInt8],
        width: Int,
        height: Int,
        excludedBottomRows: Int,
        stddevThreshold: Double = ShareRasterAcceptance.stddevThreshold,
        texturedCellFraction: Double = ShareRasterAcceptance.texturedCellFraction
    ) -> Bool {
        guard width > 0, height > 0, excludedBottomRows >= 0,
              pixels.count == width * height else { return false }
        let sampledHeight = height - excludedBottomRows
        guard sampledHeight >= gridSize, width >= gridSize else { return false }

        let deviations = cellDeviations(pixels: pixels, width: width, height: height,
                                        excludedBottomRows: excludedBottomRows)
        let texturedCells = deviations.filter { $0 > stddevThreshold }.count
        return Double(texturedCells) / Double(gridSize * gridSize) >= texturedCellFraction
    }

    /// The per-cell standard deviations `accepts` scores, in row-major cell order.
    /// Public so the pipeline can log real-capture statistics on rejection — threshold
    /// tuning happens against these numbers (plan Task 14). Empty on a malformed buffer.
    public static func cellDeviations(
        pixels: [UInt8], width: Int, height: Int, excludedBottomRows: Int
    ) -> [Double] {
        guard width > 0, height > 0, excludedBottomRows >= 0,
              pixels.count == width * height else { return [] }
        let sampledHeight = height - excludedBottomRows
        guard sampledHeight >= gridSize, width >= gridSize else { return [] }
        var deviations: [Double] = []
        for cellRow in 0..<gridSize {
            for cellCol in 0..<gridSize {
                let rows = (cellRow * sampledHeight / gridSize)..<((cellRow + 1) * sampledHeight / gridSize)
                let cols = (cellCol * width / gridSize)..<((cellCol + 1) * width / gridSize)
                deviations.append(standardDeviation(of: pixels, width: width, rows: rows, cols: cols))
            }
        }
        return deviations
    }

    private static func standardDeviation(
        of pixels: [UInt8], width: Int, rows: Range<Int>, cols: Range<Int>
    ) -> Double {
        var sum = 0.0, sumSquares = 0.0
        for row in rows {
            for col in cols {
                let value = Double(pixels[row * width + col])
                sum += value
                sumSquares += value * value
            }
        }
        let count = Double(rows.count * cols.count)
        guard count > 0 else { return 0 }
        let mean = sum / count
        // Clamp non-negative: near-flat cells can go epsilon-negative from FP rounding,
        // and sqrt(negative) is NaN — a silent false-reject if the threshold is ever near 0.
        return max(0, sumSquares / count - mean * mean).squareRoot()
    }
}
