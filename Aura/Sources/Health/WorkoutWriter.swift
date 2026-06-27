import Foundation
import HealthKit
import CoreLocation
import os
import AuraCore
import AuraKit

/// The HealthKit implementation of the `WorkoutWriting` seam. A shared singleton,
/// mirroring `RideLiveActivityController.shared`: the coordinator (injected at both
/// HUDs) and the Settings opt-in row use the same instance and one process-global
/// authorization. Fire-and-forget — a failure here never affects the ride save.
@MainActor
final class WorkoutWriter: WorkoutWriting {
    static let shared = WorkoutWriter()
    private init() {}

    enum AuthorizationResult { case authorized, denied, unavailable }

    private let healthStore = HKHealthStore()
    private let log = Logger(subsystem: "app.aura.ios", category: "HealthKit")

    private var shareTypes: Set<HKSampleType> {
        [HKWorkoutType.workoutType(),
         HKQuantityType(.distanceCycling),
         HKSeriesType.workoutRoute()]
    }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests write-only authorization for the cycling-workout types. Called from
    /// Settings when the rider turns the opt-in on. Honest about partial grants: the
    /// load-bearing `distanceCycling` share must also be authorized, not just the
    /// workout type, since HealthKit authorization is per-type.
    func requestAuthorization() async -> AuthorizationResult {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        do {
            try await healthStore.requestAuthorization(toShare: shareTypes, read: [])
        } catch {
            log.error("HealthKit authorization failed: \(error.localizedDescription)")
            return .unavailable
        }
        let workoutOK = healthStore.authorizationStatus(for: HKWorkoutType.workoutType())
            == .sharingAuthorized
        let distanceOK = healthStore.authorizationStatus(for: HKQuantityType(.distanceCycling))
            == .sharingAuthorized
        return (workoutOK && distanceOK) ? .authorized : .denied
    }

    // MARK: WorkoutWriting

    func writeWorkout(_ data: WorkoutData) {
        guard HKHealthStore.isHealthDataAvailable(),
              healthStore.authorizationStatus(for: HKWorkoutType.workoutType()) == .sharingAuthorized
        else { return }

        Task { await self.write(data) }
    }

    private func write(_ data: WorkoutData) async {
        do {
            let config = HKWorkoutConfiguration()
            config.activityType = .cycling
            config.locationType = .outdoor

            let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config,
                                           device: .local())
            try await builder.beginCollection(at: data.start)

            let distance = HKQuantity(unit: .meter(), doubleValue: max(0, data.distanceMeters))
            let sample = HKQuantitySample(type: HKQuantityType(.distanceCycling),
                                          quantity: distance, start: data.start, end: data.end)
            try await builder.addSamples([sample])
            try await builder.addMetadata([HKMetadataKeyExternalUUID: data.externalID.uuidString])
            try await builder.endCollection(at: data.end)

            let workout: HKWorkout = try await withCheckedThrowingContinuation { continuation in
                builder.finishWorkout { workout, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let workout {
                        continuation.resume(returning: workout)
                    } else {
                        continuation.resume(throwing: WorkoutWriterError.finishWorkoutReturnedNil)
                    }
                }
            }

            let locations = WorkoutRouteLocations.clLocations(from: data.route)
            guard !locations.isEmpty else { return }
            let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
            try await routeBuilder.insertRouteData(locations)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                routeBuilder.finishRoute(with: workout, metadata: nil) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            log.error("HealthKit workout write failed: \(error.localizedDescription)")
        }
    }
}

private enum WorkoutWriterError: Error {
    case finishWorkoutReturnedNil
}
