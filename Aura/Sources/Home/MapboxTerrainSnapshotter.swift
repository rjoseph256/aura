import UIKit
import os
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
        guard size.width > 0, size.height > 0 else { return nil }

        let options = MapSnapshotOptions(
            size: size,
            // Fixed @3x: `UIScreen.main.scale` is deprecated and unsafe under multiple scenes.
            pixelRatio: 3,
            glyphsRasterizationOptions: GlyphsRasterizationOptions(rasterizationMode: .ideographsRasterizedLocally))
        let snapshotter = Snapshotter(options: options)

        // Authored style → load the bundled JSON; anything else (or a missing/unreadable JSON)
        // → the dark fallback preset via the URI path, so Home never breaks on a bad asset.
        let authoredJSON = TerrainStyle.isCustom(request.styleURI) ? AuraTerrainStyleLoader.json() : nil
        if let authoredJSON {
            snapshotter.styleJSON = authoredJSON
        } else {
            guard let uri = StyleURI(rawValue: TerrainStyle.fallbackStyleURI) else { return nil }
            snapshotter.styleURI = uri
        }
        snapshotter.setCamera(to: CameraOptions(
            center: CLLocationCoordinate2D(latitude: request.center.latitude,
                                            longitude: request.center.longitude),
            zoom: 12.5,
            pitch: 0))
        // Surface a style load failure (e.g. a ROH-6 authoring typo) instead of leaving the
        // caller with a silent, permanent placeholder — this is a diagnostic log only; the
        // snapshot render below still resolves to `nil` on its own failure path.
        snapshotter.onMapLoadingError.observe { error in
            print("[TerrainSnapshotter] style load error: \(error)")
        }.store(in: &tokens)

        // Setting `styleJSON` is a non-blocking assignment; wait for the style + its remote
        // sources to report loaded before capturing, or the raster can come back blank. Time out
        // so a stall still resolves (start() then renders whatever loaded — worst case blank, and
        // the cache write below is skipped on a nil image so a bad render is never memoised). The
        // gate observer lives in a LOCAL token cancelled as soon as the gate resolves, so it does
        // not accumulate in `tokens` across image() calls.
        var gateToken: AnyCancelable?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finishOnce() { done.withLock { resumed in
                if !resumed { resumed = true; cont.resume() }
            } }
            gateToken = snapshotter.onStyleLoaded.observe { _ in finishOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finishOnce() }
        }
        gateToken?.cancel()

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
