import Foundation

/// Every live value the in-progress-ride Live Activity displays, as a pure value.
///
/// This mirrors the app target's `RideActivityAttributes.ContentState`, which is declared inside
/// an `ActivityAttributes` conformer and is therefore invisible to every test target this repo
/// has (spec D2). `ContentState` is derived *solely* from a payload — its memberwise initializer
/// is private — so payload equality implies content equality, which is what lets the controller's
/// dedupe be host-tested here rather than shipped untested there.
public struct RideActivityPayload: Codable, Hashable, Sendable {
    public var distanceMeters: Double
    public var speedMetersPerSecond: Double
    public var elevationGainMeters: Double
    public var turnInstruction: String?
    public var turnDistanceMeters: Double?
    public var turnGlyphSystemName: String?
    public var clock: RideActiveClock

    public init(distanceMeters: Double = 0,
                speedMetersPerSecond: Double = 0,
                elevationGainMeters: Double = 0,
                turnInstruction: String? = nil,
                turnDistanceMeters: Double? = nil,
                turnGlyphSystemName: String? = nil,
                clock: RideActiveClock) {
        self.distanceMeters = distanceMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.elevationGainMeters = elevationGainMeters
        self.turnInstruction = turnInstruction
        self.turnDistanceMeters = turnDistanceMeters
        self.turnGlyphSystemName = turnGlyphSystemName
        self.clock = clock
    }

    /// While paused, carry the previous payload's maneuver rather than the live one.
    ///
    /// `GuidanceViewModel.applyProgress` updates `lastUpdate` before its `isPaused` guard, so a
    /// stationary rider's distance-to-maneuver still drifts with GPS jitter. Rendered, that is a
    /// ticking number beside a frozen clock and a PAUSED pill — two readings of one surface
    /// disagreeing about whether the ride is moving. It would also make every paused navigate
    /// tick a distinct payload and defeat the dedupe.
    public func holdingTurn(from previous: RideActivityPayload?) -> RideActivityPayload {
        guard clock.isPaused, let previous else { return self }
        var held = self
        held.turnInstruction = previous.turnInstruction
        held.turnDistanceMeters = previous.turnDistanceMeters
        held.turnGlyphSystemName = previous.turnGlyphSystemName
        return held
    }
}
