import SwiftUI

enum AuraTheme {
    // MARK: - Private palette (raw values — views use the roles below, never these)
    private enum Palette {
        static let nearBlack = Color(red: 0.027, green: 0.031, blue: 0.047) // #07080C
        static let panel     = Color(red: 0.055, green: 0.063, blue: 0.078) // #0E1014
        static let lime      = Color(red: 0.784, green: 0.980, blue: 0.294) // #C8FA4B
        static let pink      = Color(red: 1.0, green: 0.302, blue: 0.616) // #FF4D9D
        static let inkOnLime = Color(red: 0.086, green: 0.129, blue: 0.039) // #16210A
        static let inkOnPink = Color(red: 0.165, green: 0.012, blue: 0.078) // #2A0314
    }

    // MARK: - Color roles
    static let background    = Palette.nearBlack
    static let surface       = Palette.panel
    static let textPrimary   = Color(white: 0.92)
    static let textSecondary = Color(white: 0.55)
    static let accent        = Palette.lime
    static let routeLine     = Palette.lime
    static let destructive   = Palette.pink
    static let onAccent      = Palette.inkOnLime
    static let onDestructive = Palette.inkOnPink
    static let border = Color.white.opacity(0.08)

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

    // MARK: - Deprecated — removed in the final cleanup task once all call sites migrate.
    static let bg = background
    static let cyan   = Palette.lime
    static let violet = Palette.lime
    static let pink   = destructive
    static let route  = Palette.lime
    static let text   = textPrimary
    static let muted  = textSecondary
    static let auroraGradient = LinearGradient(colors: [accent, accent], startPoint: .leading, endPoint: .trailing)
    static func heroNumber(_ size: CGFloat = 52) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static let unitLabel = Typography.unit
}
