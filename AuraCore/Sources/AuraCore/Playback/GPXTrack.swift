public struct GPXTrack: Equatable, Sendable {
    /// One entry per `<trkseg>` that produced at least one usable point.
    public var segments: [RideSegment]

    /// Every point in document order. Retained as a flattened accessor because replay
    /// (`GPXLocationPlayer`, `SimulatedLocationProvider`) genuinely wants one stream of
    /// fixes — the pause gap is a gap in *time*, which the schedule already honors.
    ///
    /// **O(n), and it allocates a fresh array on every access.** Bind it to a `let` before
    /// use rather than reading it repeatedly.
    public var points: [TrackPoint] {
        segments.flatMap(\.points)
    }

    public init(segments: [RideSegment]) { self.segments = segments }

    /// Single-segment convenience for hand-built tracks. An empty `points` yields zero
    /// segments, matching what the parser returns for a document with no usable trackpoints
    /// — `GPXTrack` is `Equatable`, so the two must not disagree.
    public init(points: [TrackPoint]) {
        self.segments = points.isEmpty ? [] : [RideSegment(points: points)]
    }
}
