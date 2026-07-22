import Testing
@testable import AuraKit

struct SimulatedRideConfigTests {
    @Test func absentFlagParsesToNil() {
        #expect(SimulatedRideConfig.parse(arguments: ["AppPath", "-someOther", "x"]) == nil)
    }

    @Test func goldenFixtureParsesWithDefaultMultiplier() {
        let config = SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide", "golden"])
        #expect(config == SimulatedRideConfig(fixture: "golden", speedMultiplier: 30))
    }

    @Test func explicitMultiplierOverridesDefault() {
        let config = SimulatedRideConfig.parse(
            arguments: ["App", "-auraSimulatedRide", "golden", "-auraSimulatedRideMultiplier", "60"])
        #expect(config?.speedMultiplier == 60)
    }

    @Test func malformedMultiplierFallsBackToDefault() {
        let config = SimulatedRideConfig.parse(
            arguments: ["App", "-auraSimulatedRide", "golden", "-auraSimulatedRideMultiplier", "fast"])
        #expect(config?.speedMultiplier == 30)
    }

    @Test func nonPositiveMultiplierFallsBackToDefault() {
        let config = SimulatedRideConfig.parse(
            arguments: ["App", "-auraSimulatedRide", "golden", "-auraSimulatedRideMultiplier", "0"])
        #expect(config?.speedMultiplier == 30)
    }

    @Test func missingFixtureNameParsesToNil() {
        #expect(SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide"]) == nil)
    }

    @Test func inMemoryStoreFlag() {
        #expect(SimulatedRideConfig.forcesInMemoryStore(arguments: ["App", "-auraInMemoryRideStore"]))
        #expect(!SimulatedRideConfig.forcesInMemoryStore(arguments: ["App"]))
    }
}
