import XCTest
import CoreText
@testable import AuraKit

/// Measures the share card's readout-band budget against the real Saira Condensed TTFs
/// bundled as test resources — an actual CoreText measurement, not arithmetic over the
/// spec's own constants (spec ROH-126 rev 4, §Layout).
final class ShareCardLayoutTests: XCTestCase {
    /// Measured ceiling for the context row, which is SF (system) at caption/Large: a
    /// 16.0 pt measured line box plus slack (plan erratum (c)). Measured once rather
    /// than shipping an SF copy into test resources; both band-budget tests share it.
    private static let contextCeiling: CGFloat = 16.5

    /// Same treatment for the unfinished-ride note, which is SF caption2 (11 pt at Large) to
    /// the context row's caption (12 pt): the measured 16.0 pt box scaled by 11/12, plus the
    /// same slack. The `Label`'s clock glyph is SF Symbol at the same text style, so it rides
    /// inside this line box rather than adding to it.
    private static let unfinishedNoteCeiling: CGFloat = 15.0

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
        let total = Self.contextCeiling + ShareCardLayout.gapXS + hero + ShareCardLayout.gapSM
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
        let total = Self.contextCeiling + ShareCardLayout.gapXS + hero + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(total, ShareCardLayout.bandContentHeight)
    }

    /// The unfinished-ride note (ROH-107) adds a line the band had ~3 pt of slack for, so the
    /// sparkline shrinks to pay for it. Both unfinished variants have to fit, or the card
    /// clips the state it exists to disclose.
    func testUnfinishedVariantsFitOnTheShorterSparkline() throws {
        let hero = try lineBox(fontResource: "SairaCondensed-Bold", size: ShareCardLayout.heroPointSize)
        let stats = try lineBox(fontResource: "SairaCondensed-SemiBold", size: ShareCardLayout.statsValuePointSize)
        let head = Self.contextCeiling + ShareCardLayout.gapXS + Self.unfinishedNoteCeiling
            + ShareCardLayout.gapXS + hero

        let withSparkline = head + ShareCardLayout.gapSM
            + ShareCardLayout.sparklineHeightUnfinished + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(withSparkline, ShareCardLayout.bandContentHeight,
                                 "unfinished band \(withSparkline) exceeds \(ShareCardLayout.bandContentHeight)")

        let withoutSparkline = head + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(withoutSparkline, ShareCardLayout.bandContentHeight)

        // The shorter sparkline is a reduction, not a second full-height one: a future edit
        // that quietly restores 40 pt here would clip the note instead of failing.
        XCTAssertLessThan(ShareCardLayout.sparklineHeightUnfinished, ShareCardLayout.sparklineHeight)
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
