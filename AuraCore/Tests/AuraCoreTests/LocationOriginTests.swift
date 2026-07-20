import XCTest
@testable import AuraCore

final class LocationOriginTests: XCTestCase {
    private let a = Coordinate(latitude: 40.44, longitude: -79.99)   // cached
    private let b = Coordinate(latitude: 40.45, longitude: -79.98)   // ambient
    private let now = Date(timeIntervalSince1970: 10_000)

    private func fix(_ c: Coordinate, acc: Double, age: TimeInterval) -> LocationFix {
        LocationFix(coordinate: c, horizontalAccuracy: acc, at: now.addingTimeInterval(-age))
    }

    func test_freshFineCached_winsForBothPurposes() {
        let cached = fix(a, acc: 8, age: 10)
        XCTAssertEqual(resolveOrigin(cached: cached, ambient: nil, purpose: .routing, now: now), a)
        XCTAssertEqual(resolveOrigin(cached: cached, ambient: nil, purpose: .coarse, now: now), a)
    }

    func test_coarseCached_rejectedForRouting_butOkForCoarse() {
        let cached = fix(a, acc: 1000, age: 10)   // ~1 km ambient fix
        XCTAssertNil(resolveOrigin(cached: cached, ambient: nil, purpose: .routing, now: now))
        XCTAssertEqual(resolveOrigin(cached: cached, ambient: nil, purpose: .coarse, now: now), a)
    }

    func test_invalidAccuracyCached_rejectedForRouting() {
        let cached = fix(a, acc: -1, age: 5)      // CLLocation reports -1 for invalid horizontal accuracy
        XCTAssertNil(resolveOrigin(cached: cached, ambient: nil, purpose: .routing, now: now))
    }

    func test_staleCached_isIgnored() {
        let cached = fix(a, acc: 8, age: 31)
        XCTAssertNil(resolveOrigin(cached: cached, ambient: nil, purpose: .routing, now: now))
    }

    func test_coarsePurpose_acceptsFreshAmbient() {
        XCTAssertEqual(resolveOrigin(cached: nil, ambient: fix(b, acc: 1000, age: 5), purpose: .coarse, now: now), b)
    }

    func test_routingPurpose_neverAcceptsAmbient() {
        // Even a perfectly fresh, fine-looking ambient sample is refused for routing.
        XCTAssertNil(resolveOrigin(cached: nil, ambient: fix(b, acc: 8, age: 0), purpose: .routing, now: now))
    }

    func test_staleAmbient_ignoredEvenForCoarse() {
        XCTAssertNil(resolveOrigin(cached: nil, ambient: fix(b, acc: 1000, age: 31), purpose: .coarse, now: now))
    }
}
