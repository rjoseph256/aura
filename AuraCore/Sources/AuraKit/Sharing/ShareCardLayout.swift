import Foundation

/// The shareable ride card's fixed geometry (spec ROH-126 rev 4, §Layout). These are
/// card-local constants, deliberately not the app theme's spacing tokens: the card is a
/// fixed 360×450 pt PNG that pins its own numbers, and this package cannot see
/// `AuraTheme`. The package test measures the composed budget against the bundled
/// Saira TTFs so the numbers stay honest.
public enum ShareCardLayout {
    public static let cardSize = CGSize(width: 360, height: 450)
    public static let mapFieldSize = CGSize(width: 360, height: 240)
    public static let rasterScale: CGFloat = 3

    public static let bandHeight: CGFloat = 210
    public static let bandHorizontalPadding: CGFloat = 20
    public static let bandTopPadding: CGFloat = 12
    public static let bandBottomPadding: CGFloat = 16
    public static var bandContentHeight: CGFloat { bandHeight - bandTopPadding - bandBottomPadding }

    public static let gapXS: CGFloat = 4
    public static let gapSM: CGFloat = 8

    public static let heroPointSize: CGFloat = 48
    public static let heroUnitPointSize: CGFloat = 18
    public static let statsValuePointSize: CGFloat = 17
    public static let statsLabelPointSize: CGFloat = 13
    public static let wordmarkPointSize: CGFloat = 16
    public static let sparklineHeight: CGFloat = 40
    /// The unfinished-ride note (ROH-107) costs the band one caption2 line it has no slack for,
    /// so the sparkline yields that height instead of the band growing into the map field. The
    /// budget test measures both variants.
    public static let sparklineHeightUnfinished: CGFloat = 24

    /// Route stroke on the raster: dark casing under mint (spec §Route drawing).
    public static let routeCasingWidth: CGFloat = 8
    public static let routeStrokeWidth: CGFloat = 5

    /// Bottom strip of the snapshot excluded from acceptance sampling — covers the SDK's
    /// logo (margin 10 + height 21) and attribution chip with slack (spec step 6).
    public static let mapChromeStripHeight: CGFloat = 36
    /// Camera fit padding; bottom is larger so no stroked pixel (5 pt mint + 8 pt casing
    /// half-width) can enter the chrome band (spec step 4).
    public static let cameraPaddingTop: CGFloat = 24
    public static let cameraPaddingSides: CGFloat = 24
    public static let cameraPaddingBottom: CGFloat = 40
}
