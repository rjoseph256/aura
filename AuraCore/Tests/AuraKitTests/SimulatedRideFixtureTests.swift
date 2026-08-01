import Testing
@testable import AuraKit

struct SimulatedRideFixtureTests {
    @Test func knownNamesAreTheTwoBundledFixtures() {
        #expect(SimulatedRideFixture.isKnown("golden"))
        #expect(SimulatedRideFixture.isKnown("paused"))
    }

    @Test func unknownNameIsNotKnown() {
        // The typo case the validation exists for.
        #expect(!SimulatedRideFixture.isKnown("pasued"))
        #expect(!SimulatedRideFixture.isKnown(""))
    }

    @MainActor
    @Test func providerResolvesBothFixturesAndNilsAnUnknownOne() throws {
        #expect(try SimulatedRideFixture.provider(named: "golden", multiplier: 30) != nil)
        #expect(try SimulatedRideFixture.provider(named: "paused", multiplier: 30) != nil)
        #expect(try SimulatedRideFixture.provider(named: "pasued", multiplier: 30) == nil)
    }

    /// The invariant the two-sources-of-truth version of this file could violate: a name that
    /// `parse` accepts but the lookup cannot build turns the harness on with no ride stream,
    /// which is the half-harnessed-on-real-GPS state D1 exists to prevent — reached from the
    /// other direction.
    ///
    /// The falsifiable half is `parse`, not the lookup: `provider(named:)` returns a
    /// non-optional factory's result, so `!= nil` for a key drawn from `names` holds by
    /// construction. What can break is `parse` validating against anything other than this
    /// table. The build is still exercised inside the loop — the factory throws if a known
    /// fixture's GPX is not bundled, so a packaging regression fails here for every registered
    /// name rather than only the two a sibling test spells out.
    @MainActor
    @Test func parseAcceptsEveryRegisteredFixtureName() throws {
        for name in SimulatedRideFixture.names {
            let config = SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide", name])
            #expect(config?.fixture == name,
                    "\(name) is in the registry but `parse` does not accept it")
            _ = try SimulatedRideFixture.provider(named: name, multiplier: 30)
        }
    }
}
