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

    private let kind: Ride.Kind

    public init(kind: Ride.Kind = .freeRide) { self.kind = kind }

    public func start(at date: Date) {
        track = []
        stats = .zero
        startedAt = date
        isRecording = true
    }

    public func record(_ point: TrackPoint) {
        guard isRecording else { return }
        track.append(point)
        stats = RideStatsCalculator.stats(from: track)
    }

    @discardableResult
    public func end(at date: Date) -> Ride {
        isRecording = false
        return Ride(kind: kind, startedAt: startedAt ?? date, endedAt: date,
                    track: track, stats: stats, routeId: nil, destinationPlaceId: nil)
    }
}
