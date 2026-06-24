import Foundation
import CoreLocation
import MapboxMaps

/// Downloads a Pittsburgh tile region (dark style, z10–16) for offline display.
@MainActor
final class OfflineMapManager: ObservableObject {
    enum Phase: Equatable { case idle, downloading, finished, failed(String) }

    @Published var phase: Phase = .idle
    @Published var progress: Double = 0   // 0...1

    // Pittsburgh bounding box: SW (40.36, -80.10) — NE (40.50, -79.86)
    static let sw = CLLocationCoordinate2D(latitude: 40.36, longitude: -80.10)
    static let ne = CLLocationCoordinate2D(latitude: 40.50, longitude: -79.86)

    private let tileStore = TileStore.default
    private let offlineManager = OfflineManager()
    private var download: Cancelable?
    private static let regionId = "aura.pittsburgh"

    func downloadPittsburgh() {
        guard phase != .downloading else { return }
        phase = .downloading
        progress = 0

        // Closed bbox ring: SW → SE → NE → NW → SW
        let ring = [
            Self.sw,
            CLLocationCoordinate2D(latitude: Self.sw.latitude, longitude: Self.ne.longitude),
            Self.ne,
            CLLocationCoordinate2D(latitude: Self.ne.latitude, longitude: Self.sw.longitude),
            Self.sw
        ]
        let geometry = Geometry.polygon(Polygon([ring]))

        let descriptor = offlineManager.createTilesetDescriptor(
            for: TilesetDescriptorOptions(styleURI: .dark, zoomRange: 10...16, tilesets: nil))

        guard let loadOptions = TileRegionLoadOptions(
            geometry: geometry, descriptors: [descriptor], acceptExpired: true) else {
            phase = .failed("Could not build tile region load options")
            return
        }

        download = tileStore.loadTileRegion(
            forId: Self.regionId,
            loadOptions: loadOptions,
            progress: { progress in
                let fraction = progress.requiredResourceCount > 0
                    ? Double(progress.completedResourceCount) / Double(progress.requiredResourceCount) : 0
                Task { @MainActor in self.progress = min(max(fraction, 0), 1) }
            },
            completion: { result in
                Task { @MainActor in
                    switch result {
                    case .success: self.progress = 1; self.phase = .finished
                    case .failure(let error): self.phase = .failed(error.localizedDescription)
                    }
                }
            })

        // Optional polish: also cache the dark style itself so it renders fully offline.
        if let stylePackOptions = StylePackLoadOptions(glyphsRasterizationMode: .ideographsRasterizedLocally) {
            offlineManager.loadStylePack(for: .dark, loadOptions: stylePackOptions, completion: { _ in })
        }
    }
}
