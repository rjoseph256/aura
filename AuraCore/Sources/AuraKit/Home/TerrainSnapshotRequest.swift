import Foundation
import AuraCore

/// A pure description of a terrain backdrop to render. `cacheKey` is stable across process
/// launches (FNV-1a over the style URI — NOT `String.hashValue`, which is per-process
/// seeded) so the disk cache actually hits on relaunch. The coordinate is quantized to a
/// ~1 km grid so GPS jitter reuses the cached image and only a real move re-renders (spec
/// open question #2); the size is bucketed to 10 pt so minor layout changes don't thrash.
public struct TerrainSnapshotRequest: Equatable, Sendable {
    public static let quantizationDegrees = 0.01        // ~1.1 km (default: GPS-jitter tolerant)
    public static let preciseQuantizationDegrees = 0.001 // ~110 m (rider-centered on-appear image)

    public let center: Coordinate
    public let styleURI: String
    public let zoom: Double
    public let widthBucket: Int
    public let heightBucket: Int
    public let cacheKey: String

    public init(center: Coordinate, styleURI: String, width: Double, height: Double,
                zoom: Double = HomeMapCamera.defaultZoom,
                quantizationDegrees: Double = TerrainSnapshotRequest.quantizationDegrees) {
        self.center = center
        self.styleURI = styleURI
        self.zoom = zoom
        let q = quantizationDegrees
        let latCell = Int((center.latitude / q).rounded())
        let lngCell = Int((center.longitude / q).rounded())
        self.widthBucket = Int((width / 10).rounded()) * 10
        self.heightBucket = Int((height / 10).rounded()) * 10
        let zoomBucket = Int((zoom * 10).rounded())
        let styleHash = Self.fnv1a(styleURI)
        self.cacheKey = "terrain-\(latCell)-\(lngCell)-z\(zoomBucket)-\(widthBucket)x\(heightBucket)-s\(styleHash)"
    }

    /// Stable 32-bit FNV-1a hash as a string. Deterministic across launches and platforms.
    static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in s.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash
    }
}

public extension TerrainSnapshotRequest {
    /// Downtown Pittsburgh — Aura's home terrain, genuinely hilly, so the locationless default
    /// reads as an intentional sample, not an empty map.
    static let curatedDefaultCenter = Coordinate(latitude: 40.4406, longitude: -79.9959)
    static func center(forRider rider: Coordinate?) -> Coordinate { rider ?? curatedDefaultCenter }
}
