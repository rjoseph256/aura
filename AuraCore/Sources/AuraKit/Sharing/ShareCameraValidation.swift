import Foundation

/// Validation gate for the snapshot camera fit (spec ROH-126 rev 4, step 4).
/// `Snapshotter.camera(for:)` is exception-unsafe on degenerate input and returns nil or
/// non-finite fields on the paths that survive; this predicate runs over primitives so it
/// stays package-testable (`CameraOptions` is a MapboxMaps type this package cannot see).
///
/// USAGE RULE (normative): this is a *gate*, not the camera's constructor. On a pass, the
/// caller must mutate the **returned `CameraOptions`** — replacing `zoom` only — and hand
/// the whole thing to `setCamera(to:)`. It must NOT rebuild fresh options from these
/// values: the SDK-returned `padding` is the sole enforcement of the route-clear-of-chrome
/// ToS invariant, and discarding it re-fits the route into the full 360×240 field, putting
/// ~4 pt of route casing over the Mapbox logo.
public enum ShareCameraValidation {
    /// Ceiling that keeps a short route from fitting to a nonsense street-level zoom.
    public static let maxZoom: Double = 16

    public struct Validated: Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let zoom: Double
    }

    public static func validated(latitude: Double?, longitude: Double?, zoom: Double?) -> Validated? {
        guard let latitude, let longitude, let zoom,
              latitude.isFinite, longitude.isFinite, zoom.isFinite else { return nil }
        // Finiteness is guarded BEFORE the clamp: `min` propagates NaN order-dependently.
        return Validated(latitude: latitude, longitude: longitude, zoom: min(zoom, maxZoom))
    }
}
