import Testing
import Foundation
@testable import AuraCore

struct RiderPaletteTests {
    // CIELAB ΔE (76) between two sRGB colours.
    func deltaE(_ a: RGBColor, _ b: RGBColor) -> Double {
        let la = lab(a), lb = lab(b)
        return zip(la, lb).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }
    func lab(_ c: RGBColor) -> [Double] {   // [L*, a*, b*]
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.red), g = lin(c.green), b = lin(c.blue)
        let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
        let y =  r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }
    // Crude deuteranopia simulation (project onto the confusion axis) for a distinctness floor.
    func deuter(_ c: RGBColor) -> RGBColor {
        RGBColor(red: 0.625 * c.red + 0.375 * c.green,
                 green: 0.700 * c.red + 0.300 * c.green,
                 blue: 0.300 * c.green + 0.700 * c.blue)
    }

    @Test func atLeastFourRiderHues() {
        #expect(AuraPalette.riderHues.count >= 4)
    }

    @Test func riderHuesExcludeReservedTokens() {
        for h in AuraPalette.riderHues {
            #expect(h != AuraPalette.mint)   // lime = route/accent
            #expect(h != AuraPalette.amber)  // amber = warning/stopped
        }
    }

    /// Exact inequality isn't enough — a rider hue perceptually adjacent to a reserved token
    /// would still collide two meanings on the map. Enforce a ΔE gap from both.
    @Test func riderHuesStayPerceptuallyClearOfReservedTokens() {
        for h in AuraPalette.riderHues {
            #expect(deltaE(h, AuraPalette.mint) >= 15)   // route/accent
            #expect(deltaE(h, AuraPalette.amber) >= 15)  // warning/stopped
        }
    }

    @Test func riderHuesReadOnDarkBackground() {
        for h in AuraPalette.riderHues {
            #expect(WCAGContrast.ratio(h, AuraPalette.nearBlack) >= 3.0)
        }
    }

    /// The monogram is the colour-independent, CVD-safe identity cue, so its ink must stay legible
    /// on EVERY hue — including the dark ones where a fixed dark ink drops below AA. The app picks
    /// the better of a dark/light ink per hue (`AuraTheme.riderInk`); assert such a choice exists.
    @Test func aLegibleMonogramInkExistsForEveryHue() {
        let darkInk = AuraPalette.inkOnMint
        let lightInk = RGBColor.white(1.0)
        for h in AuraPalette.riderHues {
            let best = max(WCAGContrast.ratio(darkInk, h), WCAGContrast.ratio(lightInk, h))
            #expect(best >= 4.5)   // WCAG AA for the small bold monogram
        }
    }

    @Test func riderHuesAreMutuallyDistinctInNormalAndDeuteranopia() {
        let hues = AuraPalette.riderHues
        for i in hues.indices {
            for j in (i + 1)..<hues.count {
                #expect(deltaE(hues[i], hues[j]) >= 20)                         // normal vision
                #expect(deltaE(deuter(hues[i]), deuter(hues[j])) >= 12)         // red-green CVD floor
            }
        }
    }
}
