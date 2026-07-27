public struct GPXTrack: Equatable, Sendable {
    /// One entry per `<trkseg>` that produced at least one usable point.
    public var segments: [RideSegment]

    /// Every point in document order. Retained as a flattened accessor because replay
    /// (`GPXLocationPlayer`, `SimulatedLocationProvider`) genuinely wants one stream of
    /// fixes — the pause gap is a gap in *time*, which the schedule already honors.
    ///
    /// Deliberately a manual loop, NOT `segments.flatMap(\.points)`: under concurrent
    /// first-use from multiple threads (e.g. several `@Test` functions calling this
    /// accessor at once), the `flatMap(_:)` + `KeyPath` combination reproducibly returned
    /// corrupted/uninitialized `TrackPoint` data on this toolchain — verified by reverting
    /// to `flatMap(\.points)` and watching `GoldenRideFixtureTests` /
    /// `GoldenRideFixtureRouteTests` / `SimulatedLocationProviderTests` fail with garbage
    /// values when run together, and disappear once reverted back to this loop. Do not
    /// reintroduce `flatMap(\.points)` here without re-verifying under concurrent test
    /// execution (`swift test`, not a single `--filter`).
    public var points: [TrackPoint] {
        var result: [TrackPoint] = []
        for segment in segments { result.append(contentsOf: segment.points) }
        return result
    }

    public init(segments: [RideSegment]) { self.segments = segments }

    /// Single-segment convenience for hand-built tracks. An empty `points` yields zero
    /// segments, matching what the parser returns for a document with no usable trackpoints
    /// — `GPXTrack` is `Equatable`, so the two must not disagree.
    public init(points: [TrackPoint]) {
        self.segments = points.isEmpty ? [] : [RideSegment(points: points)]
    }
}
