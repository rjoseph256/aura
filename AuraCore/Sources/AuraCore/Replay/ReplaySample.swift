import Foundation

/// One stop on the playback axis: a pause gap between segments, a stationary run inside a
/// segment, or a leg the GPS lost. All three render the same way (spec D3).
public struct ReplayHold: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case paused, stopped, signalLost }
    public var kind: Kind
    /// Ride seconds the hold stands for: the gap between fixes, or the run's summed time.
    public var seconds: TimeInterval
    /// Half-open on the playback axis, in fractions of `playbackDuration`. The sample at
    /// `lowerBound` is the hold; the sample at `upperBound` is moving.
    public var range: Range<Double>

    public init(kind: Kind, seconds: TimeInterval, range: Range<Double>) {
        self.kind = kind; self.seconds = seconds; self.range = range
    }
}

public enum ReplayPhase: Sendable, Equatable {
    case moving
    case hold(ReplayHold.Kind, seconds: TimeInterval)
    case ended
}

/// Everything the map, the band, and the instrument row need for one moment of the ride.
public struct ReplaySample: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Course over the trailing speed window (spec D9); the leg's own course before the
    /// window fills. nil in a hold, at the end, and before the first non-coincident leg.
    public var bearing: Double?
    public var elevation: Double?
    /// Trailing mean over the speed window (spec D5.1). nil → "—".
    public var speedMetersPerSecond: Double?
    public var distanceMeters: Double
    /// Σ normalized leg time up to here: pause gaps excluded, in-segment stops included. A
    /// backwards stamp lengthens the leg after it (spec §3).
    public var seconds: TimeInterval
    public var phase: ReplayPhase

    public init(coordinate: Coordinate, bearing: Double?, elevation: Double?,
                speedMetersPerSecond: Double?, distanceMeters: Double, seconds: TimeInterval,
                phase: ReplayPhase) {
        self.coordinate = coordinate; self.bearing = bearing; self.elevation = elevation
        self.speedMetersPerSecond = speedMetersPerSecond; self.distanceMeters = distanceMeters
        self.seconds = seconds; self.phase = phase
    }
}
