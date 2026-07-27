import Foundation
import AuraCore

/// Replays a GPX track as a timed stream of TrackPoints. `speedMultiplier > 1` plays faster.
@MainActor
public final class SimulatedLocationProvider: LocationStreaming {
    private let schedule: [GPXLocationPlayer.ScheduledPoint]
    private var task: Task<Void, Never>?

    public init(track: GPXTrack, speedMultiplier: Double = 1) {
        self.schedule = GPXLocationPlayer.schedule(track: track, speedMultiplier: speedMultiplier)
    }

    public func points() -> AsyncStream<TrackPoint> {
        let schedule = self.schedule
        return AsyncStream { continuation in
            let t = Task {
                var last: TimeInterval = 0
                for sp in schedule {
                    let wait = sp.offset - last
                    if wait > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }
                    if Task.isCancelled { break }
                    last = sp.offset
                    continuation.yield(sp.point)
                }
                continuation.finish()
            }
            self.task = t
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    public func stop() { task?.cancel() }
}
