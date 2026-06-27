import Foundation

/// An sRGB color as plain components (0...1), with no SwiftUI/UIKit dependency so it
/// builds on the macOS CI host and the contrast math is unit-testable.
public struct RGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A grayscale color, mirroring SwiftUI's `Color(white:)`.
    public static func white(_ level: Double) -> RGBColor {
        RGBColor(red: level, green: level, blue: level)
    }
}

/// Pure WCAG 2.x relative-luminance and contrast math.
public enum WCAGContrast {
    /// A grayscale color, mirroring SwiftUI's `Color(white:)`.
    public static func white(_ level: Double) -> RGBColor {
        RGBColor(red: level, green: level, blue: level)
    }

    public static func relativeLuminance(_ color: RGBColor) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    public static func ratio(_ a: RGBColor, _ b: RGBColor) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Straight-alpha composite of a translucent foreground over an opaque background.
    public static func composite(_ fg: RGBColor, over bg: RGBColor, alpha: Double) -> RGBColor {
        RGBColor(red: fg.red * alpha + bg.red * (1 - alpha),
                 green: fg.green * alpha + bg.green * (1 - alpha),
                 blue: fg.blue * alpha + bg.blue * (1 - alpha))
    }

    /// One sRGB component (0...1) linearized per the WCAG formula.
    private static func linear(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
