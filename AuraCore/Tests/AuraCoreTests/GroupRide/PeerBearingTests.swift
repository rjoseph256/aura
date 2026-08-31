import Testing
import AuraCore

struct PeerBearingTests {
    @Test func dueEastIsNinety() {
        let h = PeerBearing.heading(from: Coordinate(latitude: 0, longitude: 0),
                                    to: Coordinate(latitude: 0, longitude: 1))
        #expect(abs(h - 90) < 0.5)
    }
    @Test func dueNorthIsZero() {
        let h = PeerBearing.heading(from: Coordinate(latitude: 0, longitude: 0),
                                    to: Coordinate(latitude: 1, longitude: 0))
        #expect(abs(h) < 0.5)
    }
    @Test func identicalPointsHaveNoHeading() {
        let p: Coordinate? = Coordinate(latitude: 5, longitude: 5)
        #expect(PeerBearing.heading(from: p, to: p) == nil)
    }
    @Test func nilInputsGiveNil() {
        #expect(PeerBearing.heading(from: nil, to: Coordinate(latitude: 1, longitude: 1)) == nil)
    }
}

/// On-screen pointer rotation for a screen-aligned map annotation: the geographic bearing
/// with the camera's own rotation subtracted (ROH-213). A course-up camera at bearing B
/// draws geographic north at −B on screen, so a peer heading B must render as 0 (straight up).
struct PeerScreenAngleTests {
    @Test func northUpCameraPassesBearingThrough() {
        #expect(PeerBearing.screenAngle(bearing: 137, cameraBearing: 0) == 137)
    }
    @Test func courseUpCameraSubtractsItsBearing() {
        // Peer heading east on an east-up camera: straight up on screen.
        #expect(PeerBearing.screenAngle(bearing: 90, cameraBearing: 90) == 0)
    }
    @Test func wrapsIntoZeroToThreeSixty() {
        #expect(PeerBearing.screenAngle(bearing: 10, cameraBearing: 90) == 280)
    }
    @Test func nilBearingStaysNil() {
        #expect(PeerBearing.screenAngle(bearing: nil, cameraBearing: 45) == nil)
    }
    @Test func nonFiniteCameraFallsBackToRawBearing() {
        // Defensive: a NaN camera frame must not poison the pointer into NaN rotation.
        #expect(PeerBearing.screenAngle(bearing: 90, cameraBearing: .nan) == 90)
    }
}
