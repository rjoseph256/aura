import Testing
import AuraCore
@testable import AuraKit

@Suite struct ManeuverIconTests {
    @Test func nilManeuverIsTheGenericArrow() {
        #expect(ManeuverIcon.symbol(for: nil) == ManeuverIcon.genericSymbol)
    }

    @Test func directionalTurnsPickASidedArrow() {
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .turn, modifier: .right)) == "arrow.turn.up.right")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .turn, modifier: .left))  == "arrow.turn.up.left")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .uTurn, modifier: .uTurn)) == "arrow.uturn.down")
    }

    @Test func everyKindAndModifierReturnsANonEmptySymbol() {
        for kind in Maneuver.Kind.allCases {
            for modifier in Maneuver.Modifier.allCases {
                let s = ManeuverIcon.symbol(for: Maneuver(kind: kind, modifier: modifier))
                #expect(!s.isEmpty, "empty symbol for \(kind)/\(modifier)")
            }
        }
    }
}
