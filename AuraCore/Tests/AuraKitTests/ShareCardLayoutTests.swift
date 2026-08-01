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

    /// The unfinished-ride note (ROH-107) adds a row the band had ~3 pt of slack for, so the
    /// sparkline shrinks to pay for it.
    ///
    /// Read what this does and does not establish. The Saira rows are measured from the
    /// shipped faces. The context row is a pinned SF ceiling. The note's row is pinned by the
    /// VIEW — `ShareCardView.unfinishedNote` applies `.frame(height:)` — so this arithmetic is
    /// checking a height the layout enforces, not predicting one a font might exceed. An
    /// earlier version of this test derived the note's height from a scaled caption metric and
    /// could not have failed on a real overflow: it compared constants to a constant while the
    /// actual row is a `Label` whose SF Symbol is taller than its text box.
    ///
    /// Overflow here does not clip — `readoutBand` has no `.clipped()` and 16 pt of bottom
    /// padding below it — it pushes the stats row and the wordmark toward the card edge. The
    /// margin below is what keeps that from happening at all.
    func testUnfinishedVariantsFitOnTheShorterSparkline() throws {
        let hero = try lineBox(fontResource: "SairaCondensed-Bold", size: ShareCardLayout.heroPointSize)
        let stats = try lineBox(fontResource: "SairaCondensed-SemiBold", size: ShareCardLayout.statsValuePointSize)
        let head = Self.contextCeiling + ShareCardLayout.gapXS + ShareCardLayout.unfinishedNoteHeight
            + ShareCardLayout.gapXS + hero

        let withSparkline = head + ShareCardLayout.gapSM
            + ShareCardLayout.sparklineHeightUnfinished + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(withSparkline, ShareCardLayout.bandContentHeight,
                                 "unfinished band \(withSparkline) exceeds \(ShareCardLayout.bandContentHeight)")

        let withoutSparkline = head + ShareCardLayout.gapSM + stats
        XCTAssertLessThanOrEqual(withoutSparkline, ShareCardLayout.bandContentHeight)

        // Hold the same slack the finished variant ships with. The first cut of this budget
        // passed by 0.19 pt, which is not a margin — it is a rounding error that happened to
        // land on the right side.
        let finished = Self.contextCeiling + ShareCardLayout.gapXS + hero + ShareCardLayout.gapSM
            + ShareCardLayout.sparklineHeight + ShareCardLayout.gapSM + stats
        XCTAssertGreaterThanOrEqual(ShareCardLayout.bandContentHeight - withSparkline,
                                    ShareCardLayout.bandContentHeight - finished - 0.01,
                                    "the unfinished variant must not ship thinner slack than the finished one")

        // The shorter sparkline is a reduction, not a second full-height one: a future edit
        // that quietly restores 40 pt here would overflow the band instead of failing.
        XCTAssertLessThan(ShareCardLayout.sparklineHeightUnfinished, ShareCardLayout.sparklineHeight)
        // The pinned row must clear the SF Symbol that sets its height (~14 pt at 11 pt semibold).
        XCTAssertGreaterThanOrEqual(ShareCardLayout.unfinishedNoteHeight, 14)
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
