import Foundation
import CoreGraphics
import ImageIO

/// A decoded Mapbox Terrain-RGB tile: a 256×256 RGBA8 buffer whose pixels
/// encode elevation as `-10000 + (R·65536 + G·256 + B) · 0.1` meters.
///
/// Extracted from the app's `TerrainTileCache` (ROH-94) and hardened so the
/// decode either produces true elevations or fails (`nil`) — never a silent
/// flat tile, which is the regression class this type exists to prevent:
/// - rejects images that are not exactly 256×256 (CGContext.draw would
///   silently rescale, interpolating R/G/B independently into garbage);
/// - rejects incomplete sources (ImageIO can render a partial image for a
///   truncated PNG, leaving undrawn all-zero rows at −10000 m);
/// - renders into the source image's own RGB colorspace so DEM bytes are
///   never color-matched (a ±1 shift in R alone is ±6553.6 m).
public struct TerrainRGBTile: Sendable {

    public static let side = 256

    /// RGBA8, row-major, 4 bytes per pixel.
    private let pixels: [UInt8]

    public init?(pngData: Data) {
        let side = Self.side
        // Both status checks matter: the source-level status can report
        // .statusComplete for complete-but-truncated in-memory data; the
        // per-image status is what flags a partially decodable PNG.
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              CGImageSourceGetStatus(src) == .statusComplete,
              CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == side, img.height == side else { return nil }
        // Draw in the source's own colorspace (fall back to sRGB for untagged
        // input) so the draw is a byte-identity transfer, not a color match.
        let space: CGColorSpace
        if let imgSpace = img.colorSpace, imgSpace.model == .rgb {
            space = imgSpace
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            space = srgb
        } else {
            return nil
        }
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        let drew = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        // Detect partially-decoded images: if the buffer is entirely zeros,
        // ImageIO yielded a partial/undrawn image (a truncated PNG with valid
        // header but incomplete data). Check that at least one RGB component
        // is non-zero across the entire tile.
        let hasNonZeroPixels = (0..<(side * side)).contains { i in
            let off = i * 4
            return buf[off] != 0 || buf[off + 1] != 0 || buf[off + 2] != 0
        }
        guard hasNonZeroPixels else { return nil }
        self.pixels = buf
    }

    /// The elevation (meters) at a pixel, or nil for out-of-range coordinates.
    public func elevation(px: Int, py: Int) -> Double? {
        let side = Self.side
        guard (0..<side).contains(px), (0..<side).contains(py) else { return nil }
        let off = (py * side + px) * 4
        let r = Double(pixels[off]), g = Double(pixels[off + 1]), b = Double(pixels[off + 2])
        return -10000.0 + (r * 65536.0 + g * 256.0 + b) * 0.1
    }
}
