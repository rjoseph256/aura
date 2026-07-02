import Foundation

/// Resolves which Mapbox style the Home terrain backdrop renders. Pure (no MapboxMaps import)
/// so it tests on the macOS CI host; the app target bridges the URI to a `StyleURI`. The
/// custom Studio style is ROH-6's authored deliverable — until it is published the resolver
/// degrades to a dark fallback so the snapshotter always has a valid style.
public enum TerrainStyle {
    /// Safe dark fallback used until the authored terrain style is pasted in.
    public static let fallbackStyleURI = "mapbox://styles/mapbox/dark-v11"

    /// Authored custom terrain style URI (ROH-6). Set to the published
    /// `mapbox://styles/aura/<id>` once the Studio style ships. `nil` → fallback.
    static let customStyleURI: String? = nil

    /// Pure selection: custom when present, else fallback. Tested directly.
    public static func resolve(custom: String?) -> String { custom ?? fallbackStyleURI }

    /// The style the backdrop should render right now.
    public static var styleURI: String { resolve(custom: customStyleURI) }

    /// Whether `uri` is an Aura-authored terrain style (feeds the "real terrain" gate).
    /// Defined against the authored namespace, not "not the fallback", so a stock Mapbox
    /// style never passes the gate.
    public static func isCustom(_ uri: String) -> Bool { uri.hasPrefix("mapbox://styles/aura/") }
}
