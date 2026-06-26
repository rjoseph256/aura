import Foundation

/// One turn-by-turn progress update, decoded from whatever engine drives guidance
/// (Mapbox Navigation v3 today; a self-hosted engine later). Pure and
/// engine-independent — carries only the raw numbers the HUD needs, never an SDK type.
public struct GuidanceUpdate: Equatable, Sendable {
    /// Remaining distance, in meters, to the upcoming maneuver.
    public var distanceToManeuverMeters: Double
    /// Human-readable instruction for the upcoming maneuver, e.g. "Right onto Penn Ave".
    public var instruction: String
    /// Whole-route distance remaining to the destination, in meters. nil until known.
    public var distanceRemainingMeters: Double?
    /// Whole-route time remaining to the destination, in seconds. ETA = now + this.
    public var durationRemainingSeconds: Double?
    /// The road the rider is currently on, e.g. "Penn Ave". nil when the engine has no
    /// name for the current step.
    public var currentStreetName: String?

    public init(distanceToManeuverMeters: Double,
                instruction: String,
                distanceRemainingMeters: Double? = nil,
                durationRemainingSeconds: Double? = nil,
                currentStreetName: String? = nil) {
        self.distanceToManeuverMeters = distanceToManeuverMeters
        self.instruction = instruction
        self.distanceRemainingMeters = distanceRemainingMeters
        self.durationRemainingSeconds = durationRemainingSeconds
        self.currentStreetName = currentStreetName
    }
}

/// Discrete events a guidance engine emits over the life of a navigated ride. A pure
/// value type, so the navigate HUD — and its tests — react to guidance without ever
/// importing the Mapbox SDK.
public enum GuidanceEvent: Equatable, Sendable {
    /// New progress toward the next maneuver → drive the turn card.
    case progress(GuidanceUpdate)
    /// A spoken prompt to read aloud (subject to the rider's mute/voice settings).
    case spokenInstruction(String)
    /// The rider reached the final destination → end the ride.
    case arrivedAtDestination
    /// The engine started recalculating after the rider went off-route → show a cue.
    case rerouting
    /// A new route is available after a reroute → swap the drawn polyline.
    case rerouted([Coordinate])
}

/// The swappable turn-by-turn guidance interface. v1 ships a Mapbox-backed
/// implementation; a self-hosted engine can replace it without touching the HUD,
/// and a scripted double (`ScriptedGuidanceSession`) drives it in tests.
///
/// Lifecycle: `start(route:)` begins active guidance and returns an async stream of
/// `GuidanceEvent`s that stays open until the ride ends; `stop()` tears the session
/// down (and finishes the stream). `@MainActor` because the underlying engines are
/// main-actor isolated, as is the SwiftUI HUD that consumes it.
@MainActor
public protocol GuidanceSession: AnyObject {
    func start(route: Route) async -> AsyncStream<GuidanceEvent>
    func stop()
}

/// A guidance double that emits a fixed script of events then finishes. Lets tests
/// exercise the full event → turn-card pipeline with no Mapbox dependency, mirroring
/// `MockRoutingProvider` for routing.
@MainActor
public final class ScriptedGuidanceSession: GuidanceSession {
    private let script: [GuidanceEvent]
    /// `true` once `stop()` has been called — lets tests assert teardown happened.
    public private(set) var didStop = false

    public init(script: [GuidanceEvent]) {
        self.script = script
    }

    public func start(route: Route) async -> AsyncStream<GuidanceEvent> {
        let script = self.script
        return AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }

    public func stop() { didStop = true }
}
