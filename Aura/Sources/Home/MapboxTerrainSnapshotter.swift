import UIKit
import MapboxMaps
import AuraCore
import AuraKit

/// Renders the Home terrain backdrop via `MapboxMaps.Snapshotter` — an off-map raster, so it
/// adds no persistent live renderer and preserves the single-hoisted-map invariant (ROH-7).
/// Disk-cached (as PNG Data) by `request.cacheKey`.
@MainActor
final class MapboxTerrainSnapshotter: TerrainSnapshotRendering {
    private let cache = TerrainSnapshotDiskCache(directory: TerrainSnapshotDiskCache.defaultDirectory())
    private var tokens: Set<AnyCancelable> = []

    func image(for request: TerrainSnapshotRequest, size: CGSize) async -> UIImage? {
        if let data = cache.read(request.cacheKey), let img = UIImage(data: data) { return img }
        guard size.width > 0, size.height > 0,
              let styleURI = StyleURI(rawValue: request.styleURI) else { return nil }

        let options = MapSnapshotOptions(
            size: size,
            // Fixed @3x: `UIScreen.main.scale` is deprecated and unsafe under multiple scenes.
            pixelRatio: 3,
            glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally))
        let snapshotter = Snapshotter(options: options)
        snapshotter.styleURI = styleURI
        snapshotter.setCamera(to: CameraOptions(
            center: CLLocationCoordinate2D(latitude: request.center.latitude,
                                            longitude: request.center.longitude),
            zoom: 12.5,
            pitch: 0))
        // Surface a bad custom style URI (e.g. a ROH-6 authoring typo) instead of leaving the
        // caller with a silent, permanent placeholder — this is a diagnostic log only; the
        // snapshot render below still resolves to `nil` on its own failure path.
        snapshotter.onMapLoadingError.observe { error in
            print("[TerrainSnapshotter] style load error: \(error)")
        }.store(in: &tokens)

        let image: UIImage? = await withCheckedContinuation { continuation in
            // Retain `snapshotter` for the render's lifetime. `Snapshotter.start` captures
            // `[weak self]` internally and silently drops the completion if the instance has
            // already been deallocated — with no local strong reference (we don't store this
            // snapshotter anywhere else), that race would leak this continuation and hang the
            // `await` forever. Capturing `snapshotter` strongly inside the completion closure
            // keeps it alive until the SDK's callback actually fires.
            snapshotter.start(overlayHandler: nil) { [snapshotter] result in
                _ = snapshotter
                switch result {
                case .success(let img):
                    continuation.resume(returning: img)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
        if let image, let data = image.pngData() {
            cache.write(data, for: request.cacheKey)
        }
        return image
    }
}
