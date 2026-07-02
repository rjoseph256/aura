import Foundation

/// Resolves the Home terrain backdrop style. Pure (no MapboxMaps import) so it tests on the
/// macOS CI host; the app target bridges the authored JSON and the fallback URI to the SDK.
public enum TerrainStyle {
    /// Safe dark fallback, used only when the authored style fails to load.
    public static let fallbackStyleURI = "mapbox://styles/mapbox/dark-v11"

    /// Bump when `AuraTerrainStyle.json`'s look changes, to invalidate cached snapshots.
    public static let styleVersion = "1"

    /// Resource base name of the bundled authored style (`Aura/Resources/AuraTerrainStyle.json`).
    public static let authoredStyleResource = "AuraTerrainStyle"

    /// Cache-key identity for the authored style. Version-bearing so a restyle invalidates
    /// snapshots; also the signal the snapshotter uses to load the bundled JSON (vs a URI).
    public static var authoredStyleIdentity: String { "aura-terrain-v\(styleVersion)" }

    /// Pure selection kept for the fallback path. Tested directly.
    public static func resolve(custom: String?) -> String { custom ?? fallbackStyleURI }

    /// The fallback style URI the snapshotter uses when the authored style is unavailable.
    public static var styleURI: String { fallbackStyleURI }

    /// Whether `identity` is Aura's authored terrain style (not the fallback preset). Defined
    /// against the authored identity, so a stock Mapbox style never reads as the authored one.
    public static func isCustom(_ identity: String) -> Bool { identity.hasPrefix("aura-terrain") }
}
