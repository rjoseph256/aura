import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Test-support terrain-rgb PNG *encoder* (ROH-94). Encodes a DEM function into
/// the Mapbox terrain-rgb scheme (v = (e + 10000) / 0.1, R = v>>16, G = v>>8,
/// B = v) as an sRGB-tagged PNG. Uses CGImageDestination — a different code
/// path than TerrainRGBTile's CGImageSource/CGContext decode, so a shared bug
/// can't silently cancel.
enum TerrainRGBPNG {

    static func encode(side: Int, elevation: (_ px: Int, _ py: Int) -> Double) -> Data? {
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for py in 0..<side {
            for px in 0..<side {
                let v = Int(((elevation(px, py) + 10000.0) * 10.0).rounded())
                let off = (py * side + px) * 4
                bytes[off] = UInt8((v >> 16) & 0xFF)
                bytes[off + 1] = UInt8((v >> 8) & 0xFF)
                bytes[off + 2] = UInt8(v & 0xFF)
                // bytes[off + 3] stays 255 (opaque).
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: side, height: side,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString,
                                                          1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
