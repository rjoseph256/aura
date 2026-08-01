import Foundation

/// Launch-argument contract for the golden-ride harness (ROH-92). Pure parser so it is
/// unit-testable; the app's DEBUG-only call sites read the `current` statics.
/// Unknown or malformed values — including a fixture name `SimulatedRideFixture` does not
/// know — degrade to "absent" (real location) rather than crashing.
public struct SimulatedRideConfig: Equatable, Sendable {
    /// Fixture selector, e.g. "golden" → GoldenRideFixture.
    public let fixture: String
    /// Wall-clock playback compression; ride timestamps (and thus stats) are unaffected.
    public let speedMultiplier: Double

    public static let defaultMultiplier: Double = 30

    public init(fixture: String, speedMultiplier: Double) {
        self.fixture = fixture
        self.speedMultiplier = speedMultiplier
    }

    /// "-auraSimulatedRide <fixture> [-auraSimulatedRideMultiplier <n>]" → config, else nil.
    public static func parse(arguments: [String]) -> SimulatedRideConfig? {
        guard let index = arguments.firstIndex(of: "-auraSimulatedRide"),
              arguments.indices.contains(index + 1) else { return nil }
        let fixture = arguments[index + 1]
        // Spec D1: an unknown name must read as "no harness" at all six `current != nil`
        // sites, not just at the ride stream. Otherwise a typo gives you the in-memory
        // store, the probe, scripted guidance and no ambient location tier, over a ride
        // recording real GPS — which reads in CI as "distance never reached" 90 s later.
        guard !fixture.hasPrefix("-"), SimulatedRideFixture.isKnown(fixture) else { return nil }
        var multiplier = defaultMultiplier
        if let mIndex = arguments.firstIndex(of: "-auraSimulatedRideMultiplier"),
           arguments.indices.contains(mIndex + 1),
           let value = Double(arguments[mIndex + 1]), value > 0 {
            multiplier = value
        }
        return SimulatedRideConfig(fixture: fixture, speedMultiplier: multiplier)
    }

    /// "-auraInMemoryRideStore" → deterministic in-memory RideStore for UI tests.
    public static func forcesInMemoryStore(arguments: [String]) -> Bool {
        arguments.contains("-auraInMemoryRideStore")
    }

    /// Process-wide values, parsed once. MainActor confines the lazy statics under Swift 6.
    @MainActor public static let current = parse(arguments: ProcessInfo.processInfo.arguments)
    @MainActor public static let currentForcesInMemoryStore =
        forcesInMemoryStore(arguments: ProcessInfo.processInfo.arguments)
}
