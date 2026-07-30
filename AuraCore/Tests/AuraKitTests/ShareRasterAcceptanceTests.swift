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

    /// Deterministic seeded noise (LCG) — high per-cell stddev everywhere it's painted.
    private func paintNoise(into buffer: inout [UInt8], rows: Range<Int>, cols: Range<Int>, seed: UInt64 = 1) {
        var state = seed
        for row in rows {
            for col in cols {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buffer[row * width + col] = UInt8(truncatingIfNeeded: state >> 33)
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
        // than width*height; the guard must reject rather than misread rows.
        let padded = [UInt8](repeating: 128, count: 96 * height)
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

    func testThresholdParametersHaveSpecDefaults() {
        XCTAssertEqual(ShareRasterAcceptance.varianceThreshold, 4.0)
        XCTAssertEqual(ShareRasterAcceptance.texturedCellFraction, 0.5)
    }
}
