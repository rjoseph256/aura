import XCTest
import CoreText
@testable import AuraKit

/// Measures the share card's readout-band budget against the real Saira Condensed TTFs
/// bundled as test resources — an actual CoreText measurement, not arithmetic over the
/// spec's own constants (spec ROH-126 rev 4, §Layout).
final class ShareCardLayoutTests: XCTestCase {
    private func lineBox(fontResource: String, size: CGFloat) throws -> CGFloat {
        let url = try XCTUnwrap(Bundle.module.url(forResource: fontResource, withExtension: "ttf"))
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        let desc = try XCTUnwrap(descriptors?.first)
        let font = CTFontCreateWithFontDescriptor(desc, size, nil)
        return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    func testGeometryInvariants() {
        XCTAssertEqual(ShareCardLayout.cardSize, CGSize(width: 360, height: 450))
        XCTAssertEqual(ShareCardLayout.mapFieldSize, CGSize(width: 360, height: 240))
        XCTAssertEqual(ShareCardLayout.mapFieldSize.height + ShareCardLayout.bandHeight,
                       ShareCardLayout.cardSize.height)
        XCTAssertGreaterThanOrEqual(ShareCardLayout.mapChromeStripHeight, 36) // spec step 6
    }

    func testBandBudgetFitsWithMeasuredSairaLineBoxes() throws {
        let hero = try lineBox(fontResource: "SairaCondensed-Bold", size: ShareCardLayout.heroPointSize)
        let stats = try lineBox(fontResource: "SairaCondensed-SemiBold", size: ShareCardLayout.statsValuePointSize)
        // Context row is SF (system); its measured box is a 16.0 pt line at caption/Large.
        // Use a conservative 16.5 rather than shipping an SF copy into test resources.
        let contextCeiling: CGFloat = 16.5
        let total = contextCeiling + ShareCardLayout.gapXS + hero + ShareCardLayout.gapSM
            + ShareCardLayout.sparklineHeight + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(total, ShareCardLayout.bandContentHeight,
                                 "band content \(total) exceeds \(ShareCardLayout.bandContentHeight)")
        // Belts: the measured boxes and the Saira ratio the spec quotes. If the font
        // file changes, these move — re-measure before touching the layout constants.
        XCTAssertEqual(hero, 75.55, accuracy: 0.1)
        XCTAssertEqual(stats, 26.76, accuracy: 0.1)
        XCTAssertEqual(hero / ShareCardLayout.heroPointSize, 1.574, accuracy: 0.01)
    }

    func testNoElevationVariantFits() throws {
        let hero = try lineBox(fontResource: "SairaCondensed-Bold", size: ShareCardLayout.heroPointSize)
        let stats = try lineBox(fontResource: "SairaCondensed-SemiBold", size: ShareCardLayout.statsValuePointSize)
        let total = 16.5 + ShareCardLayout.gapXS + hero + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(total, ShareCardLayout.bandContentHeight)
    }

    func testFontResourceMatchesAppFont() throws {
        // Repo-relative from this source file: AuraCore/Tests/AuraKitTests/ → repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["SairaCondensed-Bold", "SairaCondensed-SemiBold"] {
            let app = try Data(contentsOf: repoRoot.appending(path: "Aura/Resources/Fonts/\(name).ttf"))
            let ours = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ttf")))
            XCTAssertEqual(app, ours, "\(name).ttf drifted from the app copy — re-copy it")
        }
    }
}
