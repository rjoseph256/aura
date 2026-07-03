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
}
