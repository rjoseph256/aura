import Foundation

/// The raw mono-lime palette as plain values (no SwiftUI). The SwiftUI `AuraTheme` in
/// the app target builds its `Color` roles from these, and the `WCAGContrast` tests read
/// the same numbers, so lowering a token below its contrast target fails CI.
public enum AuraPalette {
    // Hues
    public static let nearBlack = RGBColor(red: 0.027, green: 0.031, blue: 0.047) // #07080C
    public static let panel     = RGBColor(red: 0.055, green: 0.063, blue: 0.078) // #0E1014
    public static let lime      = RGBColor(red: 0.784, green: 0.980, blue: 0.294) // #C8FA4B
    public static let pink      = RGBColor(red: 1.0, green: 0.302, blue: 0.616)   // #FF4D9D
    public static let inkOnLime = RGBColor(red: 0.086, green: 0.129, blue: 0.039) // #16210A
    public static let inkOnPink = RGBColor(red: 0.165, green: 0.012, blue: 0.078) // #2A0314

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
