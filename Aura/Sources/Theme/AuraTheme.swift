import SwiftUI
import AuraCore

enum AuraTheme {
    // MARK: - Color roles
    // Built from the pure `AuraPalette` so the `WCAGContrast` tests in AuraCore guard the
    // exact values the app ships. Views use these roles, never raw colors.
    private static func rgb(_ c: RGBColor) -> Color {
        Color(red: c.red, green: c.green, blue: c.blue)
    }

    static let background    = rgb(AuraPalette.nearBlack)
    static let surface       = rgb(AuraPalette.panel)
    static let textPrimary   = Color(white: AuraPalette.textPrimaryWhite)
    static let textSecondary = Color(white: AuraPalette.textSecondaryWhite)
    static let accent        = rgb(AuraPalette.mint)
    static let routeLine     = rgb(AuraPalette.mint)
    static let destructive   = rgb(AuraPalette.pink)
    static let warning       = rgb(AuraPalette.amber)
    static let onAccent      = rgb(AuraPalette.inkOnMint)
    static let onDestructive = rgb(AuraPalette.inkOnPink)
    static let onWarning     = rgb(AuraPalette.inkOnAmber)
    static let border        = Color.white.opacity(AuraPalette.borderWhite)

    // MARK: - Contrast-aware resolvers
    // Scoped to high-value over-map / sunlight spots. Named apart from the constants above
    // so a call site can't silently fall back to the standard value by omitting the argument.
    static func secondaryText(_ contrast: ColorSchemeContrast) -> Color {
        Color(white: contrast == .increased
              ? AuraPalette.textSecondaryWhiteHighContrast
              : AuraPalette.textSecondaryWhite)
    }

    static func hairline(_ contrast: ColorSchemeContrast) -> Color {
        Color.white.opacity(contrast == .increased
                            ? AuraPalette.borderWhiteHighContrast
                            : AuraPalette.borderWhite)
    }

    /// Whether a floating cockpit surface should drop transparency and render solid.
    static func prefersOpaqueSurface(reduceTransparency: Bool, _ contrast: ColorSchemeContrast) -> Bool {
        reduceTransparency || contrast == .increased
    }

    /// The scrim fill for a non-material cockpit surface over the map: solid when transparency
    /// is reduced or contrast increased, otherwise a high-opacity surface that holds secondary
    /// text even over a bright sunlit map.
    static func mapScrim(reduceTransparency: Bool, _ contrast: ColorSchemeContrast) -> Color {
        prefersOpaqueSurface(reduceTransparency: reduceTransparency, contrast)
        ? surface
        : surface.opacity(AuraPalette.mapScrimOpacity)
    }

    // MARK: - Mapbox bridge
    /// `routeLine` as a UIColor so Mapbox `StyleColor(_:)` accepts it; built from the same
    /// mint token as `accent`, so the route line and the accent never drift apart.
    static let routeUIColor = UIColor(red: AuraPalette.mint.red,
                                      green: AuraPalette.mint.green,
                                      blue: AuraPalette.mint.blue, alpha: 1)

    // MARK: - Spacing scale (pt)
    enum Spacing {
        static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16
        static let xl: CGFloat = 20, xxl: CGFloat = 24, xxxl: CGFloat = 32
    }

    // MARK: - Radius scale (pt)
    enum Radius {
        static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 20
    }

    // MARK: - Cockpit font faces
    /// The bundled Saira Condensed faces, addressed by exact PostScript name.
    /// These are three separate static files; their legacy name-table entries are
    /// inconsistent across faces, so `.custom(family).weight()` can't reliably
    /// select one. Naming the PostScript face directly is deterministic.
    enum CockpitFace {
        case medium, semibold, bold
        var postScriptName: String {
            switch self {
            case .medium: "SairaCondensed-Medium"
            case .semibold: "SairaCondensed-SemiBold"
            case .bold: "SairaCondensed-Bold"
            }
        }
    }

    // MARK: - Typography roles
    enum Typography {
        /// Brand numerals (chrome): SF Pro Rounded. Pass a @ScaledMetric size for Dynamic Type.
        static func metricBrand(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static let unit = Font.system(.caption2, design: .rounded).weight(.bold)
        static func title(_ style: Font.TextStyle = .title2) -> Font {
            .system(style, design: .rounded).weight(.semibold)
        }
        /// Cockpit numerals (Saira Condensed). Scales with Dynamic Type via `relativeTo:`,
        /// so pass a plain base point size — NOT a `@ScaledMetric` value (that scales twice).
        static func metricCockpit(_ size: CGFloat,
                                  face: CockpitFace = .bold,
                                  relativeTo style: Font.TextStyle = .body) -> Font {
            .custom(face.postScriptName, size: size, relativeTo: style)
        }

        /// The large cockpit speed readout (Saira Condensed Bold). Scales with Dynamic
        /// Type via `relativeTo:`; pass a plain base point size, not a `@ScaledMetric` value.
        static func speedHero(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
            .custom(CockpitFace.bold.postScriptName, size: size, relativeTo: style)
        }
    }
}
