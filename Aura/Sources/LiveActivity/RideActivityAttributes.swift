import ActivityKit
import Foundation
import AuraKit

/// Whether the in-progress ride is a free ride or a turn-by-turn navigated ride.
/// Static for the life of an activity — a ride doesn't switch mode mid-flight.
public enum RideActivityMode: String, Codable, Hashable, Sendable {
    case freeRide
    case navigate
}

/// The data contract for the in-progress-ride Live Activity, shared by the app
/// (which starts / updates / ends it) and the widget extension (which renders it on
/// the Lock Screen and in the Dynamic Island).
///
/// `attributes` are fixed when the ride starts; `ContentState` carries the live values
/// that change as the ride progresses. The state is deliberately small — it is
/// re-serialized on every update — and holds raw numbers, not pre-formatted strings,
/// for two reasons: the widget formats them unit-aware with `RideStatsFormatter` so the
/// activity honors the distance-units setting, and the elapsed clock ticks on-device via
/// `Text(_, style: .timer)` from `startedAt` rather than being pushed every second.
public struct RideActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        /// Distance covered so far, in meters.
        public var distanceMeters: Double
        /// Speed in meters per second (the ride's average — the free-ride hero stat).
        public var speedMetersPerSecond: Double
        /// Elevation gained so far, in meters.
        public var elevationGainMeters: Double
        /// Next-maneuver instruction, e.g. "Right onto Penn Ave". `nil` in free ride, or
        /// before guidance has reported a turn.
        public var turnInstruction: String?
        /// Distance to the next maneuver, in meters. `nil` when there's no active turn.
        public var turnDistanceMeters: Double?
        /// SF Symbol name for the upcoming maneuver's directional glyph, resolved app-side
        /// via `ManeuverIcon` (so the widget needs no guidance logic). `nil` before a
        /// maneuver / in free ride — the widget falls back to the generic arrow.
        public var turnGlyphSystemName: String?

        public init(distanceMeters: Double = 0,
                    speedMetersPerSecond: Double = 0,
                    elevationGainMeters: Double = 0,
                    turnInstruction: String? = nil,
                    turnDistanceMeters: Double? = nil,
                    turnGlyphSystemName: String? = nil) {
            self.distanceMeters = distanceMeters
            self.speedMetersPerSecond = speedMetersPerSecond
            self.elevationGainMeters = elevationGainMeters
            self.turnInstruction = turnInstruction
            self.turnDistanceMeters = turnDistanceMeters
            self.turnGlyphSystemName = turnGlyphSystemName
        }
    }

    /// Free ride vs. navigate — selects which layout the widget renders.
    public var mode: RideActivityMode
    /// When the ride started; the elapsed clock counts up from here, on-device.
    public var startedAt: Date
    /// The rider's distance-units setting, so the widget formats like the rest of the app.
    public var units: DistanceUnits
    /// Destination name for a navigated ride, shown as context. `nil` for free rides.
    public var destinationName: String?

    public init(mode: RideActivityMode,
                startedAt: Date,
                units: DistanceUnits,
                destinationName: String? = nil) {
        self.mode = mode
        self.startedAt = startedAt
        self.units = units
        self.destinationName = destinationName
    }
}
