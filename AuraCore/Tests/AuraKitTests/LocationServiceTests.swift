import XCTest
import CoreLocation
@testable import AuraKit
@testable import AuraCore

@MainActor
final class LocationServiceTests: XCTestCase {
    func test_authorizationMapping() {
        XCTAssertEqual(LocationAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(LocationAuthorization(.denied), .denied)
        XCTAssertEqual(LocationAuthorization(.restricted), .restricted)
        #if !os(macOS)
        XCTAssertEqual(LocationAuthorization(.authorizedWhenInUse), .authorized)
        #endif
        XCTAssertEqual(LocationAuthorization(.authorizedAlways), .authorized)
    }

    func test_setMode_configuresManagerPerTier() {
        let svc = LocationService()

        svc.setMode(.idle)
        XCTAssertEqual(svc.mode, .idle)
        XCTAssertEqual(svc.manager.desiredAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(svc.manager.distanceFilter, kCLDistanceFilterNone)

        svc.setMode(.ambient)
        XCTAssertEqual(svc.mode, .ambient)
        XCTAssertEqual(svc.manager.desiredAccuracy, kCLLocationAccuracyKilometer)
        XCTAssertEqual(svc.manager.distanceFilter, 500)

        svc.setMode(.navigating)
        XCTAssertEqual(svc.mode, .navigating)
        XCTAssertEqual(svc.manager.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(svc.manager.distanceFilter, kCLDistanceFilterNone)

        #if os(iOS)
        XCTAssertTrue(svc.manager.showsBackgroundLocationIndicator)
        svc.setMode(.ambient)
        XCTAssertFalse(svc.manager.showsBackgroundLocationIndicator)
        #endif
    }

    func test_ingest_acceptsGoodFix_updatesSignal() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -79.99),
                             altitude: 250, horizontalAccuracy: 8, verticalAccuracy: 5,
                             timestamp: Date())
        let point = svc.ingest(loc, now: Date())
        XCTAssertNotNil(point)
        XCTAssertEqual(svc.signal, .good)
        XCTAssertEqual(point?.elevation, 250)
    }

