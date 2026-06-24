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
}
