import XCTest
import CoreLocation
@testable import AuraKit
@testable import AuraCore

@MainActor
final class LocationServiceTests: XCTestCase {
    /// Build a service backed by fakes so the test never constructs a real `CLLocationManager`
    /// (ROH-88: real managers leak `locationd` XPC connections on the headless CI runner).
    private func makeService(authorization: CLAuthorizationStatus = .notDetermined) -> LocationService {
        LocationService(manager: FakeLocationManager(authorizationStatus: authorization),
                        oneShotManager: FakeLocationManager())
    }

    func test_authorizationMapping() {
        XCTAssertEqual(LocationAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(LocationAuthorization(.denied), .denied)
        XCTAssertEqual(LocationAuthorization(.restricted), .restricted)
        #if !os(macOS)
        XCTAssertEqual(LocationAuthorization(.authorizedWhenInUse), .authorized)
        #endif
        XCTAssertEqual(LocationAuthorization(.authorizedAlways), .authorized)
    }

    // MARK: Seam — injected LocationManaging (ROH-88: no real CLLocationManager under test)

    func test_setMode_writesThroughInjectedManager() {
        let fake = FakeLocationManager()
        let svc = LocationService(manager: fake, oneShotManager: FakeLocationManager())

        svc.setMode(.ambient)
        // The tier config must land on the injected manager, proving the seam is wired.
        XCTAssertEqual(fake.desiredAccuracy, kCLLocationAccuracyKilometer)
        XCTAssertEqual(fake.distanceFilter, 500)
    }

    func test_startAmbient_startsInjectedManager_whenAuthorized() {
        let fake = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let svc = LocationService(manager: fake, oneShotManager: FakeLocationManager())

        svc.startAmbient()
        XCTAssertEqual(svc.mode, .ambient)
        XCTAssertEqual(fake.startUpdatingCount, 1, "startAmbient must drive the injected ambient manager")
    }

    func test_oneShot_requestsThroughInjectedOneShotManager() async {
        let oneShot = FakeLocationManager()
        let svc = LocationService(manager: FakeLocationManager(), oneShotManager: oneShot)
        // No fix is ever delivered by the fake, so current() times out to the fallback — but it
        // must have issued exactly one requestLocation() on the injected one-shot manager.
        _ = await svc.current(for: .routing)
        XCTAssertEqual(oneShot.requestLocationCount, 1)
    }

    func test_setMode_configuresManagerPerTier() {
        let svc = LocationService(manager: FakeLocationManager(), oneShotManager: FakeLocationManager())

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
        // Only .navigating shows the background pill and disables auto-pause.
        svc.setMode(.navigating)
        XCTAssertTrue(svc.manager.showsBackgroundLocationIndicator)
        XCTAssertFalse(svc.manager.pausesLocationUpdatesAutomatically)
        XCTAssertEqual(svc.manager.activityType, .fitness)

        svc.setMode(.ambient)
        XCTAssertFalse(svc.manager.showsBackgroundLocationIndicator)
        XCTAssertTrue(svc.manager.pausesLocationUpdatesAutomatically)
        XCTAssertEqual(svc.manager.activityType, .fitness)

        svc.setMode(.idle)
        XCTAssertFalse(svc.manager.showsBackgroundLocationIndicator)
        XCTAssertTrue(svc.manager.pausesLocationUpdatesAutomatically)
        XCTAssertEqual(svc.manager.activityType, .other)
        #endif
    }

    func test_ingest_acceptsGoodFix_updatesSignal() {
        let svc = makeService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -79.99),
                             altitude: 250, horizontalAccuracy: 8, verticalAccuracy: 5,
                             timestamp: Date())
        let point = svc.ingest(loc, now: Date())
        XCTAssertNotNil(point)
        XCTAssertEqual(svc.signal, .good)
        XCTAssertEqual(point?.elevation, 250)
    }

    func test_ingest_dropsInaccurateFix_signalLost() {
        let svc = makeService()
        let loc = CLLocation(coordinate: .init(latitude: 40.44, longitude: -79.99),
                             altitude: 0, horizontalAccuracy: 120, verticalAccuracy: 5,
                             timestamp: Date())
        XCTAssertNil(svc.ingest(loc, now: Date()))
        XCTAssertEqual(svc.signal, .lost)
    }

    func test_ingest_staleButAccurateFix_signalLost_butStillRecorded() {
        let svc = makeService()
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
        let svc = makeService()
        let coord = Coordinate(latitude: 40.44, longitude: -79.99)
        let t = Date()
        // Simulate a fix arriving on the ambient (shared) manager.
        svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.manager), coordinate: coord, accuracy: 8, timestamp: t)
        XCTAssertEqual(svc.lastKnown, LocationFix(coordinate: coord, horizontalAccuracy: 8, at: t))
    }

    func test_oneShotUpdate_doesNotTouchLastKnown() {
        let svc = makeService()
        let coord = Coordinate(latitude: 1, longitude: 2)
        // A fix on the one-shot manager must NOT be recorded as the ambient lastKnown.
        svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.oneShotManager), coordinate: coord, accuracy: 5, timestamp: Date())
        XCTAssertNil(svc.lastKnown)
    }

    // MARK: Task 5 — one-shot current(for:)

    func test_current_returnsDeliveredOneShotFix_andClearsState() async {
        let svc = makeService()
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
        let svc = makeService()
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

    func test_current_sequentialCalls_eachGetsOwnFix_stateClearsBetween() async {
        // Two back-to-back (non-overlapping) one-shot cycles must each resolve to their own
        // delivered fix, with all one-shot state cleared between them — no bleed from cycle 1
        // into cycle 2 (the cross-cycle contamination guard's happy path).
        let svc = makeService()
        func deliver(_ c: Coordinate) {
            Task { @MainActor in
                while svc.oneShotContinuation == nil { await Task.yield() }
                svc.handleLocationUpdate(managerID: ObjectIdentifier(svc.oneShotManager),
                                         coordinate: c, accuracy: 5, timestamp: Date())
            }
        }
        deliver(Coordinate(latitude: 1.0, longitude: 1.0))
        let a = await svc.current(for: .routing)
        XCTAssertEqual(a.latitude, 1.0, accuracy: 0.0001)
        XCTAssertNil(svc.oneShotContinuation)
        XCTAssertNil(svc.oneShotTask)

        deliver(Coordinate(latitude: 2.0, longitude: 2.0))
        let b = await svc.current(for: .routing)
        XCTAssertEqual(b.latitude, 2.0, accuracy: 0.0001)
    }

    func test_current_timesOutToFallback_whenNoFixDelivered() async {
        // Fresh host is .notDetermined; requestLocation delivers no usable fix, so the internal
        // timeout resolves to the Pittsburgh fallback. Must not hang.
        let svc = makeService()
        let origin = await svc.current(for: .routing)
        XCTAssertEqual(origin.latitude, 40.4406, accuracy: 0.0001)
        XCTAssertEqual(origin.longitude, -79.9959, accuracy: 0.0001)
    }

    // MARK: Task 6 — ambient monitor, releaseNonRide, clobber-proof stop()

    func test_startAmbient_noopsWhenNotAuthorized() {
        let svc = makeService()   // fresh -> notDetermined
        svc.startAmbient()
        XCTAssertEqual(svc.mode, .idle, "ambient must not start without authorization")
        XCTAssertFalse(svc.sessionActive)
    }

    func test_releaseNonRide_isNoopWhileNavigating() {
        let svc = makeService()
        svc.setMode(.navigating)      // pretend a ride is configuring the manager
        svc.releaseNonRide()
        XCTAssertEqual(svc.mode, .navigating, "releaseNonRide must never tear down the ride pipeline")
    }

    func test_releaseNonRide_stopsAmbient() {
        let svc = makeService()
        svc.setMode(.ambient)         // simulate ambient running
        svc.releaseNonRide()
        XCTAssertEqual(svc.mode, .idle)
    }

    func test_points_armsSession_stopClearsIt() {
        let svc = makeService()
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
        let svc = makeService()
        _ = svc.points()              // ride armed: sessionActive, .navigating
        svc.setMode(.ambient)         // controller re-armed ambient first
        svc.stop()                    // late teardown arrives
        XCTAssertFalse(svc.sessionActive, "session must still be released")
        XCTAssertEqual(svc.mode, .ambient, "stop() must not clobber a re-armed ambient tier")
    }
}
