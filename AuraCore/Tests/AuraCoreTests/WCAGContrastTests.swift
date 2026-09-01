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

    @Test func inkOnMintClearsBodyContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.inkOnMint, AuraPalette.mint) >= 4.5)
    }

    @Test func inkOnPinkClearsBodyContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.inkOnPink, AuraPalette.pink) >= 4.5)
    }

    @Test func mintOnBackgroundClearsContrast() {
        #expect(WCAGContrast.ratio(AuraPalette.mint, AuraPalette.nearBlack) >= 4.5)
    }

    @Test func increasedContrastSecondaryIsStronger() {
        let std = WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhite), AuraPalette.nearBlack)
        let inc = WCAGContrast.ratio(.white(AuraPalette.textSecondaryWhiteHighContrast), AuraPalette.nearBlack)
        #expect(inc > std)
        #expect(inc >= 7.0)
    }

    @Test func cardHighContrastSecondaryClearsOverScrim() {
        // The share card can't honor Increase Contrast (it's a fixed PNG), so it always uses
        // the high-contrast secondary value. Its true worst case is text over the HUD scrim
        // (surface @ mapScrimOpacity) composited over the near-black route field — lock that
        // exact pairing, not just solid panel (CI otherwise only asserts the standard 0.62).
        let s = WCAGContrast.white(AuraPalette.textSecondaryWhiteHighContrast)
        let scrim = WCAGContrast.composite(AuraPalette.panel, over: AuraPalette.nearBlack,
                                           alpha: AuraPalette.mapScrimOpacity)
        #expect(WCAGContrast.ratio(s, scrim) >= 4.5)
        #expect(WCAGContrast.ratio(s, AuraPalette.nearBlack) >= 4.5)
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

    @Test func unfinishedBadgeTextClearsBodyContrastOnBothCanvases() {
        // ROH-107. The marker is secondary text on a capsule of the same colour at low alpha.
        // Its two real backdrops are the near-black canvas (History row, summary sheet) and the
        // panel (last-ride card), and the capsule lifts both toward the text — so the pair is
        // guarded on each rather than assumed from the bare-text case.
        let text = WCAGContrast.white(AuraPalette.textSecondaryWhite)
        let alpha = AuraPalette.unfinishedBadgeFillOpacity
        for canvas in [AuraPalette.nearBlack, AuraPalette.panel] {
            let capsule = WCAGContrast.composite(.white(AuraPalette.textSecondaryWhite),
                                                 over: canvas, alpha: alpha)
            #expect(WCAGContrast.ratio(text, capsule) >= 4.5)
        }
    }

    @Test func dimmedRouteIsVisibleButSubordinateOnBothBasemaps() {
        // ROH-221. The traveled portion of the navigate route is the SAME mint line at
        // `routeDimOpacity`, composited over whatever the basemap paints under it. A sanity
        // band, not a pin: the PO tunes the exact value at the visual gate, so move the token
        // inside the band rather than moving these thresholds.
        let dimOnDark = WCAGContrast.composite(AuraPalette.mint,
                                               over: AuraPalette.nearBlack,
                                               alpha: AuraPalette.routeDimOpacity)
        #expect(WCAGContrast.ratio(dimOnDark, AuraPalette.nearBlack) >= 2.0)   // visible
        #expect(WCAGContrast.ratio(AuraPalette.mint, dimOnDark) >= 3.0)        // subordinate

        // .standard map style: the dim trace must still separate from a bright basemap.
        // Stated as a dim-vs-basemap relation, because that is what "still readable on a
        // sunlit map" actually means. A mint-vs-dim threshold cannot express it: that
        // expression's ceiling over a bright basemap is 1.2996 (reached at alpha 0, where
        // the composite IS the basemap) and it falls monotonically as alpha rises, so any
        // threshold above ~1.3 is unsatisfiable and any threshold below it rewards a
        // more invisible dim.
        let bright = WCAGContrast.white(0.75)
        let dimOnBright = WCAGContrast.composite(AuraPalette.mint, over: bright,
                                                 alpha: AuraPalette.routeDimOpacity)
        // The dim trace still separates from a bright basemap...
        #expect(WCAGContrast.ratio(dimOnBright, bright) >= 1.05)
        // ...and is strictly more subordinate to it than the full-bright line is.
        #expect(WCAGContrast.ratio(dimOnBright, bright) < WCAGContrast.ratio(AuraPalette.mint, bright))
    }

    @Test func inkOnAmberClearsBodyContrast() {
        // Dark ink on an amber pill must clear body text 4.5:1.
        #expect(WCAGContrast.ratio(AuraPalette.inkOnAmber, AuraPalette.amber) >= 4.5)
    }
}
