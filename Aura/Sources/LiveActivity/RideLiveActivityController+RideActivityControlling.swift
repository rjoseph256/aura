import Foundation
import AuraCore
import AuraKit

/// Conforms the ActivityKit-backed controller to the AuraKit seam.
/// `update(stats:currentSpeedMetersPerSecond:maneuver:activeClock:)` and `end()` already
/// match; this adds the `start(kind:…)` overload that maps the AuraCore `Ride.Kind` onto the
/// app-target `RideActivityMode`.
extension RideLiveActivityController: RideActivityControlling {
    func start(kind: Ride.Kind, startedAt: Date, units: DistanceUnits, destinationName: String?) {
        let mode: RideActivityMode = (kind == .navigate) ? .navigate : .freeRide
        start(mode: mode, startedAt: startedAt, units: units, destinationName: destinationName)
    }
}
