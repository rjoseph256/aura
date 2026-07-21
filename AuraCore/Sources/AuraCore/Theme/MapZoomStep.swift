import Foundation

/// Pure zoom-stepping arithmetic for the +/- map controls (ROH-57). Kept here as plain
/// values (no SwiftUI, no Mapbox) so the clamp/monotonicity invariants can be unit-tested
/// the way `HUDControlMetrics` is — the view and the Mapbox `Viewport` glue live in the app
/// target, which has no test bundle.
///
/// A tap reads the *live* camera zoom (a pinch may have moved it) and asks for the next level.
/// The range `[minZoom, maxZoom]` is the button's operating band; pinch itself is left
/// unclamped so a rider can still pinch out to frame a whole route. Stepping is monotonic:
/// past the band, `+` and `-` never reverse direction — `+` beyond the ceiling is a no-op, and
/// `-` from beyond the ceiling walks back down toward the band.
public enum MapZoomStep {
    /// Zoom levels added/removed per tap. One level is a 2× scale change — the familiar
    /// stepping of a maps +/- control.
    public static let step: Double = 1.0
    /// Furthest the button zooms out — a regional view, enough to orient without pinching.
    public static let minZoom: Double = 3.0
    /// Closest the button zooms in — building/street level.
    public static let maxZoom: Double = 20.0
    /// The zoom the ride HUDs follow the puck at, and re-follow at on recenter.
    public static let followDefault: Double = 16.0

    public enum Direction: Sendable { case zoomIn, zoomOut }

    /// The next zoom for a `+`/`-` tap from `current`, clamped into `[minZoom, maxZoom]` and
    /// never reversing direction when a pinch has already carried the camera past the band.
    public static func stepped(from current: Double, _ direction: Direction) -> Double {
        switch direction {
        case .zoomIn:  return current >= maxZoom ? current : min(maxZoom, current + step)
        case .zoomOut: return current <= minZoom ? current : max(minZoom, current - step)
        }
    }
}
