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

    @Test func parseAcceptsThePausedFixture() {
        let config = SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide", "paused"])
        #expect(config?.fixture == "paused")
    }

    @Test func parseRejectsAnUnknownFixtureName() {
        // Spec D1: an unrecognised name must turn the whole harness off, not just the ride
        // stream — every `current != nil` site keys off it.
        #expect(SimulatedRideConfig.parse(arguments: ["App", "-auraSimulatedRide", "pasued"]) == nil)
    }

    @Test func skipOrphanSweepFlag() {
        #expect(SimulatedRideConfig.suppressesOrphanSweep(arguments: ["App", "-skipOrphanSweep"]))
        #expect(!SimulatedRideConfig.suppressesOrphanSweep(arguments: ["App"]))
        #expect(!SimulatedRideConfig.suppressesOrphanSweep(arguments: ["App", "-skipOrphanSweepX"]))
    }

    /// The launch-only flag must imply neither more nor less than it says: it suppresses the
    /// launch sweep, the broader flag implies it, and neither touches the sweep in `start()`.
    @Test func skipLaunchOrphanSweepFlag() {
        #expect(SimulatedRideConfig.suppressesLaunchOrphanSweep(
            arguments: ["App", "-skipLaunchOrphanSweep"]))
        // The broad flag implies the narrow one.
        #expect(SimulatedRideConfig.suppressesLaunchOrphanSweep(arguments: ["App", "-skipOrphanSweep"]))
        // ...but not the reverse: the foreground sweep stays live under the launch-only flag.
        #expect(!SimulatedRideConfig.suppressesOrphanSweep(arguments: ["App", "-skipLaunchOrphanSweep"]))
        #expect(!SimulatedRideConfig.suppressesLaunchOrphanSweep(arguments: ["App"]))
    }
}
