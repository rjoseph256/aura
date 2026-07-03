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

    // A fork/merge/ramp with no sided modifier (.straight or .none) must still read as a
    // fork/merge/ramp — an indicative glyph, not the plain up-arrow the turn/continue cases use.
    @Test func forksMergesRampsAreIndicativeWithoutASide() {
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .fork, modifier: .straight)) == "arrow.triangle.branch")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .fork, modifier: .none)) == "arrow.triangle.branch")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .offRamp, modifier: .straight)) == "arrow.triangle.branch")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .offRamp, modifier: .none)) == "arrow.triangle.branch")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .merge, modifier: .straight)) == "arrow.merge")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .merge, modifier: .none)) == "arrow.merge")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .onRamp, modifier: .straight)) == "arrow.merge")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .onRamp, modifier: .none)) == "arrow.merge")
    }

    // When the SDK does supply a side, that sidedness wins over the kind-specific fallback.
    @Test func forksMergesRampsKeepTheirSideWhenGivenOne() {
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .fork, modifier: .right)) == "arrow.turn.up.right")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .merge, modifier: .left)) == "arrow.turn.up.left")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .onRamp, modifier: .slightRight)) == "arrow.turn.up.right")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .offRamp, modifier: .sharpLeft)) == "arrow.turn.up.left")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .fork, modifier: .uTurn)) == "arrow.uturn.down")
    }

    // Exhaustive matrix for the four kinds this change touches, over EVERY modifier. The
    // expected glyphs are stated here independently of the implementation (not derived from
    // it), so this catches a swapped/wrong/empty glyph — not just a relapse to "arrow.up" —
    // and covers the combinations the explicit cases above don't (e.g. merge/.uTurn, every
    // sided variant). `sideless` is the kind's indicative fallback: branch = diverge, merge = join.
    @Test func forksMergesRampsMapEveryModifierToItsExactGlyph() {
        let sideless: [Maneuver.Kind: String] = [
            .fork: "arrow.triangle.branch", .offRamp: "arrow.triangle.branch",
            .merge: "arrow.merge", .onRamp: "arrow.merge"
        ]
        for (kind, fallback) in sideless {
            for modifier in Maneuver.Modifier.allCases {
                let expected: String
                switch modifier {
                case .left, .slightLeft, .sharpLeft: expected = "arrow.turn.up.left"
                case .right, .slightRight, .sharpRight: expected = "arrow.turn.up.right"
                case .uTurn: expected = "arrow.uturn.down"
                case .straight, .none: expected = fallback
                }
                #expect(ManeuverIcon.symbol(for: Maneuver(kind: kind, modifier: modifier)) == expected,
                        "wrong glyph for \(kind)/\(modifier)")
            }
        }
    }

    // Scope guard: this change touched only fork/merge/ramp. The kinds it left alone must keep
    // their prior glyphs — notably roundabout/rotary stay the fixed clockwise glyph (the exit-
    // ordinal treatment from the same review is a separate, deferred ticket, not this change).
    @Test func untouchedKindsKeepTheirExistingGlyphs() {
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .turn, modifier: .straight)) == "arrow.up")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .turn, modifier: .none)) == "arrow.up")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .endOfRoad, modifier: .none)) == "arrow.up")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .continueOn, modifier: .straight)) == "arrow.up")
        #expect(ManeuverIcon.symbol(for: Maneuver(kind: .continueOn, modifier: .right)) == "arrow.up")
        for modifier in Maneuver.Modifier.allCases {
            #expect(ManeuverIcon.symbol(for: Maneuver(kind: .roundabout, modifier: modifier)) == "arrow.clockwise.circle")
            #expect(ManeuverIcon.symbol(for: Maneuver(kind: .rotary, modifier: modifier)) == "arrow.clockwise.circle")
        }
    }
}
