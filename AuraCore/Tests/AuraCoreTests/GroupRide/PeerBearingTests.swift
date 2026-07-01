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
