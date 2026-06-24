import MapboxMaps
import AuraKit

extension AuraKit.MapStyle {
    /// The Mapbox style preset for this app-level map-style preference.
    /// `.standard` is Mapbox's colorful default; `.dark` is the night-friendly style.
    var mapboxStyle: MapboxMaps.MapStyle {
        switch self {
        case .dark: return .dark
        case .standard: return .standard
        }
    }
}
