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
    func update(stats: RideStats, maneuver: GuidanceUpdate?)
    func end()
}

/// Persists a finished ride. `RideStore` already satisfies it; tests inject an
/// in-memory or throwing double.
@MainActor
public protocol RideSaving: AnyObject {
    func save(_ ride: Ride) throws
}

extension RideStore: RideSaving {}
