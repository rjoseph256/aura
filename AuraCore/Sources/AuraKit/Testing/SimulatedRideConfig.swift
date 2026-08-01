import Foundation

/// Launch-argument contract for the golden-ride harness (ROH-92). Pure parser so it is
/// unit-testable; the app's DEBUG-only call sites read the `current` statics. Unknown or
/// malformed values degrade to "absent" (real location) rather than crashing.
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
        guard !fixture.hasPrefix("-") else { return nil }
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

    /// "-skipOrphanSweep" → suppress the launch and foreground orphan-Live-Activity sweeps
    /// (ROH-124), so a device pass can exercise the sweep inside `start()` on its own. Without
    /// this, the launch sweep fires on the first frame and clears the ghost before a rider could
    /// tap Start, and every later step passes whether or not the other call sites exist.
    /// Deliberately does not reach that third call site.
    public static func suppressesOrphanSweep(arguments: [String]) -> Bool {
        arguments.contains("-skipOrphanSweep")
    }

    /// "-skipLaunchOrphanSweep" → suppress only the launch sweep, leaving the foreground one
    /// live. Without this the foreground call site cannot be positively verified at all: the only
    /// way to reach it is with a ghost that survived launch, and the launch sweep would have
    /// taken it. Implied by `-skipOrphanSweep`, which suppresses both.
    public static func suppressesLaunchOrphanSweep(arguments: [String]) -> Bool {
        arguments.contains("-skipLaunchOrphanSweep") || suppressesOrphanSweep(arguments: arguments)
    }

    /// Process-wide values, parsed once. MainActor confines the lazy statics under Swift 6.
    @MainActor public static let current = parse(arguments: ProcessInfo.processInfo.arguments)
    @MainActor public static let currentForcesInMemoryStore =
        forcesInMemoryStore(arguments: ProcessInfo.processInfo.arguments)
    @MainActor public static let currentSuppressesOrphanSweep =
        suppressesOrphanSweep(arguments: ProcessInfo.processInfo.arguments)
    @MainActor public static let currentSuppressesLaunchOrphanSweep =
        suppressesLaunchOrphanSweep(arguments: ProcessInfo.processInfo.arguments)
}
