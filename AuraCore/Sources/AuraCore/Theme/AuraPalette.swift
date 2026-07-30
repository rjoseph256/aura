import Foundation

/// The raw single-accent (mint) palette as plain values (no SwiftUI). The SwiftUI `AuraTheme` in
/// the app target builds its `Color` roles from these, and the `WCAGContrast` tests read
/// the same numbers, so lowering a token below its contrast target fails CI.
public enum AuraPalette {
    // Hues
    public static let nearBlack = RGBColor(red: 0.027, green: 0.031, blue: 0.047) // #07080C
    public static let panel     = RGBColor(red: 0.055, green: 0.063, blue: 0.078) // #0E1014
    public static let mint      = RGBColor(red: 0.486, green: 0.941, blue: 0.659) // #7CF0A8
    public static let pink      = RGBColor(red: 1.0, green: 0.302, blue: 0.616)   // #FF4D9D
    public static let amber     = RGBColor(red: 0.961, green: 0.761, blue: 0.294) // #F5C24B  stopped/paused
    public static let inkOnMint = RGBColor(red: 0.043, green: 0.165, blue: 0.094) // #0B2A18
    public static let inkOnPink = RGBColor(red: 0.165, green: 0.012, blue: 0.078) // #2A0314
    public static let inkOnAmber = RGBColor(red: 0.165, green: 0.118, blue: 0.0)   // #2A1E00  ink on amber

    // Grayscale text levels (mirror SwiftUI `Color(white:)`).
    public static let textPrimaryWhite = 0.92
    public static let textSecondaryWhite = 0.62             // lifted from 0.55 (5.97 -> 7.48 on bg)
    public static let textSecondaryWhiteHighContrast = 0.80 // Increase Contrast

    // Decorative hairline (white opacity over the dark background).
    public static let borderWhite = 0.14                    // firmed from 0.08
    public static let borderWhiteHighContrast = 0.24

    // Cockpit scrim over the map: surface opacity in the non-opaque branch.
    public static let mapScrimOpacity = 0.85

    /// Capsule fill behind the no-end-recorded marker (ROH-107): secondary text at low alpha.
    /// Deliberately NOT `amber` — amber already carries peer-stopped and `AuraTheme.warning`
    /// (weak/lost GPS), so a paused ride under a railway bridge would light two amber elements
    /// meaning different things. Guarded on both the near-black canvas (History, summary sheet)
    /// and the panel (last-ride card) by `AuraPaletteContrastTests`.
    public static let unfinishedBadgeFillOpacity = 0.14

    // MARK: - Rider identity palette (ROH-72)
    // Muted terrain tones that read as one Aura family on dark terrain, deliberately spanning
    // a wide lightness range so red-green colour-blind riders can still tell them apart.
    // Deuteranopia collapses the red-green axis, so distinctness must come from the blue-yellow
    // axis AND lightness — hence at most one hue per warm/cool family at a given lightness (the
    // two warm tones, rust and gold, are far apart in lightness). NEVER includes `mint`
    // (route/accent) or `amber` (warning/stopped). Guarded by RiderPaletteTests (ΔE distinctness
    // in normal + simulated deuteranopia, and contrast on `nearBlack`).
    public static let riderHues: [RGBColor] = [
        RGBColor(red: 0.325, green: 0.812, blue: 0.847),  // cyan    #53CFD8  (cool, light)
        RGBColor(red: 0.290, green: 0.408, blue: 0.788),  // navy    #4A68C9  (cool, dark)
        RGBColor(red: 0.690, green: 0.478, blue: 0.816),  // violet  #B07AD0  (cool, mid-light)
        RGBColor(red: 0.722, green: 0.318, blue: 0.220),  // rust    #B85138  (warm, dark)
        RGBColor(red: 0.847, green: 0.722, blue: 0.369)   // gold    #D8B85E  (warm, light)
    ]
}
