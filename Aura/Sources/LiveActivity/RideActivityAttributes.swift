import ActivityKit
import Foundation
import AuraCore
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
    /// **Every field added here from now on must be `Optional` or defaulted.** `ContentState` is
    /// `Codable` and re-serialized on every update, so an activity in flight across an app update
    /// is decoded by the *new* binary from bytes the *old* one wrote. Swift's synthesized
    /// `init(from:)` uses `decodeIfPresent` for `Optional` stored properties, so a missing key
    /// yields nil; a non-Optional field would throw and strand the activity on its last rendered
    /// content forever. The same applies to `RideActiveClock`'s cases and associated-value labels:
    /// adding is safe, renaming is not. No test target on any platform can see this type, so this
    /// rule is the whole guarantee (ROH-102 spec D2, invariant 6).
    ///
    /// It binds the outer `RideActivityAttributes` stored properties below just as tightly, and
    /// since ROH-124 it also decides whether a ghost can be cleared at all: an activity written by
    /// a previous binary that this one cannot decode never appears in
    /// `Activity<RideActivityAttributes>.activities`, so the orphan sweep cannot see it and
    /// nothing will ever end it.
    public struct ContentState: Codable, Hashable, Sendable {
        /// Distance covered so far, in meters.
        public let distanceMeters: Double
        /// Current smoothed speed in meters per second — not the ride average.
        public let speedMetersPerSecond: Double
        /// Elevation gained so far, in meters.
        public let elevationGainMeters: Double
        /// Next-maneuver instruction, e.g. "Right onto Penn Ave". `nil` in free ride, or
        /// before guidance has reported a turn.
        public let turnInstruction: String?
        /// Distance to the next maneuver, in meters. `nil` when there's no active turn.
        public let turnDistanceMeters: Double?
        /// SF Symbol name for the upcoming maneuver's directional glyph, resolved app-side
        /// via `ManeuverIcon` (so the widget needs no guidance logic). `nil` before a
        /// maneuver / in free ride — the widget falls back to the generic arrow.
        public let turnGlyphSystemName: String?
        /// What the clock displays. `nil` for an activity started before ROH-102 shipped; every
        /// read site falls back to `attributes.startedAt`, which is the pre-ROH-102 behavior.
        public let clock: RideActiveClock?

        /// Nothing outside a payload constructs a `ContentState`, so the dedupe's whole
        /// correctness argument — "payload equality implies content equality" — holds for a type
        /// nothing can test (invariant 5).
        private init(distanceMeters: Double = 0,
                     speedMetersPerSecond: Double = 0,
                     elevationGainMeters: Double = 0,
                     turnInstruction: String? = nil,
                     turnDistanceMeters: Double? = nil,
                     turnGlyphSystemName: String? = nil,
                     clock: RideActiveClock? = nil) {
            self.distanceMeters = distanceMeters
            self.speedMetersPerSecond = speedMetersPerSecond
            self.elevationGainMeters = elevationGainMeters
            self.turnInstruction = turnInstruction
            self.turnDistanceMeters = turnDistanceMeters
            self.turnGlyphSystemName = turnGlyphSystemName
            self.clock = clock
        }

        /// The only initializer production code uses.
        public init(payload: RideActivityPayload) {
            self.init(distanceMeters: payload.distanceMeters,
                      speedMetersPerSecond: payload.speedMetersPerSecond,
                      elevationGainMeters: payload.elevationGainMeters,
                      turnInstruction: payload.turnInstruction,
                      turnDistanceMeters: payload.turnDistanceMeters,
                      turnGlyphSystemName: payload.turnGlyphSystemName,
                      clock: payload.clock)
        }

        public var isPaused: Bool { clock?.isPaused ?? false }

        /// The clock to render, falling back to a wall-clock anchor for an activity that
        /// predates ROH-102.
        public func activeClock(startedAt: Date) -> RideActiveClock {
            clock ?? .running(anchor: startedAt)
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
