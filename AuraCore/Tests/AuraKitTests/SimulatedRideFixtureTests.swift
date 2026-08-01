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
    @MainActor
    @Test func everyKnownNameResolvesToAProvider() throws {
        for name in SimulatedRideFixture.names {
            #expect(try SimulatedRideFixture.provider(named: name, multiplier: 30) != nil,
                    "\(name) is accepted by parse but builds no provider")
        }
    }
}
