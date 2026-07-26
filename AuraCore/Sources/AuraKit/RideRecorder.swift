import Foundation
import Observation
import AuraCore

/// Accumulates a live ride from incoming TrackPoints and recomputes stats as it goes.
/// Observable so SwiftUI views update on each new sample.
@Observable
@MainActor
public final class RideRecorder {
    public private(set) var isRecording = false
    /// The ride so far, split at pauses. Pause does not exist yet, so this is always exactly
    /// one open segment from `start(at:)` onward — the shape lands now so the live map, the
    /// summary and the stats all read segments before anything can create a second one.
    public private(set) var segments: [RideSegment] = []
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

    /// Every recorded point in order. **O(n) and allocating on every access** — bind to a
    /// `let`, never read from a SwiftUI `body`.
    public var flattenedPoints: [TrackPoint] { segments.flatMap(\.points) }

    public func start(at date: Date) {
        segments = [RideSegment(points: [])]
        stats = .zero
        startedAt = date
        isRecording = true
        smoother.reset()
        currentSpeedMetersPerSecond = 0
        lastPoint = nil
    }

    public func record(_ point: TrackPoint) {
        guard isRecording, !segments.isEmpty else { return }
        segments[segments.count - 1].points.append(point)
        stats = RideStatsCalculator.stats(segments: segments)
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
        // Drop trailing empty segments so "no points" has one encoding — zero segments —
        // matching `Ride(track: [])` and the persisted round trip. INTERIOR empties are
        // legal and must survive (spec D6); only the tail goes.
        var closed = segments
        while let last = closed.last, last.points.isEmpty { closed.removeLast() }
        return Ride(kind: kind, startedAt: startedAt ?? date, endedAt: date,
                    segments: closed, stats: stats, destinationName: destinationName,
                    routeId: nil, destinationPlaceId: nil)
    }
}
