import Testing
@testable import AuraCore

@Suite("SavedPlaceKey")
struct SavedPlaceKeyTests {
    @Test func identicalCoordinatesShareKey() {
        let a = SavedPlaceKey(Coordinate(latitude: 40.4406, longitude: -79.9959))
        let b = SavedPlaceKey(Coordinate(latitude: 40.4406, longitude: -79.9959))
        #expect(a == b)
    }

    @Test func subMeterJitterSharesKey() {
        // 6th-decimal noise (~0.1 m) must not defeat identity — the two Mapbox
        // resolution paths are not guaranteed bit-identical.
        let a = SavedPlaceKey(Coordinate(latitude: 40.440601, longitude: -79.995899))
        let b = SavedPlaceKey(Coordinate(latitude: 40.440599, longitude: -79.995901))
        #expect(a == b)
    }

    @Test func distinctPlacesDiffer() {
        let a = SavedPlaceKey(Coordinate(latitude: 40.4406, longitude: -79.9959))
        let b = SavedPlaceKey(Coordinate(latitude: 40.4418, longitude: -80.0134))
        #expect(a != b)
    }
}
