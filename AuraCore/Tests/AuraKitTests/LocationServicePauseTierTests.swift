import XCTest
import CoreLocation
@testable import AuraKit
@testable import AuraCore

/// Spec D7's battery clause. During a ride the shared ambient manager is still delivering at
/// the navigating tier (`points()` re-tiers it and never stops it), so a forgotten two-hour
/// pause wakes the app for every fix to record nothing. The ride keeps *owning* the manager —
/// `mode` stays `.navigating`, which is what every "a ride owns this" guard tests — only the
/// accuracy knobs relax.
@MainActor
final class LocationServicePauseTierTests: XCTestCase {
    private func makeService() -> (LocationService, FakeLocationManager) {
        let fake = FakeLocationManager(authorizationStatus: .authorizedAlways)
        return (LocationService(manager: fake, oneShotManager: FakeLocationManager()), fake)
    }

    func test_ridePaused_relaxesTheNavigatingTier() {
        let (svc, fake) = makeService()
        svc.setMode(.navigating)

        svc.setRidePaused(true)

        XCTAssertEqual(svc.mode, .navigating, "the ride still owns the manager while paused")
        XCTAssertTrue(svc.isRidePaused)
        XCTAssertEqual(fake.desiredAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(fake.distanceFilter, 50)
    }

    func test_resume_restoresTheFullNavigatingTier() {
        let (svc, fake) = makeService()
        svc.setMode(.navigating)
        svc.setRidePaused(true)

        svc.setRidePaused(false)

        XCTAssertFalse(svc.isRidePaused)
        XCTAssertEqual(fake.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(fake.distanceFilter, kCLDistanceFilterNone)
    }

    /// A stale pause must not leak into the next ride's accuracy.
    func test_stopClearsThePausedTier() {
        let (svc, _) = makeService()
        svc.setMode(.navigating)
        svc.setRidePaused(true)

        svc.stop()

        XCTAssertFalse(svc.isRidePaused)
        XCTAssertEqual(svc.mode, .idle)
    }

    /// The non-ride tiers are unaffected: a paused ride that has already released the manager
    /// must not re-coarsen an ambient monitor that something else now owns.
    func test_ridePausedDoesNothingOutsideARide() {
        let (svc, fake) = makeService()
        svc.setMode(.ambient)

        svc.setRidePaused(true)

        XCTAssertEqual(svc.mode, .ambient)
        XCTAssertEqual(fake.desiredAccuracy, kCLLocationAccuracyKilometer)
        XCTAssertEqual(fake.distanceFilter, 500)
    }
}
