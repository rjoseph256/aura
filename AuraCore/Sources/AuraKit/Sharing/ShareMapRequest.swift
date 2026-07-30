import Foundation
import AuraCore

/// A pure description of the share-card map snapshot to render (spec ROH-126 rev 4,
/// §`ShareMapRasterProviding`). Construction runs the input hygiene
/// (`ShareRouteGeometry.prepare`) so a request that exists is safe to hand to
/// `Snapshotter.camera(for:)`; degenerate routes never become requests, and
/// out-of-range coordinates are dropped by `ShareRouteGeometry.prepare`.
///
/// `cacheKey` is an FNV-1a digest, filename-safe by construction — raw style URIs
/// contain `/` and `:`, which silently break `TerrainSnapshotDiskCache`'s
/// key-as-filename writes.
public struct ShareMapRequest: Equatable, Sendable {
    /// Version of the composited route treatment, part of the cache identity. The cache
    /// stores the COMPOSITED image (map raster + casing + mint route stroke), not the
    /// bare snapshot — so any change to the route treatment (stroke widths, colors,
    /// caps/joins) must bump this or stale-styled cards would be served forever.
    public static let compositeVersion = 1

    public let rideID: UUID
    /// Hygiene-passed, decimated route — the one geometry the pipeline may use.
    public let route: ShareRouteGeometry.Prepared
    public let style: MapStyle
    /// Raster size in points — always `ShareCardLayout.mapFieldSize`. Deliberately not
    /// configurable: the card is fixed-geometry, and downstream code treats this as a
    /// constant (the 90×60 acceptance downsample; `MapSnapshotOptions` preconditions
    /// crash outright on bad values).
    public let size: CGSize
    /// Pixel ratio for the snapshot — always `ShareCardLayout.rasterScale`, for the
    /// same reason as `size`.
    public let scale: CGFloat
    public let cacheKey: String

    /// Fails when the route is degenerate (empty, single point, stationary, non-finite)
    /// — `nil` means: no map request exists; the card keeps the polyline fallback.
    /// Size and scale are pinned internally to the `ShareCardLayout` constants.
    public init?(rideID: UUID, segments: [[Coordinate]], style: MapStyle) {
        guard let route = ShareRouteGeometry.prepare(segments: segments) else { return nil }
        self.rideID = rideID
        self.route = route
        self.style = style
        self.size = ShareCardLayout.mapFieldSize
        self.scale = ShareCardLayout.rasterScale
        self.cacheKey = Self.cacheKey(rideID: rideID, route: route, style: style,
                                      size: self.size, scale: self.scale,
                                      compositeVersion: Self.compositeVersion)
    }

    /// Cache-key identity for a map style. Derived from the AuraKit case — the SDK's
    /// `MapStyle.data` is internal. The authored terrain identity is version-bearing,
    /// so a restyle invalidates cached share cards the same way it does Home snapshots.
    static func styleIdentity(_ style: MapStyle) -> String {
        switch style {
        case .auraTerrain: TerrainStyle.authoredStyleIdentity
        case .dark: "style-dark"
        case .standard: "style-standard"
        }
    }

    static func cacheKey(rideID: UUID, route: ShareRouteGeometry.Prepared, style: MapStyle,
                         size: CGSize, scale: CGFloat,
                         compositeVersion: Int = ShareMapRequest.compositeVersion) -> String {
        let identity = [
            rideID.uuidString,
            String(route.contentHash),
            styleIdentity(style),
            "v\(compositeVersion)",
            "\(Int(size.width))x\(Int(size.height))@\(Int(scale))"
        ].joined(separator: "|")
        return "sharemap-\(TerrainSnapshotRequest.fnv1a(identity))"
    }
}
