import XCTest
@testable import AuraKit

final class ShareCameraValidationTests: XCTestCase {
    func testRejectsMissingOrNonFinite() {
        XCTAssertNil(ShareCameraValidation.validated(latitude: nil, longitude: -79, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: nil, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: nil))
        XCTAssertNil(ShareCameraValidation.validated(latitude: .nan, longitude: -79, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: .nan, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: .nan))
        XCTAssertNil(ShareCameraValidation.validated(latitude: .infinity, longitude: -79, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: -.infinity, zoom: 12))
        XCTAssertNil(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: .infinity))
    }

    func testClampsZoom() {
        XCTAssertEqual(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: 18)?.zoom, 16)
        XCTAssertEqual(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: 16)?.zoom, 16)
        XCTAssertEqual(ShareCameraValidation.validated(latitude: 40, longitude: -79, zoom: 12)?.zoom, 12)
    }

    func testPassesCenterThroughUnchanged() {
        let v = ShareCameraValidation.validated(latitude: 40.44, longitude: -79.99, zoom: 12.5)
        XCTAssertEqual(v?.latitude, 40.44)
        XCTAssertEqual(v?.longitude, -79.99)
        XCTAssertEqual(v?.zoom, 12.5)
    }
}
