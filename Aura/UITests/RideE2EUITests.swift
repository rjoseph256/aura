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

    /// ROH-103: the paused golden ride. Pauses at the fixture's own segment boundary, inside
    /// the 600 s stop that replays as ~20 s of dead air, so the ride records as two segments
    /// and the chord across the stop is never drawn.
    ///
    /// What a green run does NOT prove: active time on any post-ride surface (it does not
    /// exist yet — ROH-112); `pausedSeconds` surviving persistence; the rendered map gap
    /// (ROH-143); drift gating during a stop, since this fixture's stop has no fixes in it;
    /// the nudge ladder; or haptics.
    @MainActor
    func testPausedGoldenRideSegmentsAndSummary() throws {
        let app = XCUIApplication()
        // 20x, not the harness default of 30x: the fixture's 600 s stop then replays as a 30 s
        // silence, and Pause A's tap-assert-tap sequence has to fit inside it (spec D4).
        app.launchArguments += ["-auraDidCompleteOnboarding", "YES",
                                "-auraSimulatedRide", "paused",
                                "-auraSimulatedRideMultiplier", "20",
                                "-auraInMemoryRideStore"]
        app.launch()
        dismissLocationAlertIfPresent()

        let home = HomeScreen(app: app)
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Home never appeared")
        home.exploreButton.tap()

        let ride = RideScreen(app: app)
        XCTAssertTrue(ride.probe.waitForExistence(timeout: 15),
                      "HUD probe missing — simulated-ride hook did not engage")

        // --- Pause A: inside the replay silence, taps only. ------------------------------
        // Segment 1 is exactly `expectedSegmentDistanceMeters[0]`, every fixture point is
        // accepted unconditionally, and the next increment is +507 m thirty seconds later —
        // so this floor is reachable only at the last point of segment 1.
        let boundary = Int(PausedGoldenRideFixture.expectedSegmentDistanceMeters[0])
        XCTAssertTrue(ride.waitForDistance(atLeast: boundary, timeout: 90),
                      "never reached the segment boundary — last probe: \(ride.probe.label)")

        // Positive control: `s == 0` while paused proves nothing if speed is always 0.
        let ridingSpeed = try XCTUnwrap(ride.probeValues()?.speedDecimetersPerSecond)
        XCTAssertGreaterThan(ridingSpeed, 0, "speed already zero before the pause")

        ride.pauseControl.tap()
        XCTAssertTrue(ride.pausedBanner.waitForExistence(timeout: 5),
                      "PAUSED chip never appeared — the control is not wired")

        // `record()` is a no-op while paused, so segment 1 is final. Equality catches a tap
        // that landed early (reads low) and one that landed late (reads ~1449 — the chord).
        XCTAssertEqual(try XCTUnwrap(ride.probeValues()).distanceMeters, boundary,
                       "distance at the pause is not segment 1")

        ride.pauseControl.tap()
        // waitForNonExistence, not XCTAssertFalse(waitForExistence:) — the latter asserts
        // "absent for the whole window", which the chip's removal animation can violate, and
        // it burns its full timeout on every green run, inside the one scarce budget.
        XCTAssertTrue(ride.pausedBanner.waitForNonExistence(timeout: 5),
                      "PAUSED chip survived the resume")

        // --- Segment 2 records out. -----------------------------------------------------
        // total - 60 rather than - 30: a resume that lands one point late drops that point and
        // finishes at 1851 m, which is a correctly segmented ride with one sample lost. A 30 m
        // tolerance is narrower than the fixture's 32.5 m point spacing, so it would turn that
        // harmless case into a 90 s timeout reporting "segment 2 never completed".
        let total = Int(PausedGoldenRideFixture.expectedDistanceMeters)
        XCTAssertTrue(ride.waitForDistance(atLeast: total - 60, timeout: 90),
                      "segment 2 never completed — last probe: \(ride.probe.label)")

        let afterRide = try XCTUnwrap(ride.probeValues())
        XCTAssertEqual(afterRide.segmentCount, 2, "resume did not open a second segment")
        // Holds the segmented literal (1883 m), excludes the flattened one (2391 m).
        XCTAssertTrue((total - 60...total + 200).contains(afterRide.distanceMeters),
                      "distance \(afterRide.distanceMeters) m is not the segmented total")
        // Segmented gain is 58 m, flattened 100 m. A tap early enough to push the +42 m step
        // across the stop into segment 2 reads 98; two points early reads 54. The band brackets
        // the right answer from both sides — the exact-941 equality above is what catches a
        // one-point-early tap, which reads 56.
        XCTAssertTrue((55...70).contains(afterRide.elevationGainMeters),
                      "elevation gain \(afterRide.elevationGainMeters) m is not segmented")

        // --- Pause B: after playback, where the window costs nothing. --------------------
        ride.pauseControl.tap()
        XCTAssertTrue(ride.pausedBanner.waitForExistence(timeout: 5), "second pause did not take")

        let frozenAt = try XCTUnwrap(ride.probeValues()).elapsed
        let frozenLabel = ride.statsColumn.label
        XCTAssertEqual(try XCTUnwrap(ride.probeValues()).speedDecimetersPerSecond, 0,
                       "speed hero did not fall to zero on pause")
        // The rendered readout, not just the probe — this is what the rider sees.
        XCTAssertTrue(try XCTUnwrap(ride.speedValue.value as? String).hasPrefix("0 "),
                      "speed readout reads \(ride.speedValue.value ?? "nil") while paused")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(try XCTUnwrap(ride.probeValues()).elapsed, frozenAt,
                       "the active clock kept running while paused")
        // The same freeze at the rendered surface. The column composes distance, time and gain
        // into one label at second resolution, so four seconds of a running clock would change
        // it. Playback has ended, so distance and gain cannot move it on their own.
        XCTAssertEqual(ride.statsColumn.label, frozenLabel,
                       "the cockpit clock kept running while paused")

        ride.pauseControl.tap()
        // Proves the clock restarted AND that it did not come back lower than it went in:
        // the predicate is `elapsed > frozenAt`, so a backwards jump never satisfies it.
        XCTAssertTrue(ride.waitForElapsedToAdvance(beyond: frozenAt, timeout: 10),
                      "the clock did not restart on resume, or came back lower")
        XCTAssertNotEqual(ride.statsColumn.label, frozenLabel,
                          "the cockpit clock did not restart on resume")

        // --- End from the paused state (parent spec D6's first table row). ---------------
        ride.pauseControl.tap()
        XCTAssertTrue(ride.pausedBanner.waitForExistence(timeout: 5), "third pause did not take")
        ride.backButton.tap()
        XCTAssertTrue(ride.endAlert.waitForExistence(timeout: 10),
                      "End did nothing while paused — the ride would have been discarded")
        ride.endAlert.buttons["End ride"].tap()

        // --- Summary. -------------------------------------------------------------------
        let summary = SummaryScreen(app: app)
        XCTAssertTrue(summary.title.waitForExistence(timeout: 15), "Summary never appeared")
        try Self.assertPausedHeroDistanceInBand(summary)
        try Self.assertMovingTimeIsSegmented(summary)

        // --- History: one row, not marked unfinished, and it reads back segmented. -------
        summary.doneButton.tap()
        XCTAssertTrue(home.exploreButton.waitForExistence(timeout: 15), "Done did not return Home")
        home.goToHistory()
        let history = HistoryScreen(app: app)
        XCTAssertTrue(history.title.waitForExistence(timeout: 10))
        XCTAssertTrue(history.firstRow.waitForExistence(timeout: 10),
                      "finished ride missing from History")
        // The pause-boundary flush upserts on ride.id — a pause must not duplicate the ride.
        XCTAssertEqual(history.rideRows.count, 1)
        XCTAssertFalse(history.firstRow.label.contains(UnfinishedRideCopy.label),
                       "a paused ride is marked unfinished: \(history.firstRow.label)")

        // Tapping re-reads through `store.ride(id:)`, so these bands are the PERSISTED ride
        // decoded from segmentsData — the only step that proves the save kept its segments.
        // The absence check first: without it, a summary left in the hierarchy by a failed
        // dismissal would satisfy every assertion below while proving nothing about the save.
        XCTAssertFalse(summary.title.exists,
                       "a summary is still on screen before the History row was tapped")
        history.firstRow.tap()
        XCTAssertTrue(summary.title.waitForExistence(timeout: 10),
                      "History detail never appeared — the row tap did not land")
        try Self.assertPausedHeroDistanceInBand(summary)
        try Self.assertMovingTimeIsSegmented(summary)
    }

    /// The paused fixture's own hero band: 1883 m is 1.2 mi / 1.9 km. It must EXCLUDE the
    /// flattened reading (1.5 mi / 2.4 km), not merely contain the segmented one.
    @MainActor
    private static func assertPausedHeroDistanceInBand(_ summary: SummaryScreen,
                                                       file: StaticString = #filePath,
                                                       line: UInt = #line) throws {
        XCTAssertTrue(summary.heroDistance.waitForExistence(timeout: 5), "hero distance missing",
                      file: file, line: line)
        let label = summary.heroDistance.label
        let value = try XCTUnwrap(leadingNumber(in: label),
                                  "no number in hero label: \(label)", file: file, line: line)
        if label.contains("kilometer") {
            XCTAssertTrue((1.7...2.1).contains(value), "km out of band: \(label)",
                          file: file, line: line)
        } else {
            XCTAssertTrue((1.05...1.35).contains(value), "miles out of band: \(label)",
                          file: file, line: line)
        }
    }

    /// Segmented moving time is 290 s → "4 min"; flattened is 890 s → "14 min". The band is
    /// wide enough to absorb a boundary point and nowhere near the flattened reading. This is
    /// the only assertion here that is fully independent of when the tap landed, because
    /// movingTimeSeconds comes from the fixture's own stamps rather than wall clock.
    @MainActor
    private static func assertMovingTimeIsSegmented(_ summary: SummaryScreen,
                                                    file: StaticString = #filePath,
                                                    line: UInt = #line) throws {
        // The supporting stats sit below a 240 pt route map, the title block, the hero and the
        // elevation band, and the History read happens inside a sheet, which insets it further.
        // The ScrollView's VStack is eager so the cell should be in the tree regardless — one
        // swipe is insurance against a runtime that prunes off-screen elements.
        if !summary.movingStat.waitForExistence(timeout: 5) { summary.app.swipeUp() }
        XCTAssertTrue(summary.movingStat.waitForExistence(timeout: 5), "moving cell missing",
                      file: file, line: line)
        let label = summary.movingStat.label
        let value = try XCTUnwrap(leadingNumber(in: label),
                                  "no number in moving label: \(label)", file: file, line: line)
        XCTAssertTrue((3.0...6.0).contains(value),
                      "moving time \(label) — a flattened ride reads ~14 min",
                      file: file, line: line)
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
