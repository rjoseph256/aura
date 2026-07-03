import Testing
@testable import AuraCore

@Suite struct ManeuverTests {
    @Test func guidanceUpdateDefaultsManeuversToNil() {
        let u = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right")
        #expect(u.maneuver == nil)
        #expect(u.nextManeuver == nil)
    }

    @Test func maneuverCarriesKindModifierAndLabel() {
        let m = Maneuver(kind: .roundabout, modifier: .right, label: "3")
        #expect(m.kind == .roundabout)
        #expect(m.modifier == .right)
        #expect(m.label == "3")
    }

    @Test func maneuversThreadThroughGuidanceUpdate() {
        let u = GuidanceUpdate(distanceToManeuverMeters: 100, instruction: "Turn right",
                               maneuver: Maneuver(kind: .turn, modifier: .right),
                               nextManeuver: Maneuver(kind: .turn, modifier: .left))
        #expect(u.maneuver?.modifier == .right)
        #expect(u.nextManeuver?.modifier == .left)
    }
}
