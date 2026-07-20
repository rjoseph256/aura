import UIKit
import AuraKit

/// Renders a terrain backdrop image for a request. A `@MainActor` class protocol (matching
/// the WorkoutWriting / HapticPlaying seams) so `HomeBackdrop` can be driven by a stub in
/// previews and by Mapbox at runtime.
@MainActor
protocol TerrainSnapshotRendering: AnyObject {
    func image(for request: TerrainSnapshotRequest, size: CGSize, scale: CGFloat) async -> UIImage?
}
