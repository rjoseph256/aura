import Foundation

public enum GPXLocationPlayer {
    public struct ScheduledPoint: Equatable, Sendable {
        public var offset: TimeInterval   // seconds after playback start
        public var point: TrackPoint
    }

    /// Maps each track point to a playback offset relative to the first point.
    /// - speedMultiplier: >1 plays back faster (offsets compressed).
    public static func schedule(track: GPXTrack, speedMultiplier: Double = 1) -> [ScheduledPoint] {
        let points = track.points
        guard let first = points.first else { return [] }
        let m = speedMultiplier > 0 ? speedMultiplier : 1
        return points.map { p in
            ScheduledPoint(offset: p.timestamp.timeIntervalSince(first.timestamp) / m, point: p)
        }
    }
}
