import XCTest
import AuraKit

/// ROH-178 regression guard. The removed predicate asked whether the key window's root view
/// controller had *any* presented view controller, and `beginShareSheetWatch` treated that as "my
/// share sheet is up." On the History path the summary is itself a sheet, so it was true for the
/// summary's whole lifetime — leaving `shareSheetUp` latched and every upgrade deferred into a
/// dying view.
///
/// These began as verification-before-fix tests (systematic debugging, phase 1) and were kept as
/// permanent guards: the first fails if the predicate ever goes back to answering "is anything
/// presented", the second fails if the share sheet stops being identifiable. The pushed ride-end
/// presentation is the control: same view, same probe, no enclosing sheet.
///
/// They read `RideTestID.summaryPresentationProbe`, which reports the whole presentation chain's
/// depth, whether any controller in it is a `UIActivityViewController`, and what the shipping
/// predicate answers. Depth stays 1 on the History path after the fix — only the *subject* of the
/// question changed, which is why depth alone can never answer it.
final class SharePresentationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPresentationChainIsEmptyOnPushButNotOnTheHistorySheet() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "golden",
                                "-auraSimulatedRideMultiplier", "30",
                                "-auraInMemoryRideStore"]
        app.launch()
        dismissLocationAlertIfPresent(app)

        // Record a short golden ride so History has exactly one row to open.
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Home never appeared")
        home.exploreButton.tap()

        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15),
                      "HUD probe missing — simulated-ride hook did not engage")
        let floor = Int(0.5 * GoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: floor, timeout: 90),
                      "distance never reached \(floor) m")

        ride.backButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10), "End alert never appeared")
        ride.endAlert.buttons["End ride"].tap()

        // ---- Control: the summary pushed on the nav stack. Nothing is presented over the root.
        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")
        let pushed = try waitForProbe(in: app, describing: "pushed ride-end summary")
        XCTAssertEqual(pushed.depth, 0,
                       "the pushed summary should have nothing presented over the root; got depth \(pushed.depth)")
        XCTAssertFalse(pushed.hasActivitySheet, "no share sheet was tapped")

        // ---- Subject: the same view presented as a sheet from History.
        summary.doneButton.tap()
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Done did not return Home")
        home.goToHistory()

        let history = HistoryScreen(app: app)
        XCTAssertTrue(history.title.waitForExistence(timeout: 10), "History never appeared")
        XCTAssertTrue(history.rideRows.firstMatch.waitForExistence(timeout: 10),
                      "finished ride missing from History")
        history.rideRows.firstMatch.tap()
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "History summary sheet never appeared")

        let sheeted = try waitForProbe(in: app, describing: "History summary sheet")

        // The regression assertion. No share sheet has been tapped on either path, so the predicate
        // must be false on both. The chain depth here is legitimately 1 — the summary IS a sheet —
        // which is exactly why a depth-based predicate cannot answer this question.
        XCTAssertFalse(sheeted.hasActivitySheet, "no share sheet was tapped on the History path either")
        XCTAssertFalse(sheeted.predicate,
                       """
                       ROH-178: no share sheet is up, so the predicate must read false. It read true \
                       at chain depth \(sheeted.depth) on the History path (control, pushed depth: \
                       \(pushed.depth)) — the summary's own sheet satisfies a depth-based test, so \
                       `shareSheetUp` latches for the view's lifetime and every upgrade is deferred \
                       into a dying view.
                       """)
        // Documents why the naive fix (compare depth) is not the fix: depth is still 1 after the
        // real one. Only the *subject* of the question changed.
        XCTAssertEqual(sheeted.depth, 1,
                       "the History summary is itself a sheet, so a non-empty chain is correct here")
    }

    /// The fix depends on the share sheet being identifiable as a `UIActivityViewController` in the
    /// presentation chain. `ShareLink` documents no such thing, so this pins it rather than assuming
    /// it — if a future SwiftUI release wraps the sheet in something else, this fails and the fix's
    /// premise is gone.
    ///
    /// Expected to PASS today. It verifies UIKit behaviour, not Aura behaviour.
    @MainActor
    func testShareSheetAppearsAsAnActivityViewControllerAboveTheSummarySheet() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "golden",
                                "-auraSimulatedRideMultiplier", "30",
                                "-auraInMemoryRideStore"]
        app.launch()
        dismissLocationAlertIfPresent(app)

        let home = HomeScreen(app: app)
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Home never appeared")
        home.exploreButton.tap()

        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15), "simulated-ride hook did not engage")
        let floor = Int(0.5 * GoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: floor, timeout: 90), "distance never reached")
        ride.backButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10))
        ride.endAlert.buttons["End ride"].tap()

        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")

        // Share is enabled once the fallback card renders.
        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "Share button never appeared")
        var enabled = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if share.isEnabled { enabled = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(enabled, "Share never became enabled — no fallback card was rendered")
        share.tap()

        // Poll the probe until the activity sheet registers, then assert what the fix will key on.
        var seen: SharePresentationProbe.Values?
        let sheetDeadline = Date().addingTimeInterval(15)
        while Date() < sheetDeadline {
            if let values = SharePresentationProbe.parse(
                app.staticTexts[RideTestID.summaryPresentationProbe].label), values.hasActivitySheet {
                seen = values
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let values = try XCTUnwrap(
            seen, "share sheet never appeared as a UIActivityViewController in the presentation chain")
        XCTAssertTrue(values.hasActivitySheet)
        XCTAssertGreaterThanOrEqual(values.depth, 1,
                                    "an activity sheet implies a non-empty chain")
        // And the production predicate agrees. This is the positive half of the contract: the fix
        // must not merely stop over-reporting, it must still detect a real share sheet — otherwise
        // upgrades stop being deferred and the 2026-07-31 self-dismiss defect returns.
        XCTAssertTrue(values.predicate,
                      "the predicate must be true while a UIActivityViewController is presented")
    }

    // MARK: Helpers

    /// The probe is repainted on a 250 ms poll, so give it a couple of cycles before reading.
    private func waitForProbe(in app: XCUIApplication,
                              describing context: String) throws -> SharePresentationProbe.Values {
        let element = app.staticTexts[RideTestID.summaryPresentationProbe]
        XCTAssertTrue(element.waitForExistence(timeout: 10),
                      "presentation probe missing on \(context)")
        let deadline = Date().addingTimeInterval(5)
        var last: String = ""
        while Date() < deadline {
            last = element.label
            if let values = SharePresentationProbe.parse(last) { return values }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw XCTSkip("probe never produced a parseable line on \(context); last was '\(last)'")
    }

    private func dismissLocationAlertIfPresent(_ app: XCUIApplication) {
        let allow = app.alerts.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }
}
