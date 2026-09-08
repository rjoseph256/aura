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

    /// Opacity of the ridden portion of the navigate route line (ROH-221). The traveled span is
    /// the SAME mint line at the SAME width and casing as the road ahead — only this opacity
    /// separates them, so the trim boundary reads as a change in weight, not a change in shape.
    /// Gate-2-tunable within the band `WCAGContrastTests` guards (roughly 0.29...0.55): below it
    /// the traveled trace stops reading on the dark basemap, above it stops being subordinate.
    public static let routeDimOpacity = 0.35

    /// Capsule fill behind the no-end-recorded marker (ROH-107): secondary text at low alpha.
    /// Deliberately NOT `amber` — amber already carries peer-stopped and `AuraTheme.warning`
    /// (weak/lost GPS), so a paused ride under a railway bridge would light two amber elements
    /// meaning different things. Guarded on both the near-black canvas (History, summary sheet)
    /// and the panel (last-ride card) by `AuraPaletteContrastTests`.
    public static let unfinishedBadgeFillOpacity = 0.14

    // MARK: - Rider identity palette (ROH-72, widened ROH-228)
    // Muted terrain tones that read as one Aura family on dark terrain, deliberately spanning
    // a wide lightness range so red-green colour-blind riders can still tell them apart.
    // Deuteranopia collapses the red-green axis, so distinctness must come from the blue-yellow
    // axis AND lightness — hence at most one hue per warm/cool family at a given lightness (the
    // two warm tones, rust and gold, are far apart in lightness). Eight slots (ROH-114 §D3.3).
    // The three added on top of the original five — periwinkle, sage, sky — are all cool/neutral
    // because the warm axis is full: it already carries its two distinguishable lightness slots,
    // and a third warm tone collapses onto rust or gold under deuteranopia (a mid-orange measures
    // ΔE 8.5 against gold, under the floor of 12). The cool arc has its own crowding limit, and
    // it is a separate constraint: a lavender candidate was rejected not for any warm collision
    // but for colliding with the cool hues already here — ΔE 7.6 against violet under
    // deuteranopia, and 15.9 against periwinkle in normal vision.
    // NEVER includes `mint` (route/accent), `amber` (warning/stopped), or `pink` (destructive).
    // Guarded by RiderPaletteTests (ΔE distinctness in normal + simulated deuteranopia, contrast
    // on `nearBlack`, monogram-ink legibility, and clearance from all three reserved tokens).
    public static let riderHues: [RGBColor] = [
        RGBColor(red: 0.325, green: 0.812, blue: 0.847),  // cyan       #53CFD8  (cool, light)
        RGBColor(red: 0.290, green: 0.408, blue: 0.788),  // navy       #4A68C9  (cool, dark)
        RGBColor(red: 0.690, green: 0.478, blue: 0.816),  // violet     #B07AD0  (cool, mid-light)
        RGBColor(red: 0.722, green: 0.318, blue: 0.220),  // rust       #B85138  (warm, dark)
        RGBColor(red: 0.847, green: 0.722, blue: 0.369),  // gold       #D8B85E  (warm, light)
        RGBColor(red: 0.557, green: 0.608, blue: 0.878),  // periwinkle #8E9BE0  (cool, mid)
        RGBColor(red: 0.640, green: 0.780, blue: 0.640),  // sage       #A3C7A3  (green-grey, light)
        RGBColor(red: 0.251, green: 0.725, blue: 0.941)   // sky        #40BAF0  (cool, mid-light)
    ]
}
