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
