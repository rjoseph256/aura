import Testing
@testable import AuraCore

struct RideBackOutGateTests {
    @Test func belowFloorCanDiscard() {
        #expect(RideBackOutGate.canDiscard(distanceMeters: 0) == true)
        #expect(RideBackOutGate.canDiscard(distanceMeters: 24) == true)
    }
    @Test func atFloorCannotDiscard() {
        #expect(RideBackOutGate.canDiscard(distanceMeters: 25) == false)
    }
    @Test func aboveFloorCannotDiscard() {
        #expect(RideBackOutGate.canDiscard(distanceMeters: 26) == false)
        #expect(RideBackOutGate.canDiscard(distanceMeters: 5000) == false)
    }
}
