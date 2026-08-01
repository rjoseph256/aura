import Foundation

/// Name-to-fixture lookup for the golden-ride harness (ROH-92/93/103). A dictionary here
/// rather than a `switch` in the app target, for the reason `PauseNudgePolicy` already
/// documents: the app target has no test bundle, so a `switch` there is untestable by
/// construction. `SimulatedRideConfig.parse` validates against this, so an unrecognised
/// name turns the harness off everywhere instead of leaving the app half-harnessed on
/// real GPS.
public enum SimulatedRideFixture {
    /// One table, not a Set beside a switch. Two sources of truth here would let a name be
    /// accepted by `SimulatedRideConfig.parse` — turning on all six harness sites — while
    /// building no ride stream, which is the half-harnessed-on-real-GPS state this validation
    /// exists to prevent.
    public static let factories: [String: @MainActor (Double) throws -> SimulatedLocationProvider] = [
        "golden": { try GoldenRideFixture.simulatedProvider(multiplier: $0) },
        "paused": { try PausedGoldenRideFixture.simulatedProvider(multiplier: $0) }
    ]

    /// Every fixture the harness can play, keyed by the launch argument's value.
    public static var names: Set<String> { Set(factories.keys) }

    public static func isKnown(_ name: String) -> Bool { factories[name] != nil }

    /// The replay stream for `name`, or nil if the name is unknown. Throws only when a
    /// known fixture fails to load, which is a packaging regression.
    @MainActor
    public static func provider(named name: String,
                                multiplier: Double) throws -> SimulatedLocationProvider? {
        try factories[name]?(multiplier)
    }
}