    func test_ingest_dropsInaccurateFix_signalLost() {
        let svc = LocationService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -79.99),
                             altitude: 0, horizontalAccuracy: 120, verticalAccuracy: 5,
                             timestamp: Date())
        XCTAssertNil(svc.ingest(loc, now: Date()))
        XCTAssertEqual(svc.signal, .lost)
    }

    func test_ingest_staleButAccurateFix_signalLost_butStillRecorded() {
        let svc = LocationService()
        let t = Date()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -79.99),
                             altitude: 10, horizontalAccuracy: 8, verticalAccuracy: 5,
                             timestamp: t)
        let point = svc.ingest(loc, now: t.addingTimeInterval(30)) // 30s old
        XCTAssertNotNil(point)            // accuracy-only acceptance keeps it
        XCTAssertEqual(svc.signal, .lost) // but quality is lost due to age
    }

    // MARK: Task 4 — delegate demux + lastKnown

    func test_ambientUpdate_setsLastKnown() {
        let svc = LocationService()
        let coord = Coordinate(latitude: 40.44, longitude: -79.99)
        let t = Date()
        // Simulate a fix arriving on the ambient (shared) manager.
        svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.manager), coordinate: coord, accuracy: 8, timestamp: t)
        XCTAssertEqual(svc.lastKnown, LocationFix(coordinate: coord, horizontalAccuracy: 8, at: t))
    }

    func test_oneShotUpdate_doesNotTouchLastKnown() {
        let svc = LocationService()
        let coord = Coordinate(latitude: 1, longitude: 2)
        // A fix on the one-shot manager must NOT be recorded as the ambient lastKnown.
        svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.oneShotManager), coordinate: coord, accuracy: 5, timestamp: Date())
        XCTAssertNil(svc.lastKnown)
    }

    // MARK: Task 5 — one-shot current(for:)

    func test_current_returnsDeliveredOneShotFix_andClearsState() async {
        let svc = LocationService()
        let fix = Coordinate(latitude: 12.0, longitude: 34.0)
        // Deliver a one-shot fix as soon as current() parks its continuation.
        Task { @MainActor in
            while svc.oneShotContinuation == nil { await Task.yield() }
            svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.oneShotManager),
                                     coordinate: fix, accuracy: 5, timestamp: Date())
        }
        let origin = await svc.current(for: .routing)
        XCTAssertEqual(origin.latitude, 12.0, accuracy: 0.0001)
        XCTAssertNil(svc.oneShotContinuation, "continuation must be cleared after resume")
        XCTAssertNil(svc.oneShotTask, "in-flight task must be cleared after completion")
    }

    func test_current_concurrentCallers_coalesceToOneFix() async {
        let svc = LocationService()
        let fix = Coordinate(latitude: 12.0, longitude: 34.0)
        Task { @MainActor in
            while svc.oneShotContinuation == nil { await Task.yield() }
            svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.oneShotManager),
                                     coordinate: fix, accuracy: 5, timestamp: Date())
        }
        // Two concurrent callers must share ONE request and both receive the single delivered fix.
        async let a = svc.current(for: .routing)
        async let b = svc.current(for: .routing)
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra.latitude, 12.0, accuracy: 0.0001)
        XCTAssertEqual(rb.latitude, 12.0, accuracy: 0.0001)
        XCTAssertNil(svc.oneShotContinuation)
        XCTAssertNil(svc.oneShotTask)
    }

    func test_current_timesOutToFallback_whenNoFixDelivered() async {
        // Fresh host is .notDetermined; requestLocation delivers no usable fix, so the internal
        // timeout resolves to the Pittsburgh fallback. Must not hang.
        let svc = LocationService()
        let origin = await svc.current(for: .routing)
        XCTAssertEqual(origin.latitude, 40.4406, accuracy: 0.0001)
        XCTAssertEqual(origin.longitude, -79.9959, accuracy: 0.0001)
    }

    // MARK: Task 6 — ambient monitor, releaseNonRide, clobber-proof stop()

    func test_startAmbient_noopsWhenNotAuthorized() {
        let svc = LocationService()   // fresh -> notDetermined
        svc.startAmbient()
        XCTAssertEqual(svc.mode, .idle, "ambient must not start without authorization")
        XCTAssertFalse(svc.sessionActive)
    }

    func test_releaseNonRide_isNoopWhileNavigating() {
        let svc = LocationService()
        svc.setMode(.navigating)      // pretend a ride is configuring the manager
        svc.releaseNonRide()
        XCTAssertEqual(svc.mode, .navigating, "releaseNonRide must never tear down the ride pipeline")
    }

    func test_releaseNonRide_stopsAmbient() {
        let svc = LocationService()
        svc.setMode(.ambient)         // simulate ambient running
        svc.releaseNonRide()
        XCTAssertEqual(svc.mode, .idle)
    }

    func test_points_armsSession_stopClearsIt() {
        let svc = LocationService()
        _ = svc.points()
        XCTAssertTrue(svc.sessionActive, "points() must arm the ride session")
        XCTAssertEqual(svc.mode, .navigating)
        svc.stop()
        XCTAssertFalse(svc.sessionActive, "stop() must synchronously release the ride session")
        XCTAssertEqual(svc.mode, .idle)
    }

    func test_stop_doesNotClobberReArmedAmbient() {
        // Ride-end race: the controller re-arms ambient (path pop) BEFORE the HUD's
        // onDisappear->cancel->stop lands. stop() must release the session but NOT force
        // the tier back to .idle when ambient already took over.
        let svc = LocationService()
        _ = svc.points()              // ride armed: sessionActive, .navigating
        svc.setMode(.ambient)         // controller re-armed ambient first
        svc.stop()                    // late teardown arrives
        XCTAssertFalse(svc.sessionActive, "session must still be released")
        XCTAssertEqual(svc.mode, .ambient, "stop() must not clobber a re-armed ambient tier")
    }
}
