import Foundation
import Observation
import AuraCore

/// Accumulates a live ride from incoming TrackPoints and recomputes stats as it goes.
/// Observable so SwiftUI views update on each new sample.
@Observable
@MainActor
public final class RideRecorder {
    public private(set) var isRecording = false
    public private(set) var track: [TrackPoint] = []
    public private(set) var stats: RideStats = .zero
    public private(set) var startedAt: Date?
    /// Smoothed live speed for the HUD dial — current speed, not the ride average.
    public private(set) var currentSpeedMetersPerSecond: Double = 0

    private let kind: Ride.Kind
    // Untracked state for the live-speed pipeline; the published value above is what
    // SwiftUI observes.
    private var smoother = SpeedSmoother()
    private var lastPoint: TrackPoint?

    public init(kind: Ride.Kind = .freeRide) { self.kind = kind }

    public func start(at date: Date) {
        track = []
        stats = .zero
        startedAt = date
        isRecording = true
        smoother.reset()
        currentSpeedMetersPerSecond = 0
        lastPoint = nil
    }

    public func record(_ point: TrackPoint) {
        guard isRecording else { return }
        track.append(point)
        stats = RideStatsCalculator.stats(from: track)
        // Doppler speed when present, else position-delta from the previous fix; fed to
        // the smoother at the GPS timestamp (NOT wall-clock) so sim/GPX replay is
        // deterministic.
        let instant = InstantaneousSpeed.between(previous: lastPoint, current: point)
        currentSpeedMetersPerSecond = smoother.add(instant, at: point.timestamp)
        lastPoint = point
    }

    @discardableResult
    public func end(at date: Date, destinationName: String? = nil) -> Ride {
        isRecording = false
        return Ride(kind: kind, startedAt: startedAt ?? date, endedAt: date,
                    track: track, stats: stats, destinationName: destinationName,
                    routeId: nil, destinationPlaceId: nil)
    }
}
