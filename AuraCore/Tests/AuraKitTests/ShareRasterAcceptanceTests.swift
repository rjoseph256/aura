import XCTest
@testable import AuraKit

final class ShareRasterAcceptanceTests: XCTestCase {
    /// Pipeline dimensions: the 360×240 pt raster downsampled by 4 → 90×60, with the
    /// 36 pt SDK chrome strip mapping to 9 rows of the downsampled buffer.
    private let width = 90
    private let height = 60
    private let excludedRows = 9

    private func flat(_ value: UInt8 = 128) -> [UInt8] {
        [UInt8](repeating: value, count: width * height)
    }

    /// One step of the deterministic seeded-noise stream (LCG) every fixture draws from —
    /// high per-cell stddev everywhere it's painted.
    private func seededNoise(_ state: inout UInt64) -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 33)
    }

    private func paintNoise(into buffer: inout [UInt8], rows: Range<Int>, cols: Range<Int>, seed: UInt64 = 1) {
        var state = seed
        for row in rows {
            for col in cols {
                buffer[row * width + col] = seededNoise(&state)
            }
        }
    }

    private func paintBright(into buffer: inout [UInt8], rows: Range<Int>) {
        for row in rows {
            for col in 0..<width { buffer[row * width + col] = 255 }
        }
    }

    func testRejectsFlatBuffer() {
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: flat(), width: width, height: height, excludedBottomRows: excludedRows))
    }

    func testRejectsCountMismatch() {
        // A CGContext with default bytesPerRow alignment padding produces a buffer larger
        // than width*height (96 bytes per 90 px row). The fixture is TEXTURED noise on
        // purpose: the count guard must be an exact match — a relaxed `>=` guard would
        // misread row offsets on this buffer, still find texture, and wrongly accept.
        var padded = [UInt8](repeating: 128, count: 96 * height)
        var state: UInt64 = 7
        for i in padded.indices {
            padded[i] = seededNoise(&state)
        }
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: padded, width: width, height: height, excludedBottomRows: excludedRows))
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: [], width: width, height: height, excludedBottomRows: excludedRows))
    }

    func testRejectsBrightChromeRowsInsideExcludedStrip() {
        // A flat map with only SDK chrome (logo/attribution) in the bottom strip must
        // read as blank — the strip is excluded from sampling.
        var buffer = flat()
        paintBright(into: &buffer, rows: (height - excludedRows)..<height)
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows))
    }

    func testStripBoundaryHonoredBothDirections() {
        // Signal INSIDE the strip is never counted: even a threshold that accepts on a
        // single textured cell must reject when the only texture sits in the strip.
        var inside = flat()
        paintNoise(into: &inside, rows: (height - excludedRows)..<height, cols: 0..<width)
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: inside, width: width, height: height, excludedBottomRows: excludedRows,
            texturedCellFraction: 0.01))

        // The same band of signal shifted JUST ABOVE the boundary is real map content and
        // must be counted (accepted at the same one-cell threshold).
        var above = flat()
        paintNoise(into: &above, rows: (height - 2 * excludedRows)..<(height - excludedRows), cols: 0..<width)
        XCTAssertTrue(ShareRasterAcceptance.accepts(
            pixels: above, width: width, height: height, excludedBottomRows: excludedRows,
            texturedCellFraction: 0.01))
    }

    func testAcceptsTexturedInterior() {
        var buffer = flat()
        paintNoise(into: &buffer, rows: 0..<height, cols: 0..<width)
        XCTAssertTrue(ShareRasterAcceptance.accepts(
            pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows))
    }

    func testRejectsSingleQuadrantTexture() {
        // Texture confined to one quadrant (a partially loaded raster) covers 4 of the
        // 16 grid cells — under the 0.5 textured-cell fraction, so rejected.
        var buffer = flat()
        paintNoise(into: &buffer, rows: 0..<25, cols: 0..<45)
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows))
    }

    func testSixOfSixteenCellsRejectsOnTheFourByFourGrid() {
        // Texture exactly 6 of the 16 grid cells — 3 in the top-left quadrant, 3 in the
        // bottom-right. On the spec's 4×4 grid that is 6/16 < 0.5 → reject. On a 2×2
        // grid the same buffer textures 2 of 4 quadrants (0.5) → accept, so this
        // fixture pins gridSize itself, not just the fraction.
        var buffer = flat()
        let sampledHeight = height - excludedRows
        func cellBounds(_ r: Int, _ c: Int) -> (rows: Range<Int>, cols: Range<Int>) {
            ((r * sampledHeight / 4)..<((r + 1) * sampledHeight / 4),
             (c * width / 4)..<((c + 1) * width / 4))
        }
        for (r, c) in [(0, 0), (0, 1), (1, 0), (2, 2), (2, 3), (3, 2)] {
            let bounds = cellBounds(r, c)
            paintNoise(into: &buffer, rows: bounds.rows, cols: bounds.cols,
                       seed: UInt64(r * 4 + c + 1))
        }
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows))
    }

    func testThresholdParametersHaveSpecDefaults() {
        XCTAssertEqual(ShareRasterAcceptance.stddevThreshold, 1.0)
        XCTAssertEqual(ShareRasterAcceptance.texturedCellFraction, 0.875)
        XCTAssertEqual(ShareRasterAcceptance.gridSize, 4)
    }

    // MARK: - Partial loads

    /// Half the frame blank, in each of the four orientations. This is what a missing
    /// tile column or row at the fit zoom looks like, and it is the shape the gate exists
    /// to catch. Under the original 0.5 fraction every one of these scored exactly 8/16
    /// and ACCEPTED on the `>=` — the one value between the suite's 6/16 reject case and
    /// its fully-textured accept case, and the only value the comparison actually decides.
    ///
    /// An accepted partial does not just ship one bad card: the composite is written to
    /// the disk cache, cache hits skip acceptance entirely, and there is no negative
    /// cache, so that ride serves the half-blank card from the fast path forever.
    func testRejectsHalfBlankRasterInEveryOrientation() {
        let sampledHeight = height - excludedRows
        struct Half {
            let name: String
            let rows: Range<Int>
            let cols: Range<Int>
        }
        let halves = [
            Half(name: "top", rows: 0..<(sampledHeight / 2), cols: 0..<width),
            Half(name: "bottom", rows: (sampledHeight / 2)..<sampledHeight, cols: 0..<width),
            Half(name: "left", rows: 0..<sampledHeight, cols: 0..<(width / 2)),
            Half(name: "right", rows: 0..<sampledHeight, cols: (width / 2)..<width)
        ]
        for half in halves {
            var buffer = flat()
            paintNoise(into: &buffer, rows: half.rows, cols: half.cols)
            XCTAssertEqual(
                ShareRasterAcceptance.cellDeviations(
                    pixels: buffer, width: width, height: height,
                    excludedBottomRows: excludedRows
                ).filter { $0 > ShareRasterAcceptance.stddevThreshold }.count,
                8, "\(half.name) half should texture exactly 8 of 16 cells")
            XCTAssertFalse(ShareRasterAcceptance.accepts(
                pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows),
                "a raster blank on the \(half.name) half must not ship")
        }
    }

    /// The stddev floor's real resolution, pinned so nobody re-derives the partial-load
    /// defense from it. A cell of flat background plus a SINGLE differing pixel scores
    /// well above 1.0 and counts as textured — so "textured" means "not perfectly
    /// uniform", not "rendered map content". Fourteen specks would satisfy the fraction
    /// too; what stops this buffer is that eight cells cannot reach 14/16.
    func testOneStrayPixelMakesACellCountAsTextured() {
        var buffer = flat()
        let sampledHeight = height - excludedRows
        for (r, c) in [(0, 0), (0, 1), (0, 2), (0, 3), (1, 0), (1, 1), (1, 2), (1, 3)] {
            let row = r * sampledHeight / 4
            let col = c * width / 4
            buffer[row * width + col] = 56
        }
        let textured = ShareRasterAcceptance.cellDeviations(
            pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows
        ).filter { $0 > ShareRasterAcceptance.stddevThreshold }.count
        XCTAssertEqual(textured, 8, "one pixel per cell should clear the 1.0 stddev floor")
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows))
    }

    /// The accept side keeps slack: a real map with two genuinely low-texture cells
    /// (open water, snow, a large park) still ships at 14/16.
    func testAcceptsWithTwoUntexturedCells() {
        var buffer = flat()
        let sampledHeight = height - excludedRows
        for r in 0..<4 {
            for c in 0..<4 where !(r == 0 && c == 0) && !(r == 3 && c == 3) {
                paintNoise(into: &buffer,
                           rows: (r * sampledHeight / 4)..<((r + 1) * sampledHeight / 4),
                           cols: (c * width / 4)..<((c + 1) * width / 4),
                           seed: UInt64(r * 4 + c + 1))
            }
        }
        XCTAssertTrue(ShareRasterAcceptance.accepts(
            pixels: buffer, width: width, height: height, excludedBottomRows: excludedRows))
    }

    // MARK: - Real-capture fixture (plan Task 14)

    /// The shipped threshold must accept a real, fully-loaded authored-dark-terrain
    /// raster (device capture from ROH-126 verification). The same capture REJECTED at
    /// the pre-tuning 4.0 threshold — asserting both directions pins the discriminating
    /// band (measured per-cell stddevs 1.9–5.9) so a future re-tuning can't silently
    /// drift back into rejecting legitimate dark-style maps, and a flat fill (~0) still
    /// rejects by a wide margin.
    func testRealDarkTerrainCaptureAcceptsAtShippedThreshold() throws {
        let pixels = try grayscaleFixture("sharemap-auraterrain-capture")
        XCTAssertTrue(ShareRasterAcceptance.accepts(
            pixels: pixels, width: width, height: height, excludedBottomRows: excludedRows))
        XCTAssertFalse(ShareRasterAcceptance.accepts(
            pixels: pixels, width: width, height: height, excludedBottomRows: excludedRows,
            stddevThreshold: 4.0), "the pre-tuning threshold should reject this capture")
    }

    /// Decodes a fixture PNG and downsamples it exactly as the pipeline does
    /// (90×60 DeviceGray, `bytesPerRow: width` — no row padding).
    private func grayscaleFixture(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: width * height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
