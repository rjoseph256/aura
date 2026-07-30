import XCTest
import AuraKit

/// ROH-92 Layer 2: the golden ride through the real app. Launches with the simulated
/// location fixture, records to ≥80% of the fixture's distance, ends the ride, and asserts
/// the summary and History wiring. Numbers are sanity bands only — Layer 1
/// (GoldenRidePlaybackTests) owns precision.
final class RideE2EUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testGoldenRideRecordsToSummaryAndHistory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "golden",
                                "-auraSimulatedRideMultiplier", "30",
                                "-auraInMemoryRideStore"]
        app.launch()
        dismissLocationAlertIfPresent()

        let home = HomeScreen(app: app)
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Home never appeared")
        home.exploreButton.tap()

        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15),
                      "HUD probe missing — simulated-ride hook did not engage")

        // Playback ≈ nominal/multiplier ≈ 15 s; allow generous slack for CI. 0.85× keeps
        // the guaranteed-reached minimum inside BOTH unit bands asserted on the summary.
        let floor = Int(0.85 * GoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: floor, timeout: 90),
                      "distance never reached \(floor) m — last probe: \(ride.probe.label)")

        // Elapsed ticker advances (catches a frozen tickerTask).
        let elapsedBefore = try XCTUnwrap(ride.probeValues()).elapsed
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 3))
        let deadline = Date().addingTimeInterval(10)
        var advanced = false
        while Date() < deadline {
            if let now = ride.probeValues()?.elapsed, now > elapsedBefore { advanced = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(advanced, "elapsed ticker frozen at \(elapsedBefore)s")

        // Climb recorded (silent-flat guard at the wiring layer). NOTE: this is the spec's
        // "elevation gain nonzero" commitment, delivered at the HUD probe — RideSummaryView
        // has no numeric gain readout (gain renders only inside the profile chart), so the
        // summary itself is asserted for title + hero distance only.
        let gain = try XCTUnwrap(ride.probeValues()).elevationGainMeters
        XCTAssertGreaterThanOrEqual(gain, 40, "elevation gain flat: \(gain) m")

        // End the ride via the back control → confirmation alert.
        ride.backButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10), "End alert never appeared")
        ride.endAlert.buttons["End ride"].tap()

        // Summary (path collapse) with a sane hero distance.
        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")
        try Self.assertHeroDistanceInBand(summary)

        // Done → Home, then the ride is in History (fresh in-memory store → exactly 1 row).
        summary.doneButton.tap()
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Done did not return Home")
        home.goToHistory()
        let history = HistoryScreen(app: app)
        XCTAssertTrue(history.title.waitForExistence(timeout: 10))
        XCTAssertTrue(history.rideRows.firstMatch.waitForExistence(timeout: 10),
                      "finished ride missing from History")
        XCTAssertEqual(history.rideRows.count, 1)
    }

    /// ROH-93: the navigate-mode golden ride. Enters via the -openURL preview deep link
    /// (search is out of scope — spec Non-goals), rides the same fixture through
    /// NavigateHUDView, ends via the manual End control (no Mapbox arrival), and
    /// asserts the same summary + History wiring whose navigate seam regressed in
    /// ROH-85.
    @MainActor
    func testNavigateGoldenRideEndsToSummaryAndHistory() throws {
        let app = XCUIApplication()
        let previewLink = "aura://preview?lat=\(GoldenRideFixture.startLatitude)" +
            "&lng=\(GoldenRideFixture.startLongitude)&name=Golden%20Loop"
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "golden",
                                "-auraSimulatedRideMultiplier", "30",
                                "-auraInMemoryRideStore",
                                "-openURL", previewLink]
        app.launch()
        dismissLocationAlertIfPresent()

        // Preview: the fixture route auto-selects; the CTA enables one runloop later.
        let preview = PreviewScreen(app: app)
        XCTAssertTrue(preview.waitForStartEnabled(timeout: 15),
                      "Start RIDE never enabled — fixture route did not load/select")
        preview.startRide.tap()

        // Navigate HUD: the simulated hook engaged and records through this path.
        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15),
                      "HUD probe missing — simulated-ride hook did not engage in navigate")
        let floor = Int(0.85 * GoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: floor, timeout: 90),
                      "distance never reached \(floor) m — last probe: \(ride.probe.label)")
        // One-line stats sanity: a diverged navigate provider would record flat gain.
        // Free ride owns the fuller recorder assertions (ticker, precision bands).
        let gain = try XCTUnwrap(ride.probeValues()).elevationGainMeters
        XCTAssertGreaterThanOrEqual(gain, 40, "elevation gain flat: \(gain) m")

        // Manual End via the control cluster (no arrival in this harness).
        ride.endButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10), "End alert never appeared")
        ride.endAlert.buttons["End ride"].tap()

        // Summary (the ROH-85 seam) → Done → Home → History (fresh store → 1 row).
        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")
        try Self.assertHeroDistanceInBand(summary)
        summary.doneButton.tap()
        let home = HomeScreen(app: app)
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Done did not return Home")
        home.goToHistory()
        let history = HistoryScreen(app: app)
        XCTAssertTrue(history.title.waitForExistence(timeout: 10))
        XCTAssertTrue(history.rideRows.firstMatch.waitForExistence(timeout: 10),
                      "finished ride missing from History")
        XCTAssertEqual(history.rideRows.count, 1)
    }

    /// First decimal number found after the first comma-space (locale label like
    /// "Distance, 1.8 miles"); tolerant of grouping-free decimals.
    private static func leadingNumber(in label: String) -> Double? {
        let scanner = Scanner(string: label)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)
        return scanner.scanDouble()
    }

    /// Hero-distance sanity band shared by both golden rides. NOTE: a fixture
    /// re-record must update GoldenRideFixture's literals AND these bands together.
    @MainActor
    private static func assertHeroDistanceInBand(_ summary: SummaryScreen,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) throws {
        XCTAssertTrue(summary.heroDistance.exists, "hero distance missing",
                      file: file, line: line)
        let label = summary.heroDistance.label   // e.g. "Distance, 1.8 miles"
        let value = try XCTUnwrap(leadingNumber(in: label),
                                  "no number in hero label: \(label)", file: file, line: line)
        if label.contains("kilometer") {
            XCTAssertTrue((2.3...3.4).contains(value), "km out of band: \(label)",
                          file: file, line: line)
        } else {
            XCTAssertTrue((1.4...2.2).contains(value), "miles out of band: \(label)",
                          file: file, line: line)
        }
    }

    /// Defensive only: the ambient tier is skipped in simulated mode, but Mapbox's own
    /// location engine may still prompt on some runtimes.
    @MainActor
    private func dismissLocationAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        dismissNotificationAlertIfPresent(springboard)
    }

    /// Belt and braces beside the location one, and only that. The actual fix is at the source:
    /// `PauseNudgeScheduler.prepareAuthorization` is a no-op under the simulated-ride harness,
    /// so ROH-101's ride-start request never runs in this suite.
    ///
    /// It has to be fixed there rather than here, because a notification alert is
    /// unrecoverable for this suite in a way the location one is not. There is no
    /// `xcrun simctl privacy` service for notifications, so CI cannot pre-grant it on a freshly
    /// installed app; once the alert is up every tap lands on SpringBoard; and the retry
    /// re-enters the same state. This call also only covers a prompt raised around launch — a
    /// prompt raised later, at the ride start, is already past it.
    @MainActor
    private func dismissNotificationAlertIfPresent(_ springboard: XCUIApplication) {
        // Short wait, not `exists`: the request is asynchronous, so an alert may still be on
        // its way when the location check returns. Exact label — the location alert's buttons
        // are "Allow While Using App" / "Allow Once", so this cannot match those.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }
}
