import MapboxMaps
import AuraKit

extension AuraKit.MapStyle {
    /// The Mapbox style for this app-level map-style preference.
    /// `.auraTerrain` renders the bundled authored terrain JSON (the same asset Home's
    /// snapshotter uses via `AuraTerrainStyleLoader`), falling back to stock dark if the asset
    /// is missing or unreadable — exactly as Home falls back. `.standard` is Mapbox's colorful
    /// default; `.dark` is the night-friendly style.
    var mapboxStyle: MapboxMaps.MapStyle {
        switch self {
        case .auraTerrain:
            return AuraTerrainStyleLoader.json().map { MapboxMaps.MapStyle(json: $0) } ?? .dark
        case .dark: return .dark
        case .standard: return .standard
        }
    }
}
