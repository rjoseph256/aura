import Foundation
import AuraCore

/// Keeps the display awake while a ride records. The app conforms a UIKit-backed type;
/// the package stays free of UIKit so it builds on the macOS CI host.
@MainActor
public protocol ScreenWakeControlling: AnyObject {
    func setKeepAwake(_ on: Bool)
}

/// Drives the in-progress-ride Live Activity. The app conforms its ActivityKit-backed
/// controller; the package never imports ActivityKit. `start` takes `Ride.Kind` rather
/// than the app-target `RideActivityMode`, which the conformer maps.
@MainActor
public protocol RideActivityControlling: AnyObject {
    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?)
    func update(stats: RideStats, currentSpeedMetersPerSecond: Double, maneuver: GuidanceUpdate?)
    func end()
}

/// Persists a ride. `RideStore` already satisfies it; tests inject an in-memory or throwing
/// double.
///
/// Since the pause-boundary flush (spec D7) a ride is written more than once — once per pause,
/// then again at End — so `save` is an upsert keyed on `Ride.id`, and an abandoned ride's
/// checkpoint is removed with `discard(id:)`.
@MainActor
public protocol RideSaving: AnyObject {
    func save(_ ride: Ride) throws
    /// Remove a ride previously written by `save`. Used to clear a mid-ride checkpoint when
    /// the ride is abandoned rather than finished, so a backed-out ride leaves no ghost in
    /// History.
    func discard(id: UUID) throws
}

extension RideStore: RideSaving {
    /// `RideStore.delete(id:)` under the seam's name.
    public func discard(id: UUID) throws { try delete(id: id) }
}

/// A collaborator that has to learn about a pause **in the same turn as the tap**.
///
/// The navigate HUD's `GuidanceViewModel` is the one that matters: it consumes guidance events
/// on the main actor, and an arrival can drain between the tap and a SwiftUI `.onChange` body
/// running a turn later. That is the one window where a rider who paused at their destination
/// would have the ride ended under them — precisely what suppressing arrival exists to prevent
/// (spec D7). So the coordinator notifies this synchronously instead.
@MainActor
public protocol RidePauseObserving: AnyObject {
    func rideDidSetPaused(_ paused: Bool)
}

/// Writes a finished ride to Apple Health as a cycling workout. The app conforms a
/// HealthKit-backed type; the package never imports HealthKit. Fire-and-forget: the
/// coordinator calls this and moves on, so a HealthKit failure cannot affect the save.
@MainActor
public protocol WorkoutWriting: AnyObject {
    func writeWorkout(_ data: WorkoutData)
}
