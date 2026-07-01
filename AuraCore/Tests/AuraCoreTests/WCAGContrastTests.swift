import Testing
import Foundation
import AuraCore

struct WCAGContrastTests {
    @Test func whiteOnBlackIsMaxRatio() {
        #expect(abs(WCAGContrast.ratio(.white(1), .white(0)) - 21) < 0.001)
    }

    @Test func sameColorIsOne() {
        #expect(abs(WCAGContrast.ratio(.white(0.5), .white(0.5)) - 1) < 1e-9)
    }

    @Test func ratioIsSymmetric() {
        let a = WCAGContrast.white(0.6), b = WCAGContrast.white(0.1)
        #expect(WCAGContrast.ratio(a, b) == WCAGContrast.ratio(b, a))
    }

    @Test func luminanceBounds() {
        #expect(WCAGContrast.relativeLuminance(.white(0)) == 0)
        #expect(abs(WCAGContrast.relativeLuminance(.white(1)) - 1) < 1e-9)
    }

    @Test func compositeEndpointsAreFgAndBg() {
        let fg = RGBColor(red: 1, green: 0, blue: 0)
        let bg = WCAGContrast.white(0)
        #expect(WCAGContrast.composite(fg, over: bg, alpha: 1) == fg)
        #expect(WCAGContrast.composite(fg, over: bg, alpha: 0) == bg)
    }
}

struct AuraPaletteContrastTests {
    @Test func secondaryTextClearsBodyContrast() {
        let s = WCAGContrast.white(AuraPalette.textSecondaryWhite)
        #expect(WCAGContrast.ratio(s, AuraPalette.nearBlack) >= 4.5)
        #expect(WCAGContrast.ratio(s, AuraPalette.panel) >= 4.5)
    }

    @Test func liftedSecondaryHasSunlightMargin() {
        // The 0.55 baseline was 5.97:1; the lift targets >=7:1 on background. This locks
        // the bump: reverting textSecondaryWhite to 0.55 (5.97) fails here.
        #expect(WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhite), AuraPalette.nearBlack) >= 7.0)
    }

    @Test func primaryTextClearsBodyContrast() {
        #expect(WCAGContrast.ratio(.white(AuraPalette.textPrimaryWhite), AuraPalette.nearBlack) >= 4.5)
    }

    @Test func inkOnLimeClearsBodyContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.inkOnLime, AuraPalette.lime) >= 4.5)
    }

    @Test func inkOnPinkClearsBodyContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.inkOnPink, AuraPalette.pink) >= 4.5)
    }

    @Test func limeOnBackgroundClearsContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.lime, AuraPalette.nearBlack) >= 4.5)
    }

    @Test func increasedContrastSecondaryIsStronger() {
        let std = WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhite), AuraPalette.nearBlack)
        let inc = WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhiteHighContrast), AuraPalette.nearBlack)
        #expect(inc > std)
        #expect(inc >= 7.0)
    }

    @Test func liftedSecondaryHoldsOverBrightMapScrim() {
        // Worst-case: secondary text over the map scrim (surface @ mapScrimOpacity) on a
        // bright sunlit map pixel. Documents the design's over-map target; >=4.5.
        let brightMap = WCAGContrast.white(0.75)
        let scrim = WCAGContrast.composite(AuraPalette.panel, over: brightMap, alpha: AuraPalette.mapScrimOpacity)
        let secondary = WCAGContrast.white(AuraPalette.textSecondaryWhite)
        #expect(WCAGContrast.ratio(secondary, scrim) >= 4.5)
    }

    @Test func amberClearsGraphicalContrastOnDark() {
        // Amber is a status *dot/pill* colour on the near-black map; graphical/large-text bar is 3:1.
        #expect(WCAGContrast.ratio(AuraPalette.amber, AuraPalette.nearBlack) >= 3.0)
        #expect(WCAGContrast.ratio(AuraPalette.amber, AuraPalette.panel) >= 3.0)
    }

    @Test func inkOnAmberClearsBodyContrast() {
        // Dark ink on an amber pill must clear body text 4.5:1.
        #expect(WCAGContrast.ratio(AuraPalette.inkOnAmber, AuraPalette.amber) >= 4.5)
    }
}
